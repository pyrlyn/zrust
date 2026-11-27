# T5. Done

ZRust compiles programs that compute. `zrust-codegen` lowers `SwitchInt`, `Call` (direct and through a function pointer, with scalar arguments), `Assert`, the binary and unary operators on integers, floats, `bool`, `char` and pointers, the overflow-checked operators, and the casts between scalars, `transmute` of one size included. Values are computed in their immediate form (`bool` as `i1`) and stored in their memory form; a place is a pointer, a layout and an alignment, with the `field` projection; a function is declared when something first refers to it, so calls into other codegen units and into C work.

A failed assertion ends the program with a trap instead of a panic: the panic functions take a `&Location`, a constant with relocations, which belongs to A5. Where panics unwind, an assertion is refused.

The ZRMIR format did not change; it is still version 2.

Pull request: https://github.com/pyrlyn/zrust/pull/6

## How it was checked

- The exit criterion ("Fibonacci, loops, recursion in `tests/run-pass` pass"), on macOS arm64: `zig build test-run-pass --summary all` passes (79 steps). It builds `fib.rs`, `loops.rs`, `ops.rs`, `casts.rs`, `fn_pointers.rs` and `overflow.rs` with stock rustc once and with zrust twice (plain and `-O`), runs all three and compares them with the header: exit codes 55, 42, 0, 0 and 30, and for `overflow.rs` death by `SIGABRT` (stock rustc, from the test's panic handler) or by the trap signal (zrust).
- Locally on macOS arm64: `zig build test --summary all` passes (117 steps, nine unit tests), and `zig fmt --check build.zig src` is clean.
- CI run https://github.com/pyrlyn/zrust/actions/runs/45912541384 on commit `bef5b88`: `build (macos-latest)` and `build (ubuntu-latest)` both pass, including `zig build test`. This is the only check of zrust's own output on Linux x86_64, where a trap is `SIGILL`.
- The first CI run (https://github.com/pyrlyn/zrust/actions/runs/45911985390) failed on Linux: stock rustc links there with rust-lld, which keeps the reference libcore's unwind tables make to `rust_eh_personality`, and the reference builds of the six new programs did not link. The programs now define the function. Checked before pushing in a Linux aarch64 container with stock rustc and `-Clinker-features=+lld`: without the definition all six fail to link, with it they give 55, 42, 0, 0, 30 and `SIGABRT`.

## Known gaps

Those of the code generator are listed in `plan/README.md` ("Known gaps after A4"), those of the format in `docs/ZRMIR.md` §10. Beyond them:

- Under `-C panic=abort` a failed assertion kills the program without running its panic handler, so nothing is printed and the signal differs from stock rustc's build.
- The `overflow.rs` test knows the trap signal only for aarch64 and x86_64 hosts.
- Checked multiplication of 128-bit integers is lowered but no test runs it.
- The intermediate commits of the pull request were not built one by one; only its final tree was tested.
