# Ideas

Not approved yet. Nothing here moves to `roadmap.md` or `plan/` without the owner's approval.

- **Rust-to-Rust printer** (`zrust build --emit=rust-mir`): write monomorphized MIR back out as low-level compilable Rust, as a debugging aid and a differential oracle. Described as optional in `docs/AGENT_PROMPT.md` §9; possible any time after phase A5.
- **In-process codegen** through a C ABI instead of a subprocess per CGU. Only viable if the Zig side stops loading libLLVM (emits bitcode itself) or the two LLVM versions match (`docs/AGENT_PROMPT.md` §3).
- **Track B**: a from-scratch frontend in Zig that also produces ZRMIR (`docs/PLAN.md` §4).
