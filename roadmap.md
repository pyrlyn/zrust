# Roadmap

Approved work that is not in `plan/` yet. Phases and their exit criteria are defined in [`docs/AGENT_PROMPT.md`](docs/AGENT_PROMPT.md) §9.

- **Phase A4 — control flow and calls.** `Goto`, `SwitchInt`, `Call`, `Assert`, checked arithmetic, casts, function pointers.
- **Phase A5 — aggregates and references.** Structs, tuples, enums, arrays and slices, references, drops, statics, constant allocations, vtables and `dyn Trait`.
- **Phase A6 — std hello world.** Entry shim, allocator shim, linking against the prebuilt std with `panic=abort`.
- **Phase A7 — real-world semantics.** Unwinding, remaining intrinsics, collections, closures, debug info, optimized pipelines; 90% of the rustc UI subset.
- **Phase A8 — crates and performance.** `zrust cargo build` on serde, regex and ripgrep; parallel CGU codegen.
