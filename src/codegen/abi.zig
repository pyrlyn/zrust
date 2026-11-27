//! ZRMIR function ABIs as LLVM function signatures.
//!
//! rustc has already decided how every argument travels (`PassMode`); this only spells that decision in LLVM's terms.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const Lowering = @import("module.zig").Lowering;
const types = @import("types.zig");

/// The LLVM function of this name, added to the module without a body if it is not there yet.
pub fn declare(l: *const Lowering, name: []const u8, fn_abi: *const schema.FnAbi) codegen.Error!llvm.LLVMValueRef {
    const name_z = try l.arena.dupeSentinel(u8, name, 0);
    if (llvm.LLVMGetNamedFunction(l.module, name_z)) |declared| return declared;

    const value = llvm.LLVMAddFunction(l.module, name_z, try signature(l, fn_abi));
    llvm.LLVMSetFunctionCallConv(value, try convention(l, fn_abi));
    attributes(l, fn_abi, .{ .function = value });
    return value;
}

/// Gives a declared function what only its definition knows.
pub fn define(value: llvm.LLVMValueRef, item: *const schema.Function) void {
    llvm.LLVMSetLinkage(value, switch (item.linkage) {
        .external => llvm.LLVMExternalLinkage,
        .available_externally => llvm.LLVMAvailableExternallyLinkage,
        .link_once_any => llvm.LLVMLinkOnceAnyLinkage,
        .link_once_odr => llvm.LLVMLinkOnceODRLinkage,
        .weak_any => llvm.LLVMWeakAnyLinkage,
        .weak_odr => llvm.LLVMWeakODRLinkage,
        .internal => llvm.LLVMInternalLinkage,
        .external_weak => llvm.LLVMExternalWeakLinkage,
    });
    llvm.LLVMSetVisibility(value, switch (item.visibility) {
        .default => llvm.LLVMDefaultVisibility,
        .hidden => llvm.LLVMHiddenVisibility,
        .protected => llvm.LLVMProtectedVisibility,
    });
}

/// How a value travels between a caller and a callee, in LLVM's terms.
pub const Passed = union(enum) {
    /// Not at all: the value has no size.
    ignore,
    direct: schema.Scalar,
    pair: Pair,
    /// In registers of this LLVM type, whatever the Rust type is made of.
    cast: llvm.LLVMTypeRef,
    indirect: Indirect,

    pub const Pair = @FieldType(schema.ValueRepr, "scalar_pair");

    /// In memory, by a pointer to it.
    pub const Indirect = struct {
        /// What the callee may take the pointer to be aligned to.
        alignment: u64,
    };
};

pub fn classify(l: *const Lowering, arg: *const schema.ArgAbi) codegen.Error!Passed {
    const layout = l.layoutOf(arg.layout);
    const name = l.typeOf(arg.ty).name;
    switch (arg.mode) {
        .ignore => return .ignore,
        .direct => return switch (layout.repr) {
            .scalar => |repr| .{ .direct = repr.scalar },
            else => l.unsupported("passing `{s}`, which is not a scalar, directly", .{name}),
        },
        .pair => return switch (layout.repr) {
            .scalar_pair => |pair| .{ .pair = pair },
            else => l.malformed("`{s}` is passed as a pair of scalars and is not one", .{name}),
        },
        .cast => |cast| return .{ .cast = try types.cast(l, cast) },
        .indirect => |indirect| {
            if (indirect.address_space orelse 0 != 0) return l.unsupported("passing `{s}` in another address space", .{name});
            if (indirect.mode == .amdgpu_kernel_arg) return l.unsupported("passing `{s}` as a GPU kernel argument", .{name});
            return .{ .indirect = .{ .alignment = indirect.attrs.pointee_align orelse layout.@"align" } };
        },
        .indirect_unsized => return l.unsupported("passing `{s}`, which has no size known when compiling", .{name}),
    }
}

/// The type of a function with this ABI, which is also the type a call through a pointer names.
///
/// The parameters come in the order `attributes` and both ends of a call count them in: the pointer to the memory
/// of a result returned indirectly, then one or two per argument that is passed at all.
pub fn signature(l: *const Lowering, fn_abi: *const schema.FnAbi) codegen.Error!llvm.LLVMTypeRef {
    if (fn_abi.c_variadic) return l.unsupported("a C-variadic function", .{});

    const pointer = llvm.LLVMPointerTypeInContext(l.context, 0);
    var params: std.ArrayList(llvm.LLVMTypeRef) = .empty;
    const ret = switch (try classify(l, &fn_abi.ret)) {
        .ignore => llvm.LLVMVoidTypeInContext(l.context),
        .direct => |kind| try types.scalar(l, kind, .immediate),
        .pair => |pair| both: {
            var members = [_]llvm.LLVMTypeRef{ try types.scalar(l, pair.a, .immediate), try types.scalar(l, pair.b, .immediate) };
            break :both llvm.LLVMStructTypeInContext(l.context, &members, members.len, 0);
        },
        .cast => |ty| ty,
        .indirect => in_memory: {
            if (fn_abi.ret.mode.indirect.mode != .pointer) return l.malformed("a result is returned on the stack", .{});
            try params.append(l.arena, pointer);
            break :in_memory llvm.LLVMVoidTypeInContext(l.context);
        },
    };
    for (fn_abi.args) |*arg| switch (try classify(l, arg)) {
        .ignore => {},
        .direct => |kind| try params.append(l.arena, try types.scalar(l, kind, .immediate)),
        .pair => |pair| {
            try params.append(l.arena, try types.scalar(l, pair.a, .immediate));
            try params.append(l.arena, try types.scalar(l, pair.b, .immediate));
        },
        .cast => |ty| try params.append(l.arena, ty),
        .indirect => try params.append(l.arena, pointer),
    };
    return llvm.LLVMFunctionType(ret, params.items.ptr, @intCast(params.items.len), 0);
}

pub fn convention(l: *const Lowering, fn_abi: *const schema.FnAbi) codegen.Error!c_uint {
    return switch (fn_abi.conv) {
        // The Rust ABI is not a calling convention of its own for LLVM: its rules are all in the pass modes.
        .c, .rust => llvm.LLVMCCallConv,
        else => |other| l.unsupported("the calling convention `{s}`", .{@tagName(other)}),
    };
}

/// A function and a call of it have to agree on how values are passed, and a call through a pointer has only
/// itself to say so: the attributes go on both.
pub const Attributed = union(enum) {
    function: llvm.LLVMValueRef,
    call: llvm.LLVMValueRef,
};

/// Only the attributes that change how a value is passed. Those that merely license optimizations (`noundef`,
/// `nonnull`, `noalias`, …) wait until there is something to optimize. For a signature `signature` has accepted.
pub fn attributes(l: *const Lowering, fn_abi: *const schema.FnAbi, on: Attributed) void {
    // LLVM counts parameters from one here; zero is the return value.
    var param: c_uint = 0;
    switch (fn_abi.ret.mode) {
        .direct => |*direct| argAttributes(l, on, llvm.LLVMAttributeReturnIndex, &direct.attrs),
        .indirect => |*indirect| {
            param += 1;
            argAttributes(l, on, param, &indirect.attrs);
            memoryAttributes(l, on, param, "sret", &fn_abi.ret);
        },
        else => {},
    }
    for (fn_abi.args) |*arg| switch (arg.mode) {
        .ignore, .indirect_unsized => {},
        .direct => |*direct| {
            param += 1;
            argAttributes(l, on, param, &direct.attrs);
        },
        .pair => |*pair| {
            argAttributes(l, on, param + 1, &pair.a);
            argAttributes(l, on, param + 2, &pair.b);
            param += 2;
        },
        .cast => param += 1,
        .indirect => |*indirect| {
            param += 1;
            argAttributes(l, on, param, &indirect.attrs);
            memoryAttributes(l, on, param, if (indirect.mode == .on_stack) "byval" else null, arg);
        },
    };
}

fn argAttributes(l: *const Lowering, on: Attributed, index: c_uint, attrs: *const schema.ArgAttrs) void {
    switch (attrs.ext) {
        .none => {},
        .zext => attribute(on, index, enumAttribute(l, "zeroext", 0)),
        .sext => attribute(on, index, enumAttribute(l, "signext", 0)),
    }
    if (std.mem.findScalarPos(schema.ArgFlag, attrs.flags, 0, .in_reg) != null) attribute(on, index, enumAttribute(l, "inreg", 0));
}

/// What a pointer to the memory of a value says about that memory. `sret` and `byval` name the value's size, which
/// decides where LLVM puts it; for `byval` the alignment decides it too.
fn memoryAttributes(l: *const Lowering, on: Attributed, index: c_uint, kind: ?[]const u8, arg: *const schema.ArgAbi) void {
    if (kind) |name| {
        const id = llvm.LLVMGetEnumAttributeKindForName(name.ptr, name.len);
        attribute(on, index, llvm.LLVMCreateTypeAttribute(l.context, id, types.bytes(l, l.layoutOf(arg.layout).size)));
    }
    if (arg.mode.indirect.attrs.pointee_align) |alignment| attribute(on, index, enumAttribute(l, "align", alignment));
}

fn enumAttribute(l: *const Lowering, name: []const u8, value: u64) llvm.LLVMAttributeRef {
    return llvm.LLVMCreateEnumAttribute(l.context, llvm.LLVMGetEnumAttributeKindForName(name.ptr, name.len), value);
}

fn attribute(on: Attributed, index: c_uint, value: llvm.LLVMAttributeRef) void {
    switch (on) {
        .function => |function| llvm.LLVMAddAttributeAtIndex(function, index, value),
        .call => |call| llvm.LLVMAddCallSiteAttribute(call, index, value),
    }
}
