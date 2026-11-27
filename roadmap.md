# Roadmap

Approved work that is not in `plan/` yet. Phases and their exit criteria are defined in [`docs/AGENT_PROMPT.md`](docs/AGENT_PROMPT.md) §9.

- **Phase A5 — aggregates and references**, the parts after the first two (structs, tuples, arrays and thin references; statics, constants with pointers, slices and `str`):
  - enums: niche and tagged layouts, `Discriminant`, `SetDiscriminant`, `Downcast`, and the `cmp` operator, whose result is one;
  - drops through `drop_in_place`, vtables and `dyn Trait` calls, and the panic functions a failed assertion calls.
- **Phase A6 — std hello world.** Entry shim, allocator shim, linking against the prebuilt std with `panic=abort`.
- **Phase A7 — real-world semantics.** Unwinding, remaining intrinsics, collections, closures, debug info, optimized pipelines; 90% of the rustc UI subset.
- **Phase A8 — crates and performance.** `zrust cargo build` on serde, regex and ripgrep; parallel CGU codegen.
