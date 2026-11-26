# Agent prompt: continue "ZRust" via the reuse track (Track A)

You are an engineering agent continuing the project **ZRust** (repository `pyrlyn/zrust`): a Rust compiler whose own code is written in **Zig** and which emits machine code through **LLVM**. Your job is to implement **Track A** from [`docs/PLAN.md`](PLAN.md): reuse the existing `rustc` frontend and middle end through `rustc_private`, and write the **backend and the driver in Zig**. Rust code is allowed **only** in one thin shim crate, and only where rustc's APIs can be called from Rust alone.

Read this whole file before writing code. Follow the phases in order; each phase has exit criteria and verification commands. Do not skip ahead.

## 0. Ground rules
- All docs, comments, commit messages and PR text in **English**.
- Every change goes through a **pull request** on `pyrlyn/zrust`. Never push to `main`, never force-push, never merge without the owner's explicit request and green CI.
- Do not add third-party dependencies (Zig packages, crates) without the owner's approval. Exceptions already approved by this plan: LLVM 22 (system), the pinned Rust nightly with `rustc-dev`, `serde`/`serde_json` inside the shim (they come with the toolchain's `rustc_public`).
- Keep the shim small. If you are about to write real logic in Rust, stop: move it to Zig and pass the data through ZRMIR.
- Project is unofficial; keep the non-affiliation notice in README. "Rust" is a Rust Foundation trademark and "ZRust" still contains it, so the policy may still apply — the final name is the owner's decision.

## 1. Pinned versions
| Component | Version | Why |
|---|---|---|
| Rust toolchain | `nightly-2026-11-24` with components `rust-src`, `rustc-dev`, `llvm-tools` | Same nightly that [rustc_codegen_cranelift pins](https://github.com/rust-lang/rustc_codegen_cranelift/blob/master/rust-toolchain.toml) — known to work for an out-of-tree `CodegenBackend`. rustc version line 1.102.0-nightly. |
| Zig | `0.17.1` | Latest release ([download](https://ziglang.org/download/)) |
| LLVM (Zig side) | `22.x` | What Zig 0.17.1 builds against (`find_package(llvm 22)` in Zig's `CMakeLists.txt`) |
| rustc's LLVM | whatever the pinned nightly ships (`rustc +nightly-2026-11-24 -vV` → `LLVM version:`) | Lives inside `librustc_driver`; **never** loaded together with ours in one process |

`rust-toolchain.toml` at repo root:
```toml
[toolchain]
channel = "nightly-2026-11-24"
components = ["rust-src", "rustc-dev", "llvm-tools"]
profile = "minimal"
```
Bumping the nightly is its own PR with a checklist: update the pin, rebuild shim, fix API breakage, rerun the whole test suite, note changes in `docs/NIGHTLY_BUMPS.md`.

## 2. What is reused vs built

### 2.1 Reused from rustc (do NOT reimplement)
| Concern | Crate / API | Entry point we use |
|---|---|---|
| CLI, session, sysroot, crate loading | `rustc_driver` (`rustc_driver_impl`), `rustc_interface`, `rustc_session`, `rustc_metadata` | rustc itself loads our backend via `-Zcodegen-backend` ([unstable book](https://doc.rust-lang.org/unstable-book/compiler-flags/codegen-backend.html)) |
| Lexing, parsing, AST | `rustc_lexer`, `rustc_parse`, `rustc_ast` | implicit |
| Macro expansion, proc macros | `rustc_expand`, `rustc_builtin_macros` | implicit |
| Name resolution | `rustc_resolve` | implicit |
| HIR | `rustc_ast_lowering`, `rustc_hir` | implicit |
| Type collection, well-formedness, type check | `rustc_hir_analysis`, `rustc_hir_typeck` (the old `rustc_typeck` was split into these two) | implicit |
| Trait solving | `rustc_trait_selection`, `rustc_next_trait_solver` | implicit |
| THIR, MIR building, exhaustiveness | `rustc_mir_build`, `rustc_pattern_analysis` | implicit |
| Borrow checking | `rustc_borrowck` | implicit |
| MIR optimizations, drop elaboration, const eval | `rustc_mir_transform`, `rustc_const_eval` | implicit (we read `optimized_mir` via `Instance::body()`) |
| Monomorphization + CGU partitioning | `rustc_monomorphize` | query `tcx.collect_and_partition_mono_items(())` |
| Layouts, ABI | `rustc_abi`, `rustc_target`, `rustc_ty_utils` | `rustc_public`: `Ty::layout()`, `Instance::fn_abi()` |
| Symbol mangling | `rustc_symbol_mangling` | `Instance::mangled_name()` |
| Crate metadata (`.rmeta`), rlib packaging, linker invocation | `rustc_metadata`, `rustc_codegen_ssa::back::link` | default `CodegenBackend::link` → [`link_binary`](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_codegen_ssa/back/link/fn.link_binary.html) |
| Standard library | prebuilt `std`/`core`/`alloc` rlibs of the pinned nightly | linked as-is in phases A1–A7; generic std code is monomorphized into our CGUs and compiled by us |
| Stable view of MIR | `rustc_public` (formerly `stable_mir`; [docs](https://doc.rust-lang.org/nightly/nightly-rustc/rustc_public/index.html), [source](https://github.com/rust-lang/rust/tree/master/compiler/rustc_public), [tests](https://github.com/rust-lang/rust/tree/master/tests/ui-fulldeps/rustc_public), [project](https://github.com/rust-lang/project-stable-mir)) | `rustc_public::rustc_internal::run(tcx, || …)` |

### 2.2 Built from scratch
| Part | Language | Location |
|---|---|---|
| `zrust` CLI driver (wraps `rustc`/`cargo`) | Zig | `src/main.zig`, `src/driver/` |
| ZRMIR format: schema, decoder | Zig (decoder), Rust (encoder in shim) | `docs/ZRMIR.md`, `src/zrmir/`, `shim/src/zrmir.rs` |
| MIR → LLVM IR lowering (types, places, rvalues, terminators, drops, intrinsics, consts/allocations, vtables) | Zig | `src/codegen/` |
| LLVM wrapper: module/target machine/pass pipeline/object emission/debug info | Zig over LLVM-C | `src/llvm/` |
| `zrust-codegen` executable (one CGU in, one `.o` out) | Zig | `src/codegen_main.zig` |
| Entry shim (`main` → `std::rt::lang_start`), allocator shim (`__rust_alloc` → `__rdl_alloc`/`#[global_allocator]`) | Zig | `src/codegen/shims.zig` |
| `CodegenBackend` implementation and ZRMIR encoder | Rust (thin) | `shim/` |
| Test harness: goldens, rustc UI subset runner, differential vs stock rustc and Miri | Zig + shell | `tests/` |

## 3. Architecture

```
zrust (Zig)                                    # user-facing CLI
  │  exec
  ▼
rustc +nightly-2026-11-24 -Zcodegen-backend=<repo>/zig-out/lib/libzrust_shim.{dylib,so} <args>
  │  frontend + middle end (reused)
  ▼
zrust_shim::ZRustBackend::codegen_crate(tcx)  # Rust, thin
  │  for each CGU: rustc_public view → <out>/<crate>.<cgu>.zrmir   (types, layouts, FnAbi, bodies, allocations)
  │  spawn
  ▼
zrust-codegen --in X.zrmir --out X.o --target <triple> --cpu <cpu> --opt <0..3>   # Zig + LLVM 22
  ▼
join_codegen → CompiledModules{ .o files } → default link() → link_binary → cc / ld.lld
```

Why out of process: `librustc_driver` statically contains rustc's own LLVM. Loading libLLVM 22 into the same process risks duplicate-symbol and global-state clashes and ties us to rustc's LLVM version. Files + a subprocess also give free parallelism per CGU, crash isolation, and reproducible repro files (`.zrmir` can be attached to bug reports). An in-process C ABI (`export fn zrust_codegen(req: *const ZrRequest) callconv(.c) c_int`) is a later optimisation, allowed only if the Zig side then emits bitcode without libLLVM (like Zig's own compiler) or the LLVM versions match.

Alternative considered: a `rustc_driver` wrapper binary using `rustc_driver::Callbacks::after_analysis` + `Compilation::Stop` (e.g. via `rustc_public::run!`). Use it **only** for analysis tools (ZRMIR dumps of a single crate, Rust-to-Rust printer). For full builds the `-Zcodegen-backend` path is better because rustc keeps doing metadata, rlibs, linking and cargo integration.

## 4. Repository layout to create
```
rust-toolchain.toml
build.zig                 # builds zig binaries AND runs `cargo build --release -p zrust_shim`
build.zig.zon
src/
  main.zig                # zrust CLI
  codegen_main.zig        # zrust-codegen
  driver/{toolchain.zig, args.zig, cargo.zig}
  zrmir/{schema.zig, decode.zig}
  codegen/{module.zig, types.zig, abi.zig, place.zig, rvalue.zig, terminator.zig, consts.zig, intrinsics.zig, shims.zig, debuginfo.zig}
  llvm/{c.zig, target.zig, passes.zig, emit.zig}
shim/
  Cargo.toml              # [lib] crate-type = ["dylib"]  (rustc loads it with dlopen)
  src/{lib.rs, backend.rs, zrmir.rs, spawn.rs}
tests/
  run-pass/*.rs           # own programs with expected stdout
  ui-subset.txt           # list of rustc tests/ui run-pass tests we must pass
  run_ui.sh, diff.sh
docs/{PLAN.md, AGENT_PROMPT.md, ZRMIR.md, NIGHTLY_BUMPS.md}
```

## 5. The shim (Rust, `shim/`)

`shim/Cargo.toml`:
```toml
[package]
name = "zrust_shim"
version = "0.0.0"
edition = "2024"

[lib]
crate-type = ["dylib"]

[package.metadata.rust-analyzer]
rustc_private = true
```
`shim/src/lib.rs` (shape — copy exact signatures from `compiler/rustc_codegen_ssa/src/traits/backend.rs` **at the commit of the pinned nightly**, see `rustc +nightly-2026-11-24 -vV` → `commit-hash`; master already differs, e.g. `init` returns a tuple there while cg_clif's pinned version returns `CodegenBackendInit`):
```rust
#![feature(rustc_private)]
extern crate rustc_codegen_ssa;
extern crate rustc_data_structures;
extern crate rustc_driver;      // must be linked so the dylib resolves rustc symbols
extern crate rustc_metadata;
extern crate rustc_middle;
extern crate rustc_public;
extern crate rustc_session;
extern crate rustc_span;

use std::any::Any;
use rustc_codegen_ssa::traits::CodegenBackend;
use rustc_middle::ty::TyCtxt;
use rustc_session::Session;

pub struct ZRustBackend;

impl CodegenBackend for ZRustBackend {
    fn name(&self) -> &'static str { "zrust" }
    fn target_cpu(&self, sess: &Session) -> String { /* sess.opts.cg.target_cpu or target default */ }
    fn codegen_crate<'tcx>(&self, tcx: TyCtxt<'tcx>) -> Box<dyn Any> {
        // 1. let (_, cgus) = tcx.collect_and_partition_mono_items(()) — internal API
        // 2. rustc_public::rustc_internal::run(tcx, || { encode each CGU to ZRMIR })
        // 3. spawn `zrust-codegen` per CGU (path from env ZRUST_CODEGEN), keep the handles
        // 4. return Box::new(OngoingCodegen { modules, crate_info, .. })
    }
    fn join_codegen(/* exact args from pinned nightly */) -> /* CompiledModules */ {
        // wait for subprocesses, map .o paths into CompiledModule { kind: Regular, object: Some(path), .. }
        // add allocator module if `rustc_codegen_ssa::base::allocator_kind_for_codegen(tcx)` was Some
    }
    // keep the default `link` → rustc_codegen_ssa::back::link::link_binary
}

#[unsafe(no_mangle)]
pub fn __rustc_codegen_backend() -> Box<dyn CodegenBackend> { Box::new(ZRustBackend) }
```
Reference implementations to read side by side: cg_clif [`src/lib.rs`](https://github.com/rust-lang/rustc_codegen_cranelift/blob/master/src/lib.rs) (`codegen_crate`, `join_codegen`, `__rustc_codegen_backend`), [`src/driver/aot.rs`](https://github.com/rust-lang/rustc_codegen_cranelift/blob/master/src/driver/aot.rs) (CGU loop, `CompiledModules`), [`src/main_shim.rs`](https://github.com/rust-lang/rustc_codegen_cranelift/blob/master/src/main_shim.rs), [`src/allocator.rs`](https://github.com/rust-lang/rustc_codegen_cranelift/blob/master/src/allocator.rs); [rustc_codegen_gcc `src/lib.rs`](https://github.com/rust-lang/rustc_codegen_gcc/blob/master/src/lib.rs); [rustc_codegen_clr](https://github.com/FractalFir/rustc_codegen_clr) for a backend that emits a different IR in a separate tool; [Kani](https://github.com/model-checking/kani) and [Charon](https://github.com/AeneasVerif/charon) for large `rustc_public`/MIR consumers.

APIs the encoder uses (`rustc_public`, all verified in nightly docs):
- `rustc_public::rustc_internal::{run, stable, internal}` — enter the stable API from a `TyCtxt` and convert internal `Instance`s from CGUs.
- `mir::mono::Instance`: `body()`, `fn_abi()`, `mangled_name()`, `intrinsic_name()`, `is_empty_shim()`, `resolve_drop_in_place(ty)`, `try_const_eval(ty)`.
- `mir::mono::MonoItem::{Fn, Static, GlobalAsm}`, `StaticDef::eval_initializer()`.
- `mir::Body` (blocks, locals, `arg_locals`, var debug info), `ty::Ty::layout()` → `LayoutShape` (size, align, fields offsets, variants, abi), `ty::Allocation` (bytes + provenance → relocations), `entry_fn()`.
- `rustc_public` types implement `serde::Serialize`, but `Ty`/`Span`/`DefId` serialize as opaque indices. ZRMIR therefore needs **its own tables**: a type table (kind + layout), a function-ABI table, an allocation table, a symbol table. Do not depend on rustc_public's serialized shape.

## 6. ZRMIR (document it in `docs/ZRMIR.md` first)
- One file per CGU: header (`magic "ZRMIR"`, version, target triple, data layout string from `tcx.data_layout`, pointer width, panic strategy), then tables: `types[]`, `layouts[]`, `fn_abis[]`, `allocs[]`, `symbols[]`, `functions[]` (mangled name, linkage, visibility, ABI id, MIR body), `statics[]`, `entry` (optional), `allocator_shim` (optional).
- Phase A2 uses **JSON** (easy to diff, `serde_json` from the toolchain). Switch to a compact binary encoding in A8 only if profiling says so; keep JSON as `--zrmir-format=json` for debugging.
- The decoder in Zig is strict: unknown tags are hard errors with the file offset/path.

## 7. The Zig backend (`src/codegen`, `src/llvm`)
- `src/llvm/c.zig`: `pub const c = @cImport({ @cInclude("llvm-c/Core.h"); @cInclude("llvm-c/TargetMachine.h"); @cInclude("llvm-c/Target.h"); @cInclude("llvm-c/Analysis.h"); @cInclude("llvm-c/Transforms/PassBuilder.h"); @cInclude("llvm-c/DebugInfo.h"); });`
- `build.zig`: find LLVM 22 via `llvm-config --includedir --libdir --libs` (Homebrew: `/opt/homebrew/opt/llvm@22`; Linux: `apt.llvm.org` `llvm-22-dev`), link it to `zrust-codegen` only.
- Lowering strategy (same as `rustc_codegen_ssa`, but in Zig): every MIR local → `alloca` (let `mem2reg`/SROA clean up); scalar/scalar-pair locals as SSA later. Types from ZRMIR **layouts**, not from Rust types: `Scalar` → int/float/ptr, `ScalarPair` → `{a, b}`, `Aggregate` → `[size x i8]` with GEP by byte offset. Calls use `FnAbi` (`PassMode::{Ignore, Direct, Pair, Cast, Indirect}`) to build LLVM signatures and attributes.
- Entry points:
  - `pub fn lowerModule(gpa: std.mem.Allocator, cgu: *const zrmir.Cgu, ctx: *llvm.Context) !llvm.Module`
  - `pub fn emitObject(m: llvm.Module, tm: llvm.TargetMachine, opt: OptLevel, out_path: [:0]const u8) !void` → `LLVMRunPasses(m, "default<O2>", tm, opts)` then `LLVMTargetMachineEmitToFile`.
  - `src/codegen_main.zig`: `pub fn main() !u8` parsing `--in --out --target --cpu --opt --emit=obj|llvm-ir|bc`.
- Always `LLVMVerifyModule` in debug builds; `--emit=llvm-ir` writes `.ll` next to `.o` for inspection.

## 8. The Zig driver (`zrust`)
- `zrust rustc <rustc args…>`: resolve rustc with `rustup which rustc --toolchain nightly-2026-11-24`, then exec it with `-Zcodegen-backend=<abs path to libzrust_shim>` and env `ZRUST_CODEGEN=<abs path to zrust-codegen>`.
- `zrust build file.rs [-O] [-o out]`: sugar for the above.
- `zrust cargo <cmd…>`: exec `cargo +nightly-2026-11-24 <cmd>` with `RUSTFLAGS="-Zcodegen-backend=<shim>"` appended and `ZRUST_CODEGEN` set.
- `zrust dump-zrmir file.rs`: run with `ZRUST_KEEP_ZRMIR=1`, print paths.
- On macOS a standalone `rustc_driver`-based binary needs `DYLD_LIBRARY_PATH=$(rustc +nightly-2026-11-24 --print sysroot)/lib`; the `-Zcodegen-backend` route does not, because rustc itself loads the shim.

## 9. Phases, exit criteria, verification

| Phase | Work | Exit criterion | Verify |
|---|---|---|---|
| **A0** Toolchain + skeleton | `rust-toolchain.toml`, `build.zig`, empty `shim`, CI (macOS arm64 + Linux x86_64) | `zig build` builds both binaries and the shim | `rustup toolchain install nightly-2026-11-24 -c rust-src -c rustc-dev -c llvm-tools && zig build && ls zig-out/bin zig-out/lib` |
| **A1** Logging shim | Shim implements `CodegenBackend`; `codegen_crate` only logs every CGU and its mono items, then stops with a fatal "not implemented" diagnostic | rustc loads the backend and prints the CGU list for `hello.rs` | `rustc +nightly-2026-11-24 -Zcodegen-backend=$PWD/zig-out/lib/libzrust_shim.dylib tests/run-pass/hello.rs` shows our log line |
| **A2** ZRMIR dump | Encoder for types, layouts, FnAbi, bodies, allocations; `docs/ZRMIR.md`; Zig decoder that round-trips | Decoder reads every CGU of `tests/run-pass/*` and of a 2k-line crate without errors | `ZRUST_KEEP_ZRMIR=1 zig-out/bin/zrust build tests/run-pass/hello.rs && zig-out/bin/zrust-codegen --in target/*.zrmir --check` |
| **A3** First code | `#![no_std] #![no_main]` + `#[no_mangle] extern "C" fn main() -> i32 { 42 }`: integer constants, returns, locals, `Assign`, `Return` | Binary exits with 42 | `./a.out; echo $?` → `42` |
| **A4** Control flow + calls | `Goto`, `SwitchInt`, `Call`, `Assert`(abort), binary/unary ops with overflow checks, casts, function pointers | Fibonacci, loops, recursion in `tests/run-pass` pass | `zig build test-run-pass` |
| **A5** Aggregates + references | structs, tuples, enums (niche + tagged, `Discriminant`, `SetDiscriminant`), arrays/slices, `Ref`/`RawPtr`, `Len`, `Aggregate`, `Drop` via `drop_in_place` instances, statics, const allocations with relocations, vtables + `dyn Trait` calls | Enum/trait-object tests pass | same + `tests/diff.sh` vs stock rustc output |
| **A6** std hello world | Entry shim (`main` → `lang_start`), allocator shim, link against prebuilt std, `panic=abort` | `fn main(){ println!("hello") }` prints `hello` | `zig-out/bin/zrust build tests/run-pass/hello.rs -C panic=abort && ./hello` |
| **A7** Real-world semantics | Unwinding (`invoke`/`landingpad`, `rust_eh_personality`), remaining intrinsics, `Box`/`Vec`/`String`/`HashMap`, closures, generics-heavy code, debug info (DWARF line tables), `-O` pipelines | 90% of `tests/ui-subset.txt` (≈500 run-pass tests chosen from rustc `tests/ui`) | `tests/run_ui.sh` prints pass rate; CI fails on regression |
| **A8** Crates + perf | `zrust cargo build` on `serde`, `regex`, `ripgrep`; parallel CGU codegen; optional binary ZRMIR; optional sysroot built with our backend (cg_clif-style) | ripgrep builds and passes its tests | `zig-out/bin/zrust cargo test` in a ripgrep checkout |

Optional mode (any time after A5): **Rust-to-Rust** printer — `zrust build --emit=rust-mir` writes monomorphized MIR as compilable low-level Rust (one `unsafe fn` per instance, `goto` via `loop`/`match` state machine). Used for debugging and as a differential oracle (compile the printed Rust with stock rustc and compare outputs). Implemented in Zig from ZRMIR, not in the shim.

## 10. Testing strategy
- `tests/run-pass/*.rs` with `// expect-stdout:` headers; runner in Zig (`zig build test-run-pass`).
- Differential: compile each test with stock rustc and with `zrust`, compare exit code + stdout (`tests/diff.sh`). For UB-sensitive tests also run Miri (`cargo +nightly-2026-11-24 miri run`).
- rustc UI subset: list paths from https://github.com/rust-lang/rust/tree/master/tests/ui in `tests/ui-subset.txt`, only `//@ run-pass` tests; track pass rate in CI.
- Every bug gets a minimized `.rs` + its `.zrmir` in `tests/regressions/`.

## 11. Track B hook
The Zig backend consumes only ZRMIR. Track B (from-scratch frontend in Zig, see `docs/PLAN.md` §4) must produce ZRMIR too, so the backend is shared and stays the single source of codegen truth.

## 12. Deliverables per PR
Small PRs, one phase or sub-phase each. PR description: what changed, exit-criterion evidence (command + output), known gaps. Never merge yourself.
