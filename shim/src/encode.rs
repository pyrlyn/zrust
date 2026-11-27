//! Translates the mono items of one codegen unit into a ZRMIR module.
//!
//! Everything here is a lookup or a change of shape. Decisions about code generation belong to `zrust-codegen`.

use std::collections::HashMap;
use std::fmt::{Display, Write};
use std::hash::Hash;

use rustc_attr_ir::Linkage;
use rustc_middle::mono::{self, CodegenUnit, MonoItemData};
use rustc_middle::ty::print::with_no_trimmed_paths;
use rustc_middle::ty::{self, TyCtxt};
use rustc_public::abi as pabi;
use rustc_public::mir::alloc::{AllocId, GlobalAlloc};
use rustc_public::mir::mono::{Instance, InstanceKind, MonoItem, StaticDef};
use rustc_public::mir::{self, Mutability};
use rustc_public::rustc_internal::{internal, stable};
use rustc_public::target::{Endian, MachineInfo, MachineSize};
use rustc_public::ty::{self as pty, RigidTy, Ty, TyKind};
use rustc_public::{CrateDef, CrateDefType};
use rustc_public_bridge::IndexedVal;
use rustc_session::config::{EntryFnType, OptLevel};
use rustc_target::spec::PanicStrategy;

use crate::zrmir as z;

pub fn encode_cgu<'tcx>(tcx: TyCtxt<'tcx>, cgu: &CodegenUnit<'tcx>, cpu: String) -> z::Module {
    let mut encoder = Encoder::new(tcx);
    let mut functions = Vec::new();
    let mut statics = Vec::new();
    for (item, data) in cgu.items_in_deterministic_order(tcx) {
        match stable(item) {
            MonoItem::Fn(instance) => functions.push(encoder.function(instance, &data)),
            MonoItem::Static(def) => statics.push(encoder.static_item(def, &data)),
            MonoItem::GlobalAsm(_) => encoder.unsupported("`global_asm!` is not supported yet"),
        }
    }
    let entry = encoder.entry(cgu);

    let sess = tcx.sess;
    z::Module {
        magic: z::MAGIC,
        version: z::VERSION,
        crate_name: tcx.crate_name(rustc_span::def_id::LOCAL_CRATE).to_string(),
        cgu_name: cgu.name().to_string(),
        target: z::Target {
            triple: sess.opts.target_triple.tuple().to_string(),
            llvm_target: rustc_codegen_ssa::back::versioned_llvm_target(sess).to_string(),
            data_layout: sess.target.data_layout.to_string(),
            cpu,
            pointer_width: sess.target.pointer_width.into(),
            endian: match MachineInfo::target_endianness() {
                Endian::Little => z::Endian::Little,
                Endian::Big => z::Endian::Big,
            },
        },
        panic_strategy: match sess.panic_strategy() {
            PanicStrategy::Unwind => z::PanicStrategy::Unwind,
            PanicStrategy::Abort => z::PanicStrategy::Abort,
            PanicStrategy::ImmediateAbort => z::PanicStrategy::ImmediateAbort,
        },
        opt_level: match sess.opts.optimize {
            OptLevel::No => z::OptLevel::None,
            OptLevel::Less => z::OptLevel::Less,
            OptLevel::More => z::OptLevel::More,
            OptLevel::Aggressive => z::OptLevel::Aggressive,
            OptLevel::Size => z::OptLevel::Size,
            OptLevel::SizeMin => z::OptLevel::SizeMin,
        },
        files: encoder.files.finish(),
        spans: encoder.spans.finish(),
        types: encoder.types.finish(),
        layouts: encoder.layouts.finish(),
        fn_abis: encoder.fn_abis.finish(),
        allocs: encoder.allocs.finish(),
        symbols: encoder.symbols.finish(),
        functions,
        statics,
        entry,
    }
}

/// A table of the module under construction: `K` identifies an entry on the rustc side, the position is its id in the file.
struct Table<K, V> {
    ids: HashMap<K, u32>,
    items: Vec<Option<V>>,
}

impl<K: Hash + Eq, V> Table<K, V> {
    fn new() -> Self {
        Table { ids: HashMap::new(), items: Vec::new() }
    }

    fn get(&self, key: &K) -> Option<u32> {
        self.ids.get(key).copied()
    }

    /// Hands out the id before the entry exists, so an entry can refer to itself (a struct holding a pointer to itself).
    fn reserve(&mut self, key: K) -> u32 {
        let id = self.items.len() as u32;
        self.ids.insert(key, id);
        self.items.push(None);
        id
    }

    fn fill(&mut self, id: u32, value: V) {
        self.items[id as usize] = Some(value);
    }

    fn insert(&mut self, key: K, value: V) -> u32 {
        let id = self.reserve(key);
        self.fill(id, value);
        id
    }

    fn finish(self) -> Vec<V> {
        self.items.into_iter().map(|item| item.expect("every reserved entry is filled")).collect()
    }
}

#[derive(PartialEq, Eq, Hash)]
enum SymbolKey {
    Fn(Instance),
    Static(StaticDef),
}

/// What encoding a body needs to know about the function around it.
struct BodyCx<'a> {
    body: &'a mir::Body,
    track_caller: bool,
}

struct Encoder<'tcx> {
    tcx: TyCtxt<'tcx>,
    files: Table<String, String>,
    spans: Table<pty::Span, z::Span>,
    types: Table<Ty, z::Type>,
    layouts: Table<pabi::Layout, z::Layout>,
    fn_abis: Table<z::FnAbi, z::FnAbi>,
    instance_abis: HashMap<Instance, z::FnAbiId>,
    allocs: Table<AllocId, z::GlobalAlloc>,
    symbols: Table<SymbolKey, z::Symbol>,
}

impl<'tcx> Encoder<'tcx> {
    fn new(tcx: TyCtxt<'tcx>) -> Self {
        Encoder {
            tcx,
            files: Table::new(),
            spans: Table::new(),
            types: Table::new(),
            layouts: Table::new(),
            fn_abis: Table::new(),
            instance_abis: HashMap::new(),
            allocs: Table::new(),
            symbols: Table::new(),
        }
    }

    /// ZRMIR has no "unknown" escape hatch: what the encoder cannot express stops the build instead of being dropped.
    fn unsupported(&self, what: impl Display) -> ! {
        self.tcx.dcx().fatal(format!("zrust: {what}"))
    }

    fn expect<T>(&self, result: Result<T, rustc_public::Error>) -> T {
        result.unwrap_or_else(|error| self.unsupported(error))
    }

    // Items

    fn function(&mut self, instance: Instance, data: &MonoItemData) -> z::Function {
        let Some(body) = instance.body() else {
            self.unsupported(format!("`{}` has no MIR body", instance.name()))
        };
        let cx = BodyCx { body: &body, track_caller: instance.requires_caller_location() };
        z::Function {
            symbol: self.fn_symbol(instance),
            linkage: linkage(data.linkage),
            visibility: visibility(data.visibility),
            track_caller: cx.track_caller,
            body: self.body(&cx),
        }
    }

    fn static_item(&mut self, def: StaticDef, data: &MonoItemData) -> z::Static {
        let init = self.expect(def.eval_initializer());
        z::Static {
            symbol: self.static_symbol(def),
            linkage: linkage(data.linkage),
            visibility: visibility(data.visibility),
            init: self.allocation(&init),
        }
    }

    fn entry(&mut self, cgu: &CodegenUnit<'tcx>) -> Option<z::Entry> {
        let (def_id, EntryFnType::Main { sigpipe }) = self.tcx.entry_fn(())?;
        let main = ty::Instance::mono(self.tcx, def_id);
        // The same rule as rustc_codegen_ssa: the entry wrapper lives next to a local `main`, or in the primary unit
        // when `main` is re-exported from another crate.
        let here = if def_id.is_local() { cgu.contains_item(&mono::MonoItem::Fn(main)) } else { cgu.is_primary() };
        here.then(|| z::Entry { main: self.fn_symbol(stable(main)), sigpipe })
    }

    fn fn_symbol(&mut self, instance: Instance) -> z::SymbolId {
        let key = SymbolKey::Fn(instance);
        if let Some(id) = self.symbols.get(&key) {
            return id;
        }
        let abi = self.instance_abi(instance);
        self.symbols.insert(key, z::Symbol { name: instance.mangled_name(), kind: z::SymbolKind::Fn { abi } })
    }

    fn static_symbol(&mut self, def: StaticDef) -> z::SymbolId {
        let key = SymbolKey::Static(def);
        if let Some(id) = self.symbols.get(&key) {
            return id;
        }
        let thread_local = self.tcx.is_thread_local_static(internal(self.tcx, def.def_id()));
        let name = Instance::from(def).mangled_name();
        self.symbols.insert(key, z::Symbol { name, kind: z::SymbolKind::Static { thread_local } })
    }

    // Spans

    fn span(&mut self, span: pty::Span) -> z::SpanId {
        if let Some(id) = self.spans.get(&span) {
            return id;
        }
        let name = span.get_filename();
        let file = match self.files.get(&name) {
            Some(id) => id,
            None => self.files.insert(name.clone(), name),
        };
        let lines = span.get_lines();
        self.spans.insert(
            span,
            z::Span {
                file,
                start_line: lines.start_line as u32,
                start_col: lines.start_col as u32,
                end_line: lines.end_line as u32,
                end_col: lines.end_col as u32,
            },
        )
    }

    // Types and layouts

    fn ty(&mut self, ty: Ty) -> z::TypeId {
        if let Some(id) = self.types.get(&ty) {
            return id;
        }
        let id = self.types.reserve(ty);
        let name = with_no_trimmed_paths!(internal(self.tcx, ty).to_string());
        // rustc refuses a layout only for types no value of which exists at run time (too large, for one).
        let layout = ty.layout().ok().map(|layout| self.layout(layout));
        let kind = self.ty_kind(ty, &name);
        self.types.fill(id, z::Type { name, layout, kind });
        id
    }

    fn ty_kind(&mut self, ty: Ty, name: &str) -> z::TypeKind {
        let TyKind::RigidTy(rigid) = ty.kind() else {
            self.unsupported(format!("type `{name}` is not monomorphic"))
        };
        match rigid {
            RigidTy::Bool => z::TypeKind::Bool {},
            RigidTy::Char => z::TypeKind::Char {},
            RigidTy::Never => z::TypeKind::Never {},
            RigidTy::Str => z::TypeKind::Str {},
            RigidTy::Int(width) => z::TypeKind::Int {
                width: match width {
                    pty::IntTy::Isize => z::IntWidth::Isize,
                    pty::IntTy::I8 => z::IntWidth::I8,
                    pty::IntTy::I16 => z::IntWidth::I16,
                    pty::IntTy::I32 => z::IntWidth::I32,
                    pty::IntTy::I64 => z::IntWidth::I64,
                    pty::IntTy::I128 => z::IntWidth::I128,
                },
            },
            RigidTy::Uint(width) => z::TypeKind::Uint {
                width: match width {
                    pty::UintTy::Usize => z::UintWidth::Usize,
                    pty::UintTy::U8 => z::UintWidth::U8,
                    pty::UintTy::U16 => z::UintWidth::U16,
                    pty::UintTy::U32 => z::UintWidth::U32,
                    pty::UintTy::U64 => z::UintWidth::U64,
                    pty::UintTy::U128 => z::UintWidth::U128,
                },
            },
            RigidTy::Float(width) => z::TypeKind::Float {
                width: match width {
                    pty::FloatTy::F16 => z::FloatWidth::F16,
                    pty::FloatTy::F32 => z::FloatWidth::F32,
                    pty::FloatTy::F64 => z::FloatWidth::F64,
                    pty::FloatTy::F128 => z::FloatWidth::F128,
                },
            },
            RigidTy::Adt(def, args) => {
                let kind = match def.kind() {
                    pty::AdtKind::Struct => z::AdtKind::Struct,
                    pty::AdtKind::Enum => z::AdtKind::Enum,
                    pty::AdtKind::Union => z::AdtKind::Union,
                };
                let variants = def
                    .variants_iter()
                    .map(|variant| z::Variant {
                        name: variant.name(),
                        // rustc only defines discriminants for enums.
                        discr: match kind {
                            z::AdtKind::Enum => def.discriminant_for_variant(variant.idx()).val,
                            z::AdtKind::Struct | z::AdtKind::Union => 0,
                        },
                        fields: variant
                            .fields()
                            .iter()
                            .map(|field| z::Field { name: field.name.clone(), ty: self.ty(field.ty_with_args(&args)) })
                            .collect(),
                    })
                    .collect();
                z::TypeKind::Adt { name: def.name(), kind, variants }
            }
            RigidTy::Foreign(def) => z::TypeKind::Foreign { name: def.name() },
            RigidTy::Array(elem, len) => {
                z::TypeKind::Array { elem: self.ty(elem), len: self.expect(len.eval_target_usize()) }
            }
            RigidTy::Pat(base, _) => z::TypeKind::Pat { base: self.ty(base) },
            RigidTy::Slice(elem) => z::TypeKind::Slice { elem: self.ty(elem) },
            RigidTy::RawPtr(pointee, mutability) => {
                z::TypeKind::RawPtr { pointee: self.ty(pointee), mutable: is_mut(mutability) }
            }
            RigidTy::Ref(_, pointee, mutability) => {
                z::TypeKind::Ref { pointee: self.ty(pointee), mutable: is_mut(mutability) }
            }
            RigidTy::FnDef(def, _) => z::TypeKind::FnDef { name: def.name() },
            RigidTy::FnPtr(_) => z::TypeKind::FnPtr {},
            RigidTy::Closure(def, _) => z::TypeKind::Closure { name: def.name() },
            RigidTy::Coroutine(def, _) => z::TypeKind::Coroutine { name: def.name() },
            RigidTy::CoroutineClosure(def, _) => z::TypeKind::CoroutineClosure { name: def.name() },
            RigidTy::CoroutineWitness(def, _) => z::TypeKind::CoroutineWitness { name: def.name() },
            RigidTy::Dynamic(..) => z::TypeKind::Dynamic {},
            RigidTy::Tuple(fields) => z::TypeKind::Tuple { fields: fields.into_iter().map(|field| self.ty(field)).collect() },
        }
    }

    fn layout(&mut self, layout: pabi::Layout) -> z::LayoutId {
        if let Some(id) = self.layouts.get(&layout) {
            return id;
        }
        let shape = layout.shape();
        let repr = match shape.value_repr {
            pabi::ValueRepr::Scalar(scalar) => z::ValueRepr::Scalar { scalar: self.scalar(scalar) },
            pabi::ValueRepr::ScalarPair { a, b, b_offset } => {
                z::ValueRepr::ScalarPair { a: self.scalar(a), b: self.scalar(b), b_offset: bytes(b_offset) }
            }
            pabi::ValueRepr::Vector { element, count } => z::ValueRepr::Vector { element: self.scalar(element), count },
            pabi::ValueRepr::ScalableVector { .. } => self.unsupported("scalable vector types are not supported yet"),
            pabi::ValueRepr::Aggregate { sized } => z::ValueRepr::Aggregate { sized },
        };
        let fields = match shape.fields {
            pabi::FieldsShape::Primitive => z::FieldsShape::Primitive {},
            pabi::FieldsShape::Union(count) => z::FieldsShape::Union { count: count.get() as u64 },
            pabi::FieldsShape::Array { stride, count } => z::FieldsShape::Array { stride: bytes(stride), count },
            pabi::FieldsShape::Arbitrary { offsets } => z::FieldsShape::Arbitrary { offsets: offsets_in_bytes(offsets) },
        };
        let variants = match shape.variants {
            pabi::VariantsShape::Empty => z::VariantsShape::Empty {},
            pabi::VariantsShape::Single { index } => z::VariantsShape::Single { index: index.to_index() as u32 },
            pabi::VariantsShape::Multiple { tag, tag_encoding, tag_field, variants } => z::VariantsShape::Multiple {
                tag: self.scalar(tag),
                tag_encoding: match tag_encoding {
                    pabi::TagEncoding::Direct => z::TagEncoding::Direct {},
                    pabi::TagEncoding::Niche { untagged_variant, niche_variants, niche_start } => z::TagEncoding::Niche {
                        untagged_variant: untagged_variant.to_index() as u32,
                        first_niche_variant: niche_variants.start().to_index() as u32,
                        last_niche_variant: niche_variants.end().to_index() as u32,
                        niche_start,
                    },
                },
                tag_field: tag_field as u32,
                variants: variants
                    .into_iter()
                    .map(|variant| z::VariantLayout { offsets: offsets_in_bytes(variant.offsets) })
                    .collect(),
            },
        };
        self.layouts.insert(
            layout,
            z::Layout { size: bytes(shape.size), align: shape.abi_align, repr, fields, variants },
        )
    }

    fn scalar(&self, scalar: pabi::Scalar) -> z::Scalar {
        let (value, valid_range) = match scalar {
            pabi::Scalar::Initialized { value, valid_range } => {
                (value, Some(z::WrappingRange { start: valid_range.start, end: valid_range.end }))
            }
            pabi::Scalar::Union { value } => (value, None),
        };
        let primitive = match value {
            pabi::Primitive::Bool => z::Primitive::Bool {},
            pabi::Primitive::Int { length, signed } => z::Primitive::Int { bits: length.bits() as u32, signed },
            pabi::Primitive::Float { length } => z::Primitive::Float {
                format: match length {
                    pabi::FloatLength::F16 => z::FloatFormat::F16,
                    pabi::FloatLength::F16B => z::FloatFormat::F16b,
                    pabi::FloatLength::F32 => z::FloatFormat::F32,
                    pabi::FloatLength::F64 => z::FloatFormat::F64,
                    pabi::FloatLength::X87F80 => z::FloatFormat::X87F80,
                    pabi::FloatLength::F128 => z::FloatFormat::F128,
                    pabi::FloatLength::PpcF128 => z::FloatFormat::PpcF128,
                },
            },
            pabi::Primitive::Pointer(space) => z::Primitive::Pointer { address_space: space.0 },
        };
        z::Scalar { primitive, valid_range }
    }

    // Function ABIs

    fn instance_abi(&mut self, instance: Instance) -> z::FnAbiId {
        if let Some(id) = self.instance_abis.get(&instance) {
            return *id;
        }
        let abi = self.expect(instance.fn_abi());
        let id = self.fn_abi(&abi);
        self.instance_abis.insert(instance, id);
        id
    }

    fn fn_abi(&mut self, abi: &pabi::FnAbi) -> z::FnAbiId {
        let value = z::FnAbi {
            conv: call_conv(abi.conv),
            c_variadic: abi.c_variadic,
            fixed_count: abi.fixed_count,
            args: abi.args.iter().map(|arg| self.arg_abi(arg)).collect(),
            ret: self.arg_abi(&abi.ret),
        };
        match self.fn_abis.get(&value) {
            Some(id) => id,
            None => self.fn_abis.insert(value.clone(), value),
        }
    }

    fn arg_abi(&mut self, arg: &pabi::ArgAbi) -> z::ArgAbi {
        let mode = match &arg.mode {
            pabi::PassMode::Ignore => z::PassMode::Ignore {},
            pabi::PassMode::Direct(attrs) => z::PassMode::Direct { attrs: arg_attrs(attrs) },
            pabi::PassMode::Pair(a, b) => z::PassMode::Pair { a: arg_attrs(a), b: arg_attrs(b) },
            pabi::PassMode::Cast { pad_i32_count, cast } => z::PassMode::Cast {
                pad_i32_count: *pad_i32_count,
                prefix: cast.prefix.iter().map(reg).collect(),
                rest_offset: cast.rest_offset.map(bytes),
                rest: z::Uniform {
                    unit: reg(&cast.rest.unit),
                    total: bytes(cast.rest.total),
                    is_consecutive: cast.rest.is_consecutive,
                },
            },
            pabi::PassMode::Indirect { attrs, address_space, mode } => z::PassMode::Indirect {
                attrs: arg_attrs(attrs),
                address_space: address_space.map(|space| space.0),
                mode: match mode {
                    pabi::IndirectMode::Pointer => z::IndirectMode::Pointer,
                    pabi::IndirectMode::OnStack => z::IndirectMode::OnStack,
                    pabi::IndirectMode::AmdgpuKernelArg => z::IndirectMode::AmdgpuKernelArg,
                },
            },
            pabi::PassMode::IndirectUnsized { attrs, meta_attrs } => {
                z::PassMode::IndirectUnsized { attrs: arg_attrs(attrs), meta_attrs: arg_attrs(meta_attrs) }
            }
        };
        z::ArgAbi { ty: self.ty(arg.ty), layout: self.layout(arg.layout), mode }
    }

    /// The ABI of one call site. It differs from the callee's own ABI only for C-variadic calls, where the arguments
    /// past the fixed ones are classified per call.
    fn call_abi(&mut self, cx: &BodyCx<'_>, instance: Option<Instance>, func_ty: Ty, sig: &pty::PolyFnSig, args: &[mir::Operand]) -> z::FnAbiId {
        let fixed = sig.value.inputs().len();
        if !sig.value.c_variadic || args.len() <= fixed {
            return match instance {
                Some(instance) => self.instance_abi(instance),
                None => {
                    let abi = self.expect(sig.clone().fn_ptr_abi());
                    self.fn_abi(&abi)
                }
            };
        }

        // rustc_public cannot ask for an ABI with extra arguments, so this goes to the queries behind it.
        let tcx = self.tcx;
        let extra: Vec<_> =
            args[fixed..].iter().map(|arg| internal(tcx, self.expect(arg.ty(cx.body.locals())))).collect();
        let extra = tcx.mk_type_list(&extra);
        let env = ty::TypingEnv::fully_monomorphized();
        let abi = match instance {
            Some(instance) => tcx.fn_abi_of_instance(env.as_query_input((internal(tcx, instance), extra))),
            None => tcx.fn_abi_of_fn_ptr(env.as_query_input((internal(tcx, func_ty).fn_sig(tcx), extra))),
        };
        match abi {
            Ok(abi) => self.fn_abi(&stable(abi)),
            Err(error) => self.unsupported(format!("cannot compute the ABI of a variadic call: {error:?}")),
        }
    }

    // Constants and global memory

    fn constant(&mut self, constant: &pty::MirConst) -> z::Const {
        let value = match constant.kind() {
            pty::ConstantKind::Allocated(allocation) => z::ConstValue::Memory(self.memory(allocation)),
            pty::ConstantKind::ZeroSized => z::ConstValue::ZeroSized {},
            pty::ConstantKind::Ty(constant) => match constant.kind() {
                pty::TyConstKind::Value(_, allocation) => z::ConstValue::Memory(self.memory(allocation)),
                pty::TyConstKind::ZSTValue(_) => z::ConstValue::ZeroSized {},
                kind => self.unsupported(format!("constant `{kind:?}` reached code generation unevaluated")),
            },
            kind @ (pty::ConstantKind::Unevaluated(_) | pty::ConstantKind::Param(_)) => {
                self.unsupported(format!("constant `{kind:?}` reached code generation unevaluated"))
            }
        };
        z::Const { ty: self.ty(constant.ty()), value }
    }

    fn memory(&mut self, allocation: &pty::Allocation) -> z::Memory {
        let mut bytes = String::with_capacity(allocation.bytes.len() * 2);
        for byte in &allocation.bytes {
            match byte {
                Some(byte) => write!(bytes, "{byte:02x}").unwrap(),
                None => bytes.push_str("__"),
            }
        }
        let relocs = allocation
            .provenance
            .ptrs
            .iter()
            .map(|(offset, prov)| z::Reloc { offset: *offset as u64, alloc: self.global_alloc(prov.0) })
            .collect();
        z::Memory { bytes, relocs }
    }

    fn allocation(&mut self, allocation: &pty::Allocation) -> z::Allocation {
        z::Allocation {
            align: allocation.align,
            mutable: is_mut(allocation.mutability),
            memory: self.memory(allocation),
        }
    }

    fn global_alloc(&mut self, id: AllocId) -> z::AllocId {
        if let Some(known) = self.allocs.get(&id) {
            return known;
        }
        let slot = self.allocs.reserve(id);
        let value = match GlobalAlloc::from(id) {
            GlobalAlloc::Memory(allocation) => z::GlobalAlloc::Memory(self.allocation(&allocation)),
            GlobalAlloc::Function(instance) => z::GlobalAlloc::Function { symbol: self.fn_symbol(instance) },
            GlobalAlloc::Static(def) => z::GlobalAlloc::Static { symbol: self.static_symbol(def) },
            vtable @ GlobalAlloc::VTable(..) => {
                let Some(memory) = vtable.vtable_allocation() else {
                    self.unsupported(format!("no vtable exists for `{vtable:?}`"))
                };
                let GlobalAlloc::VTable(ty, _) = vtable else { unreachable!() };
                z::GlobalAlloc::Vtable { ty: self.ty(ty), alloc: self.global_alloc(memory) }
            }
            GlobalAlloc::TypeId { ty } => {
                z::GlobalAlloc::TypeId { ty: self.ty(ty), hash: self.tcx.type_id_hash(internal(self.tcx, ty)).as_u128() }
            }
        };
        self.allocs.fill(slot, value);
        slot
    }

    // Bodies

    fn body(&mut self, cx: &BodyCx<'_>) -> z::Body {
        let body = cx.body;
        z::Body {
            span: self.span(body.span),
            arg_count: body.arg_locals().len() as u32,
            spread_arg: body.spread_arg().map(|local| local as u32),
            locals: body.locals().iter().map(|local| z::Local { ty: self.ty(local.ty) }).collect(),
            blocks: body
                .blocks
                .iter()
                .map(|block| z::Block {
                    statements: block.statements.iter().filter_map(|statement| self.statement(cx, statement)).collect(),
                    terminator: self.terminator(cx, &block.terminator),
                })
                .collect(),
        }
    }

    fn statement(&mut self, cx: &BodyCx<'_>, statement: &mir::Statement) -> Option<z::Statement> {
        let kind = match &statement.kind {
            mir::StatementKind::Assign(place, rvalue) => {
                z::StatementKind::Assign { place: self.place(place), rvalue: self.rvalue(cx, rvalue) }
            }
            mir::StatementKind::SetDiscriminant { place, variant_index } => {
                z::StatementKind::SetDiscriminant { place: self.place(place), variant: variant_index.to_index() as u32 }
            }
            mir::StatementKind::StorageLive(local) => z::StatementKind::StorageLive(*local as u32),
            mir::StatementKind::StorageDead(local) => z::StatementKind::StorageDead(*local as u32),
            mir::StatementKind::Intrinsic(mir::NonDivergingIntrinsic::Assume(cond)) => {
                z::StatementKind::Assume(self.operand(cond))
            }
            mir::StatementKind::Intrinsic(mir::NonDivergingIntrinsic::CopyNonOverlapping(copy)) => {
                z::StatementKind::CopyNonoverlapping {
                    src: self.operand(&copy.src),
                    dst: self.operand(&copy.dst),
                    count: self.operand(&copy.count),
                }
            }
            // These only matter to the borrow checker, the interpreter and coverage instrumentation, so no machine
            // code comes out of them.
            mir::StatementKind::FakeRead(..)
            | mir::StatementKind::PlaceMention(..)
            | mir::StatementKind::AscribeUserType { .. }
            | mir::StatementKind::Coverage(..)
            | mir::StatementKind::ConstEvalCounter
            | mir::StatementKind::Nop => return None,
        };
        Some(z::Statement { span: self.span(statement.source_info.span), kind })
    }

    fn place(&mut self, place: &mir::Place) -> z::Place {
        z::Place {
            local: place.local as u32,
            projection: place
                .projection
                .iter()
                .map(|elem| match elem {
                    mir::ProjectionElem::Deref => z::ProjectionElem::Deref {},
                    mir::ProjectionElem::Field(index, ty) => {
                        z::ProjectionElem::Field { index: *index as u32, ty: self.ty(*ty) }
                    }
                    mir::ProjectionElem::Index(local) => z::ProjectionElem::Index { local: *local as u32 },
                    mir::ProjectionElem::ConstantIndex { offset, min_length, from_end } => {
                        z::ProjectionElem::ConstantIndex { offset: *offset, min_length: *min_length, from_end: *from_end }
                    }
                    mir::ProjectionElem::Subslice { from, to, from_end } => {
                        z::ProjectionElem::Subslice { from: *from, to: *to, from_end: *from_end }
                    }
                    mir::ProjectionElem::Downcast(variant) => {
                        z::ProjectionElem::Downcast { variant: variant.to_index() as u32 }
                    }
                    mir::ProjectionElem::OpaqueCast(ty) => z::ProjectionElem::OpaqueCast { ty: self.ty(*ty) },
                })
                .collect(),
        }
    }

    fn operand(&mut self, operand: &mir::Operand) -> z::Operand {
        match operand {
            mir::Operand::Copy(place) => z::Operand::Copy(self.place(place)),
            mir::Operand::Move(place) => z::Operand::Move(self.place(place)),
            mir::Operand::Constant(constant) => z::Operand::Constant(self.constant(&constant.const_)),
            // Whether a check is on is a session option, which only this side of the pipe knows.
            mir::Operand::RuntimeChecks(check) => {
                let sess = self.tcx.sess;
                let (kind, value) = match check {
                    mir::RuntimeChecks::UbChecks => (z::RuntimeCheck::UbChecks, sess.ub_checks()),
                    mir::RuntimeChecks::ContractChecks => (z::RuntimeCheck::ContractChecks, sess.contract_checks()),
                    mir::RuntimeChecks::OverflowChecks => (z::RuntimeCheck::OverflowChecks, sess.overflow_checks()),
                };
                z::Operand::RuntimeChecks { kind, value }
            }
        }
    }

    fn rvalue(&mut self, cx: &BodyCx<'_>, rvalue: &mir::Rvalue) -> z::Rvalue {
        match rvalue {
            mir::Rvalue::Use(operand, _) => z::Rvalue::Use(self.operand(operand)),
            mir::Rvalue::Repeat(operand, count) => {
                z::Rvalue::Repeat { operand: self.operand(operand), count: self.expect(count.eval_target_usize()) }
            }
            mir::Rvalue::Ref(_, kind, place) => z::Rvalue::Ref {
                kind: match kind {
                    mir::BorrowKind::Shared => z::BorrowKind::Shared,
                    mir::BorrowKind::Fake(_) => z::BorrowKind::Fake,
                    mir::BorrowKind::Mut { .. } => z::BorrowKind::Mut,
                },
                place: self.place(place),
            },
            mir::Rvalue::Reborrow(ty, mutability, place) => {
                z::Rvalue::Reborrow { ty: self.ty(*ty), mutable: is_mut(*mutability), place: self.place(place) }
            }
            mir::Rvalue::AddressOf(kind, place) => z::Rvalue::AddressOf {
                kind: match kind {
                    mir::RawPtrKind::Const => z::RawPtrKind::Const,
                    mir::RawPtrKind::Mut => z::RawPtrKind::Mut,
                    mir::RawPtrKind::FakeForPtrMetadata => z::RawPtrKind::FakeForPtrMetadata,
                },
                place: self.place(place),
            },
            mir::Rvalue::ThreadLocalRef(item) => {
                let def = self.expect(StaticDef::try_from(*item));
                z::Rvalue::ThreadLocalRef { symbol: self.static_symbol(def) }
            }
            mir::Rvalue::Len(place) => z::Rvalue::Len(self.place(place)),
            mir::Rvalue::Cast(kind, operand, ty) => z::Rvalue::Cast {
                kind: self.cast_kind(cx, *kind, operand),
                operand: self.operand(operand),
                ty: self.ty(*ty),
            },
            mir::Rvalue::BinaryOp(op, left, right) => {
                z::Rvalue::BinaryOp { op: bin_op(*op), left: self.operand(left), right: self.operand(right) }
            }
            mir::Rvalue::CheckedBinaryOp(op, left, right) => {
                z::Rvalue::CheckedBinaryOp { op: bin_op(*op), left: self.operand(left), right: self.operand(right) }
            }
            mir::Rvalue::UnaryOp(op, operand) => z::Rvalue::UnaryOp {
                op: match op {
                    mir::UnOp::Not => z::UnOp::Not,
                    mir::UnOp::Neg => z::UnOp::Neg,
                    mir::UnOp::PtrMetadata => z::UnOp::PtrMetadata,
                },
                operand: self.operand(operand),
            },
            mir::Rvalue::Discriminant(place) => z::Rvalue::Discriminant(self.place(place)),
            mir::Rvalue::Aggregate(kind, operands) => z::Rvalue::Aggregate {
                kind: match kind {
                    mir::AggregateKind::Array(_) => z::AggregateKind::Array {},
                    mir::AggregateKind::Tuple => z::AggregateKind::Tuple {},
                    mir::AggregateKind::Adt(_, variant, _, _, active_field) => z::AggregateKind::Adt {
                        variant: variant.to_index() as u32,
                        active_field: active_field.map(|field| field as u32),
                    },
                    mir::AggregateKind::Closure(..) => z::AggregateKind::Closure {},
                    mir::AggregateKind::Coroutine(..) => z::AggregateKind::Coroutine {},
                    mir::AggregateKind::CoroutineClosure(..) => z::AggregateKind::CoroutineClosure {},
                    mir::AggregateKind::RawPtr(..) => z::AggregateKind::RawPtr {},
                },
                ty: {
                    let ty = self.expect(rvalue.ty(cx.body.locals()));
                    self.ty(ty)
                },
                operands: operands.iter().map(|operand| self.operand(operand)).collect(),
            },
            mir::Rvalue::CopyForDeref(place) => z::Rvalue::CopyForDeref(self.place(place)),
        }
    }

    fn cast_kind(&mut self, cx: &BodyCx<'_>, kind: mir::CastKind, operand: &mir::Operand) -> z::CastKind {
        use mir::PointerCoercion as Coercion;
        match kind {
            mir::CastKind::PointerExposeAddress => z::CastKind::PointerExposeAddress {},
            mir::CastKind::PointerWithExposedProvenance => z::CastKind::PointerWithExposedProvenance {},
            mir::CastKind::PointerCoercion(Coercion::ReifyFnPointer(_)) => {
                let from = self.expect(operand.ty(cx.body.locals())).kind();
                let Some((def, args)) = from.fn_def() else {
                    self.unsupported("a function pointer is made from something that is not a function item")
                };
                let instance = self.expect(Instance::resolve_for_fn_ptr(def, args));
                z::CastKind::ReifyFnPointer { symbol: self.fn_symbol(instance) }
            }
            mir::CastKind::PointerCoercion(Coercion::ClosureFnPointer(_)) => {
                let from = self.expect(operand.ty(cx.body.locals())).kind();
                let TyKind::RigidTy(RigidTy::Closure(def, args)) = from else {
                    self.unsupported("a closure is coerced to a function pointer, but the operand is not a closure")
                };
                let instance = self.expect(Instance::resolve_closure(def, &args, pty::ClosureKind::FnOnce));
                z::CastKind::ClosureFnPointer { symbol: self.fn_symbol(instance) }
            }
            mir::CastKind::PointerCoercion(Coercion::UnsafeFnPointer) => z::CastKind::UnsafeFnPointer {},
            mir::CastKind::PointerCoercion(Coercion::MutToConstPointer) => z::CastKind::MutToConstPointer {},
            mir::CastKind::PointerCoercion(Coercion::ArrayToPointer) => z::CastKind::ArrayToPointer {},
            mir::CastKind::PointerCoercion(Coercion::Unsize) => z::CastKind::Unsize {},
            mir::CastKind::IntToInt => z::CastKind::IntToInt {},
            mir::CastKind::FloatToInt => z::CastKind::FloatToInt {},
            mir::CastKind::FloatToFloat => z::CastKind::FloatToFloat {},
            mir::CastKind::IntToFloat => z::CastKind::IntToFloat {},
            mir::CastKind::PtrToPtr => z::CastKind::PtrToPtr {},
            mir::CastKind::FnPtrToPtr => z::CastKind::FnPtrToPtr {},
            mir::CastKind::Transmute => z::CastKind::Transmute {},
            mir::CastKind::BoxDerefTransmute => z::CastKind::BoxDerefTransmute {},
            mir::CastKind::Subtype => z::CastKind::Subtype {},
        }
    }

    fn terminator(&mut self, cx: &BodyCx<'_>, terminator: &mir::Terminator) -> z::Terminator {
        let kind = match &terminator.kind {
            mir::TerminatorKind::Goto { target } => z::TerminatorKind::Goto { target: *target as u32 },
            mir::TerminatorKind::SwitchInt { discr, targets } => z::TerminatorKind::SwitchInt {
                discr: self.operand(discr),
                branches: targets
                    .branches()
                    .map(|(value, target)| z::SwitchBranch { value, target: target as u32 })
                    .collect(),
                otherwise: targets.otherwise() as u32,
            },
            mir::TerminatorKind::Resume => z::TerminatorKind::Resume {},
            mir::TerminatorKind::Abort => z::TerminatorKind::Abort {},
            mir::TerminatorKind::Return => z::TerminatorKind::Return {},
            mir::TerminatorKind::Unreachable => z::TerminatorKind::Unreachable {},
            mir::TerminatorKind::Drop { place, target, unwind } => z::TerminatorKind::Drop {
                place: self.place(place),
                glue: self.drop_glue(cx, place),
                target: *target as u32,
                unwind: unwind_action(unwind),
            },
            mir::TerminatorKind::Call { func, args, destination, target, unwind } => {
                self.call(cx, terminator, func, args, destination, *target, unwind)
            }
            mir::TerminatorKind::Assert { cond, expected, msg, target, unwind } => z::TerminatorKind::Assert {
                cond: self.operand(cond),
                expected: *expected,
                msg: self.assert_message(msg),
                caller_location: self.caller_location(cx, terminator),
                target: *target as u32,
                unwind: unwind_action(unwind),
            },
            mir::TerminatorKind::InlineAsm { template, operands, options, line_spans, destination, unwind } => {
                z::TerminatorKind::InlineAsm {
                    template: template.clone(),
                    operands: operands
                        .iter()
                        .map(|operand| z::InlineAsmOperand {
                            in_value: operand.in_value.as_ref().map(|value| self.operand(value)),
                            out_place: operand.out_place.as_ref().map(|place| self.place(place)),
                            raw: operand.raw_rpr.clone(),
                        })
                        .collect(),
                    options: options.clone(),
                    line_spans: line_spans.clone(),
                    destination: destination.map(|block| block as u32),
                    unwind: unwind_action(unwind),
                }
            }
        };
        z::Terminator { span: self.span(terminator.source_info.span), kind }
    }

    fn drop_glue(&mut self, cx: &BodyCx<'_>, place: &mir::Place) -> z::DropGlue {
        let ty = self.expect(place.ty(cx.body.locals()));
        if matches!(ty.kind(), TyKind::RigidTy(RigidTy::Dynamic(..))) {
            return z::DropGlue::Virtual {};
        }
        let glue = Instance::resolve_drop_in_place(ty);
        if glue.is_empty_shim() { z::DropGlue::None {} } else { z::DropGlue::Direct { symbol: self.fn_symbol(glue) } }
    }

    #[allow(clippy::too_many_arguments)]
    fn call(
        &mut self,
        cx: &BodyCx<'_>,
        terminator: &mir::Terminator,
        func: &mir::Operand,
        args: &[mir::Operand],
        destination: &mir::Place,
        target: Option<usize>,
        unwind: &mir::UnwindAction,
    ) -> z::TerminatorKind {
        let func_ty = self.expect(func.ty(cx.body.locals()));
        let func_kind = func_ty.kind();
        let Some(sig) = func_kind.fn_sig() else { self.unsupported("a call through a value that is not a function") };

        let instance = func_kind.fn_def().map(|(def, generic_args)| self.expect(Instance::resolve(def, generic_args)));
        let callee = match instance {
            None => z::Callee::Indirect {},
            Some(instance) => match instance.kind {
                InstanceKind::Item | InstanceKind::Shim | InstanceKind::LlvmIntrinsic => {
                    z::Callee::Direct { symbol: self.fn_symbol(instance) }
                }
                InstanceKind::Intrinsic => z::Callee::Intrinsic {
                    name: instance.intrinsic_name().expect("an intrinsic instance has an intrinsic name"),
                    fallback: instance.has_body().then(|| self.fn_symbol(instance)),
                },
                InstanceKind::Virtual { idx } => z::Callee::Virtual { index: idx as u64 },
            },
        };
        let caller_location = instance
            .is_some_and(|instance| instance.requires_caller_location())
            .then(|| self.caller_location(cx, terminator));

        z::TerminatorKind::Call {
            func: self.operand(func),
            callee,
            abi: self.call_abi(cx, instance, func_ty, &sig, args),
            rust_call: matches!(sig.value.abi, pty::Abi::RustCall),
            caller_location,
            args: args.iter().map(|arg| self.operand(arg)).collect(),
            destination: self.place(destination),
            target: target.map(|block| block as u32),
            unwind: unwind_action(unwind),
        }
    }

    fn caller_location(&mut self, cx: &BodyCx<'_>, terminator: &mir::Terminator) -> z::CallerLocation {
        // `Body::caller_location` needs the inherited location as a constant and does not say whether it used it,
        // so a marker constant stands in for "the location this function received".
        let marker = cx.track_caller.then(|| pty::MirConst::from_bool(true));
        let location = cx.body.caller_location(terminator, marker.clone());
        if marker.as_ref() == Some(&location) {
            z::CallerLocation::Inherited {}
        } else {
            z::CallerLocation::Const(self.constant(&location))
        }
    }

    fn assert_message(&mut self, message: &mir::AssertMessage) -> z::AssertMessage {
        use mir::AssertMessage as M;
        match message {
            M::BoundsCheck { len, index } => {
                z::AssertMessage::BoundsCheck { len: self.operand(len), index: self.operand(index) }
            }
            M::Overflow(op, left, right) => {
                z::AssertMessage::Overflow { op: bin_op(*op), left: self.operand(left), right: self.operand(right) }
            }
            M::OverflowNeg(operand) => z::AssertMessage::OverflowNeg { operand: self.operand(operand) },
            M::DivisionByZero(operand) => z::AssertMessage::DivisionByZero { operand: self.operand(operand) },
            M::RemainderByZero(operand) => z::AssertMessage::RemainderByZero { operand: self.operand(operand) },
            M::ResumedAfterReturn(kind) => z::AssertMessage::ResumedAfterReturn { coroutine: coroutine_kind(kind) },
            M::ResumedAfterPanic(kind) => z::AssertMessage::ResumedAfterPanic { coroutine: coroutine_kind(kind) },
            M::ResumedAfterDrop(kind) => z::AssertMessage::ResumedAfterDrop { coroutine: coroutine_kind(kind) },
            M::MisalignedPointerDereference { required, found } => z::AssertMessage::MisalignedPointerDereference {
                required: self.operand(required),
                found: self.operand(found),
            },
            M::NullPointerDereference => z::AssertMessage::NullPointerDereference {},
            M::NullReferenceConstructed => z::AssertMessage::NullReferenceConstructed {},
            M::InvalidEnumConstruction(operand) => {
                z::AssertMessage::InvalidEnumConstruction { operand: self.operand(operand) }
            }
        }
    }
}

fn bytes(size: MachineSize) -> u64 {
    size.bytes() as u64
}

fn offsets_in_bytes(offsets: Vec<MachineSize>) -> Vec<u64> {
    offsets.into_iter().map(bytes).collect()
}

fn is_mut(mutability: Mutability) -> bool {
    matches!(mutability, Mutability::Mut)
}

fn reg(reg: &pabi::Reg) -> z::Reg {
    z::Reg {
        kind: match reg.kind {
            pabi::RegKind::Integer => z::RegKind::Integer,
            pabi::RegKind::Float => z::RegKind::Float,
            pabi::RegKind::Vector => z::RegKind::Vector,
        },
        size: bytes(reg.size),
    }
}

fn arg_attrs(attrs: &pabi::ArgAttributes) -> z::ArgAttrs {
    let regular = attrs.regular();
    let flags = [
        (regular.captures_none, z::ArgFlag::CapturesNone),
        (regular.captures_address, z::ArgFlag::CapturesAddress),
        (regular.captures_read_only, z::ArgFlag::CapturesReadOnly),
        (regular.no_alias, z::ArgFlag::NoAlias),
        (regular.non_null, z::ArgFlag::NonNull),
        (regular.read_only, z::ArgFlag::ReadOnly),
        (regular.in_reg, z::ArgFlag::InReg),
        (regular.no_undef, z::ArgFlag::NoUndef),
        (regular.writable, z::ArgFlag::Writable),
        (regular.no_free, z::ArgFlag::NoFree),
    ];
    z::ArgAttrs {
        flags: flags.into_iter().filter_map(|(set, flag)| set.then_some(flag)).collect(),
        ext: match attrs.arg_extension() {
            pabi::ArgExtension::None => z::ArgExtension::None,
            pabi::ArgExtension::Zext => z::ArgExtension::Zext,
            pabi::ArgExtension::Sext => z::ArgExtension::Sext,
        },
        pointee_size: bytes(attrs.pointee_size()),
        pointee_align: attrs.pointee_align(),
    }
}

fn call_conv(conv: pabi::CallConvention) -> z::CallConv {
    use pabi::CallConvention as C;
    match conv {
        C::C => z::CallConv::C,
        C::Rust => z::CallConv::Rust,
        C::Cold => z::CallConv::Cold,
        C::PreserveMost => z::CallConv::PreserveMost,
        C::PreserveAll => z::CallConv::PreserveAll,
        C::PreserveNone => z::CallConv::PreserveNone,
        C::Tail => z::CallConv::Tail,
        C::Custom => z::CallConv::Custom,
        C::Swift => z::CallConv::Swift,
        C::ArmAapcs => z::CallConv::ArmAapcs,
        C::CCmseNonSecureCall => z::CallConv::CCmseNonSecureCall,
        C::CCmseNonSecureEntry => z::CallConv::CCmseNonSecureEntry,
        C::Msp430Intr => z::CallConv::Msp430Intr,
        C::PtxKernel => z::CallConv::PtxKernel,
        C::GpuKernel => z::CallConv::GpuKernel,
        C::X86Fastcall => z::CallConv::X86Fastcall,
        C::X86Intr => z::CallConv::X86Intr,
        C::X86Stdcall => z::CallConv::X86Stdcall,
        C::X86ThisCall => z::CallConv::X86ThisCall,
        C::X86VectorCall => z::CallConv::X86VectorCall,
        C::X86_64SysV => z::CallConv::X86_64SysV,
        C::X86_64Win64 => z::CallConv::X86_64Win64,
        C::AvrInterrupt => z::CallConv::AvrInterrupt,
        C::AvrNonBlockingInterrupt => z::CallConv::AvrNonBlockingInterrupt,
        C::RiscvInterrupt => z::CallConv::RiscvInterrupt,
    }
}

fn linkage(linkage: Linkage) -> z::Linkage {
    use Linkage as L;
    match linkage {
        L::External => z::Linkage::External,
        L::AvailableExternally => z::Linkage::AvailableExternally,
        L::LinkOnceAny => z::Linkage::LinkOnceAny,
        L::LinkOnceODR => z::Linkage::LinkOnceOdr,
        L::WeakAny => z::Linkage::WeakAny,
        L::WeakODR => z::Linkage::WeakOdr,
        L::Internal => z::Linkage::Internal,
        L::ExternalWeak => z::Linkage::ExternalWeak,
    }
}

fn visibility(visibility: mono::Visibility) -> z::Visibility {
    match visibility {
        mono::Visibility::Default => z::Visibility::Default,
        mono::Visibility::Hidden => z::Visibility::Hidden,
        mono::Visibility::Protected => z::Visibility::Protected,
    }
}

fn unwind_action(action: &mir::UnwindAction) -> z::UnwindAction {
    match action {
        mir::UnwindAction::Continue => z::UnwindAction::Continue {},
        mir::UnwindAction::Unreachable => z::UnwindAction::Unreachable {},
        mir::UnwindAction::Terminate => z::UnwindAction::Terminate {},
        mir::UnwindAction::Cleanup(target) => z::UnwindAction::Cleanup { target: *target as u32 },
    }
}

fn coroutine_kind(kind: &mir::CoroutineKind) -> z::CoroutineKind {
    match kind {
        mir::CoroutineKind::Coroutine(_) => z::CoroutineKind::Coroutine,
        mir::CoroutineKind::Desugared(mir::CoroutineDesugaring::Async, _) => z::CoroutineKind::Async,
        mir::CoroutineKind::Desugared(mir::CoroutineDesugaring::Gen, _) => z::CoroutineKind::Gen,
        mir::CoroutineKind::Desugared(mir::CoroutineDesugaring::AsyncGen, _) => z::CoroutineKind::AsyncGen,
    }
}

fn bin_op(op: mir::BinOp) -> z::BinOp {
    use mir::BinOp as B;
    match op {
        B::Add => z::BinOp::Add,
        B::AddUnchecked => z::BinOp::AddUnchecked,
        B::Sub => z::BinOp::Sub,
        B::SubUnchecked => z::BinOp::SubUnchecked,
        B::Mul => z::BinOp::Mul,
        B::MulUnchecked => z::BinOp::MulUnchecked,
        B::Div => z::BinOp::Div,
        B::Rem => z::BinOp::Rem,
        B::BitXor => z::BinOp::BitXor,
        B::BitAnd => z::BinOp::BitAnd,
        B::BitOr => z::BinOp::BitOr,
        B::Shl => z::BinOp::Shl,
        B::ShlUnchecked => z::BinOp::ShlUnchecked,
        B::Shr => z::BinOp::Shr,
        B::ShrUnchecked => z::BinOp::ShrUnchecked,
        B::Eq => z::BinOp::Eq,
        B::Lt => z::BinOp::Lt,
        B::Le => z::BinOp::Le,
        B::Ne => z::BinOp::Ne,
        B::Ge => z::BinOp::Ge,
        B::Gt => z::BinOp::Gt,
        B::Cmp => z::BinOp::Cmp,
        B::Offset => z::BinOp::Offset,
    }
}
