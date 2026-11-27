//! ZRMIR function ABIs as LLVM function signatures.
//!
//! rustc has already decided how every argument travels (`PassMode`); this only spells that decision in LLVM's terms.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const Lowering = @import("module.zig").Lowering;
const types = @import("types.zig");

/// Adds the function to the LLVM module, without a body.
pub fn declare(
    l: *const Lowering,
    item: *const schema.Function,
    name: []const u8,
    fn_abi: *const schema.FnAbi,
) codegen.Error!llvm.LLVMValueRef {
    if (fn_abi.c_variadic) return l.unsupported("a C-variadic function", .{});
    const conv: c_uint = switch (fn_abi.conv) {
        // The Rust ABI is not a calling convention of its own for LLVM: its rules are all in the pass modes.
        .c, .rust => llvm.LLVMCCallConv,
        else => |other| return l.unsupported("the calling convention `{s}`", .{@tagName(other)}),
    };

    var params: std.ArrayList(llvm.LLVMTypeRef) = .empty;
    for (fn_abi.args) |*arg| {
        if (try directScalar(l, arg)) |kind| try params.append(l.arena, try types.scalar(l, kind, .immediate));
    }
    const ret = if (try directScalar(l, &fn_abi.ret)) |kind|
        try types.scalar(l, kind, .immediate)
    else
        llvm.LLVMVoidTypeInContext(l.context);

    const value = llvm.LLVMAddFunction(
        l.module,
        try l.arena.dupeSentinel(u8, name, 0),
        llvm.LLVMFunctionType(ret, params.items.ptr, @intCast(params.items.len), 0),
    );
    llvm.LLVMSetFunctionCallConv(value, conv);
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

    var param: c_uint = 0;
    for (fn_abi.args) |*arg| switch (arg.mode) {
        .direct => |direct| {
            param += 1;
            attributes(l, value, param, &direct.attrs);
        },
        else => {},
    };
    switch (fn_abi.ret.mode) {
        .direct => |direct| attributes(l, value, llvm.LLVMAttributeReturnIndex, &direct.attrs),
        else => {},
    }
    return value;
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

/// Only the attributes that change how a value is passed. Those that merely license optimizations (`noundef`,
/// `nonnull`, `noalias`, …) wait until there is something to optimize.
fn attributes(l: *const Lowering, function: llvm.LLVMValueRef, index: c_uint, attrs: *const schema.ArgAttrs) void {
    switch (attrs.ext) {
        .none => {},
        .zext => attribute(l, function, index, "zeroext"),
        .sext => attribute(l, function, index, "signext"),
    }
    if (std.mem.findScalarPos(schema.ArgFlag, attrs.flags, 0, .in_reg) != null) attribute(l, function, index, "inreg");
}

fn attribute(l: *const Lowering, function: llvm.LLVMValueRef, index: c_uint, name: []const u8) void {
    const kind = llvm.LLVMGetEnumAttributeKindForName(name.ptr, name.len);
    llvm.LLVMAddAttributeAtIndex(function, index, llvm.LLVMCreateEnumAttribute(l.context, kind, 0));
}
