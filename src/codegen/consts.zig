//! ZRMIR constants as LLVM constants.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const Lowering = @import("module.zig").Lowering;
const types = @import("types.zig");

/// The constant a scalar's bytes stand for, in the form it is stored in.
pub fn scalar(l: *const Lowering, memory: *const schema.Memory, kind: schema.Scalar) codegen.Error!llvm.LLVMValueRef {
    if (memory.relocs.len != 0) return l.unsupported("a constant that points into another allocation", .{});
    const ty = try types.scalar(l, kind, .memory);

    const size = memory.bytes.len / 2;
    const uninit = std.mem.count(u8, memory.bytes, "__");
    if (uninit == size) return llvm.LLVMGetUndef(ty);
    // Undefined for the whole value would be wrong: the bytes that are there are a promise.
    if (uninit != 0) return l.unsupported("a scalar constant that is initialised in part", .{});

    var words = [2]u64{ 0, 0 };
    if (size > @sizeOf(@TypeOf(words))) return l.malformed("a scalar constant of {d} bytes", .{size});
    for (0..size) |at| {
        // The validator has checked the digits.
        const byte: u64 = std.fmt.parseInt(u8, memory.bytes[at * 2 ..][0..2], 16) catch unreachable;
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
        .bool, .int => bits,
        .float => llvm.LLVMConstBitCast(bits, ty),
        .pointer => llvm.LLVMConstIntToPtr(bits, ty),
    };
}
