//! ZRMIR constants as LLVM constants.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const globals = @import("globals.zig");
const Lowering = @import("module.zig").Lowering;
const types = @import("types.zig");

/// The constant a scalar's bytes stand for, in the form it is computed with.
pub fn scalar(l: *const Lowering, memory: *const schema.Memory, kind: schema.Scalar) codegen.Error!llvm.LLVMValueRef {
    const ty = try types.scalar(l, kind, .immediate);
    const size = memory.bytes.len / 2;
    if (memory.relocs.len != 0) {
        // rustc's interpreter never leaves a pointer in a value that is not one.
        if (kind.primitive != .pointer) return l.malformed("a `{s}` constant that holds a pointer", .{@tagName(kind.primitive)});
        const reloc = memory.relocs[0];
        if (memory.relocs.len != 1 or reloc.offset != 0 or size != pointerSize(l)) {
            return l.malformed("a pointer constant that is not one pointer", .{});
        }
        return globals.address(l, reloc.alloc, try addend(l, memory, reloc));
    }

    const uninit = std.mem.count(u8, memory.bytes, "__");
    if (uninit == size) return llvm.LLVMGetUndef(ty);
    // Undefined for the whole value would be wrong: the bytes that are there are a promise.
    if (uninit != 0) return l.unsupported("a scalar constant that is initialised in part", .{});

    if (size > @sizeOf([2]u64)) return l.malformed("a scalar constant of {d} bytes", .{size});
    var words = integer(l, memory, 0, size);
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

/// The type of a global that holds this memory: bytes, or a packed struct of the runs of bytes between the pointers
/// and the pointers themselves. It depends on where the pointers are and not on what they point at, so a global can
/// be made before the globals its contents point at.
pub fn shape(l: *const Lowering, memory: *const schema.Memory) codegen.Error!llvm.LLVMTypeRef {
    if (memory.relocs.len == 0) return types.bytes(l, memory.bytes.len / 2);
    const parts = try split(l, memory);
    const members = try l.arena.alloc(llvm.LLVMTypeRef, parts.len);
    for (members, parts) |*member, part| member.* = switch (part) {
        .bytes => |run| types.bytes(l, run.len),
        .pointer => pointerType(l),
    };
    return llvm.LLVMStructTypeInContext(l.context, members.ptr, @intCast(members.len), 1);
}

/// The contents of a global of the type `shape` gives for the same memory.
pub fn initializer(l: *const Lowering, memory: *const schema.Memory) codegen.Error!llvm.LLVMValueRef {
    if (memory.relocs.len == 0) return bytesOf(l, memory, 0, memory.bytes.len / 2);
    const parts = try split(l, memory);
    const members = try l.arena.alloc(llvm.LLVMValueRef, parts.len);
    for (members, parts) |*member, part| member.* = switch (part) {
        .bytes => |run| try bytesOf(l, memory, run.from, run.len),
        .pointer => |reloc| try globals.address(l, reloc.alloc, try addend(l, memory, reloc)),
    };
    return llvm.LLVMConstStructInContext(l.context, members.ptr, @intCast(members.len), 1);
}

/// What memory with pointers in it is made of, from its first byte to its last.
const Part = union(enum) {
    bytes: struct { from: usize, len: usize },
    pointer: schema.Reloc,
};

fn split(l: *const Lowering, memory: *const schema.Memory) codegen.Error![]const Part {
    const size = memory.bytes.len / 2;
    const pointer = pointerSize(l);
    var parts: std.ArrayList(Part) = .empty;
    var at: usize = 0;
    for (memory.relocs) |reloc| {
        const offset = std.math.cast(usize, reloc.offset) orelse size;
        if (offset < at or offset > size or size - offset < pointer) {
            return l.malformed("a pointer in a constant overlaps another one or the end of the constant", .{});
        }
        if (offset > at) try parts.append(l.arena, .{ .bytes = .{ .from = at, .len = offset - at } });
        try parts.append(l.arena, .{ .pointer = reloc });
        at = offset + pointer;
    }
    if (size > at) try parts.append(l.arena, .{ .bytes = .{ .from = at, .len = size - at } });
    return parts.items;
}

/// The bytes at a relocation are no part of the address of what it points at: they say how far into it the pointer
/// points.
fn addend(l: *const Lowering, memory: *const schema.Memory, reloc: schema.Reloc) codegen.Error!u64 {
    const from: usize = @intCast(reloc.offset);
    const pointer = pointerSize(l);
    if (std.mem.find(u8, memory.bytes[from * 2 ..][0 .. pointer * 2], "__") != null) {
        return l.malformed("a pointer in a constant that is not initialised", .{});
    }
    return integer(l, memory, from, pointer)[0];
}

/// A run of bytes that holds no pointer.
fn bytesOf(l: *const Lowering, memory: *const schema.Memory, from: usize, len: usize) codegen.Error!llvm.LLVMValueRef {
    const digits = memory.bytes[from * 2 ..][0 .. len * 2];
    const byte = llvm.LLVMInt8TypeInContext(l.context);
    if (std.mem.find(u8, digits, "__") == null) {
        const decoded = try l.arena.alloc(u8, len);
        for (decoded, 0..) |*one, at| one.* = byteAt(memory, from + at).?;
        // Not a C string: nothing is appended to the bytes.
        return llvm.LLVMConstStringInContext2(l.context, decoded.ptr, decoded.len, 1);
    }
    const elements = try l.arena.alloc(llvm.LLVMValueRef, len);
    for (elements, 0..) |*element, at| {
        element.* = if (byteAt(memory, from + at)) |defined| llvm.LLVMConstInt(byte, defined, 0) else llvm.LLVMGetUndef(byte);
    }
    return llvm.LLVMConstArray2(byte, elements.ptr, len);
}

/// The integer in `size` initialised bytes, at most sixteen of them, as LLVM takes one: the low word first.
fn integer(l: *const Lowering, memory: *const schema.Memory, from: usize, size: usize) [2]u64 {
    var words = [2]u64{ 0, 0 };
    for (0..size) |at| {
        const byte: u64 = byteAt(memory, from + at).?;
        const significance = switch (l.source.target.endian) {
            .little => at,
            .big => size - 1 - at,
        };
        words[significance / 8] |= byte << @intCast(significance % 8 * 8);
    }
    return words;
}

/// The byte at an index, or null where the constant is not initialised.
fn byteAt(memory: *const schema.Memory, at: usize) ?u8 {
    const digits = memory.bytes[at * 2 ..][0..2];
    if (std.mem.eql(u8, digits, "__")) return null;
    // The validator has checked the digits.
    return std.fmt.parseInt(u8, digits, 16) catch unreachable;
}

fn pointerSize(l: *const Lowering) usize {
    return l.source.target.pointer_width / 8;
}

/// Data and functions are taken to share one address space, as they do on every target ZRust builds for.
fn pointerType(l: *const Lowering) llvm.LLVMTypeRef {
    return llvm.LLVMPointerTypeInContext(l.context, 0);
}
