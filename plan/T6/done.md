# T6. Done

ZRust compiles programs whose values live in memory. `zrust-codegen` lowers values of any sized layout: a type without a size reads as nothing, a scalar is loaded, anything else is `[size x i8]` that stays where it is and is assigned with `memcpy`. A place is an address (a pointer and what it is known to be aligned to), a type and a layout, and every local has a stack slot. On top of that: the projections `deref` of a thin pointer, `field` of a struct, a tuple or a union, `index` and `constant_index` of an array; the rvalues `ref`, `address_of`, `aggregate` (array, tuple, struct, union), `repeat` and `copy_for_deref`; the `offset` operator; the `copy_nonoverlapping` statement; constants that are not scalars and hold no pointers, as private globals; and the pass modes `pair`, `cast` and `indirect` for arguments and results, in the Rust and the C ABI, spelled as rustc's LLVM backend spells them.

Two things differ from the plan. The `cmp` operator moved to the enums part of A5: its result is `Ordering`, and nothing can look at one before enums are lowered. And the pull request, opened on top of the A4 branch, was retargeted to `main` once the earlier pull requests were merged.

Pull request: https://github.com/pyrlyn/zrust/pull/7 (commits `53992af`, `70d2972`, `6afac50`, `e372a27`).

## How it was checked

- `zig build test --summary all` on macOS arm64: 165 of 165 steps, 9 of 9 unit tests. It includes `test-run-pass`, which builds `structs.rs`, `tuples.rs`, `arrays.rs`, `references.rs`, `c_abi.rs` and `bounds.rs` with stock rustc once and with zrust twice (plain and `-O`), runs all three and compares them with the header: exit code 0 for the first five, and for `bounds.rs` death by `SIGABRT` (stock rustc, from the test's panic handler) or by the trap signal (zrust).
- CI on `e372a27`, run https://github.com/pyrlyn/zrust/actions/runs/45921906663: `build (macos-latest)` and `build (ubuntu-latest)` pass. The Linux job is the first run of the x86_64 pass modes: `byval` arguments and a `cast` to a struct of registers such as `{ i64, double }`.
- Signatures against stock rustc (`--emit=llvm-ir -C no-prepopulate-passes`, aarch64) for `structs.rs` and `c_abi.rs`: every function has the same parameter and result types and the same `sret`, `zeroext` and `signext`. Stock rustc also puts `align N` on references passed directly and declares the panic functions ZRust does not call yet.
- `c_abi.rs` calls the C library's `div` and `lldiv`, which return structs, so one side of those calls is compiled by a C compiler.

## Known gaps

Those of the code generator are listed in `plan/README.md` ("Known gaps after A5, part 1"), those of the format in `docs/ZRMIR.md` §10. Beyond them:

- The x86_64 pass modes were run only in CI; on a developer machine only aarch64 was.
- No test passes a value in a `cast` mode with `i32` padding, an offset of the rest or vector registers: those are refused.
- A constant that is not a scalar gets a new global at every use; equal ones are left for LLVM or the linker to merge.
- The intermediate commits of the pull request were not built one by one; only its final tree was tested.
