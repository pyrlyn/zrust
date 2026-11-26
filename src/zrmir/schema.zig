//! The ZRMIR data model. `docs/ZRMIR.md` is the specification; `shim/src/zrmir.rs` is the same model on the writing side.
//!
//! Every type here is read and written by `std.json` as it stands, so the declarations are the wire format: a field or
//! a tag is spelled exactly as in the file, and fields are declared in the order the file has them.

pub const magic = "ZRMIR";
pub const version = 2;

/// What an id points into. `blocks` and `locals` belong to the body the id appears in, the rest to the module.
pub const Table = enum { files, spans, types, layouts, fn_abis, allocs, symbols, blocks, locals };

/// An index into `table`. A distinct type per table lets the validator find every reference by its type alone.
pub fn Id(comptime table: Table) type {
    return enum(u32) {
        _,

        pub const refers_to = table;

        pub fn index(id: @This()) u32 {
            return @backingInt(id);
        }
    };
}

pub const FileId = Id(.files);
pub const SpanId = Id(.spans);
pub const TypeId = Id(.types);
pub const LayoutId = Id(.layouts);
pub const FnAbiId = Id(.fn_abis);
pub const AllocId = Id(.allocs);
pub const SymbolId = Id(.symbols);
pub const BlockId = Id(.blocks);
pub const LocalId = Id(.locals);

pub const Module = struct {
    magic: []const u8,
    version: u32,
    crate_name: []const u8,
    cgu_name: []const u8,
    target: Target,
    panic_strategy: PanicStrategy,
    opt_level: OptLevel,
    files: []const []const u8,
    spans: []const Span,
    types: []const Type,
    layouts: []const Layout,
    fn_abis: []const FnAbi,
    allocs: []const GlobalAlloc,
    symbols: []const Symbol,
    functions: []const Function,
    statics: []const Static,
    entry: ?Entry,
};

pub const Target = struct {
    triple: []const u8,
    llvm_target: []const u8,
    data_layout: []const u8,
    cpu: []const u8,
    features: []const u8,
    relocation_model: RelocModel,
    pointer_width: u32,
    endian: Endian,
};

pub const RelocModel = enum { static, pic, pie, dynamic_no_pic, ropi, rwpi, ropi_rwpi };
pub const Endian = enum { little, big };
pub const PanicStrategy = enum { unwind, abort, immediate_abort };
pub const OptLevel = enum { none, less, more, aggressive, size, size_min };

pub const Span = struct {
    file: FileId,
    start_line: u32,
    start_col: u32,
    end_line: u32,
    end_col: u32,
};

// Types

pub const Type = struct {
    name: []const u8,
    layout: ?LayoutId,
    kind: TypeKind,
};

pub const TypeKind = union(enum) {
    bool,
    char,
    never,
    str,
    int: struct { width: IntWidth },
    uint: struct { width: UintWidth },
    float: struct { width: FloatWidth },
    adt: struct { name: []const u8, kind: AdtKind, variants: []const Variant },
    foreign: struct { name: []const u8 },
    array: struct { elem: TypeId, len: u64 },
    pat: struct { base: TypeId },
    slice: struct { elem: TypeId },
    raw_ptr: struct { pointee: TypeId, mutable: bool },
    ref: struct { pointee: TypeId, mutable: bool },
    fn_def: struct { name: []const u8 },
    fn_ptr,
    closure: struct { name: []const u8 },
    coroutine: struct { name: []const u8 },
    coroutine_closure: struct { name: []const u8 },
    coroutine_witness: struct { name: []const u8 },
    dynamic,
    tuple: struct { fields: []const TypeId },
};

pub const IntWidth = enum { isize, i8, i16, i32, i64, i128 };
pub const UintWidth = enum { usize, u8, u16, u32, u64, u128 };
pub const FloatWidth = enum { f16, f32, f64, f128 };
pub const AdtKind = enum { @"struct", @"enum", @"union" };

pub const Variant = struct {
    name: []const u8,
    discr: u128,
    fields: []const Field,
};

pub const Field = struct {
    name: []const u8,
    ty: TypeId,
};

// Layouts

pub const Layout = struct {
    size: u64,
    @"align": u64,
    repr: ValueRepr,
    fields: FieldsShape,
    variants: VariantsShape,
};

pub const ValueRepr = union(enum) {
    scalar: struct { scalar: Scalar },
    scalar_pair: struct { a: Scalar, b: Scalar, b_offset: u64 },
    vector: struct { element: Scalar, count: u64 },
    aggregate: struct { sized: bool },
};

pub const Scalar = struct {
    primitive: Primitive,
    valid_range: ?WrappingRange,
};

pub const Primitive = union(enum) {
    bool,
    int: struct { bits: u32, signed: bool },
    float: struct { format: FloatFormat },
    pointer: struct { address_space: u32 },
};

pub const FloatFormat = enum { f16, f16b, f32, f64, x87_f80, f128, ppc_f128 };

pub const WrappingRange = struct {
    start: u128,
    end: u128,
};

pub const FieldsShape = union(enum) {
    primitive,
    @"union": struct { count: u64 },
    array: struct { stride: u64, count: u64 },
    arbitrary: struct { offsets: []const u64 },
};

pub const VariantsShape = union(enum) {
    empty,
    single: struct { index: u32 },
    multiple: struct { tag: Scalar, tag_encoding: TagEncoding, tag_field: u32, variants: []const VariantLayout },
};

pub const TagEncoding = union(enum) {
    direct,
    niche: struct { untagged_variant: u32, first_niche_variant: u32, last_niche_variant: u32, niche_start: u128 },
};

pub const VariantLayout = struct {
    offsets: []const u64,
};

// Function ABIs

pub const FnAbi = struct {
    conv: CallConv,
    c_variadic: bool,
    fixed_count: u32,
    args: []const ArgAbi,
    ret: ArgAbi,
};

pub const ArgAbi = struct {
    ty: TypeId,
    layout: LayoutId,
    mode: PassMode,
};

pub const PassMode = union(enum) {
    ignore,
    direct: struct { attrs: ArgAttrs },
    pair: struct { a: ArgAttrs, b: ArgAttrs },
    cast: struct { pad_i32_count: u8, prefix: []const Reg, rest_offset: ?u64, rest: Uniform },
    indirect: struct { attrs: ArgAttrs, address_space: ?u32, mode: IndirectMode },
    indirect_unsized: struct { attrs: ArgAttrs, meta_attrs: ArgAttrs },
};

pub const ArgAttrs = struct {
    flags: []const ArgFlag,
    ext: ArgExtension,
    pointee_size: u64,
    pointee_align: ?u64,
};

pub const ArgFlag = enum {
    captures_none,
    captures_address,
    captures_read_only,
    no_alias,
    non_null,
    read_only,
    in_reg,
    no_undef,
    writable,
    no_free,
};

pub const ArgExtension = enum { none, zext, sext };
pub const IndirectMode = enum { pointer, on_stack, amdgpu_kernel_arg };

pub const Reg = struct {
    kind: RegKind,
    size: u64,
};

pub const RegKind = enum { integer, float, vector };

pub const Uniform = struct {
    unit: Reg,
    total: u64,
    is_consecutive: bool,
};

pub const CallConv = enum {
    c,
    rust,
    cold,
    preserve_most,
    preserve_all,
    preserve_none,
    tail,
    custom,
    swift,
    arm_aapcs,
    c_cmse_non_secure_call,
    c_cmse_non_secure_entry,
    msp430_intr,
    ptx_kernel,
    gpu_kernel,
    x86_fastcall,
    x86_intr,
    x86_stdcall,
    x86_this_call,
    x86_vector_call,
    x86_64_sys_v,
    x86_64_win64,
    avr_interrupt,
    avr_non_blocking_interrupt,
    riscv_interrupt,
};

// Constants and global memory

/// Bytes with the pointers in them: the value of a constant, or the contents of a global allocation.
pub const Memory = struct {
    /// Two characters per byte: hex digits, or `__` for a byte that is not initialised.
    bytes: []const u8,
    relocs: []const Reloc,
};

pub const Allocation = struct {
    @"align": u64,
    mutable: bool,
    memory: Memory,
};

pub const Reloc = struct {
    offset: u64,
    alloc: AllocId,
};

pub const GlobalAlloc = union(enum) {
    memory: Allocation,
    function: struct { symbol: SymbolId },
    static: struct { symbol: SymbolId },
    vtable: struct { ty: TypeId, alloc: AllocId },
    type_id: struct { ty: TypeId, hash: u128 },
};

pub const Const = struct {
    ty: TypeId,
    value: ConstValue,
};

pub const ConstValue = union(enum) {
    zero_sized,
    memory: Memory,
};

// Items

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
};

pub const SymbolKind = union(enum) {
    @"fn": struct { abi: FnAbiId },
    static: struct { thread_local: bool },
};

pub const Linkage = enum {
    external,
    available_externally,
    link_once_any,
    link_once_odr,
    weak_any,
    weak_odr,
    internal,
    external_weak,
};

pub const Visibility = enum { default, hidden, protected };

pub const Function = struct {
    symbol: SymbolId,
    linkage: Linkage,
    visibility: Visibility,
    track_caller: bool,
    body: Body,
};

pub const Static = struct {
    symbol: SymbolId,
    linkage: Linkage,
    visibility: Visibility,
    init: Allocation,
};

pub const Entry = struct {
    main: SymbolId,
    sigpipe: u8,
};

// Bodies

pub const Body = struct {
    span: SpanId,
    arg_count: u32,
    spread_arg: ?LocalId,
    locals: []const Local,
    blocks: []const Block,
};

pub const Local = struct {
    ty: TypeId,
};

pub const Block = struct {
    statements: []const Statement,
    terminator: Terminator,
};

pub const Statement = struct {
    span: SpanId,
    kind: StatementKind,
};

pub const StatementKind = union(enum) {
    assign: struct { place: Place, rvalue: Rvalue },
    set_discriminant: struct { place: Place, variant: u32 },
    storage_live: LocalId,
    storage_dead: LocalId,
    assume: Operand,
    copy_nonoverlapping: struct { src: Operand, dst: Operand, count: Operand },
};

pub const Place = struct {
    local: LocalId,
    projection: []const ProjectionElem,
};

pub const ProjectionElem = union(enum) {
    deref,
    field: struct { index: u32, ty: TypeId },
    index: struct { local: LocalId },
    constant_index: struct { offset: u64, min_length: u64, from_end: bool },
    subslice: struct { from: u64, to: u64, from_end: bool },
    downcast: struct { variant: u32 },
    opaque_cast: struct { ty: TypeId },
};

pub const Operand = union(enum) {
    copy: Place,
    move: Place,
    constant: Const,
    runtime_checks: struct { kind: RuntimeCheck, value: bool },
};

pub const RuntimeCheck = enum { ub_checks, contract_checks, overflow_checks };

pub const Rvalue = union(enum) {
    use: Operand,
    repeat: struct { operand: Operand, count: u64 },
    ref: struct { kind: BorrowKind, place: Place },
    reborrow: struct { ty: TypeId, mutable: bool, place: Place },
    address_of: struct { kind: RawPtrKind, place: Place },
    thread_local_ref: struct { symbol: SymbolId },
    len: Place,
    cast: struct { kind: CastKind, operand: Operand, ty: TypeId },
    binary_op: struct { op: BinOp, left: Operand, right: Operand },
    checked_binary_op: struct { op: BinOp, left: Operand, right: Operand },
    unary_op: struct { op: UnOp, operand: Operand },
    discriminant: Place,
    aggregate: struct { kind: AggregateKind, ty: TypeId, operands: []const Operand },
    copy_for_deref: Place,
};

pub const BorrowKind = enum { shared, fake, mut };
pub const RawPtrKind = enum { @"const", mut, fake_for_ptr_metadata };

pub const CastKind = union(enum) {
    pointer_expose_address,
    pointer_with_exposed_provenance,
    reify_fn_pointer: struct { symbol: SymbolId },
    unsafe_fn_pointer,
    closure_fn_pointer: struct { symbol: SymbolId },
    mut_to_const_pointer,
    array_to_pointer,
    unsize,
    int_to_int,
    float_to_int,
    float_to_float,
    int_to_float,
    ptr_to_ptr,
    fn_ptr_to_ptr,
    transmute,
    box_deref_transmute,
    subtype,
};

pub const BinOp = enum {
    add,
    add_unchecked,
    sub,
    sub_unchecked,
    mul,
    mul_unchecked,
    div,
    rem,
    bit_xor,
    bit_and,
    bit_or,
    shl,
    shl_unchecked,
    shr,
    shr_unchecked,
    eq,
    lt,
    le,
    ne,
    ge,
    gt,
    cmp,
    offset,
};

pub const UnOp = enum { not, neg, ptr_metadata };

pub const AggregateKind = union(enum) {
    array,
    tuple,
    adt: struct { variant: u32, active_field: ?u32 },
    closure,
    coroutine,
    coroutine_closure,
    raw_ptr,
};

pub const Terminator = struct {
    span: SpanId,
    kind: TerminatorKind,
};

pub const TerminatorKind = union(enum) {
    goto: struct { target: BlockId },
    switch_int: struct { discr: Operand, branches: []const SwitchBranch, otherwise: BlockId },
    @"resume",
    abort,
    @"return",
    @"unreachable",
    drop: struct { place: Place, glue: DropGlue, target: BlockId, unwind: UnwindAction },
    call: struct {
        func: Operand,
        callee: Callee,
        abi: ?FnAbiId,
        rust_call: bool,
        caller_location: ?CallerLocation,
        args: []const Operand,
        destination: Place,
        target: ?BlockId,
        unwind: UnwindAction,
    },
    assert: struct {
        cond: Operand,
        expected: bool,
        msg: AssertMessage,
        caller_location: CallerLocation,
        target: BlockId,
        unwind: UnwindAction,
    },
    inline_asm: struct {
        template: []const u8,
        operands: []const InlineAsmOperand,
        options: []const u8,
        line_spans: []const u8,
        destination: ?BlockId,
        unwind: UnwindAction,
    },
};

pub const SwitchBranch = struct {
    value: u128,
    target: BlockId,
};

pub const UnwindAction = union(enum) {
    @"continue",
    @"unreachable",
    terminate,
    cleanup: struct { target: BlockId },
};

pub const DropGlue = union(enum) {
    none,
    direct: struct { symbol: SymbolId },
    virtual,
};

pub const Callee = union(enum) {
    direct: struct { symbol: SymbolId },
    intrinsic: struct { name: []const u8, fallback: ?SymbolId },
    llvm_intrinsic: struct { name: []const u8 },
    virtual: struct { index: u64 },
    indirect,
};

pub const CallerLocation = union(enum) {
    inherited,
    @"const": Const,
};

pub const AssertMessage = union(enum) {
    bounds_check: struct { len: Operand, index: Operand },
    overflow: struct { op: BinOp, left: Operand, right: Operand },
    overflow_neg: struct { operand: Operand },
    division_by_zero: struct { operand: Operand },
    remainder_by_zero: struct { operand: Operand },
    resumed_after_return: struct { coroutine: CoroutineKind },
    resumed_after_panic: struct { coroutine: CoroutineKind },
    resumed_after_drop: struct { coroutine: CoroutineKind },
    misaligned_pointer_dereference: struct { required: Operand, found: Operand },
    null_pointer_dereference,
    null_reference_constructed,
    invalid_enum_construction: struct { operand: Operand },
};

pub const CoroutineKind = enum { coroutine, async, gen, async_gen };

pub const InlineAsmOperand = struct {
    in_value: ?Operand,
    out_place: ?Place,
    raw: []const u8,
};
