//! Why a ZRMIR module was rejected, in words a person can act on.

const std = @import("std");

/// Allocated in the arena the failing call was given.
message: []const u8 = "",

pub const Error = error{ Malformed, OutOfMemory };

pub fn fail(
    diagnostic: *@This(),
    arena: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) Error {
    diagnostic.message = try std.fmt.allocPrint(arena, format, args);
    return error.Malformed;
}
