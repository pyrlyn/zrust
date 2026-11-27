---
status: in progress
priority: P0
complexity: 5
readiness: 90%
agent: Claude Code / claude-fable-5-2
---

# T7. Phase A5, part 2: statics, constants with pointers, slices and str

The second part of phase A5 of Track A (`docs/AGENT_PROMPT.md` §9). After the first part every pointer is thin and no constant may hold one, so a program cannot have a static, a string literal or a slice. This part gives the code generator global memory and pointers that carry a length.

Done means: `zrust-codegen` defines the statics of a unit and declares the ones it only mentions; lowers constants and initializers that hold pointers to anonymous memory, to functions and to statics; lowers wide pointers to slices and `str` as a pair of a data pointer and a length: `deref`, `index` and `constant_index` behind them, `ref` and `address_of` of what they point at, the `ptr_metadata` operator (the pinned rustc emits it where older ones had the `len` rvalue, which stays refused), the `subslice` projection of a slice, a struct whose last field is a slice or a `str`, the `raw_ptr` aggregate, the `unsize` cast of an array to a slice, also as the tail of a struct, and the pointer casts and transmutes between wide pointers and from a wide pointer to a thin one. `#![no_std]` programs that use these build with `zrust`, run, and give the same result as with stock rustc, with and without `-O`. What stays outside the part is still refused, never compiled wrongly.

Check: `zig build test` passes locally and in both CI jobs, including `zig build test-run-pass` with the new programs `globals.rs`, `slices.rs`, `strings.rs` and `puts.rs` in `tests/run-pass/`.

## Execution plan

1. Test programs first: write the `no_std` programs above, check them with stock rustc, and dump their ZRMIR, with and without `-O`, to see which constructs they really contain.
2. `src/codegen/module.zig`: a global for every static symbol, created before any body is lowered and initialized afterwards, so that statics may point at each other; anonymous allocations become private globals, made once per allocation.
3. `src/codegen/consts.zig`: memory with relocations becomes a packed struct of byte runs and pointers; a scalar constant that is a pointer becomes the address it relocates to.
4. `src/codegen/function.zig`: a place may carry the metadata of the wide pointer it came from; projections, `ref`, `address_of`, `len`, `ptr_metadata`, the `raw_ptr` aggregate and the casts above.
5. Docs: `docs/ZRMIR.md` if the format has to change, `README.md`, `plan/README.md`.

Out of scope, the later parts of A5: enums and the `cmp` operator; drops, vtables, `dyn Trait` and the `unsize` cast to one; calling the panic functions on a failed assertion. Also out: thread-local statics, `type_id` relocations, the `subslice` projection of an array, comparing wide pointers, unsized arguments, intrinsics.
