# T3. Done

ZRMIR version 1 exists. `docs/ZRMIR.md` specifies it: one JSON file per codegen unit in a canonical form, with tables for files, spans, types, layouts, function ABIs, global allocations and symbols, then the functions with their MIR bodies, the statics and the entry point. The shim encodes every codegen unit through `rustc_public`; `zrust-codegen --check` decodes each file strictly, validates what the JSON shape cannot express and requires that encoding the module again gives the same bytes. The driver gained `zrust rustc`, `zrust build` and `zrust dump-zrmir`. A compilation still ends with `zrust: code generation is not implemented yet`, unless `ZRUST_KEEP_ZRMIR` asks for the dump.

Pull request: https://github.com/pyrlyn/zrust/pull/4

## How it was checked

- Locally on macOS arm64: `zig build test` passes (30 steps): the decoder's seven unit tests, the dump of every `tests/run-pass/*.rs` and of the shim crate (2035 lines, 16 codegen units, 48 MB of ZRMIR), each with and without `-O`, and the two failure paths.
- `ZRUST_KEEP_ZRMIR=1 zig-out/bin/zrust build tests/run-pass/hello.rs && zig-out/bin/zrust-codegen --in target/*.zrmir --check` exits 0 and reports `9 functions, 0 statics, 44 types, 1 allocs`.
- CI run https://github.com/pyrlyn/zrust/actions/runs/45904285038: `build (macos-latest)` and `build (ubuntu-latest)` both pass, including `zig build test`.

## Known gaps

The format's gaps are listed in `docs/ZRMIR.md` §10 with the phase that fills each. Beyond the format:

- Nothing compares the Rust and the Zig declarations of the format directly; they are checked against each other only through the values that occur in the dumped files.
- `zrust cargo` is not implemented.
- `rustfmt` is not among the pinned toolchain's components, so the Rust code is not formatter-checked.
- The intermediate commits of the pull request were not built one by one; only its final tree was tested.
