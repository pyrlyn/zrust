# Toolchain

## Programs

| Program | How to install | Why here | Source |
| --- | --- | --- | --- |
| zig 0.17.1 | mise (`mise.toml`) | Builds the driver and the backend; runs the build | https://github.com/ziglang/zig |
| LLVM 22.1.8 (`llvm-config`, headers, `libLLVM-22`) | mise (`conda:llvmdev` in `mise.toml`) | Code generation in `zrust-codegen`; the same major version Zig 0.17.1 is built against | https://github.com/llvm/llvm-project |
| rustc, cargo `nightly-2026-11-24` with `rust-src`, `rustc-dev`, `llvm-tools` | rustup (`rust-toolchain.toml`) | Frontend and middle end that load the shim; builds the shim against `rustc_private` crates. A dated nightly with `rustc-dev` is only distributed through rustup | https://github.com/rust-lang/rust |
| rustup | https://rustup.rs | Installs the pinned nightly; the `zrust` driver starts rustc through `rustup run <pinned nightly>` | https://github.com/rust-lang/rustup |

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

## Rust sysroot (`rustc-dev` component)

The shim has no `[dependencies]`: every crate it uses ships with the pinned nightly and is named with `extern crate`.

| Package | Where | Source | Why here |
| --- | --- | --- | --- |
| `rustc_driver`, `rustc_codegen_ssa`, `rustc_middle`, `rustc_session`, `rustc_target`, `rustc_metadata`, `rustc_span`, `rustc_attr_ir`, `smallvec` | global | https://github.com/rust-lang/rust/tree/master/compiler | The `CodegenBackend` interface and the queries behind it |
| `rustc_public`, `rustc_public_bridge` | global | https://github.com/rust-lang/rust/tree/master/compiler/rustc_public | Reading monomorphic MIR, types, layouts and ABIs |
| `serde`, `serde_json` | global | https://github.com/serde-rs/serde, https://github.com/serde-rs/json | Writing ZRMIR as JSON; the copies `rustc_public` is built with |
