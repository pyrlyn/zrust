//! The ZRMIR data model. `docs/ZRMIR.md` is the specification; `src/zrmir/schema.zig` is the same model on the reading side.
//!
//! Two conventions keep the JSON readable by `std.json` without custom code: tables are indexed by plain numbers, and an
//! enum that carries data never has a unit variant (`Return {}` instead of `Return`), so every such value is a one-key object.

use serde::Serialize;

pub const MAGIC: &str = "ZRMIR";
pub const VERSION: u32 = 2;

pub type FileId = u32;
pub type SpanId = u32;
pub type TypeId = u32;
pub type LayoutId = u32;
pub type FnAbiId = u32;
pub type AllocId = u32;
pub type SymbolId = u32;
pub type BlockId = u32;
pub type LocalId = u32;

#[derive(Serialize)]
pub struct Module {
    pub magic: &'static str,
    pub version: u32,
    pub crate_name: String,
    pub cgu_name: String,
    pub target: Target,
    pub panic_strategy: PanicStrategy,
    pub opt_level: OptLevel,
    pub files: Vec<String>,
    pub spans: Vec<Span>,
    pub types: Vec<Type>,
    pub layouts: Vec<Layout>,
    pub fn_abis: Vec<FnAbi>,
    pub allocs: Vec<GlobalAlloc>,
    pub symbols: Vec<Symbol>,
    pub functions: Vec<Function>,
    pub statics: Vec<Static>,
    pub entry: Option<Entry>,
}

#[derive(Serialize)]
pub struct Target {
    pub triple: String,
    pub llvm_target: String,
    pub data_layout: String,
    pub cpu: String,
    pub features: String,
    pub relocation_model: RelocModel,
    pub pointer_width: u32,
    pub endian: Endian,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RelocModel {
    Static,
    Pic,
    Pie,
    DynamicNoPic,
    Ropi,
    Rwpi,
    RopiRwpi,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Endian {
    Little,
    Big,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PanicStrategy {
    Unwind,
    Abort,
    ImmediateAbort,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OptLevel {
    None,
    Less,
    More,
    Aggressive,
    Size,
    SizeMin,
}

#[derive(Serialize)]
pub struct Span {
    pub file: FileId,
    pub start_line: u32,
    pub start_col: u32,
    pub end_line: u32,
    pub end_col: u32,
}

// Types

#[derive(Serialize)]
pub struct Type {
    pub name: String,
    pub layout: Option<LayoutId>,
    pub kind: TypeKind,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TypeKind {
    Bool {},
    Char {},
    Never {},
    Str {},
    Int { width: IntWidth },
    Uint { width: UintWidth },
    Float { width: FloatWidth },
    Adt { name: String, kind: AdtKind, variants: Vec<Variant> },
    Foreign { name: String },
    Array { elem: TypeId, len: u64 },
    Pat { base: TypeId },
    Slice { elem: TypeId },
    RawPtr { pointee: TypeId, mutable: bool },
    Ref { pointee: TypeId, mutable: bool },
    FnDef { name: String },
    FnPtr {},
    Closure { name: String },
    Coroutine { name: String },
    CoroutineClosure { name: String },
    CoroutineWitness { name: String },
    Dynamic {},
    Tuple { fields: Vec<TypeId> },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum IntWidth {
    Isize,
    I8,
    I16,
    I32,
    I64,
    I128,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UintWidth {
    Usize,
    U8,
    U16,
    U32,
    U64,
    U128,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FloatWidth {
    F16,
    F32,
    F64,
    F128,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AdtKind {
    Struct,
    Enum,
    Union,
}

#[derive(Serialize)]
pub struct Variant {
    pub name: String,
    pub discr: u128,
    pub fields: Vec<Field>,
}

#[derive(Serialize)]
pub struct Field {
    pub name: String,
    pub ty: TypeId,
}

// Layouts

#[derive(Serialize)]
pub struct Layout {
    pub size: u64,
    pub align: u64,
    pub repr: ValueRepr,
    pub fields: FieldsShape,
    pub variants: VariantsShape,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ValueRepr {
    Scalar { scalar: Scalar },
    ScalarPair { a: Scalar, b: Scalar, b_offset: u64 },
    Vector { element: Scalar, count: u64 },
    Aggregate { sized: bool },
}

#[derive(Serialize)]
pub struct Scalar {
    pub primitive: Primitive,
    pub valid_range: Option<WrappingRange>,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Primitive {
    Bool {},
    Int { bits: u32, signed: bool },
    Float { format: FloatFormat },
    Pointer { address_space: u32 },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FloatFormat {
    F16,
    F16b,
    F32,
    F64,
    X87F80,
    F128,
    PpcF128,
}

#[derive(Serialize)]
pub struct WrappingRange {
    pub start: u128,
    pub end: u128,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FieldsShape {
    Primitive {},
    Union { count: u64 },
    Array { stride: u64, count: u64 },
    Arbitrary { offsets: Vec<u64> },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum VariantsShape {
    Empty {},
    Single { index: u32 },
    Multiple { tag: Scalar, tag_encoding: TagEncoding, tag_field: u32, variants: Vec<VariantLayout> },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TagEncoding {
    Direct {},
    Niche { untagged_variant: u32, first_niche_variant: u32, last_niche_variant: u32, niche_start: u128 },
}

#[derive(Serialize)]
pub struct VariantLayout {
    pub offsets: Vec<u64>,
}

// Function ABIs

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
pub struct FnAbi {
    pub conv: CallConv,
    pub c_variadic: bool,
    pub fixed_count: u32,
    pub args: Vec<ArgAbi>,
    pub ret: ArgAbi,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
pub struct ArgAbi {
    pub ty: TypeId,
    pub layout: LayoutId,
    pub mode: PassMode,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum PassMode {
    Ignore {},
    Direct { attrs: ArgAttrs },
    Pair { a: ArgAttrs, b: ArgAttrs },
    Cast { pad_i32_count: u8, prefix: Vec<Reg>, rest_offset: Option<u64>, rest: Uniform },
    Indirect { attrs: ArgAttrs, address_space: Option<u32>, mode: IndirectMode },
    IndirectUnsized { attrs: ArgAttrs, meta_attrs: ArgAttrs },
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
pub struct ArgAttrs {
    pub flags: Vec<ArgFlag>,
    pub ext: ArgExtension,
    pub pointee_size: u64,
    pub pointee_align: Option<u64>,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ArgFlag {
    CapturesNone,
    CapturesAddress,
    CapturesReadOnly,
    NoAlias,
    NonNull,
    ReadOnly,
    InReg,
    NoUndef,
    Writable,
    NoFree,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum ArgExtension {
    None,
    Zext,
    Sext,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum IndirectMode {
    Pointer,
    OnStack,
    AmdgpuKernelArg,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
pub struct Reg {
    pub kind: RegKind,
    pub size: u64,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum RegKind {
    Integer,
    Float,
    Vector,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
pub struct Uniform {
    pub unit: Reg,
    pub total: u64,
    pub is_consecutive: bool,
}

#[derive(Serialize, Clone, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum CallConv {
    C,
    Rust,
    Cold,
    PreserveMost,
    PreserveAll,
    PreserveNone,
    Tail,
    Custom,
    Swift,
    ArmAapcs,
    CCmseNonSecureCall,
    CCmseNonSecureEntry,
    Msp430Intr,
    PtxKernel,
    GpuKernel,
    X86Fastcall,
    X86Intr,
    X86Stdcall,
    X86ThisCall,
    X86VectorCall,
    X86_64SysV,
    X86_64Win64,
    AvrInterrupt,
    AvrNonBlockingInterrupt,
    RiscvInterrupt,
}

// Constants and global memory

/// Bytes with the pointers in them: the value of a constant, or the contents of a global allocation.
#[derive(Serialize)]
pub struct Memory {
    pub bytes: String,
    pub relocs: Vec<Reloc>,
}

#[derive(Serialize)]
pub struct Allocation {
    pub align: u64,
    pub mutable: bool,
    pub memory: Memory,
}

#[derive(Serialize)]
pub struct Reloc {
    pub offset: u64,
    pub alloc: AllocId,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GlobalAlloc {
    Memory(Allocation),
    Function { symbol: SymbolId },
    Static { symbol: SymbolId },
    Vtable { ty: TypeId, alloc: AllocId },
    TypeId { ty: TypeId, hash: u128 },
}

#[derive(Serialize)]
pub struct Const {
    pub ty: TypeId,
    pub value: ConstValue,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ConstValue {
    ZeroSized {},
    Memory(Memory),
}

// Items

#[derive(Serialize)]
pub struct Symbol {
    pub name: String,
    pub kind: SymbolKind,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SymbolKind {
    Fn { abi: FnAbiId },
    Static { thread_local: bool },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Linkage {
    External,
    AvailableExternally,
    LinkOnceAny,
    LinkOnceOdr,
    WeakAny,
    WeakOdr,
    Internal,
    ExternalWeak,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Visibility {
    Default,
    Hidden,
    Protected,
}

#[derive(Serialize)]
pub struct Function {
    pub symbol: SymbolId,
    pub linkage: Linkage,
    pub visibility: Visibility,
    pub track_caller: bool,
    pub body: Body,
}

#[derive(Serialize)]
pub struct Static {
    pub symbol: SymbolId,
    pub linkage: Linkage,
    pub visibility: Visibility,
    pub init: Allocation,
}

#[derive(Serialize)]
pub struct Entry {
    pub main: SymbolId,
    pub sigpipe: u8,
}

// Bodies

#[derive(Serialize)]
pub struct Body {
    pub span: SpanId,
    pub arg_count: u32,
    pub spread_arg: Option<LocalId>,
    pub locals: Vec<Local>,
    pub blocks: Vec<Block>,
}

#[derive(Serialize)]
pub struct Local {
    pub ty: TypeId,
}

#[derive(Serialize)]
pub struct Block {
    pub statements: Vec<Statement>,
    pub terminator: Terminator,
}

#[derive(Serialize)]
pub struct Statement {
    pub span: SpanId,
    pub kind: StatementKind,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StatementKind {
    Assign { place: Place, rvalue: Rvalue },
    SetDiscriminant { place: Place, variant: u32 },
    StorageLive(LocalId),
    StorageDead(LocalId),
    Assume(Operand),
    CopyNonoverlapping { src: Operand, dst: Operand, count: Operand },
}

#[derive(Serialize)]
pub struct Place {
    pub local: LocalId,
    pub projection: Vec<ProjectionElem>,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProjectionElem {
    Deref {},
    Field { index: u32, ty: TypeId },
    Index { local: LocalId },
    ConstantIndex { offset: u64, min_length: u64, from_end: bool },
    Subslice { from: u64, to: u64, from_end: bool },
    Downcast { variant: u32 },
    OpaqueCast { ty: TypeId },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Operand {
    Copy(Place),
    Move(Place),
    Constant(Const),
    RuntimeChecks { kind: RuntimeCheck, value: bool },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeCheck {
    UbChecks,
    ContractChecks,
    OverflowChecks,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Rvalue {
    Use(Operand),
    Repeat { operand: Operand, count: u64 },
    Ref { kind: BorrowKind, place: Place },
    Reborrow { ty: TypeId, mutable: bool, place: Place },
    AddressOf { kind: RawPtrKind, place: Place },
    ThreadLocalRef { symbol: SymbolId },
    Len(Place),
    Cast { kind: CastKind, operand: Operand, ty: TypeId },
    BinaryOp { op: BinOp, left: Operand, right: Operand },
    CheckedBinaryOp { op: BinOp, left: Operand, right: Operand },
    UnaryOp { op: UnOp, operand: Operand },
    Discriminant(Place),
    Aggregate { kind: AggregateKind, ty: TypeId, operands: Vec<Operand> },
    CopyForDeref(Place),
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BorrowKind {
    Shared,
    Fake,
    Mut,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RawPtrKind {
    Const,
    Mut,
    FakeForPtrMetadata,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CastKind {
    PointerExposeAddress {},
    PointerWithExposedProvenance {},
    ReifyFnPointer { symbol: SymbolId },
    UnsafeFnPointer {},
    ClosureFnPointer { symbol: SymbolId },
    MutToConstPointer {},
    ArrayToPointer {},
    Unsize {},
    IntToInt {},
    FloatToInt {},
    FloatToFloat {},
    IntToFloat {},
    PtrToPtr {},
    FnPtrToPtr {},
    Transmute {},
    BoxDerefTransmute {},
    Subtype {},
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BinOp {
    Add,
    AddUnchecked,
    Sub,
    SubUnchecked,
    Mul,
    MulUnchecked,
    Div,
    Rem,
    BitXor,
    BitAnd,
    BitOr,
    Shl,
    ShlUnchecked,
    Shr,
    ShrUnchecked,
    Eq,
    Lt,
    Le,
    Ne,
    Ge,
    Gt,
    Cmp,
    Offset,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UnOp {
    Not,
    Neg,
    PtrMetadata,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AggregateKind {
    Array {},
    Tuple {},
    Adt { variant: u32, active_field: Option<u32> },
    Closure {},
    Coroutine {},
    CoroutineClosure {},
    RawPtr {},
}

#[derive(Serialize)]
pub struct Terminator {
    pub span: SpanId,
    pub kind: TerminatorKind,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TerminatorKind {
    Goto { target: BlockId },
    SwitchInt { discr: Operand, branches: Vec<SwitchBranch>, otherwise: BlockId },
    Resume {},
    Abort {},
    Return {},
    Unreachable {},
    Drop { place: Place, glue: DropGlue, target: BlockId, unwind: UnwindAction },
    Call {
        func: Operand,
        callee: Callee,
        abi: Option<FnAbiId>,
        rust_call: bool,
        caller_location: Option<CallerLocation>,
        args: Vec<Operand>,
        destination: Place,
        target: Option<BlockId>,
        unwind: UnwindAction,
    },
    Assert {
        cond: Operand,
        expected: bool,
        msg: AssertMessage,
        caller_location: CallerLocation,
        target: BlockId,
        unwind: UnwindAction,
    },
    InlineAsm {
        template: String,
        operands: Vec<InlineAsmOperand>,
        options: String,
        line_spans: String,
        destination: Option<BlockId>,
        unwind: UnwindAction,
    },
}

#[derive(Serialize)]
pub struct SwitchBranch {
    pub value: u128,
    pub target: BlockId,
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UnwindAction {
    Continue {},
    Unreachable {},
    Terminate {},
    Cleanup { target: BlockId },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DropGlue {
    None {},
    Direct { symbol: SymbolId },
    Virtual {},
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Callee {
    Direct { symbol: SymbolId },
    Intrinsic { name: String, fallback: Option<SymbolId> },
    LlvmIntrinsic { name: String },
    Virtual { index: u64 },
    Indirect {},
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CallerLocation {
    Inherited {},
    Const(Const),
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AssertMessage {
    BoundsCheck { len: Operand, index: Operand },
    Overflow { op: BinOp, left: Operand, right: Operand },
    OverflowNeg { operand: Operand },
    DivisionByZero { operand: Operand },
    RemainderByZero { operand: Operand },
    ResumedAfterReturn { coroutine: CoroutineKind },
    ResumedAfterPanic { coroutine: CoroutineKind },
    ResumedAfterDrop { coroutine: CoroutineKind },
    MisalignedPointerDereference { required: Operand, found: Operand },
    NullPointerDereference {},
    NullReferenceConstructed {},
    InvalidEnumConstruction { operand: Operand },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CoroutineKind {
    Coroutine,
    Async,
    Gen,
    AsyncGen,
}

#[derive(Serialize)]
pub struct InlineAsmOperand {
    pub in_value: Option<Operand>,
    pub out_place: Option<Place>,
    pub raw: String,
}
