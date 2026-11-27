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

/// The type of a function with this ABI, which is also the type a call through a pointer names.
pub fn signature(l: *const Lowering, fn_abi: *const schema.FnAbi) codegen.Error!llvm.LLVMTypeRef {
    if (fn_abi.c_variadic) return l.unsupported("a C-variadic function", .{});

    var params: std.ArrayList(llvm.LLVMTypeRef) = .empty;
    for (fn_abi.args) |*arg| {
        if (try directScalar(l, arg)) |kind| try params.append(l.arena, try types.scalar(l, kind, .immediate));
    }
    const ret = if (try directScalar(l, &fn_abi.ret)) |kind|
        try types.scalar(l, kind, .immediate)
    else
        llvm.LLVMVoidTypeInContext(l.context);
    return llvm.LLVMFunctionType(ret, params.items.ptr, @intCast(params.items.len), 0);
}

pub fn convention(l: *const Lowering, fn_abi: *const schema.FnAbi) codegen.Error!c_uint {
    return switch (fn_abi.conv) {
        // The Rust ABI is not a calling convention of its own for LLVM: its rules are all in the pass modes.
        .c, .rust => llvm.LLVMCCallConv,
        else => |other| l.unsupported("the calling convention `{s}`", .{@tagName(other)}),
    };
}

/// The scalar an argument or a return value is passed as, or null if nothing is passed for it.
pub fn directScalar(l: *const Lowering, arg: *const schema.ArgAbi) codegen.Error!?schema.Scalar {
    switch (arg.mode) {
        .ignore => return null,
        .direct => {},
        else => |mode| return l.unsupported(
            "passing `{s}` in the `{s}` mode",
            .{ l.typeOf(arg.ty).name, @tagName(mode) },
        ),
    }
    return switch (l.layoutOf(arg.layout).repr) {
        .scalar => |repr| repr.scalar,
        else => l.unsupported("passing `{s}`, which is not a scalar, directly", .{l.typeOf(arg.ty).name}),
    };
}

/// A function and a call of it have to agree on how values are extended, and a call through a pointer has only
/// itself to say so: the attributes go on both.
pub const Attributed = union(enum) {
    function: llvm.LLVMValueRef,
    call: llvm.LLVMValueRef,
};

/// Only the attributes that change how a value is passed. Those that merely license optimizations (`noundef`,
/// `nonnull`, `noalias`, …) wait until there is something to optimize.
pub fn attributes(l: *const Lowering, fn_abi: *const schema.FnAbi, on: Attributed) void {
    var param: c_uint = 0;
    for (fn_abi.args) |*arg| switch (arg.mode) {
        .direct => |direct| {
            // LLVM counts parameters from one here; zero is the return value.
            param += 1;
            argAttributes(l, on, param, &direct.attrs);
        },
        else => {},
    };
    switch (fn_abi.ret.mode) {
        .direct => |direct| argAttributes(l, on, llvm.LLVMAttributeReturnIndex, &direct.attrs),
        else => {},
    }
}

fn argAttributes(l: *const Lowering, on: Attributed, index: c_uint, attrs: *const schema.ArgAttrs) void {
    switch (attrs.ext) {
        .none => {},
        .zext => attribute(l, on, index, "zeroext"),
        .sext => attribute(l, on, index, "signext"),
    }
    if (std.mem.findScalarPos(schema.ArgFlag, attrs.flags, 0, .in_reg) != null) attribute(l, on, index, "inreg");
}

fn attribute(l: *const Lowering, on: Attributed, index: c_uint, name: []const u8) void {
    const kind = llvm.LLVMGetEnumAttributeKindForName(name.ptr, name.len);
    const value = llvm.LLVMCreateEnumAttribute(l.context, kind, 0);
    switch (on) {
        .function => |function| llvm.LLVMAddAttributeAtIndex(function, index, value),
        .call => |call| llvm.LLVMAddCallSiteAttribute(call, index, value),
    }
}
