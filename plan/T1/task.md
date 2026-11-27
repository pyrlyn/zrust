---
status: in progress
priority: P0
complexity: 2
readiness: 80%
agent: Claude Code / claude-fable-5-2
---

# T1. Phase A0: toolchain pins and build skeleton

Phase A0 of Track A (`docs/AGENT_PROMPT.md` §9). Every later phase needs a repository where one command builds the two Zig binaries and the Rust shim against the pinned toolchains, and CI that proves it on both supported hosts.

Done means: `zig build` produces `zig-out/bin/zrust`, `zig-out/bin/zrust-codegen` (linked against LLVM 22) and `zig-out/lib/libzrust_shim.{dylib,so}` (linked against the pinned nightly's `rustc_driver`), locally on macOS arm64 and in CI on macOS arm64 and Linux x86_64.

Check: `zig build && zig-out/bin/zrust --version && zig-out/bin/zrust-codegen --version && ls zig-out/lib` succeeds locally and in both CI jobs.

## Execution plan

1. Pins: `rust-toolchain.toml` (`nightly-2026-11-24` with `rust-src`, `rustc-dev`, `llvm-tools`), `mise.toml` (Zig 0.17.1, `conda:llvmdev` 22.1.8).
2. `build.zig` / `build.zig.zon`: build `zrust` and `zrust-codegen`; locate LLVM through `llvm-config`, refuse any major version other than 22; run `cargo build --release --locked` for the shim and install the dylib into `zig-out/lib`.
3. `src/main.zig`, `src/codegen_main.zig`: `--version` only. `zrust-codegen --version` prints the LLVM version it is linked against, which proves headers, linking and rpath.
4. `shim/`: an empty `dylib` crate that only links `rustc_driver`, which proves `rustc-dev` is usable.
5. `.github/workflows/ci.yml`: macOS arm64 and Linux x86_64, build plus the check above.
6. Project files: `plan/`, `roadmap.md`, `ideas.md`, `toolchain.md`.

Out of scope: any `CodegenBackend` code (A1), the ZRMIR format (A2), tests beyond the smoke check.
