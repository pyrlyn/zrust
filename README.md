# ZRust

**ZRust** is an experimental Rust compiler written in **Zig** with an **LLVM** backend.

- **Status:** phase A5, the first part of it — rustc runs with ZRust as its code generator: every codegen unit is written out as [ZRMIR](docs/ZRMIR.md), the Zig side turns it into an object file through LLVM, and rustc links the result. So far this covers `#![no_std]` programs that compute with scalars, structs, tuples, unions and arrays: arithmetic, casts, branches, loops, calls in the Rust and the C ABI, recursion, function pointers, references and raw pointers. Everything else (slices, `str`, enums, statics, trait objects, `std`) is refused with an error that names the construct, and a failed assertion such as an integer overflow stops the program with a trap instead of a panic message. This README contains the full plan; the same text lives in [`docs/PLAN.md`](docs/PLAN.md). Tasks are tracked in [`plan/`](plan/README.md).
- **Recommended path:** reuse the existing `rustc` frontend through `rustc_private` / `rustc_public` and write the backend (MIR → LLVM IR → object) and the driver in Zig. Step-by-step instructions for an implementing agent: [`docs/AGENT_PROMPT.md`](docs/AGENT_PROMPT.md).
- **Alternative path:** a from-scratch frontend in Zig, sharing the same backend.

> **Disclaimer.** This is an unofficial, independent project. It is **not affiliated with, endorsed by, or sponsored by the official Rust project or Rust Foundation**. "Rust" and its logo are trademarks of Rust Foundation ([policy](https://rustfoundation.org/policy/rust-trademark-policy/)). The name "ZRust" still contains "Rust", so Rust Foundation's trademark policy may still apply to it; it is less risky than the earlier working name, and remains provisional.

License: not chosen yet.

## Building

Needs [mise](https://mise.jdx.dev/) and [rustup](https://rustup.rs/). Supported hosts: macOS arm64 and Linux x86_64.

```sh
mise install    # Zig 0.17.1 and LLVM 22 (mise.toml)
zig build       # rustup installs the pinned nightly (rust-toolchain.toml) on first use
```

This produces `zig-out/bin/zrust`, `zig-out/bin/zrust-codegen` and `zig-out/lib/libzrust_shim.{dylib,so}`. To use another LLVM 22 install, pass `-Dllvm-config=<path to llvm-config>`. Tools and versions are listed in [`toolchain.md`](toolchain.md).

## Usage

```sh
zig-out/bin/zrust build tests/run-pass/exit42.rs -C panic=abort -C default-linker-libraries -o a.out
./a.out; echo $?                                        # 42
zig-out/bin/zrust dump-zrmir tests/run-pass/hello.rs    # write the ZRMIR of every codegen unit, print the paths
zig-out/bin/zrust-codegen --check --in <file.zrmir>...  # decode and validate ZRMIR files
zig-out/bin/zrust-codegen --in <file.zrmir> --out <file> [--emit=obj|llvm-ir]   # compile one ZRMIR module
zig-out/bin/zrust rustc <rustc arguments>               # the pinned rustc with ZRust as its code generator
zig build test                                          # everything below
zig build test-run-pass                                 # build and run tests/run-pass with zrust and with stock rustc
```

The driver finds the pinned nightly through `rustup run`.

## Tests

`zig build test` runs the unit tests, dumps the ZRMIR of every program in `tests/run-pass/` and of the shim crate, and runs `test-run-pass`. Each program in `tests/run-pass/` says in its first comment lines what it must do:

| Directive | Meaning |
| --- | --- |
| `// expect-stdout: <line>` | One line of the expected output; repeat it for more lines. |
| `// expect-exit: <code>` | The expected exit code; `0` when absent. |
| `// expect-panic: <what fails>` | The program must die from a failed assertion instead of exiting: stock rustc's build from the `abort` in the program's own panic handler, ZRust's from a trap. |
| `// rustc-flags: <flags>` | Extra arguments for both compilers. |
| `// unsupported: <reason>` | ZRust cannot build the program yet: the test expects its "is not supported yet" error instead of a binary. |

Stock rustc builds and runs every program too, so a header that is wrong about Rust fails on its own. ZRust builds each supported program twice, with and without `-O`.

---


## 0. Goal and two tracks

Build a Rust compiler whose own code is written in **Zig** and which generates machine code through **LLVM**.

There are two ways to get there. Both keep the Zig requirement: Zig owns the driver and the backend.

| | Track A — Reuse (recommended) | Track B — From scratch (alternative) |
|---|---|---|
| Frontend (parse, macros, resolve, typeck, traits, borrowck) | Existing `rustc` crates via `rustc_private`, pinned nightly | Written in Zig |
| MIR | `rustc` MIR, read through `rustc_public` (formerly `stable_mir`) | Own MIR in Zig |
| Backend (MIR → LLVM IR → object) | **Zig**, LLVM-C API | Zig, LLVM-C API |
| Driver | **Zig** CLI wrapping `rustc -Zcodegen-backend=…` | Zig CLI |
| Rust code in repo | One thin shim crate (only where rustc APIs require Rust) | None |
| Time to "hello world" | Weeks | Many months |
| Time to "compiles real crates" | Months | Years |

Track A is the recommended path. Track B stays documented as the long-term option: Track A's Zig backend is reused unchanged by Track B, so nothing built in A is wasted. Full Track A instructions for an implementing agent are in [`docs/AGENT_PROMPT.md`](docs/AGENT_PROMPT.md).

## 1. What to study

### 1.1 Zig
- Language fundamentals: `comptime`, explicit allocators (`std.mem.Allocator`, `ArenaAllocator`, `GeneralPurposeAllocator`/`DebugAllocator`), error unions and `try`/`errdefer`, tagged unions, slices, `std.ArrayList`/`std.HashMap`, `std.Io` (the new I/O interface).
- `build.zig` / `build.zig.zon`: build steps, static/shared libraries, linking system libraries (LLVM), running external commands (cargo) from the build graph, test steps.
- C interop: `@cImport`/`translate-c`, `extern` functions, `callconv(.c)`, exporting a C ABI (`export fn`), `[*c]` pointers.
- Pin **Zig 0.17.1** (latest release, [ziglang.org/download](https://ziglang.org/download/)). Docs: [language reference](https://ziglang.org/documentation/master/), [Learn](https://ziglang.org/learn/).

### 1.2 LLVM IR and the LLVM-C API from Zig
- [LLVM Language Reference](https://llvm.org/docs/LangRef.html): types, GEP, `alloca`/SSA, calling conventions, attributes, `invoke`/`landingpad`, intrinsics.
- [LLVM-C API](https://llvm.org/doxygen/group__LLVMC.html) and [headers](https://github.com/llvm/llvm-project/tree/main/llvm/include/llvm-c): `Core.h`, `TargetMachine.h`, `Transforms/PassBuilder.h` (`LLVMRunPasses`), `DebugInfo.h`, `Analysis.h` (`LLVMVerifyModule`).
- How Zig itself drives LLVM: [`src/codegen/llvm.zig`](https://codeberg.org/ziglang/zig/src/branch/master/src/codegen/llvm.zig) and [`src/codegen/llvm/`](https://codeberg.org/ziglang/zig/src/branch/master/src/codegen/llvm) (Zig moved to Codeberg; [GitHub mirror](https://github.com/ziglang/zig)). Note that Zig builds its own bitcode and only uses libLLVM for optimization/emission.
- **Pin LLVM 22** — the version Zig 0.17.1 builds against (`find_package(llvm 22)` in Zig's `CMakeLists.txt`). Keep one LLVM for the whole Zig side.
- [New pass manager](https://llvm.org/docs/NewPassManager.html), [passes](https://llvm.org/docs/Passes.html), [source-level debugging](https://llvm.org/docs/SourceLevelDebugging.html), [LTO](https://llvm.org/docs/LinkTimeOptimization.html), [LLD](https://lld.llvm.org/).

### 1.3 ZRust language
- [ZRust Reference](https://doc.rust-lang.org/reference/).
- [Ferrocene Language Specification (FLS)](https://spec.ferrocene.dev/) ([source](https://github.com/ferrocene/specification)) — the most precise written spec; use its paragraph IDs in test names.
- [ZRustonomicon](https://doc.rust-lang.org/nomicon/) for unsafe, layout, drop, unwinding.

### 1.4 Compiler architecture
- Pipeline vs **query-based/incremental** compilation ([rustc query system](https://rustc-dev-guide.rust-lang.org/query.html)).
- Arenas and interning (types, symbols, spans) — natural in Zig with arena allocators and `u32` handles.
- Pratt parsing ([matklad's article](https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html)), [Crafting Interpreters](https://craftinginterpreters.com/) for fundamentals.

## 2. What to research

### 2.1 How rustc is structured ([rustc-dev-guide overview](https://rustc-dev-guide.rust-lang.org/overview.html), [source](https://github.com/rust-lang/rust/tree/master/compiler))
| Stage | rustc crate(s) | Guide |
|---|---|---|
| Lexing/parsing | `rustc_lexer`, `rustc_parse`, `rustc_ast` | [parser](https://rustc-dev-guide.rust-lang.org/the-parser.html) |
| Macro expansion | `rustc_expand`, `rustc_builtin_macros` | [macro expansion](https://rustc-dev-guide.rust-lang.org/macro-expansion.html) |
| Name resolution | `rustc_resolve` | [name resolution](https://rustc-dev-guide.rust-lang.org/name-resolution.html) |
| HIR | `rustc_ast_lowering`, `rustc_hir` | [HIR](https://rustc-dev-guide.rust-lang.org/hir.html) |
| Type collection / check | `rustc_hir_analysis`, `rustc_hir_typeck` (old `rustc_typeck` was split) | [type inference](https://rustc-dev-guide.rust-lang.org/type-inference.html) |
| Trait solving | `rustc_trait_selection`, `rustc_next_trait_solver` | [trait resolution](https://rustc-dev-guide.rust-lang.org/traits/resolution.html), [new solver](https://rustc-dev-guide.rust-lang.org/solve/trait-solving.html) |
| THIR, exhaustiveness | `rustc_mir_build`, `rustc_pattern_analysis` | [THIR](https://rustc-dev-guide.rust-lang.org/thir.html), [exhaustiveness](https://rustc-dev-guide.rust-lang.org/pat-exhaustive-checking.html) |
| MIR | `rustc_middle::mir`, `rustc_mir_transform` | [MIR](https://rustc-dev-guide.rust-lang.org/mir/index.html) |
| Borrow check | `rustc_borrowck` | [borrowck](https://rustc-dev-guide.rust-lang.org/borrow_check.html) |
| Monomorphization | `rustc_monomorphize` | [monomorph](https://rustc-dev-guide.rust-lang.org/backend/monomorph.html) |
| Codegen | `rustc_codegen_ssa`, `rustc_codegen_llvm` | [codegen](https://rustc-dev-guide.rust-lang.org/backend/codegen.html), [backend-agnostic](https://rustc-dev-guide.rust-lang.org/backend/backend-agnostic.html) |

### 2.2 LLVM codegen pipeline
New pass manager and `default<O0..O3>` pipelines via `LLVMRunPasses`; target triple/data layout/`TargetMachine` creation; debug info (DWARF via `DIBuilder`); thin/fat LTO; object emission (`LLVMTargetMachineEmitToFile`).

### 2.3 Ownership and borrow checking
- [NLL RFC 2094](https://rust-lang.github.io/rfcs/2094-nll.html), [two-phase borrows (RFC 2025)](https://rust-lang.github.io/rfcs/2025-nested-method-calls.html).
- Polonius: [book](https://rust-lang.github.io/polonius/), [repo](https://github.com/rust-lang/polonius), [alias-based formulation](https://smallcultfollowing.com/babysteps/blog/2018/04/27/an-alias-based-formulation-of-the-borrow-checker/).
- [a-mir-formality](https://github.com/rust-lang/a-mir-formality) — formal model of traits/MIR.

### 2.4 Prior art
| Project | Why it matters |
|---|---|
| [rustc_codegen_cranelift](https://github.com/rust-lang/rustc_codegen_cranelift) | Out-of-tree `CodegenBackend`; the template for Track A (main shim, allocator shim, AOT driver) |
| [rustc_codegen_gcc](https://github.com/rust-lang/rustc_codegen_gcc) | Second backend reusing `rustc_codegen_ssa` traits |
| [rustc_codegen_clr](https://github.com/FractalFir/rustc_codegen_clr) | Backend emitting a non-native IR (.NET CIL / C) — closest to "Rust to another language" |
| [Kani](https://github.com/model-checking/kani), [Charon](https://github.com/AeneasVerif/charon) | Real consumers of MIR / `rustc_public` outside rustc |
| [project-stable-mir](https://github.com/rust-lang/project-stable-mir) | The stable MIR API effort (`rustc_public`) |
| [Miri](https://github.com/rust-lang/miri) | MIR interpreter; reference semantics for differential tests |
| [mrustc](https://github.com/thepowersgang/mrustc) | Independent Rust compiler in C++ (no borrowck) — closest analogue to Track B |
| [gccrs](https://github.com/Rust-GCC/gccrs) | Independent frontend for GCC |
| [rust-analyzer](https://github.com/rust-lang/rust-analyzer), [chalk](https://github.com/rust-lang/chalk) | Query-based HIR/type inference/trait solving outside rustc |
| [Cranelift](https://cranelift.dev/) | Comparison point for a fast debug backend |
| Zig's self-hosted compiler ([Codeberg](https://codeberg.org/ziglang/zig)) | Large compiler written in Zig; LLVM bitcode emission |

## 3. Track A — Reuse rustc, Zig backend (recommended)

Summary (full instructions in [`docs/AGENT_PROMPT.md`](docs/AGENT_PROMPT.md)):

```
zrust (Zig CLI)
  └─ exec: rustc +nightly-2026-11-24 -Zcodegen-backend=libzrust_shim.{so,dylib} ...
        rustc frontend: parse → expand → resolve → HIR → typeck → THIR → MIR → borrowck → mono collection   (REUSED)
        shim (Rust, CodegenBackend): read MIR via rustc_public, write .zrmir per CGU                         (THIN)
          └─ spawn: zrust-codegen (Zig): .zrmir → LLVM IR → optimize → .o                                  (NEW, Zig)
        rustc_codegen_ssa::back::link::link_binary → system linker / lld                                     (REUSED)
```

Phases A0–A8: toolchain pin and skeleton → shim that delegates (no-op) → ZRMIR schema and dump → Zig codegen for `fn main` returning constants → scalars, control flow, calls → aggregates, references, enums, drops → std linking (`println!` works) → unwinding, intrinsics, debug info → run rustc `tests/ui` run-pass subset and real crates. Optional output mode: **Rust-to-Rust** (`--emit=rust-mir`) — pretty-print monomorphized MIR as compilable low-level Rust, used for debugging and differential tests.

## 4. Track B — From scratch in Zig (alternative)

Each phase has an exit criterion; do not start the next phase until it passes.

| # | Phase | Exit criterion |
|---|---|---|
| B0 | Repo/build setup, LLVM 22 linkage via `build.zig`, CI on macOS + Linux | `zig build test` links LLVM, emits an object for a hand-built `ret i32 0` module |
| B1 | Lexer: all tokens incl. raw strings `r#"…"#`, byte/C strings, lifetimes vs char literals, **nested block comments**, shebang, suffixes | Round-trips every `.rs` in a corpus (e.g. `library/core`) token-for-token against `rustc_lexer` output |
| B2 | Parser (recursive descent + Pratt for expressions), error recovery | Parses all of `library/core` without errors; golden AST dumps |
| B3 | AST + spans + diagnostics infrastructure | Diagnostics with source snippets, stable AST printer |
| B4 | `macro_rules!` (matcher/transcriber, hygiene basics), modules, `use`, name resolution, built-in macros (`println!`, `format_args!` subset) | `vec!`, `assert_eq!` expand; module tree resolves |
| B5 | HIR lowering (desugar `for`, `?`, `async` later, `if let`) | HIR printer goldens |
| B6 | Type inference (HM-style unification + subtyping for lifetimes), traits, generics, associated types, method resolution, auto-deref, coercions | Typechecks MVP test suite; error parity on 50 selected UI tests |
| B7 | Pattern exhaustiveness (usefulness algorithm) | Matches rustc on exhaustiveness UI tests in the MVP subset |
| B8 | THIR → MIR building (CFG, places, drops scheduled) | MIR printer goldens; interpretable by a tiny MIR interpreter |
| B9 | Borrow checking on MIR (NLL first; Polonius-style later), two-phase borrows | Accepts/rejects the borrowck UI subset like rustc |
| B10 | Drop elaboration, const eval (subset), monomorphization | Mono item set equals rustc's for test crates |
| B11 | **LLVM IR generation — shared with Track A** | Same Zig backend consumes Track B MIR |
| B12 | Optimization (`default<O2>` etc.), debug info | `-O` binaries match rustc output behaviour |
| B13 | Object emission and linking (system `cc` or `ld.lld`) | Executables on aarch64-macOS and x86_64-Linux |
| B14 | `core`/`alloc`/`std`: `no_std` + own minimal core first; later compile real `core`/`alloc`; for `std`, link against a rustc-built std only if ABI-compatible, otherwise compile `std` | `#![no_std]` binaries, then `alloc`, then `std` hello world |
| B15 | Testing: own golden tests, subset of rustc [UI tests](https://github.com/rust-lang/rust/tree/master/tests/ui) ([guide](https://rustc-dev-guide.rust-lang.org/tests/ui.html)), differential testing vs rustc and Miri | CI dashboards of pass rate |
| B16 | Stretch: incremental/query engine, proc macros, async, inline asm, LTO, Cargo integration, self-host the Zig parts' tests | — |

### 4.1 Realistic MVP subset (Track B)
Integers/bool/char, structs/enums/tuples, `match`, `if/loop/while/for` over ranges, references with lifetimes elided, generics with trait bounds, `impl`/trait methods, `Box`/`Vec`/`String` from own minimal `alloc`, `macro_rules!` basics, `panic=abort`. Explicitly **out**: proc macros, async, specialization, const generics beyond literals, inline asm, unwinding, incremental compilation.

### 4.2 Suggested Zig layout (both tracks)
```
build.zig / build.zig.zon
src/
  main.zig            # zrust CLI driver (Track A: wraps rustc; Track B: full pipeline)
  driver/             # argument parsing, sysroot/toolchain discovery, cargo integration
  zrmir/              # ZRMIR schema + decoder (Track A input)
  codegen/            # MIR → LLVM IR (shared): types.zig, place.zig, rvalue.zig, terminator.zig, intrinsics.zig, abi.zig, debuginfo.zig
  llvm/               # thin LLVM-C wrapper (bindings.zig), target machine, pass pipeline, object emission
  frontend/           # Track B only: lexer/, parser/, ast/, expand/, resolve/, hir/, typeck/, traits/, thir/, mir/, borrowck/, mono/
  util/               # arenas, interner, diagnostics, spans
shim/                 # Track A only: Rust crate zrust_shim (cdylib, rustc_private)
tests/                # golden tests, ui subset runner, differential harness
docs/
```

## 5. Risks and scope
- **Rust is huge.** Track B to full Rust is a multi-year effort (mrustc took years and skips borrowck). Hence Track A first.
- **rustc_private is unstable.** APIs change every nightly. Mitigation: pin one nightly in `rust-toolchain.toml`, keep the shim tiny, read MIR through `rustc_public` where possible, bump the nightly on a schedule with a checklist.
- **Two LLVMs in one process.** `librustc_driver` statically contains rustc's LLVM; loading a second libLLVM into the same process can clash. Mitigation: the Zig codegen runs **out of process** (`zrust-codegen` executable) and talks to the shim through `.zrmir` files.
- **ABI correctness.** Use rustc's computed layouts and `FnAbi` (exported into ZRMIR) instead of reimplementing them, so objects link with the prebuilt std.
- **Naming/trademark.** "Rust" is a Rust Foundation trademark; "ZRust" is less risky than the earlier working name but still contains "Rust", so the [Rust Foundation trademark policy](https://rustfoundation.org/policy/rust-trademark-policy/) may still apply. Review the name before any public release.
- **License** not chosen yet.

## 6. References
All links above were checked to resolve (HTTP 200) on 2026-11-26.
