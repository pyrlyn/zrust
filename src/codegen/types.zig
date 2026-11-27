//! ZRMIR layouts as LLVM types.
//!
//! LLVM is never asked to lay a type out. rustc already did, and the sizes, alignments and offsets in the ZRMIR tables
//! are the truth: a scalar becomes the LLVM scalar of its kind, anything else is so many bytes.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const Lowering = @import("module.zig").Lowering;

/// A `bool` is a byte where it is stored and a bit where it is computed with or passed; every other scalar has one form.
pub const Form = enum { memory, immediate };

pub fn scalar(l: *const Lowering, value: schema.Scalar, form: Form) codegen.Error!llvm.LLVMTypeRef {
    return switch (value.primitive) {
        .bool => llvm.LLVMIntTypeInContext(l.context, switch (form) {
            .memory => 8,
            .immediate => 1,
        }),
        .int => |int| llvm.LLVMIntTypeInContext(l.context, int.bits),
        .float => |float| switch (float.format) {
            .f16 => llvm.LLVMHalfTypeInContext(l.context),
            .f32 => llvm.LLVMFloatTypeInContext(l.context),
            .f64 => llvm.LLVMDoubleTypeInContext(l.context),
            .f128 => llvm.LLVMFP128TypeInContext(l.context),
            .f16b, .x87_f80, .ppc_f128 => return l.unsupported("the float format `{s}`", .{@tagName(float.format)}),
        },
        .pointer => |pointer| llvm.LLVMPointerTypeInContext(l.context, pointer.address_space),
    };
}

/// The scalar every comparison gives back.
pub const boolean: schema.Scalar = .{ .primitive = .bool, .valid_range = null };

/// How many bits a scalar takes where it is stored.
pub fn bits(l: *const Lowering, value: schema.Scalar) u32 {
    return switch (value.primitive) {
        .bool => 8,
        .int => |int| int.bits,
        .float => |float| switch (float.format) {
            .f16, .f16b => 16,
            .f32 => 32,
            .f64 => 64,
            .x87_f80 => 80,
            .f128, .ppc_f128 => 128,
        },
        .pointer => l.source.target.pointer_width,
    };
}

/// The type of a stack slot or a global that holds a value of this layout.
pub fn memory(l: *const Lowering, layout: *const schema.Layout) codegen.Error!llvm.LLVMTypeRef {
    return switch (layout.repr) {
        .scalar => |repr| scalar(l, repr.scalar, .memory),
        .scalar_pair, .vector, .aggregate => bytes(l, layout.size),
    };
}

/// So many bytes, which is all LLVM is told about a value that is not a scalar.
pub fn bytes(l: *const Lowering, size: u64) llvm.LLVMTypeRef {
    return llvm.LLVMArrayType2(llvm.LLVMInt8TypeInContext(l.context), size);
}

/// An integer as wide as a pointer.
pub fn pointerSized(l: *const Lowering) llvm.LLVMTypeRef {
    return llvm.LLVMIntTypeInContext(l.context, l.source.target.pointer_width);
}

/// The registers a value is passed in when its pass mode is `cast`, spelled the way rustc's LLVM backend spells
/// them: both sides of a call have to agree on it, and the other side may be compiled by rustc.
pub fn cast(l: *const Lowering, mode: @FieldType(schema.PassMode, "cast")) codegen.Error!llvm.LLVMTypeRef {
    if (mode.pad_i32_count != 0) return l.unsupported("a `cast` pass mode with padding", .{});
    if (mode.rest_offset != null) return l.unsupported("a `cast` pass mode with an offset", .{});

    const unit = try register(l, mode.rest.unit);
    const count = if (mode.rest.total == 0) 0 else count: {
        if (mode.rest.unit.size == 0) return l.malformed("a `cast` pass mode with registers of no size", .{});
        break :count std.math.divCeil(u64, mode.rest.total, mode.rest.unit.size) catch unreachable;
    };
    if (mode.prefix.len == 0) {
        // One 128-bit register that has to stay in consecutive registers is an array of one, which LLVM does not
        // split.
        const splittable = mode.rest.is_consecutive and mode.rest.unit.kind == .integer and mode.rest.unit.size == 16;
        if (count == 1 and !splittable) return unit;
        return llvm.LLVMArrayType2(unit, count);
    }

    var members: std.ArrayList(llvm.LLVMTypeRef) = .empty;
    for (mode.prefix) |reg| try members.append(l.arena, try register(l, reg));
    const repeated = std.math.cast(u32, count) orelse return l.malformed("a `cast` pass mode of {d} registers", .{count});
    try members.appendNTimes(l.arena, unit, repeated);
    return llvm.LLVMStructTypeInContext(l.context, members.items.ptr, @intCast(members.items.len), 0);
}

fn register(l: *const Lowering, reg: schema.Reg) codegen.Error!llvm.LLVMTypeRef {
    return switch (reg.kind) {
        .integer => llvm.LLVMIntTypeInContext(l.context, std.math.cast(c_uint, reg.size * 8) orelse return l.malformed("an integer register of {d} bytes", .{reg.size})),
        .float => switch (reg.size) {
            2 => llvm.LLVMHalfTypeInContext(l.context),
            4 => llvm.LLVMFloatTypeInContext(l.context),
            8 => llvm.LLVMDoubleTypeInContext(l.context),
            16 => llvm.LLVMFP128TypeInContext(l.context),
            else => l.malformed("a float register of {d} bytes", .{reg.size}),
        },
        .vector => l.unsupported("a vector register", .{}),
    };
}

/// How many bytes a stack slot of this type takes. Asked only about the registers of a `cast` pass mode, which are
/// LLVM's own types; the layout of a Rust type is never LLVM's to decide.
pub fn allocSize(l: *const Lowering, ty: llvm.LLVMTypeRef) u64 {
    return llvm.LLVMABISizeOfType(llvm.LLVMGetModuleDataLayout(l.module), ty);
}

pub fn abiAlignment(l: *const Lowering, ty: llvm.LLVMTypeRef) u64 {
    return llvm.LLVMABIAlignmentOfType(llvm.LLVMGetModuleDataLayout(l.module), ty);
}

pub fn toImmediate(l: *const Lowering, value: llvm.LLVMValueRef, kind: schema.Scalar) llvm.LLVMValueRef {
    if (kind.primitive != .bool) return value;
    return llvm.LLVMBuildTrunc(l.builder, value, llvm.LLVMIntTypeInContext(l.context, 1), "");
}

pub fn toMemory(l: *const Lowering, value: llvm.LLVMValueRef, kind: schema.Scalar) llvm.LLVMValueRef {
    if (kind.primitive != .bool) return value;
    return llvm.LLVMBuildZExt(l.builder, value, llvm.LLVMIntTypeInContext(l.context, 8), "");
}
