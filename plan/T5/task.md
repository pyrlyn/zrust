---
status: in progress
priority: P0
complexity: 4
readiness: 90%
agent: Claude Code / claude-fable-5-2
---

# T5. Phase A4: control flow and calls

Phase A4 of Track A (`docs/AGENT_PROMPT.md` §9). After A3 a function can only return a constant. This phase makes functions compute: branches, loops, calls, arithmetic and casts on scalars.

Done means: `zrust-codegen` lowers `SwitchInt`, `Call` (direct and through a function pointer), `Assert`, binary and unary operators on integers, floats, `bool` and `char`, the overflow-checked operators, and the casts between scalars; `#![no_std]` programs with recursion (Fibonacci), loops, operators, casts and function pointers build with `zrust`, run, and give the same result as with stock rustc, with and without `-O`. A failed assertion aborts the program with a trap: calling the panic machinery needs constant allocations (A5) and `std` (A6). What stays outside the phase is still refused, never compiled wrongly.

Check: `zig build test` passes locally and in both CI jobs, including `zig build test-run-pass` with the new programs `fib.rs`, `loops.rs`, `ops.rs`, `casts.rs`, `fn_pointers.rs` and `overflow.rs` in `tests/run-pass/`.

## Execution plan

1. Test programs first: write the `no_std` programs above and dump their ZRMIR, with and without `-O`, to see which statements, rvalues and terminators they really contain.
2. `src/codegen/function.zig`: values in their immediate form (`bool` as `i1`); places as a pointer plus a layout, with the `field` projection, which the `(T, bool)` result of a checked operator needs; `SwitchInt`; `Assert` as a branch to a trap; the `assume` statement and the runtime-check operand.
3. `src/codegen/rvalue.zig`: binary, checked and unary operators, casts.
4. `src/codegen/abi.zig`, `src/codegen/module.zig`, `src/codegen/function.zig`: declare a function when something first refers to it, not only when the module defines it; direct and indirect calls with scalar arguments; function pointers (`reify_fn_pointer`).
5. `build.zig`: an `expect-panic` header directive for a program that must die from a failed assertion.
6. Docs: `docs/ZRMIR.md` if the format has to change, `README.md`, `plan/README.md`.

Out of scope: places behind a pointer, aggregates, enums, `pair`, `cast` and `indirect` pass modes, statics and constants with relocations (A5); calling the panic functions on a failed assertion, caller locations, `std` programs (A5–A6); unwinding, `rust-call`, intrinsics (A7).
