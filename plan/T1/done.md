# T1. Done

`zig build` builds `zrust`, `zrust-codegen` (linked against LLVM 22.1.8) and the `zrust_shim` dylib (linked against `rustc_driver` of `nightly-2026-11-24`). Toolchains are pinned in `rust-toolchain.toml` and `mise.toml`; CI builds and smoke-tests on macOS arm64 and Linux x86_64.

Pull request: https://github.com/pyrlyn/zrust/pull/2

## How it was checked

- Locally on macOS arm64: `zig build && zig-out/bin/zrust --version && zig-out/bin/zrust-codegen --version && ls zig-out/lib` prints `zrust 0.0.0`, `zrust-codegen 0.0.0 (LLVM 22.1.8)` and `libzrust_shim.dylib`.
- CI run https://github.com/pyrlyn/zrust/actions/runs/45892452985: both `build (macos-latest)` and `build (ubuntu-latest)` pass and print the same two version lines (`libzrust_shim.so` on Linux).
- A wrong LLVM is refused: `zig build -Dllvm-config=<LLVM 23 llvm-config>` fails with "reports LLVM 23.1.5, but LLVM 22 is required".
