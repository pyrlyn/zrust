---
status: in progress
priority: P0
complexity: 2
readiness: 80%
agent: Claude Code / claude-fable-5-2
---

# T2. Phase A1: logging shim

Phase A1 of Track A (`docs/AGENT_PROMPT.md` §9). Before any data leaves rustc, the shim has to be a real codegen backend: rustc must load it through `-Zcodegen-backend`, hand it the monomorphized crate, and the shim must see every codegen unit and mono item.

Done means: compiling `tests/run-pass/hello.rs` with the shim as the backend prints each codegen unit with its mono items, then stops with a "not implemented" diagnostic instead of producing a binary.

Check: `zig build test` passes locally and in both CI jobs; it runs `rustc -Zcodegen-backend=<shim> tests/run-pass/hello.rs` and requires the CGU header, the log line for `fn main`, the "not implemented" error and exit code 1.

## Execution plan

1. `shim/src/backend.rs`: `ZrustBackend` implementing `CodegenBackend` with the signatures of the pinned nightly (rustc commit `20fe935d5`): `name`, `target_config`, `target_cpu`, `codegen_crate`, `join_codegen`; `link` stays the default. `codegen_crate` walks `collect_and_partition_mono_items(())`, logs every CGU and item (symbol name, linkage, visibility) to stderr and ends with a fatal diagnostic.
2. `shim/src/lib.rs`: the `extern crate` list and the `__rustc_codegen_backend` entry point.
3. `tests/run-pass/hello.rs`: the first test program.
4. `build.zig`: a `test` step that compiles `hello.rs` through the shim and checks stderr and the exit code.
5. CI: run `zig build test`.

Out of scope: reading MIR, `rustc_public`, ZRMIR (A2); spawning `zrust-codegen`.
