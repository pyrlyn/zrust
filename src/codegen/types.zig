//! ZRMIR layouts as LLVM types.
//!
//! LLVM is never asked to lay a type out. rustc already did, and the sizes, alignments and offsets in the ZRMIR tables
//! are the truth: a scalar becomes the LLVM scalar of its kind, anything else is so many bytes.

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

/// The type of a stack slot or a global that holds a value of this layout.
pub fn memory(l: *const Lowering, layout: *const schema.Layout) codegen.Error!llvm.LLVMTypeRef {
    return switch (layout.repr) {
        .scalar => |repr| scalar(l, repr.scalar, .memory),
        .scalar_pair, .vector, .aggregate => llvm.LLVMArrayType2(llvm.LLVMInt8TypeInContext(l.context), layout.size),
    };
}

pub fn toImmediate(l: *const Lowering, value: llvm.LLVMValueRef, kind: schema.Scalar) llvm.LLVMValueRef {
    if (kind.primitive != .bool) return value;
    return llvm.LLVMBuildTrunc(l.builder, value, llvm.LLVMIntTypeInContext(l.context, 1), "");
}

pub fn toMemory(l: *const Lowering, value: llvm.LLVMValueRef, kind: schema.Scalar) llvm.LLVMValueRef {
    if (kind.primitive != .bool) return value;
    return llvm.LLVMBuildZExt(l.builder, value, llvm.LLVMIntTypeInContext(l.context, 8), "");
}
