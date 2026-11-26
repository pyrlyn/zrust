use std::any::Any;

use rustc_codegen_ssa::target_features::internal_target_features;
use rustc_codegen_ssa::traits::CodegenBackend;
use rustc_codegen_ssa::{CompiledModules, CrateInfo, TargetConfig};
use rustc_middle::dep_graph::WorkProductMap;
use rustc_middle::mono::MonoItemPartitions;
use rustc_middle::ty::TyCtxt;
use rustc_middle::ty::print::with_no_trimmed_paths;
use rustc_session::config::OutputFilenames;
use rustc_session::{EarlySession, IncrCompSession, Session};
use smallvec::{SmallVec, smallvec};

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

        for cgu in codegen_units {
            let items = cgu.items_in_deterministic_order(tcx);
            eprintln!("zrust: cgu {} ({} items)", cgu.name(), items.len());
            for (item, data) in &items {
                // Trimmed paths drop the modules (`lang_start` for `std::rt::lang_start`); the log
                // has to name items unambiguously.
                let path = with_no_trimmed_paths!(item.to_string());
                eprintln!(
                    "zrust:   {path} [{}, {:?}, {:?}]",
                    item.symbol_name(tcx),
                    data.linkage,
                    data.visibility,
                );
            }
        }

        tcx.dcx().fatal("zrust: code generation is not implemented yet")
    }

    fn join_codegen(
        &self,
        _ongoing_codegen: Box<dyn Any>,
        sess: &Session,
        _incr_comp_session: Option<&IncrCompSession>,
        _outputs: &OutputFilenames,
        _crate_info: &CrateInfo,
    ) -> (CompiledModules, WorkProductMap) {
        // `codegen_crate` never returns, so rustc cannot get here; a diagnostic beats a panic if
        // that changes.
        sess.dcx().fatal("zrust: code generation is not implemented yet")
    }
}
