//! Lowers a ZRMIR module to an LLVM module.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const zrmir = @import("../zrmir.zig");
const schema = zrmir.schema;
const abi = @import("abi.zig");
const function = @import("function.zig");

/// What every part of the lowering needs: the module being read and the one being built.
pub const Lowering = struct {
    arena: std.mem.Allocator,
    source: *const schema.Module,
    context: llvm.LLVMContextRef,
    module: llvm.LLVMModuleRef,
    builder: llvm.LLVMBuilderRef,
    diagnostic: *zrmir.Diagnostic,

    /// Refuses what the code generator cannot compile yet. That is the only alternative to compiling it correctly:
    /// nothing is skipped or approximated.
    pub fn unsupported(l: *const Lowering, comptime what: []const u8, args: anytype) codegen.Error {
        return codegen.fail(l.diagnostic, l.arena, what ++ " is not supported yet", args);
    }

    /// For input that passed the validator and still contradicts itself.
    pub fn malformed(l: *const Lowering, comptime what: []const u8, args: anytype) codegen.Error {
        return codegen.fail(l.diagnostic, l.arena, "the ZRMIR is inconsistent: " ++ what, args);
    }

    pub fn typeOf(l: *const Lowering, id: schema.TypeId) *const schema.Type {
        return &l.source.types[id.index()];
    }

    pub fn layoutOf(l: *const Lowering, id: schema.LayoutId) *const schema.Layout {
        return &l.source.layouts[id.index()];
    }
};

pub fn lowerModule(
    arena: std.mem.Allocator,
    source: *const schema.Module,
    context: llvm.LLVMContextRef,
    machine: llvm.LLVMTargetMachineRef,
    diagnostic: *zrmir.Diagnostic,
) codegen.Error!llvm.LLVMModuleRef {
    const module = llvm.LLVMModuleCreateWithNameInContext(try arena.dupeSentinel(u8, source.cgu_name, 0), context);
    llvm.LLVMSetTarget(module, try arena.dupeSentinel(u8, source.target.llvm_target, 0));
    // LLVM's own data layout for the target, not the string in the ZRMIR: that one is written by rustc for the LLVM
    // rustc ships, a later version than ours. Nothing depends on the difference, because no type is laid out by LLVM.
    const data_layout = llvm.LLVMCreateTargetDataLayout(machine);
    defer llvm.LLVMDisposeTargetData(data_layout);
    llvm.LLVMSetModuleDataLayout(module, data_layout);

    const builder = llvm.LLVMCreateBuilderInContext(context);
    defer llvm.LLVMDisposeBuilder(builder);
    const lowering: Lowering = .{
        .arena = arena,
        .source = source,
        .context = context,
        .module = module,
        .builder = builder,
        .diagnostic = diagnostic,
    };

    if (source.statics.len != 0) {
        const name = source.symbols[source.statics[0].symbol.index()].name;
        return lowering.unsupported("a static (`{s}`)", .{name});
    }
    for (source.functions) |*item| {
        const symbol = &source.symbols[item.symbol.index()];
        const fn_abi = &source.fn_abis[symbol.kind.@"fn".abi.index()];
        const value = try abi.declare(&lowering, item, symbol.name, fn_abi);
        try function.lower(&lowering, item, symbol.name, fn_abi, value);
    }
    return module;
}
