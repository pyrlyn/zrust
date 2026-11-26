# T4. Done

ZRust compiles its first programs. `zrust-codegen --in X.zrmir --out X.o [--emit=obj|llvm-ir]` lowers a ZRMIR module to LLVM IR, has LLVM verify it, runs the pass pipeline of the module's optimization level and writes an object file. The shim runs it for every codegen unit and returns the objects from `join_codegen`, and rustc links them as it links its own. The phase covers scalar constants, locals, copies and moves, `return`, `goto` and `unreachable`; anything else is refused with an error that names the function, the block and the statement.

ZRMIR is at version 2: the target carries `features` and `relocation_model`, and a call to an LLVM intrinsic has its own callee without an `abi`. Version 1 wrote such a call as a direct one, which is an internal compiler error in rustc as soon as a crate contains one; the dump of the shim crate found it.

Pull request: https://github.com/pyrlyn/zrust/pull/5

## How it was checked

- The exit criterion, on macOS arm64: `zig-out/bin/zrust build tests/run-pass/exit42.rs -C panic=abort -C default-linker-libraries -o a.out; ./a.out; echo $?` prints `42`, and so does the same build with `-O`.
- Locally on macOS arm64: `zig build test --summary all` passes (69 steps): nine unit tests of the decoder and the validator; the ZRMIR dump of every `tests/run-pass/*.rs` and of the shim crate, each with and without `-O`; `zig build test-run-pass`, which builds `exit42.rs` and `locals.rs` with zrust (plain and `-O`) and with stock rustc, runs them and compares the exit codes, and checks that the seven `std` programs are refused with "is not supported yet"; the three failure paths of the shim (no `ZRUST_CODEGEN`, a rejected dump, a unit that is not compiled).
- `zig fmt --check build.zig src` is clean.
- CI run https://github.com/pyrlyn/zrust/actions/runs/45909189216: `build (macos-latest)` and `build (ubuntu-latest)` both pass, including `zig build test`. This is the only check of Linux x86_64.

## Known gaps

The format's gaps are listed in `docs/ZRMIR.md` §10, those of the code generator in `plan/README.md` ("Known gaps after A3"). Beyond them:

- `zrust-codegen` reads the target, the CPU and the optimization level from the ZRMIR module instead of taking the `--target`, `--cpu` and `--opt` flags of `docs/AGENT_PROMPT.md` §5, and has no `--emit=bc`.
- `ZRUST_KEEP_ZRMIR=1 zrust build` of a `std` program, the dump command of phase A2, fails until A6; `zrust dump-zrmir` writes the dump.
- The intermediate commits of the pull request were not built one by one; only its final tree was tested.
