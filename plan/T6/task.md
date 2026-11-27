---
status: in progress
priority: P0
complexity: 5
readiness: 5%
agent: Claude Code / claude-fable-5-2
---

# T6. Phase A5, part 1: structs, tuples, arrays and references

Phase A5 of Track A (`docs/AGENT_PROMPT.md` §9) is too large for one pull request, so it is done in parts; the others are in `roadmap.md`. After A4 a value is one scalar. This part gives the code generator values that live in memory and pointers to them.

Done means: `zrust-codegen` lowers values of any sized layout (a scalar, a pair of scalars, bytes in memory); the place projections `deref`, `field`, `index` and `constant_index` on structs, tuples, unions and arrays behind thin pointers; the rvalues `ref`, `address_of`, `aggregate` (array, tuple, struct, union), `repeat` and `copy_for_deref`; the pointer operator `offset`; the `copy_nonoverlapping` statement; constants that are not scalars, as long as they hold no pointers; and the pass modes `pair`, `cast` and `indirect`, for arguments and results, in the Rust and the C ABI. `#![no_std]` programs that use these build with `zrust`, run, and give the same result as with stock rustc, with and without `-O`. What stays outside the part is still refused, never compiled wrongly.

Check: `zig build test` passes locally and in both CI jobs, including `zig build test-run-pass` with the new programs `structs.rs`, `tuples.rs`, `arrays.rs`, `references.rs`, `c_abi.rs` and `bounds.rs` in `tests/run-pass/`.

## Execution plan

1. Test programs first: write the `no_std` programs above and dump their ZRMIR, with and without `-O`, to see which constructs they really contain.
2. `src/codegen/function.zig`: every local gets a stack slot, zero-sized ones too, so every place has an address; a value is nothing, a scalar, or a place to copy from; assignments of values in memory are a `memcpy`; the projections; the new rvalues and the statement.
3. `src/codegen/abi.zig`: the pass modes `pair`, `cast` (prefix registers and a uniform rest, as rustc's LLVM backend spells them) and `indirect` (`sret` for a result, `byval` for `on_stack`), on both sides of a call.
4. `src/codegen/consts.zig`: a constant that is not a scalar becomes a private global the value is copied from.
5. `src/codegen/rvalue.zig`: `offset`. `cmp` moved to the enums part: its result is `Ordering`, and nothing can look at one before enums are lowered.
6. Docs: `docs/ZRMIR.md` if the format has to change, `README.md`, `plan/README.md`.

Out of scope, the later parts of A5: wide pointers, slices, `str`, unsizing casts, `len`, statics and constants with relocations; enums (`discriminant`, `set_discriminant`, `downcast`); drops, vtables and `dyn Trait`; calling the panic functions on a failed assertion. Also out: intrinsics, `subslice` and `opaque_cast` projections, vectors, unsized locals.
