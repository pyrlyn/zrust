//! ZRMIR constants as LLVM constants.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const Lowering = @import("module.zig").Lowering;
const types = @import("types.zig");

/// The constant a scalar's bytes stand for, in the form it is computed with.
pub fn scalar(l: *const Lowering, memory: *const schema.Memory, kind: schema.Scalar) codegen.Error!llvm.LLVMValueRef {
    if (memory.relocs.len != 0) return l.unsupported("a constant that points into another allocation", .{});
    const ty = try types.scalar(l, kind, .immediate);

    const size = memory.bytes.len / 2;
    const uninit = std.mem.count(u8, memory.bytes, "__");
    if (uninit == size) return llvm.LLVMGetUndef(ty);
    // Undefined for the whole value would be wrong: the bytes that are there are a promise.
    if (uninit != 0) return l.unsupported("a scalar constant that is initialised in part", .{});

    var words = [2]u64{ 0, 0 };
    if (size > @sizeOf(@TypeOf(words))) return l.malformed("a scalar constant of {d} bytes", .{size});
    for (0..size) |at| {
        const byte: u64 = byteAt(memory, at).?;
        const significance = switch (l.source.target.endian) {
            .little => at,
            .big => size - 1 - at,
        };
        words[significance / 8] |= byte << @intCast(significance % 8 * 8);
    }
    const bits = llvm.LLVMConstIntOfArbitraryPrecision(
        llvm.LLVMIntTypeInContext(l.context, @intCast(size * 8)),
        words.len,
        &words,
    );
    return switch (kind.primitive) {
        .bool => switch (words[0]) {
            0, 1 => |bit| llvm.LLVMConstInt(ty, bit, 0),
            else => |byte| l.malformed("a `bool` constant with the byte {d}", .{byte}),
        },
        .int => bits,
        .float => llvm.LLVMConstBitCast(bits, ty),
        .pointer => llvm.LLVMConstIntToPtr(bits, ty),
    };
}

/// A constant that is not a scalar, as a global that holds its bytes.
pub fn global(l: *const Lowering, memory: *const schema.Memory, layout: *const schema.Layout) codegen.Error!llvm.LLVMValueRef {
    if (memory.relocs.len != 0) return l.unsupported("a constant that points into another allocation", .{});
    const size = memory.bytes.len / 2;
    if (size != layout.size) return l.malformed("a constant of {d} bytes for a type of {d}", .{ size, layout.size });

    const byte = llvm.LLVMInt8TypeInContext(l.context);
    const elements = try l.arena.alloc(llvm.LLVMValueRef, size);
    for (elements, 0..) |*element, at| {
        element.* = if (byteAt(memory, at)) |defined| llvm.LLVMConstInt(byte, defined, 0) else llvm.LLVMGetUndef(byte);
    }
    const value = llvm.LLVMAddGlobal(l.module, types.bytes(l, size), "");
    llvm.LLVMSetInitializer(value, llvm.LLVMConstArray2(byte, elements.ptr, size));
    llvm.LLVMSetGlobalConstant(value, 1);
    llvm.LLVMSetLinkage(value, llvm.LLVMPrivateLinkage);
    // The constant is read, never compared by address, so equal ones may share their bytes.
    llvm.LLVMSetUnnamedAddress(value, llvm.LLVMGlobalUnnamedAddr);
    // The validator has bounded the alignment.
    llvm.LLVMSetAlignment(value, @intCast(layout.@"align"));
    return value;
}

/// The byte at an index, or null where the constant is not initialised.
fn byteAt(memory: *const schema.Memory, at: usize) ?u8 {
    const digits = memory.bytes[at * 2 ..][0..2];
    if (std.mem.eql(u8, digits, "__")) return null;
    // The validator has checked the digits.
    return std.fmt.parseInt(u8, digits, 16) catch unreachable;
}
