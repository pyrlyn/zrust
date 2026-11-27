# T2. Done

`zrust_shim` now implements `CodegenBackend`. `rustc -Zcodegen-backend=<shim>` loads it, the shim reports the target features rustc needs to accept the target, logs every codegen unit and mono item (path, symbol name, linkage, visibility) to stderr and stops with the diagnostic `zrust: code generation is not implemented yet`. `zig build test` compiles `tests/run-pass/hello.rs` through the shim and checks that output.

Pull request: https://github.com/pyrlyn/zrust/pull/3

## How it was checked

- Locally on macOS arm64: `zig build test` passes; changing one of the expected stderr lines makes it fail.
- CI run https://github.com/pyrlyn/zrust/actions/runs/45899534546: `build (macos-latest)` and `build (ubuntu-latest)` both pass, including the `zig build test` step.

## Known gaps

- `cfg(target_feature)` is under-reported: only the features the target ABI requires are listed. Features implied by the target CPU need LLVM, which lives on the Zig side.
- `f16` and `f128` are reported as unreliable.
- The log goes to stderr unconditionally; phase A2 replaces it with ZRMIR files.
