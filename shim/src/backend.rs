use std::any::Any;
use std::ffi::OsStr;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use rustc_codegen_ssa::target_features::internal_target_features;
use rustc_codegen_ssa::traits::CodegenBackend;
use rustc_codegen_ssa::{CompiledModules, CrateInfo, TargetConfig};
use rustc_metadata::EncodedMetadata;
use rustc_middle::dep_graph::WorkProductMap;
use rustc_middle::mono::MonoItemPartitions;
use rustc_middle::ty::TyCtxt;
use rustc_session::config::OutputFilenames;
use rustc_session::{EarlySession, IncrCompSession, Session};
use smallvec::{SmallVec, smallvec};

use crate::{encode, zrmir};

/// Path of the `zrust-codegen` executable; the `zrust` driver sets it.
const CODEGEN_ENV: &str = "ZRUST_CODEGEN";
/// When set, the ZRMIR files outlive the compilation.
const KEEP_ENV: &str = "ZRUST_KEEP_ZRMIR";

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
            // Nothing is generated yet, so no `f16`/`f128` support can be promised.
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
        let MonoItemPartitions { codegen_units, .. } = tcx.collect_and_partition_mono_items(());
        let outputs = tcx.output_filenames(());
        let cpu = self.target_cpu(tcx.sess);

        // One `run` for the whole crate: rustc_public's handles are only valid inside it.
        let encoded = rustc_public::rustc_internal::run(tcx, || {
            let mut files = Vec::with_capacity(codegen_units.len());
            for cgu in codegen_units {
                let path = outputs.temp_path_ext_for_cgu("zrmir", cgu.name().as_str());
                let module = encode::encode_cgu(tcx, cgu, cpu.clone());
                if let Err(error) = write_module(&path, &module) {
                    tcx.dcx().fatal(format!("zrust: cannot write {}: {error}", path.display()));
                }
                files.push(path);
            }
            files
        });
        let files = encoded.unwrap_or_else(|error| tcx.dcx().fatal(format!("zrust: {error}")));

        if let Some(codegen) = std::env::var_os(CODEGEN_ENV) {
            check_modules(tcx, &codegen, &files);
        }

        if std::env::var_os(KEEP_ENV).is_some_and(|value| !value.is_empty()) {
            // Dumping ZRMIR was the point of this run, so it succeeds, but says that it produced nothing else.
            let mut warning =
                tcx.dcx().struct_warn("zrust: code generation is not implemented yet, nothing is compiled or linked");
            for file in &files {
                warning.note(format!("wrote {}", file.display()));
            }
            warning.emit();
            return Box::new(());
        }

        for file in &files {
            // A leftover file is harmless, and the error below is the one worth reporting.
            let _ = std::fs::remove_file(file);
        }
        tcx.dcx().fatal("zrust: code generation is not implemented yet")
    }

    fn join_codegen(
        &self,
        _ongoing_codegen: Box<dyn Any>,
        _sess: &Session,
        _incr_comp_session: Option<&IncrCompSession>,
        _outputs: &OutputFilenames,
        _crate_info: &CrateInfo,
    ) -> (CompiledModules, WorkProductMap) {
        (CompiledModules { modules: Vec::new(), allocator_module: None }, WorkProductMap::default())
    }

    fn link(
        &self,
        _sess: &Session,
        _compiled_modules: CompiledModules,
        _crate_info: CrateInfo,
        _metadata: EncodedMetadata,
        _outputs: &OutputFilenames,
    ) {
        // rustc only gets here on a ZRMIR dump (see `codegen_crate`), and no object files exist to link.
    }
}

fn write_module(path: &Path, module: &zrmir::Module) -> std::io::Result<()> {
    let mut file = BufWriter::new(File::create(path)?);
    serde_json::to_writer(&mut file, module)?;
    file.flush()
}

/// Has `zrust-codegen` read back every file, so a mismatch between the encoder and the decoder fails the build that
/// produced it.
fn check_modules(tcx: TyCtxt<'_>, codegen: &OsStr, files: &[PathBuf]) {
    let output = match Command::new(codegen).arg("--check").arg("--in").args(files).output() {
        Ok(output) => output,
        Err(error) => tcx.dcx().fatal(format!("zrust: cannot run {}: {error}", codegen.display())),
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        tcx.dcx().fatal(format!("zrust: {} rejected the ZRMIR ({}):\n{}", codegen.display(), output.status, stderr.trim_end()));
    }
}
