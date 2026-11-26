use std::any::Any;
use std::ffi::OsStr;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use rustc_codegen_ssa::back::archive::ArArchiveBuilderBuilder;
use rustc_codegen_ssa::back::link::link_binary;
use rustc_codegen_ssa::target_features::internal_target_features;
use rustc_codegen_ssa::traits::CodegenBackend;
use rustc_codegen_ssa::{CompiledModule, CompiledModules, CrateInfo, ModuleKind, TargetConfig};
use rustc_metadata::EncodedMetadata;
use rustc_middle::dep_graph::WorkProductMap;
use rustc_middle::mono::MonoItemPartitions;
use rustc_middle::ty::TyCtxt;
use rustc_session::config::OutputFilenames;
use rustc_session::output::OutputType;
use rustc_session::{EarlySession, IncrCompSession, Session};
use smallvec::{SmallVec, smallvec};

use crate::{encode, zrmir};

/// Path of the `zrust-codegen` executable; the `zrust` driver sets it.
const CODEGEN_ENV: &str = "ZRUST_CODEGEN";
/// When set, the ZRMIR files outlive the compilation.
const KEEP_ENV: &str = "ZRUST_KEEP_ZRMIR";
/// When set, the ZRMIR files are all the compilation produces: no code is generated and nothing is linked.
const ZRMIR_ONLY_ENV: &str = "ZRUST_ZRMIR_ONLY";

pub struct ZrustBackend;

impl CodegenBackend for ZrustBackend {
    fn name(&self) -> &'static str {
        "zrust"
    }

    fn target_config(&self, sess: &EarlySession) -> TargetConfig {
        // Which features the target CPU implies is LLVM's knowledge, and LLVM lives in
        // `zrust-codegen`. Until the shim can ask it, report only what the target's ABI mandates
        // (plus `-Ctarget-feature`): rustc rejects a backend that lacks those, and under-reporting
        // the rest only hides `cfg(target_feature)` fast paths.
        let abi_required = sess.target.abi_required_features().required;
        let internal_target_features = internal_target_features(
            sess,
            |feature| -> SmallVec<[&str; 1]> { smallvec![feature] },
            |feature| {
                abi_required.contains(&feature)
                    // rustc's ABI constraints name only `neon` on hard-float AArch64, but LLVM
                    // always pairs it with `fp-armv8`, and the prebuilt std records `fp-armv8` as
                    // enabled. Crates that disagree on it get an ABI-mismatch warning per dependency.
                    || (feature == "fp-armv8" && abi_required.contains(&"neon"))
            },
        );

        TargetConfig {
            internal_target_features,
            // The code generator refuses the `f16b` format and has never compiled an operation on the others.
            has_reliable_f16: false,
            has_reliable_f16_math: false,
            has_reliable_f16b: false,
            has_reliable_f128: false,
            has_reliable_f128_math: false,
        }
    }

    fn target_cpu(&self, sess: &Session) -> String {
        match sess.opts.cg.target_cpu {
            Some(ref name) => name,
            None => sess.target.cpu.as_ref(),
        }
        .to_owned()
    }

    fn codegen_crate<'tcx>(&self, tcx: TyCtxt<'tcx>) -> Box<dyn Any> {
        // rustc's own target-feature bookkeeping accepts the flag (see `target_config`), but the features never reach
        // LLVM, so code compiled as if they were on would run without them.
        if !tcx.sess.opts.cg.target_feature.is_empty() {
            tcx.dcx().fatal("zrust: `-C target-feature` is not supported yet");
        }

        let MonoItemPartitions { codegen_units, .. } = tcx.collect_and_partition_mono_items(());
        let outputs = tcx.output_filenames(());
        let cpu = self.target_cpu(tcx.sess);

        // One `run` for the whole crate: rustc_public's handles are only valid inside it.
        let encoded = rustc_public::rustc_internal::run(tcx, || {
            let mut units = Vec::with_capacity(codegen_units.len());
            for cgu in codegen_units {
                let name = cgu.name();
                let name = name.as_str();
                let zrmir = outputs.temp_path_ext_for_cgu("zrmir", name);
                let module = encode::encode_cgu(tcx, cgu, cpu.clone());
                if let Err(error) = write_module(&zrmir, &module) {
                    tcx.dcx().fatal(format!("zrust: cannot write {}: {error}", zrmir.display()));
                }
                units.push(Unit { name: name.to_owned(), zrmir, object: outputs.temp_path_for_cgu(OutputType::Object, name) });
            }
            units
        });
        let units = encoded.unwrap_or_else(|error| tcx.dcx().fatal(format!("zrust: {error}")));

        let zrmir_only = is_set(ZRMIR_ONLY_ENV);
        let keep = zrmir_only || is_set(KEEP_ENV);
        let Some(codegen) = std::env::var_os(CODEGEN_ENV) else {
            tcx.dcx().fatal(format!("zrust: {CODEGEN_ENV} is not set; run rustc through the `zrust` driver"))
        };

        // One process per module, one after another. The modules are independent, so this can become a pool.
        let failure = if zrmir_only {
            run_codegen(&codegen, |command| command.arg("--check").arg("--in").args(units.iter().map(|unit| &unit.zrmir)))
                .err()
                .map(|output| format!("zrust: {} rejected the ZRMIR{output}", codegen.display()))
        } else {
            units.iter().find_map(|unit| {
                run_codegen(&codegen, |command| command.arg("--in").arg(&unit.zrmir).arg("--out").arg(&unit.object))
                    .err()
                    .map(|output| format!("zrust: {} could not compile `{}`{output}", codegen.display(), unit.name))
            })
        };

        if !keep {
            for unit in &units {
                // A leftover file is harmless, and a failure to remove it is not worth a diagnostic.
                let _ = std::fs::remove_file(&unit.zrmir);
            }
        }
        if let Some(failure) = failure {
            let mut error = tcx.dcx().struct_fatal(failure);
            if !keep {
                error.note(format!("set {KEEP_ENV}=1 to keep the ZRMIR of the build"));
            }
            error.emit()
        }

        if zrmir_only {
            // Dumping ZRMIR was the point of this run, so it succeeds, but says that it produced nothing else.
            let mut warning = tcx.dcx().struct_warn("zrust: only ZRMIR was asked for, nothing is compiled or linked");
            for unit in &units {
                warning.note(format!("wrote {}", unit.zrmir.display()));
            }
            warning.emit();
            return Box::new(None::<Vec<CompiledModule>>);
        }

        let modules = units.into_iter().map(|unit| CompiledModule {
            name: unit.name,
            kind: ModuleKind::Regular,
            object: Some(unit.object),
            global_asm_object: None,
            dwarf_object: None,
            bytecode: None,
            assembly: None,
            llvm_ir: None,
        });
        Box::new(Some(modules.collect::<Vec<_>>()))
    }

    fn join_codegen(
        &self,
        ongoing_codegen: Box<dyn Any>,
        _sess: &Session,
        _incr_comp_session: Option<&IncrCompSession>,
        _outputs: &OutputFilenames,
        _crate_info: &CrateInfo,
    ) -> (CompiledModules, WorkProductMap) {
        let modules = ongoing_codegen.downcast::<Option<Vec<CompiledModule>>>().expect("the value `codegen_crate` returned");
        // A program with a global allocator needs a module that routes `__rust_alloc` to it; none is generated yet.
        (CompiledModules { modules: modules.unwrap_or_default(), allocator_module: None }, WorkProductMap::default())
    }

    fn link(
        &self,
        sess: &Session,
        compiled_modules: CompiledModules,
        crate_info: CrateInfo,
        metadata: EncodedMetadata,
        outputs: &OutputFilenames,
    ) {
        // A ZRMIR dump has no objects, and linking nothing would leave an empty library or a failed link behind.
        if is_set(ZRMIR_ONLY_ENV) {
            return;
        }
        link_binary(sess, &ArArchiveBuilderBuilder, compiled_modules, crate_info, metadata, outputs, self.name());
    }
}

/// One codegen unit on its way through `zrust-codegen`.
struct Unit {
    name: String,
    zrmir: PathBuf,
    object: PathBuf,
}

fn is_set(variable: &str) -> bool {
    std::env::var_os(variable).is_some_and(|value| !value.is_empty())
}

fn write_module(path: &Path, module: &zrmir::Module) -> std::io::Result<()> {
    let mut file = BufWriter::new(File::create(path)?);
    serde_json::to_writer(&mut file, module)?;
    file.flush()
}

/// Runs `zrust-codegen`. On failure, returns what it has to say, ready to follow the caller's own sentence.
fn run_codegen(codegen: &OsStr, arguments: impl FnOnce(&mut Command) -> &mut Command) -> Result<(), String> {
    let mut command = Command::new(codegen);
    match arguments(&mut command).output() {
        Ok(output) if output.status.success() => Ok(()),
        Ok(output) => Err(format!(" ({}):\n{}", output.status, String::from_utf8_lossy(&output.stderr).trim_end())),
        Err(error) => Err(format!(": it cannot be run: {error}")),
    }
}
