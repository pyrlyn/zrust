//! Operators and casts on scalars.
//!
//! Everything here works on values that are already computed and gives back a value: where operands come from and
//! where a result goes is the business of `function.zig`.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const Lowering = @import("module.zig").Lowering;
const types = @import("types.zig");

/// A scalar in the form it is computed with and passed in: a `bool` is one bit.
pub const Value = struct {
    value: llvm.LLVMValueRef,
    kind: schema.Scalar,
};

pub fn binary(l: *const Lowering, op: schema.BinOp, left: Value, right: Value) codegen.Error!Value {
    const b = l.builder;
    const same = std.meta.eql(left.kind.primitive, right.kind.primitive);
    switch (op) {
        // The amount of a shift may be of any integer type.
        .shl, .shl_unchecked, .shr, .shr_unchecked => {
            const int = try integer(l, op, left);
            if (right.kind.primitive != .int) return l.malformed("a shift by something that is not an integer", .{});
            var amount = resize(l, right.value, right.kind.primitive.int.bits, int.bits, false);
            // MIR defines `shl` and `shr` for every amount, by taking it modulo the width; LLVM leaves an amount of
            // the width or more undefined. The unchecked operators promise that it is in range.
            if (op == .shl or op == .shr) {
                amount = llvm.LLVMBuildAnd(b, amount, llvm.LLVMConstInt(llvm.LLVMTypeOf(left.value), int.bits - 1, 0), "");
            }
            return result(left, switch (op) {
                .shl, .shl_unchecked => llvm.LLVMBuildShl(b, left.value, amount, ""),
                else => if (int.signed)
                    llvm.LLVMBuildAShr(b, left.value, amount, "")
                else
                    llvm.LLVMBuildLShr(b, left.value, amount, ""),
            });
        },
        .cmp, .offset => return l.unsupported("the operator `{s}`", .{@tagName(op)}),
        else => {},
    }
    if (!same) return l.malformed("the operator `{s}` on two values of different kinds", .{@tagName(op)});

    if (comparison(op)) |predicates| {
        const compared = switch (left.kind.primitive) {
            .float => llvm.LLVMBuildFCmp(b, predicates.float, left.value, right.value, ""),
            .int => |int| llvm.LLVMBuildICmp(b, if (int.signed) predicates.signed else predicates.unsigned, left.value, right.value, ""),
            .bool, .pointer => llvm.LLVMBuildICmp(b, predicates.unsigned, left.value, right.value, ""),
        };
        return .{ .value = compared, .kind = types.boolean };
    }

    switch (left.kind.primitive) {
        .float => return result(left, switch (op) {
            .add => llvm.LLVMBuildFAdd(b, left.value, right.value, ""),
            .sub => llvm.LLVMBuildFSub(b, left.value, right.value, ""),
            .mul => llvm.LLVMBuildFMul(b, left.value, right.value, ""),
            .div => llvm.LLVMBuildFDiv(b, left.value, right.value, ""),
            .rem => llvm.LLVMBuildFRem(b, left.value, right.value, ""),
            else => return l.malformed("the operator `{s}` on floats", .{@tagName(op)}),
        }),
        .bool => return result(left, switch (op) {
            .bit_and => llvm.LLVMBuildAnd(b, left.value, right.value, ""),
            .bit_or => llvm.LLVMBuildOr(b, left.value, right.value, ""),
            .bit_xor => llvm.LLVMBuildXor(b, left.value, right.value, ""),
            else => return l.malformed("the operator `{s}` on booleans", .{@tagName(op)}),
        }),
        .pointer => return l.malformed("the operator `{s}` on pointers", .{@tagName(op)}),
        .int => |int| return result(left, switch (op) {
            .add => llvm.LLVMBuildAdd(b, left.value, right.value, ""),
            .sub => llvm.LLVMBuildSub(b, left.value, right.value, ""),
            .mul => llvm.LLVMBuildMul(b, left.value, right.value, ""),
            // The unchecked operators promise not to overflow, which is what `nsw` and `nuw` tell LLVM.
            .add_unchecked => if (int.signed)
                llvm.LLVMBuildNSWAdd(b, left.value, right.value, "")
            else
                llvm.LLVMBuildNUWAdd(b, left.value, right.value, ""),
            .sub_unchecked => if (int.signed)
                llvm.LLVMBuildNSWSub(b, left.value, right.value, "")
            else
                llvm.LLVMBuildNUWSub(b, left.value, right.value, ""),
            .mul_unchecked => if (int.signed)
                llvm.LLVMBuildNSWMul(b, left.value, right.value, "")
            else
                llvm.LLVMBuildNUWMul(b, left.value, right.value, ""),
            // MIR asserts that the divisor is not zero, and for signed operands that the result fits, before either.
            .div => if (int.signed)
                llvm.LLVMBuildSDiv(b, left.value, right.value, "")
            else
                llvm.LLVMBuildUDiv(b, left.value, right.value, ""),
            .rem => if (int.signed)
                llvm.LLVMBuildSRem(b, left.value, right.value, "")
            else
                llvm.LLVMBuildURem(b, left.value, right.value, ""),
            .bit_and => llvm.LLVMBuildAnd(b, left.value, right.value, ""),
            .bit_or => llvm.LLVMBuildOr(b, left.value, right.value, ""),
            .bit_xor => llvm.LLVMBuildXor(b, left.value, right.value, ""),
            else => unreachable,
        }),
    }
}

pub const Checked = struct {
    value: Value,
    overflowed: Value,
};

/// An operator together with whether its exact result did not fit.
pub fn checked(l: *const Lowering, op: schema.BinOp, left: Value, right: Value) codegen.Error!Checked {
    const int = try integer(l, op, left);
    if (!std.meta.eql(left.kind.primitive, right.kind.primitive)) {
        return l.malformed("the checked operator `{s}` on two values of different kinds", .{@tagName(op)});
    }
    const name = switch (op) {
        .add => if (int.signed) "llvm.sadd.with.overflow" else "llvm.uadd.with.overflow",
        .sub => if (int.signed) "llvm.ssub.with.overflow" else "llvm.usub.with.overflow",
        .mul => if (int.signed) "llvm.smul.with.overflow" else "llvm.umul.with.overflow",
        else => return l.unsupported("the checked operator `{s}`", .{@tagName(op)}),
    };
    const both = l.callIntrinsic(name, &.{llvm.LLVMTypeOf(left.value)}, &.{ left.value, right.value });
    return .{
        .value = result(left, llvm.LLVMBuildExtractValue(l.builder, both, 0, "")),
        .overflowed = .{ .value = llvm.LLVMBuildExtractValue(l.builder, both, 1, ""), .kind = types.boolean },
    };
}

pub fn unary(l: *const Lowering, op: schema.UnOp, operand: Value) codegen.Error!Value {
    return result(operand, switch (op) {
        .not => switch (operand.kind.primitive) {
            .bool, .int => llvm.LLVMBuildNot(l.builder, operand.value, ""),
            else => return l.malformed("`not` on a value that is neither an integer nor a boolean", .{}),
        },
        .neg => switch (operand.kind.primitive) {
            .int => llvm.LLVMBuildNeg(l.builder, operand.value, ""),
            .float => llvm.LLVMBuildFNeg(l.builder, operand.value, ""),
            else => return l.malformed("`neg` on a value that is not a number", .{}),
        },
        .ptr_metadata => return l.unsupported("the operator `ptr_metadata`", .{}),
    });
}

/// A cast between two scalars. The casts that need more than the value (`reify_fn_pointer`, `unsize`, …) are not
/// here.
pub fn cast(l: *const Lowering, kind: schema.CastKind, operand: Value, to: schema.Scalar) codegen.Error!Value {
    const b = l.builder;
    const from = operand.kind.primitive;
    const ty = try types.scalar(l, to, .immediate);
    const value = switch (kind) {
        .int_to_int => converted: {
            if (to.primitive != .int) return l.malformed("an `int_to_int` cast to something that is not an integer", .{});
            const bits, const signed = switch (from) {
                // The widths are those of the immediate form: a `bool` is one bit there, and zero-extending it
                // gives 0 or 1.
                .bool => .{ 1, false },
                .int => |int| .{ int.bits, int.signed },
                else => return l.malformed("an `int_to_int` cast of something that is not an integer", .{}),
            };
            break :converted resize(l, operand.value, bits, to.primitive.int.bits, signed);
        },
        .float_to_int => converted: {
            if (from != .float or to.primitive != .int) return l.malformed("a `float_to_int` cast between other kinds", .{});
            // `as` saturates and turns NaN into zero, which is exactly the `sat` intrinsics; `fptosi` and `fptoui`
            // are undefined out of range.
            const name = if (to.primitive.int.signed) "llvm.fptosi.sat" else "llvm.fptoui.sat";
            break :converted l.callIntrinsic(name, &.{ ty, llvm.LLVMTypeOf(operand.value) }, &.{operand.value});
        },
        .int_to_float => converted: {
            if (from != .int or to.primitive != .float) return l.malformed("an `int_to_float` cast between other kinds", .{});
            break :converted if (from.int.signed)
                llvm.LLVMBuildSIToFP(b, operand.value, ty, "")
            else
                llvm.LLVMBuildUIToFP(b, operand.value, ty, "");
        },
        .float_to_float => converted: {
            if (from != .float or to.primitive != .float) return l.malformed("a `float_to_float` cast between other kinds", .{});
            const from_bits = types.bits(l, operand.kind);
            const to_bits = types.bits(l, to);
            break :converted if (from_bits < to_bits)
                llvm.LLVMBuildFPExt(b, operand.value, ty, "")
            else if (from_bits > to_bits)
                llvm.LLVMBuildFPTrunc(b, operand.value, ty, "")
            else
                operand.value;
        },
        // Pointers are opaque to LLVM: one that changes only its Rust type stays the same value.
        .ptr_to_ptr, .mut_to_const_pointer, .fn_ptr_to_ptr, .unsafe_fn_pointer => converted: {
            if (!std.meta.eql(from, to.primitive) or from != .pointer) {
                return l.unsupported("the cast `{s}` between pointers that are not both thin and in one address space", .{@tagName(kind)});
            }
            break :converted operand.value;
        },
        .pointer_expose_address => converted: {
            if (from != .pointer or to.primitive != .int) return l.malformed("a `pointer_expose_address` cast between other kinds", .{});
            break :converted llvm.LLVMBuildPtrToInt(b, operand.value, ty, "");
        },
        .pointer_with_exposed_provenance => converted: {
            if (from != .int or to.primitive != .pointer) return l.malformed("a `pointer_with_exposed_provenance` cast between other kinds", .{});
            break :converted llvm.LLVMBuildIntToPtr(b, operand.value, ty, "");
        },
        .transmute => try transmute(l, operand, to),
        else => return l.unsupported("the cast `{s}`", .{@tagName(kind)}),
    };
    return .{ .value = value, .kind = to };
}

/// Reinterprets the bytes of one scalar as another of the same size.
fn transmute(l: *const Lowering, operand: Value, to: schema.Scalar) codegen.Error!llvm.LLVMValueRef {
    const b = l.builder;
    const bits = types.bits(l, to);
    if (types.bits(l, operand.kind) != bits) return l.malformed("a transmute between scalars of different sizes", .{});
    if (std.meta.eql(operand.kind.primitive, to.primitive)) return operand.value;

    const word = llvm.LLVMIntTypeInContext(l.context, bits);
    const as_int = switch (operand.kind.primitive) {
        .bool => llvm.LLVMBuildZExt(b, operand.value, word, ""),
        .int => operand.value,
        .float => llvm.LLVMBuildBitCast(b, operand.value, word, ""),
        .pointer => llvm.LLVMBuildPtrToInt(b, operand.value, word, ""),
    };
    const ty = try types.scalar(l, to, .immediate);
    return switch (to.primitive) {
        // A byte that is neither 0 nor 1 is no `bool`: transmuting one is undefined, so the other bits may go.
        .bool => llvm.LLVMBuildTrunc(b, as_int, ty, ""),
        .int => as_int,
        .float => llvm.LLVMBuildBitCast(b, as_int, ty, ""),
        .pointer => llvm.LLVMBuildIntToPtr(b, as_int, ty, ""),
    };
}

/// The result of an operator that gives back the type of its operand. The valid range of the operand says nothing
/// about the result.
fn result(operand: Value, value: llvm.LLVMValueRef) Value {
    return .{ .value = value, .kind = .{ .primitive = operand.kind.primitive, .valid_range = null } };
}

fn integer(l: *const Lowering, op: schema.BinOp, value: Value) codegen.Error!@FieldType(schema.Primitive, "int") {
    return switch (value.kind.primitive) {
        .int => |int| int,
        else => l.malformed("the operator `{s}` on a value that is not an integer", .{@tagName(op)}),
    };
}

fn resize(l: *const Lowering, value: llvm.LLVMValueRef, from_bits: u32, to_bits: u32, signed: bool) llvm.LLVMValueRef {
    const ty = llvm.LLVMIntTypeInContext(l.context, to_bits);
    if (from_bits > to_bits) return llvm.LLVMBuildTrunc(l.builder, value, ty, "");
    if (from_bits == to_bits) return value;
    return if (signed) llvm.LLVMBuildSExt(l.builder, value, ty, "") else llvm.LLVMBuildZExt(l.builder, value, ty, "");
}

const Predicates = struct { signed: c_uint, unsigned: c_uint, float: c_uint };

fn comparison(op: schema.BinOp) ?Predicates {
    // The float predicates are the ordered ones, false when an operand is NaN, except for `ne`, which is then true.
    return switch (op) {
        .eq => .{ .signed = llvm.LLVMIntEQ, .unsigned = llvm.LLVMIntEQ, .float = llvm.LLVMRealOEQ },
        .ne => .{ .signed = llvm.LLVMIntNE, .unsigned = llvm.LLVMIntNE, .float = llvm.LLVMRealUNE },
        .lt => .{ .signed = llvm.LLVMIntSLT, .unsigned = llvm.LLVMIntULT, .float = llvm.LLVMRealOLT },
        .le => .{ .signed = llvm.LLVMIntSLE, .unsigned = llvm.LLVMIntULE, .float = llvm.LLVMRealOLE },
        .gt => .{ .signed = llvm.LLVMIntSGT, .unsigned = llvm.LLVMIntUGT, .float = llvm.LLVMRealOGT },
        .ge => .{ .signed = llvm.LLVMIntSGE, .unsigned = llvm.LLVMIntUGE, .float = llvm.LLVMRealOGE },
        else => null,
    };
}
