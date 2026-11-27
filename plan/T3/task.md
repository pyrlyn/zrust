---
status: in progress
priority: P0
complexity: 4
readiness: 90%
agent: Claude Code / claude-fable-5-2
---

# T3. Phase A2: ZRMIR dump

Phase A2 of Track A (`docs/AGENT_PROMPT.md` §9). Everything `zrust-codegen` will ever know about a crate has to cross a process boundary, so before any code is generated the interchange format has to exist: the shim writes what rustc knows about each codegen unit into a ZRMIR file, and the Zig side reads it back strictly.

Done means: `docs/ZRMIR.md` specifies the format; the shim encodes types, layouts, function ABIs, bodies, constants and global allocations of every codegen unit; `zrust-codegen --check` decodes, validates and re-encodes each file byte for byte; this holds for every program in `tests/run-pass/` and for a crate of more than 2000 lines (the shim itself), with and without optimizations.

Check: `zig build test` passes locally and in both CI jobs; it dumps every `tests/run-pass/*.rs` and `shim/src/lib.rs`, each with and without `-O`, with `zrust-codegen --check` run on every file by the shim, and `ZRUST_KEEP_ZRMIR=1 zig-out/bin/zrust build tests/run-pass/hello.rs && zig-out/bin/zrust-codegen --in target/*.zrmir --check` exits 0.

## Execution plan

1. `docs/ZRMIR.md`: the format, version 1, as JSON in a canonical form.
2. `shim/src/zrmir.rs`: the data model as serde types. `shim/src/encode.rs`: one codegen unit to one module, read through `rustc_public` and, where it has no answer, the rustc queries behind it.
3. `shim/src/backend.rs`: write one file per codegen unit, have `zrust-codegen --check` read them back when the driver names it in `ZRUST_CODEGEN`, keep the files when `ZRUST_KEEP_ZRMIR` is set, otherwise delete them and stop with the "not implemented" diagnostic.
4. `src/zrmir/`: the same data model in Zig (`schema.zig`), a strict `std.json` decoder with file positions (`codec.zig`), a validator for everything the types cannot express (`validate.zig`), unit tests for the rejections (`tests.zig`).
5. `src/codegen_main.zig`: `zrust-codegen --check --in <files>`.
6. `src/main.zig`: the driver commands `zrust rustc`, `zrust build` and `zrust dump-zrmir`.
7. `tests/run-pass/`: programs that cover enums, traits and `dyn`, closures, statics, collections and arithmetic. `build.zig`: dump all of them and the shim crate in `zig build test`.

Out of scope: generating code (A3 onwards); `zrust cargo`; a binary encoding; the `allocator_shim` table and the `lang_start` reference of `entry` (A6).
