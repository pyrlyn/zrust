---
status: in progress
priority: P0
complexity: 4
readiness: 90%
agent: Claude Code / claude-fable-5-2
---

# T4. Phase A3: first code

Phase A3 of Track A (`docs/AGENT_PROMPT.md` §9). Until now the shim wrote ZRMIR and stopped. This phase closes the loop for the smallest program there is: `zrust-codegen` turns a ZRMIR module into an object file through LLVM, the shim hands the objects to rustc, and rustc links them as it links its own.

Done means: `zrust-codegen --in X.zrmir --out X.o` lowers a module to LLVM IR, verifies it, runs the pass pipeline of its optimization level and writes an object; the shim runs it for every codegen unit and returns the objects from `join_codegen`, so rustc's own `link` produces the binary; a `#![no_std] #![no_main]` program whose `main` returns 42 exits with 42, with and without `-O`; anything outside the phase (calls, aggregates, operators, …) is refused with an error that names the function and the construct, never compiled wrongly.

Check: `zig build test` passes locally and in both CI jobs, including `zig build test-run-pass`, which builds `tests/run-pass/exit42.rs` with `zrust`, runs it and expects exit code 42 (`zig-out/bin/zrust build tests/run-pass/exit42.rs -C panic=abort -C default-linker-libraries -o a.out; ./a.out; echo $?` prints `42`).

## Execution plan

1. ZRMIR version 2: `target.relocation_model` and `target.features`, which LLVM's target machine needs and version 1 did not carry. `docs/ZRMIR.md`, `shim/src/zrmir.rs`, `shim/src/encode.rs`, `src/zrmir/schema.zig`, `src/zrmir/tests.zig`.
2. LLVM: more of the LLVM-C API in `src/llvm/c.h`; `src/codegen/target.zig` creates the target machine a module asks for; `src/codegen/emit.zig` verifies a module, runs the passes and writes the object or the textual IR.
3. `src/codegen/`: `types.zig` (layout to LLVM type), `abi.zig` (function ABI to LLVM signature), `consts.zig` (constant bytes to LLVM constant), `function.zig` (locals as allocas, `Assign` of `Use`, `Return`, `Goto`, `Unreachable`), `module.zig` (`lowerModule`). Everything else returns an "is not supported yet" error with its place.
4. `src/codegen_main.zig`: `--in`, `--out`, `--emit=obj|llvm-ir` next to `--check`.
5. `shim/src/backend.rs`: run `zrust-codegen` per codegen unit, return `CompiledModule`s, drop the `link` override. `ZRUST_KEEP_ZRMIR` only keeps the files; `ZRUST_ZRMIR_ONLY` is the dump mode of phase A2. `src/main.zig`: `dump-zrmir` sets the latter.
6. Tests: header directives in `tests/run-pass/*.rs` (`expect-stdout`, `expect-exit`, `rustc-flags`, `unsupported`), `zig build test-run-pass` in `build.zig` (build with `zrust`, run, compare; the same expectations against stock rustc), a refusal test for the programs marked `unsupported`.
7. Docs: `docs/ZRMIR.md`, `README.md`, `plan/README.md`.

Out of scope: calls, `SwitchInt`, operators and casts (A4); places with projections, aggregates, `ScalarPair` and `Cast` pass modes, statics and relocations in constants (A5); `std` programs, the entry and allocator shims (A6); unwinding and debug info (A7); codegen units in parallel (A8).
