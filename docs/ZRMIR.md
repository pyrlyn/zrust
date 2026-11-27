# ZRMIR

ZRMIR is the interchange format between the two halves of ZRust: the Rust shim (`shim/`), which runs inside rustc, writes it, and `zrust-codegen`, the Zig backend, reads it. It carries everything rustc knows that code generation needs — monomorphic MIR bodies, types, layouts, function ABIs, constants and global memory — so that the Zig side never has to ask rustc anything.

This document specifies **version 2**. The data model is declared twice, and both declarations follow this document:

- `shim/src/zrmir.rs` — the writing side (serde types);
- `src/zrmir/schema.zig` — the reading side (`std.json` types).

ZRMIR is ZRust's own format. It does not depend on the serialized shape of `rustc_public` types: the shim translates every value into the types below by hand.

## 1. Files

One file per codegen unit (CGU). The shim writes it where rustc would put the unit's object file, with the extension `zrmir`:

```
<out-dir>/<crate>.<cgu name>.rcgu.zrmir      e.g. target/hello.hello.7f70e975c4f329d4-cgu.0.rcgu.zrmir
```

A file is self-contained: its tables are not shared with the other units of the crate.

### 1.1 Encoding

Version 2 is JSON (UTF-8). A binary encoding may replace it later under a new version number.

A file is in **canonical form**:

- no whitespace between tokens and no trailing newline;
- object fields in exactly the order this document lists them, every field present (an absent optional value is `null`);
- integers in decimal without sign, fraction or exponent.

Canonical form makes a module a pure function of its content: decoding a file and encoding the result gives the same bytes. `zrust-codegen --check` relies on this (§8).

### 1.2 Conventions

| Convention | Meaning |
| --- | --- |
| Names | Fields, tags and enum values are `snake_case`. |
| Structs | JSON objects. |
| Plain enums | JSON strings: `"little"`. Written below as `a \| b \| c`. |
| Tagged unions | An object with exactly one key, the tag, whose value is the payload: `{"return":{}}`, `{"copy":<Place>}`. A tag without data still has the payload `{}`. Written below as a table of tags. |
| Optional values | `T?` is either a `T` or `null`. |
| Lists | `[T]` is a JSON array. |
| Ids | A `u32` index into a table, written as a plain number. `TypeId` indexes `types`, `LayoutId` `layouts`, `FnAbiId` `fn_abis`, `AllocId` `allocs`, `SymbolId` `symbols`, `SpanId` `spans`, `FileId` `files`. `BlockId` and `LocalId` index `blocks` and `locals` of the body they appear in. |
| Sizes, offsets, alignments | Bytes. |
| Wide integers | `u64` and `u128` values are JSON numbers with all their digits. A reader must not go through floating point. |
| Bits | A value described as "bits" is the bit pattern of the value, zero-extended: the `i8` value `-128` is `128`. |

A table may refer to itself: a type can name a type with a higher id, and a struct that holds a pointer to itself names its own id.

There is no "unknown" or "other" value anywhere. What the shim cannot express stops the compilation with an error (§9) instead of being dropped, and a reader rejects every tag, field or enum value it does not know.

## 2. Module

The top-level object.

| Field | Type | Meaning |
| --- | --- | --- |
| `magic` | string | Always `"ZRMIR"`. |
| `version` | u32 | Always `2` for this document. |
| `crate_name` | string | The crate being compiled. |
| `cgu_name` | string | rustc's name of the codegen unit. |
| `target` | Target | What code is generated for. |
| `panic_strategy` | `unwind \| abort \| immediate_abort` | |
| `opt_level` | `none \| less \| more \| aggressive \| size \| size_min` | `-Copt-level` 0, 1, 2, 3, `s`, `z`. |
| `files` | [string] | Source file names, for spans. |
| `spans` | [Span] | |
| `types` | [Type] | |
| `layouts` | [Layout] | |
| `fn_abis` | [FnAbi] | |
| `allocs` | [GlobalAlloc] | Everything a pointer in constant memory can point at. |
| `symbols` | [Symbol] | Every function and static the unit defines or refers to. |
| `functions` | [Function] | The functions the unit defines. |
| `statics` | [Static] | The statics the unit defines. |
| `entry` | Entry? | Present in the one unit that has to define the program's entry point. |

`functions` and `statics` are in rustc's deterministic item order. The other tables are in the order the encoder first met each entry.

**Target**

| Field | Type | Meaning |
| --- | --- | --- |
| `triple` | string | The Rust target tuple: `aarch64-apple-darwin`. |
| `llvm_target` | string | The LLVM triple, with the deployment target where there is one: `arm64-apple-macosx11.0.0`. |
| `data_layout` | string | The LLVM data layout string of the target. |
| `cpu` | string | `-Ctarget-cpu`, or the target's default CPU. |
| `features` | string | The target's own LLVM feature string, such as `+v7,+thumb2`; empty on most targets. `-Ctarget-feature` is not in it (§9). |
| `relocation_model` | `static \| pic \| pie \| dynamic_no_pic \| ropi \| rwpi \| ropi_rwpi` | `-Crelocation-model`, or the target's default. |
| `pointer_width` | u32 | Bits: 16, 32 or 64. |
| `endian` | `little \| big` | |

**Span** — a range of source text, for diagnostics and, later, debug info.

| Field | Type | Meaning |
| --- | --- | --- |
| `file` | FileId | |
| `start_line`, `start_col` | u32 | 1-based line and column of the first character. |
| `end_line`, `end_col` | u32 | 1-based line and column just past the last character. |

## 3. Types and layouts

### 3.1 Type

Every type is monomorphic. A type says what a value *is*; how it is stored is the business of its layout.

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | The type as rustc prints it, with full paths: `core::option::Option<u32>`. For people and debug info, not an identity. |
| `layout` | LayoutId? | `null` only when rustc refuses to compute a layout (a type too large to exist). No value of such a type is ever created. |
| `kind` | TypeKind | |

**TypeKind**

| Tag | Payload | Meaning |
| --- | --- | --- |
| `bool`, `char`, `never`, `str` | — | |
| `int` | `width`: `isize \| i8 \| i16 \| i32 \| i64 \| i128` | |
| `uint` | `width`: `usize \| u8 \| u16 \| u32 \| u64 \| u128` | |
| `float` | `width`: `f16 \| f32 \| f64 \| f128` | |
| `adt` | `name`: string, `kind`: `struct \| enum \| union`, `variants`: [Variant] | A struct or a union has exactly one variant. |
| `foreign` | `name`: string | An `extern type`. |
| `array` | `elem`: TypeId, `len`: u64 | |
| `pat` | `base`: TypeId | A pattern type; stored like `base`. |
| `slice` | `elem`: TypeId | |
| `raw_ptr` | `pointee`: TypeId, `mutable`: bool | |
| `ref` | `pointee`: TypeId, `mutable`: bool | |
| `fn_def` | `name`: string | The zero-sized type of a function item. |
| `fn_ptr` | — | The signature is not recorded (§10). |
| `closure`, `coroutine`, `coroutine_closure`, `coroutine_witness` | `name`: string | The captured state is described by the layout only. |
| `dynamic` | — | `dyn Trait`. |
| `tuple` | `fields`: [TypeId] | The unit type is the empty tuple. |

**Variant** — `name`: string, `discr`: u128, `fields`: [Field]. `discr` is the bits of the variant's discriminant for an enum and `0` otherwise. **Field** — `name`: string, `ty`: TypeId. Variants and fields are in source order; every variant and field index in this format counts in that order.

### 3.2 Layout

rustc's layout of a type, taken as is. ZRust never computes a layout of its own, which is what keeps its objects compatible with the prebuilt standard library.

| Field | Type | Meaning |
| --- | --- | --- |
| `size` | u64 | |
| `align` | u64 | The ABI alignment. |
| `repr` | ValueRepr | How a value travels as an SSA value. |
| `fields` | FieldsShape | Where the fields are. |
| `variants` | VariantsShape | How the variants of an enum are told apart. |

**ValueRepr**

| Tag | Payload | Meaning |
| --- | --- | --- |
| `scalar` | `scalar`: Scalar | One scalar. |
| `scalar_pair` | `a`: Scalar, `b`: Scalar, `b_offset`: u64 | Two scalars; `a` is at offset 0. |
| `vector` | `element`: Scalar, `count`: u64 | A SIMD vector. |
| `aggregate` | `sized`: bool | Lives in memory. `sized` is false for unsized types. |

**Scalar** — `primitive`: Primitive, `valid_range`: WrappingRange?. `valid_range` is `null` for a scalar that may hold any bits, uninitialised ones included (a union's scalar). **WrappingRange** — `start`: u128, `end`: u128, both inclusive, as bits; when `start > end` the range wraps around: the valid values are `start..=MAX` and `0..=end`.

**Primitive**

| Tag | Payload |
| --- | --- |
| `bool` | — |
| `int` | `bits`: u32, `signed`: bool |
| `float` | `format`: `f16 \| f16b \| f32 \| f64 \| x87_f80 \| f128 \| ppc_f128` |
| `pointer` | `address_space`: u32 |

**FieldsShape**

| Tag | Payload | Meaning |
| --- | --- | --- |
| `primitive` | — | No fields. |
| `union` | `count`: u64 | `count` fields, all at offset 0. |
| `array` | `stride`: u64, `count`: u64 | Element `i` is at `i * stride`. |
| `arbitrary` | `offsets`: [u64] | `offsets[i]` is the offset of field `i` in source order. |

**VariantsShape**

| Tag | Payload | Meaning |
| --- | --- | --- |
| `empty` | — | An uninhabited type without variants. |
| `single` | `index`: u32 | One variant, or an enum of which only variant `index` can exist. |
| `multiple` | `tag`: Scalar, `tag_encoding`: TagEncoding, `tag_field`: u32, `variants`: [VariantLayout] | Several variants behind a tag. `tag_field` indexes the layout's own `fields`; `variants[i].offsets` are the field offsets of variant `i`. |

**TagEncoding**

| Tag | Payload | Meaning |
| --- | --- | --- |
| `direct` | — | The tag holds the discriminant. |
| `niche` | `untagged_variant`: u32, `first_niche_variant`: u32, `last_niche_variant`: u32, `niche_start`: u128 | Variant `v` in `first_niche_variant..=last_niche_variant` is stored as the tag value `niche_start + (v - first_niche_variant)`, wrapping in the tag's width. Any other tag value means `untagged_variant`. |

**VariantLayout** — `offsets`: [u64].

## 4. Function ABIs

rustc's `FnAbi`, taken as is: how each argument and the return value are passed. One entry may be shared by many functions and call sites.

**FnAbi**

| Field | Type | Meaning |
| --- | --- | --- |
| `conv` | CallConv | |
| `c_variadic` | bool | |
| `fixed_count` | u32 | How many of `args` are not variadic. |
| `args` | [ArgAbi] | |
| `ret` | ArgAbi | |

`args` describes the arguments as they are passed, which is not always how the body sees them:

- a function with `track_caller` (§6) has one more argument at the end, the caller's location, which is no local of its body;
- a function called through the `rust-call` ABI receives the fields of its last tuple argument one by one (`spread_arg` in §7.1, `rust_call` in §7.7).

**CallConv** — `c | rust | cold | preserve_most | preserve_all | preserve_none | tail | custom | swift | arm_aapcs | c_cmse_non_secure_call | c_cmse_non_secure_entry | msp430_intr | ptx_kernel | gpu_kernel | x86_fastcall | x86_intr | x86_stdcall | x86_this_call | x86_vector_call | x86_64_sys_v | x86_64_win64 | avr_interrupt | avr_non_blocking_interrupt | riscv_interrupt`.

**ArgAbi** — `ty`: TypeId, `layout`: LayoutId, `mode`: PassMode.

**PassMode**

| Tag | Payload | Meaning |
| --- | --- | --- |
| `ignore` | — | Not passed at all. |
| `direct` | `attrs`: ArgAttrs | Passed as one value. |
| `pair` | `a`: ArgAttrs, `b`: ArgAttrs | A `scalar_pair` passed as two values. |
| `cast` | `pad_i32_count`: u8, `prefix`: [Reg], `rest_offset`: u64?, `rest`: Uniform | Passed as other types: `pad_i32_count` padding `i32`s, then each of `prefix`, then `rest` starting at `rest_offset` (right after the prefix when `null`). |
| `indirect` | `attrs`: ArgAttrs, `address_space`: u32?, `mode`: `pointer \| on_stack \| amdgpu_kernel_arg` | Passed as a pointer to the value; `on_stack` is LLVM's `byval`. |
| `indirect_unsized` | `attrs`: ArgAttrs, `meta_attrs`: ArgAttrs | An unsized value passed as a pointer and its metadata. |

**ArgAttrs**

| Field | Type | Meaning |
| --- | --- | --- |
| `flags` | [ArgFlag] | In the order of the list below. |
| `ext` | `none \| zext \| sext` | How a small integer is extended. |
| `pointee_size` | u64 | For a pointer: how many bytes behind it are dereferenceable; `0` when unknown. |
| `pointee_align` | u64? | For a pointer: the alignment of what it points at. |

**ArgFlag** — `captures_none | captures_address | captures_read_only | no_alias | non_null | read_only | in_reg | no_undef | writable | no_free`.

**Reg** — `kind`: `integer | float | vector`, `size`: u64. **Uniform** — `unit`: Reg, `total`: u64, `is_consecutive`: bool: as many `unit`s as cover `total` bytes.

## 5. Constants and global memory

### 5.1 Memory

Bytes, and the pointers among them.

| Field | Type | Meaning |
| --- | --- | --- |
| `bytes` | string | Two characters per byte, in memory order: lowercase hex digits, or `__` for a byte that is not initialised. |
| `relocs` | [Reloc] | The pointers, by ascending offset. |

**Reloc** — `offset`: u64, `alloc`: AllocId. The pointer-sized bytes at `offset` are a pointer into `allocs[alloc]`. The bytes themselves hold, in the target's byte order, the offset of the pointer inside that allocation.

### 5.2 Constants

**Const** — `ty`: TypeId, `value`: ConstValue.

| Tag | Payload | Meaning |
| --- | --- | --- |
| `zero_sized` | — | The only value of a zero-sized type; a function item, for one. |
| `memory` | Memory | The value as it would lie in memory, as long as the layout of `ty`. |

Every constant is evaluated: `42u32` is `{"memory":{"bytes":"2a000000","relocs":[]}}`, a `&str` is a pointer with a relocation followed by the length.

### 5.3 Global allocations

**GlobalAlloc** — what a relocation can point at.

| Tag | Payload | Meaning |
| --- | --- | --- |
| `memory` | Allocation | Anonymous constant memory: a string literal, a promoted constant, the contents of a vtable. An allocation of zero bytes has no address of its own: rustc turns a pointer into it into the integer `align` plus the offset. |
| `function` | `symbol`: SymbolId | The address of a function. |
| `static` | `symbol`: SymbolId | The address of a static. |
| `vtable` | `ty`: TypeId, `alloc`: AllocId | The vtable of the concrete type `ty` for some trait; `alloc` is a `memory` entry with its contents. |
| `type_id` | `ty`: TypeId, `hash`: u128 | A piece of a `TypeId`. Nothing is addressed: the bytes at the relocation already hold that piece of `hash`, and the pointer is those bytes. |

**Allocation** — `align`: u64, `mutable`: bool, `memory`: Memory.

## 6. Symbols and items

**Symbol** — `name`: string, `kind`: SymbolKind. `name` is the mangled linker name. The table holds every function and static the unit mentions: the ones it defines, and the ones it only calls or takes the address of, which the code generator declares.

| Tag | Payload |
| --- | --- |
| `fn` | `abi`: FnAbiId |
| `static` | `thread_local`: bool |

**Function** — a function the unit defines.

| Field | Type | Meaning |
| --- | --- | --- |
| `symbol` | SymbolId | A `fn` symbol. |
| `linkage` | Linkage | |
| `visibility` | `default \| hidden \| protected` | |
| `track_caller` | bool | The function receives its caller's location as a hidden last argument (`#[track_caller]`). |
| `body` | Body | |

**Linkage** — `external | available_externally | link_once_any | link_once_odr | weak_any | weak_odr | internal | external_weak`, with LLVM's meaning.

**Static** — `symbol`: SymbolId (a `static` symbol), `linkage`: Linkage, `visibility`, `init`: Allocation. `init` is the evaluated initializer.

**Entry** — `main`: SymbolId, `sigpipe`: u8. The unit has to define the C `main` of the program, which starts the Rust runtime with the Rust `main` function `main` and the `sigpipe` setting. The unit that holds a local `main` gets the entry; when `main` comes from another crate, the primary unit does.

## 7. Bodies

A body is rustc's optimized, monomorphic MIR: a control-flow graph of basic blocks over numbered locals.

### 7.1 Body

| Field | Type | Meaning |
| --- | --- | --- |
| `span` | SpanId | The whole function. |
| `arg_count` | u32 | |
| `spread_arg` | LocalId? | The argument local, a tuple, that the caller passes field by field (`rust-call`). |
| `locals` | [Local] | Local `0` is the return place, locals `1..=arg_count` are the arguments, the rest are variables and temporaries. |
| `blocks` | [Block] | Block `0` is the entry. |

**Local** — `ty`: TypeId. **Block** — `statements`: [Statement], `terminator`: Terminator.

### 7.2 Statements

**Statement** — `span`: SpanId, `kind`: StatementKind.

| Tag | Payload | Meaning |
| --- | --- | --- |
| `assign` | `place`: Place, `rvalue`: Rvalue | |
| `set_discriminant` | `place`: Place, `variant`: u32 | Make `place` the variant with this index. |
| `storage_live`, `storage_dead` | LocalId | The local's stack slot starts or stops being in use. |
| `assume` | Operand | The operand is true; behaviour is undefined otherwise. |
| `copy_nonoverlapping` | `src`: Operand, `dst`: Operand, `count`: Operand | Copy `count` values (not bytes) of the pointee type. |

MIR statements that generate no code (`FakeRead`, `PlaceMention`, `AscribeUserType`, `Coverage`, `ConstEvalCounter`, `Nop`) are not written.

### 7.3 Places

**Place** — `local`: LocalId, `projection`: [ProjectionElem]: start at the local and apply the projections left to right.

| Tag | Payload | Meaning |
| --- | --- | --- |
| `deref` | — | The place a pointer points at. |
| `field` | `index`: u32, `ty`: TypeId | Field `index`, of type `ty`. |
| `index` | `local`: LocalId | The element whose index is in a `usize` local. |
| `constant_index` | `offset`: u64, `min_length`: u64, `from_end`: bool | Element `offset`, counted from the end when `from_end`. |
| `subslice` | `from`: u64, `to`: u64, `from_end`: bool | Elements `from..to`, or `from..len-to` when `from_end`. |
| `downcast` | `variant`: u32 | The place seen as this variant. |
| `opaque_cast` | `ty`: TypeId | The place seen as type `ty`. |

### 7.4 Operands

| Tag | Payload | Meaning |
| --- | --- | --- |
| `copy` | Place | Read the place. |
| `move` | Place | Read the place; it is not used again. |
| `constant` | Const | |
| `runtime_checks` | `kind`: `ub_checks \| contract_checks \| overflow_checks`, `value`: bool | Whether the checks of that kind are compiled in. The shim has already looked the answer up: use `value`. |

### 7.5 Rvalues

| Tag | Payload | Meaning |
| --- | --- | --- |
| `use` | Operand | |
| `repeat` | `operand`: Operand, `count`: u64 | `[operand; count]`. |
| `ref` | `kind`: `shared \| fake \| mut`, `place`: Place | `&place`. |
| `reborrow` | `ty`: TypeId, `mutable`: bool, `place`: Place | A reborrow of a user type that imitates the reborrowing of references; the result has type `ty`. |
| `address_of` | `kind`: `const \| mut \| fake_for_ptr_metadata`, `place`: Place | `&raw const place`. |
| `thread_local_ref` | `symbol`: SymbolId | The address of a thread-local static in the current thread. |
| `len` | Place | The length of an array or slice. |
| `cast` | `kind`: CastKind, `operand`: Operand, `ty`: TypeId | `operand as ty`. |
| `binary_op` | `op`: BinOp, `left`: Operand, `right`: Operand | |
| `checked_binary_op` | `op`: BinOp, `left`: Operand, `right`: Operand | The pair of the wrapped result and a `bool` that is true on overflow. |
| `unary_op` | `op`: `not \| neg \| ptr_metadata`, `operand`: Operand | |
| `discriminant` | Place | The discriminant of an enum value. |
| `aggregate` | `kind`: AggregateKind, `ty`: TypeId, `operands`: [Operand] | Build a value of type `ty` from its fields. |
| `copy_for_deref` | Place | Like `use` of a copy. |

**CastKind** — tags without payload: `pointer_expose_address`, `pointer_with_exposed_provenance`, `unsafe_fn_pointer`, `mut_to_const_pointer`, `array_to_pointer`, `unsize`, `int_to_int`, `float_to_int`, `float_to_float`, `int_to_float`, `ptr_to_ptr`, `fn_ptr_to_ptr`, `transmute`, `box_deref_transmute`, `subtype`. Tags with the payload `symbol`: SymbolId, the function whose address the cast produces: `reify_fn_pointer` (a function item becomes a function pointer) and `closure_fn_pointer` (a closure without captures does).

**BinOp** — `add | add_unchecked | sub | sub_unchecked | mul | mul_unchecked | div | rem | bit_xor | bit_and | bit_or | shl | shl_unchecked | shr | shr_unchecked | eq | lt | le | ne | ge | gt | cmp | offset`. The `_unchecked` forms have undefined behaviour on overflow, the plain forms wrap; `cmp` gives a `core::cmp::Ordering`; `offset` is pointer arithmetic in units of the pointee.

**AggregateKind** — tags without payload: `array`, `tuple`, `closure`, `coroutine`, `coroutine_closure`, `raw_ptr` (a pointer from a data pointer and its metadata). `adt` has the payload `variant`: u32, `active_field`: u32?; `active_field` is set for a union and names the one field the single operand initialises.

### 7.6 Terminators

**Terminator** — `span`: SpanId, `kind`: TerminatorKind.

| Tag | Payload | Meaning |
| --- | --- | --- |
| `goto` | `target`: BlockId | |
| `switch_int` | `discr`: Operand, `branches`: [SwitchBranch], `otherwise`: BlockId | Go to the branch whose `value` equals `discr`, else to `otherwise`. |
| `resume` | — | Continue unwinding. |
| `abort` | — | Abort the process. |
| `return` | — | Return local `0`. |
| `unreachable` | — | Never executed. |
| `drop` | `place`: Place, `glue`: DropGlue, `target`: BlockId, `unwind`: UnwindAction | Drop the value in `place`. |
| `call` | see §7.7 | |
| `assert` | `cond`: Operand, `expected`: bool, `msg`: AssertMessage, `caller_location`: CallerLocation, `target`: BlockId, `unwind`: UnwindAction | Go to `target` when `cond == expected`, panic with `msg` otherwise. |
| `inline_asm` | `template`: string, `operands`: [InlineAsmOperand], `options`: string, `line_spans`: string, `destination`: BlockId?, `unwind`: UnwindAction | See §10. |

**SwitchBranch** — `value`: u128 (bits), `target`: BlockId.

**UnwindAction** — what happens when the operation unwinds: `continue` (keep unwinding out of this function), `unreachable` (it cannot unwind), `terminate` (abort), `cleanup` with the payload `target`: BlockId (run that block).

**DropGlue**

| Tag | Payload | Meaning |
| --- | --- | --- |
| `none` | — | Dropping this type does nothing: go to `target`. |
| `direct` | `symbol`: SymbolId | Call this `drop_in_place` instance with a pointer to the place. |
| `virtual` | — | The place is a `dyn Trait`: call the drop function from its vtable. |

**AssertMessage** — what failed: `bounds_check` (`len`, `index`), `overflow` (`op`: BinOp, `left`, `right`), `overflow_neg` (`operand`), `division_by_zero` (`operand`), `remainder_by_zero` (`operand`), `resumed_after_return`, `resumed_after_panic`, `resumed_after_drop` (each with `coroutine`: `coroutine | async | gen | async_gen`), `misaligned_pointer_dereference` (`required`, `found`), `null_pointer_dereference`, `null_reference_constructed`, `invalid_enum_construction` (`operand`). The named payload fields other than `op` and `coroutine` are Operands.

**InlineAsmOperand** — `in_value`: Operand?, `out_place`: Place?, `raw`: string.

### 7.7 Calls

The payload of `call`:

| Field | Type | Meaning |
| --- | --- | --- |
| `func` | Operand | The callee as a value: a zero-sized constant of a `fn_def` type, or a function pointer. |
| `callee` | Callee | What the shim resolved `func` to. |
| `abi` | FnAbiId? | The ABI of this call; `null` exactly when `callee` is `llvm_intrinsic`. |
| `rust_call` | bool | The last argument is a tuple whose fields are passed one by one. |
| `caller_location` | CallerLocation? | Set when the callee takes a caller location (§4): what to pass as that hidden last argument. |
| `args` | [Operand] | |
| `destination` | Place | Where the result goes. |
| `target` | BlockId? | Where to continue; `null` when the call does not return. |
| `unwind` | UnwindAction | |

**Callee**

| Tag | Payload | Meaning |
| --- | --- | --- |
| `direct` | `symbol`: SymbolId | Call this function. |
| `intrinsic` | `name`: string, `fallback`: SymbolId? | A compiler intrinsic. A code generator that does not implement it calls `fallback`; without one the intrinsic has to be implemented. |
| `llvm_intrinsic` | `name`: string | An LLVM intrinsic, declared in Rust as an `extern "llvm-intrinsic"` item: `name` is what LLVM calls it, `llvm.aarch64.neon.umaxp.v16i8`. It is no symbol and has no Rust ABI: the arguments and the result are passed as LLVM values, the way LLVM declares the intrinsic. |
| `virtual` | `index`: u64 | A `dyn Trait` method: the function pointer is entry `index` of the receiver's vtable, counting pointer-sized entries from the start of the vtable. `abi` already takes the receiver as a thin data pointer. |
| `indirect` | — | Call the function pointer in `func`. |

Where there is one, `abi` equals the ABI of the callee's symbol except for a C-variadic call that passes more than the fixed arguments, where the extra arguments are classified for this call alone.

**CallerLocation** — the `&'static core::panic::Location` a call or an assertion reports.

| Tag | Payload | Meaning |
| --- | --- | --- |
| `inherited` | — | The location the enclosing function itself received; only inside a function with `track_caller`. |
| `const` | Const | A constant location. |

## 8. Reading: `zrust-codegen`

```
zrust-codegen --check --in <file.zrmir>...
zrust-codegen --in <file.zrmir> --out <file> [--emit=obj|llvm-ir]
```

The first form reads every file and exits with `0` when all pass, printing one line per file (`ok <path>: <n> functions, <n> statics, <n> types, <n> allocs`), and with `1` after `zrust-codegen: <path>: <message>` on stderr for each file that does not. A file passes three checks:

1. **Decoding.** `magic` and `version` are checked first, so a file of another version is reported as such. Then the file is parsed strictly: an unknown or duplicate field, a missing field, an unknown tag or enum value, a value of the wrong shape or a number that does not fit its type is an error with the line, the column, the byte offset and the text around it.
2. **Validation**, for what the shape of the data cannot express. The error names the path of the value (`functions[0].body.locals[0].ty: id 7 is out of range: ...`).
   - Every id is inside its table; block and local ids are inside their own body.
   - A symbol is of the kind its use needs: `fn` for a function, a direct callee, an intrinsic fallback, a `function` allocation and `entry.main`; `static` for a static and a `static` allocation.
   - The `alloc` of a `vtable` is a `memory` entry.
   - A body has at least one block and more locals than arguments.
   - `bytes` is an even number of characters, each pair hex or `__`, and every relocation leaves room for a pointer.
   - `pointer_width` is 16, 32 or 64.
   - A layout's alignment is a power of two of at most 2^29 bytes. A layout with a `scalar` representation is as large as its scalar, and an integer scalar has 8, 16, 32, 64 or 128 bits.
   - A `memory` constant has as many bytes as the layout of its type, when the type has one.
   - A call has an `abi` exactly when its callee is not `llvm_intrinsic`, and the name of an LLVM intrinsic starts with `llvm.`.
3. **Canonical form.** The decoded module is encoded again and compared with the file byte for byte. This also rejects what a lenient JSON parser lets through, and it proves that the Rust and the Zig declarations of the format describe the same thing for every value that occurs in the file.

The second form compiles one module: after the same three checks it lowers the module to LLVM IR, has LLVM verify the result, runs the pass pipeline of the module's `opt_level` and writes an object file, or the textual IR with `--emit=llvm-ir`. The target, the CPU, the features, the relocation model and the optimization level all come from the module; the command line names only files. A construct the code generator does not implement yet is an error that names the function, the block and the statement (`` `main`, bb0[3]: the rvalue `aggregate` is not supported yet ``) and no output is written; nothing is ever approximated.

## 9. Writing: the shim

For every compilation the shim encodes every codegen unit and writes the files. What follows depends on the environment:

| Variable | Meaning |
| --- | --- |
| `ZRUST_CODEGEN` | The path of `zrust-codegen`. Required; the `zrust` driver sets it. |
| `ZRUST_ZRMIR_ONLY` | Set and not empty: stop after the ZRMIR. |
| `ZRUST_KEEP_ZRMIR` | Set and not empty: do not delete the files afterwards. |

- **A build.** The shim runs `zrust-codegen --in <unit>.zrmir --out <unit>.o` for one unit after another and hands the objects to rustc, which links them like those of its own backend. When a unit is refused the compilation fails with that program's output. The ZRMIR files are deleted in either case unless `ZRUST_KEEP_ZRMIR` is set.
- **`ZRUST_ZRMIR_ONLY`.** The shim runs `zrust-codegen --check --in <files>`, keeps the files, lists them in a warning (`zrust: only ZRMIR was asked for, nothing is compiled or linked`) and lets rustc finish successfully without object files or a linked artifact. `zrust dump-zrmir <file.rs>` is this mode: it writes into `target/zrmir/<file stem>/` and prints the paths of the files.

The shim stops with an error, prefixed `zrust:`, for what version 2 cannot express: `global_asm!`, scalable vector types, a constant or a type that reached code generation unevaluated, an LLVM intrinsic without a link name. It also refuses `-C target-feature`, which would have to change both `target.features` and the features of single functions.

## 10. Versioning and known gaps

`version` grows by one with every change of the format, however small: a reader accepts exactly the version it was built for and nothing else. The shim and `zrust-codegen` are built and installed together, so no compatibility between versions is kept.

Versions so far:

- **1** (phase A2): the first one.
- **2** (phase A3): `target.features` and `target.relocation_model`, which LLVM's target machine needs; the callee `llvm_intrinsic`, with a call's `abi` becoming optional for it. Version 1 wrote such a call as a `direct` one, which made rustc compute an ABI it does not define.

What version 2 leaves out, and the phase (`docs/AGENT_PROMPT.md` §9) that needs it:

- **Unsizing casts** (`unsize`) do not say what metadata the wide pointer gets: the array length or the vtable. A5.
- **Assertions** do not name the panic functions to call; `zrust-codegen` ends the program with a trap instead. A5.
- **Virtual drops** carry no ABI of the drop function. A5.
- **The entry point** does not name the `lang_start` function, and there is no allocator shim table. A6.
- **Debug info**: no variable names, source scopes or cleanup-block marks. A7.
- **Function pointer types** carry no signature; the ABI of an indirect call is at the call site.
- **`FnAbi`** has no "can unwind" flag.
- **A `cast` pass mode** has no attributes: rustc can ask for a small integer passed this way to be extended, which no target ZRust is tested on does.
- **Function attributes** (inlining hints, `cold`, `naked`, target features, link sections, instruction sets, whether a function can unwind, frame pointers and unwind tables) and static attributes (link section, `used`) are missing.
- **Layouts** have no "uninhabited" flag.
- **Inline assembly** is carried only as the strings `rustc_public` renders, which is not enough to generate code from.
- **`global_asm!`** and **scalable vectors** are errors.
- **Coverage instrumentation** is dropped.
- **Size.** JSON is large (49 MB for the 2000-line shim crate in a debug build); a binary encoding is planned once the format settles.
