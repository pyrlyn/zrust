//! Global memory: the statics of a unit, and the memory without a name its constants point into.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const consts = @import("consts.zig");
const module = @import("module.zig");
const types = @import("types.zig");

const Lowering = module.Lowering;

/// Makes the global of a static the unit defines, without its contents: those may point at any other static, this
/// one included.
pub fn declare(l: *const Lowering, item: *const schema.Static) codegen.Error!void {
    const name = try nameOf(l, item.symbol);
    if (llvm.LLVMGetNamedGlobal(l.module, name) != null) return l.malformed("the static `{s}` is defined twice", .{name});

    const value = llvm.LLVMAddGlobal(l.module, try consts.shape(l, &item.init.memory), name);
    module.define(value, item.linkage, item.visibility);
    // The validator has bounded the alignment.
    llvm.LLVMSetAlignment(value, @intCast(item.init.@"align"));
    // A static that is written, through `static mut` or through a cell, must not land in read-only memory.
    llvm.LLVMSetGlobalConstant(value, @intFromBool(!item.init.mutable));
}

pub fn initialize(l: *const Lowering, item: *const schema.Static) codegen.Error!void {
    llvm.LLVMSetInitializer(try staticOf(l, item.symbol), try consts.initializer(l, &item.init.memory));
}

/// The global of a static, declared on first use when the unit does not define it.
pub fn staticOf(l: *const Lowering, id: schema.SymbolId) codegen.Error!llvm.LLVMValueRef {
    const name = try nameOf(l, id);
    if (llvm.LLVMGetNamedGlobal(l.module, name)) |known| return known;
    // All that is known of a static defined elsewhere is its address, so nothing is promised about what is there:
    // no size and no alignment.
    return llvm.LLVMAddGlobal(l.module, types.bytes(l, 0), name);
}

fn nameOf(l: *const Lowering, id: schema.SymbolId) codegen.Error![:0]const u8 {
    const symbol = &l.source.symbols[id.index()];
    switch (symbol.kind) {
        .static => |static| if (static.thread_local) return l.unsupported("the thread-local static `{s}`", .{symbol.name}),
        .@"fn" => return l.malformed("the function `{s}` is used as a static", .{symbol.name}),
    }
    return l.arena.dupeSentinel(u8, symbol.name, 0);
}

/// The address a pointer in a constant stands for: `offset` bytes into what the allocation is.
pub fn address(l: *const Lowering, id: schema.AllocId, offset: u64) codegen.Error!llvm.LLVMValueRef {
    const word = types.pointerSized(l);
    const base = switch (l.source.allocs[id.index()]) {
        .memory => |*allocation| base: {
            // Memory of no bytes has no address of its own. A pointer into it only has to be aligned and not null,
            // and rustc makes it the alignment itself.
            if (allocation.memory.bytes.len == 0) {
                const dangling = llvm.LLVMConstInt(word, allocation.@"align" +% offset, 0);
                return llvm.LLVMConstIntToPtr(dangling, llvm.LLVMPointerTypeInContext(l.context, 0));
            }
            break :base try anonymous(l, id, allocation);
        },
        .function => |function| try l.functionOf(function.symbol),
        .static => |static| try staticOf(l, static.symbol),
        .vtable => return l.unsupported("a pointer to a vtable", .{}),
        .type_id => return l.unsupported("a constant that holds a `TypeId`", .{}),
    };
    if (offset == 0) return base;
    var index = llvm.LLVMConstInt(word, offset, 0);
    // Not `inbounds`: a constant may hold a pointer that was moved out of its allocation and is never read through.
    return llvm.LLVMConstGEP2(llvm.LLVMInt8TypeInContext(l.context), base, &index, 1);
}

/// The global of memory without a name, made the first time something points at it.
fn anonymous(l: *const Lowering, id: schema.AllocId, allocation: *const schema.Allocation) codegen.Error!llvm.LLVMValueRef {
    const made = &l.allocs[id.index()];
    if (made.*) |value| return value;
    const value = private(l, try consts.shape(l, &allocation.memory), allocation.@"align", !allocation.mutable);
    // Known before its contents are: they may point back at it.
    made.* = value;
    llvm.LLVMSetInitializer(value, try consts.initializer(l, &allocation.memory));
    return value;
}

/// A global for the value of a constant that is used where it is written, to copy the value from.
pub fn constant(l: *const Lowering, memory: *const schema.Memory, alignment: u64) codegen.Error!llvm.LLVMValueRef {
    const value = private(l, try consts.shape(l, memory), alignment, true);
    llvm.LLVMSetInitializer(value, try consts.initializer(l, memory));
    return value;
}

fn private(l: *const Lowering, ty: llvm.LLVMTypeRef, alignment: u64, read_only: bool) llvm.LLVMValueRef {
    const value = llvm.LLVMAddGlobal(l.module, ty, "");
    llvm.LLVMSetLinkage(value, llvm.LLVMPrivateLinkage);
    // The validator has bounded the alignment.
    llvm.LLVMSetAlignment(value, @intCast(alignment));
    if (read_only) {
        llvm.LLVMSetGlobalConstant(value, 1);
        // Rust promises nothing about the address of a constant, so equal ones may share their bytes. Memory that is
        // written is another matter: two of those are two.
        llvm.LLVMSetUnnamedAddress(value, llvm.LLVMGlobalUnnamedAddr);
    }
    return value;
}
