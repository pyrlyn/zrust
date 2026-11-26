# Toolchain

## Programs

| Program | How to install | Why here | Source |
| --- | --- | --- | --- |
| zig 0.17.1 | mise (`mise.toml`) | Builds the driver and the backend; runs the build | https://github.com/ziglang/zig |
| LLVM 22.1.8 (`llvm-config`, headers, `libLLVM-22`) | mise (`conda:llvmdev` in `mise.toml`) | Code generation in `zrust-codegen`; the same major version Zig 0.17.1 is built against | https://github.com/llvm/llvm-project |
| rustc, cargo `nightly-2026-11-24` with `rust-src`, `rustc-dev`, `llvm-tools` | rustup (`rust-toolchain.toml`) | Frontend and middle end that load the shim; builds the shim against `rustc_private` crates. A dated nightly with `rustc-dev` is only distributed through rustup | https://github.com/rust-lang/rust |

## mise

| Package | Where | Source | Why here |
| --- | --- | --- | --- |
| `zig` | local | https://github.com/ziglang/zig | Compiler and build system |
| `conda:llvmdev` | local | https://github.com/conda-forge/llvmdev-feedstock | LLVM 22 headers, `llvm-config` and shared library |

## GitHub Actions

| Package | Where | Source | Why here |
| --- | --- | --- | --- |
| `actions/checkout` | local | https://github.com/actions/checkout | Check out the repository in CI |
| `jdx/mise-action` | local | https://github.com/jdx/mise-action | Install the `mise.toml` tools in CI |
