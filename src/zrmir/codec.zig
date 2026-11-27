//! Reads and writes ZRMIR modules as JSON.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("Diagnostic.zig");
const schema = @import("schema.zig");

/// How much of the input an error message quotes on each side of the place it points at.
const excerpt_len = 48;

/// Strict: an unknown, missing or duplicate field or tag is an error. `input` must outlive the module, whose strings
/// point into it wherever they need no unescaping.
pub fn decode(arena: Allocator, input: []const u8, diagnostic: *Diagnostic) Diagnostic.Error!schema.Module {
    // Read on its own first: a file of another version fails the full parse somewhere in the middle, with a message
    // about a field nobody recognises instead of the one thing that is actually wrong.
    const Header = struct { magic: []const u8, version: u32 };
    const header = parse(Header, arena, input, .{ .ignore_unknown_fields = true }, diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Malformed => return diagnostic.fail(arena, "not a ZRMIR module: {s}", .{diagnostic.message}),
    };
    if (!std.mem.eql(u8, header.magic, schema.magic)) {
        return diagnostic.fail(arena, "not a ZRMIR module: the magic is \"{s}\"", .{header.magic});
    }
    if (header.version != schema.version) {
        return diagnostic.fail(
            arena,
            "ZRMIR version {d} is not supported: this zrust-codegen reads version {d}",
            .{ header.version, schema.version },
        );
    }
    return parse(schema.Module, arena, input, .{}, diagnostic);
}

fn parse(
    comptime T: type,
    arena: Allocator,
    input: []const u8,
    options: std.json.ParseOptions,
    diagnostic: *Diagnostic,
) Diagnostic.Error!T {
    var scanner: std.json.Scanner = .initCompleteInput(arena, input);
    var position: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&position);

    return std.json.parseFromTokenSourceLeaky(T, arena, &scanner, options) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const offset: usize = @intCast(position.getByteOffset());
        return diagnostic.fail(arena, "line {d}, column {d} (byte {d}): {s}, near `{s}`", .{
            position.getLine(),
            position.getColumn(),
            offset,
            describe(err),
            excerpt(input, offset),
        });
    };
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownField => "unknown field or tag",
        error.MissingField => "a required field is missing",
        error.DuplicateField => "duplicate field",
        error.UnexpectedToken => "a value of the wrong shape",
        error.InvalidEnumTag => "unknown enum value",
        error.Overflow => "number out of range",
        error.InvalidNumber, error.InvalidCharacter => "malformed number",
        error.SyntaxError => "malformed JSON",
        error.UnexpectedEndOfInput => "truncated JSON",
        else => @errorName(err),
    };
}

fn excerpt(input: []const u8, offset: usize) []const u8 {
    const at = @min(offset, input.len);
    return input[at -| excerpt_len..@min(input.len, at + excerpt_len)];
}

pub fn encode(arena: Allocator, module: *const schema.Module) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(arena, module.*, .{});
}

/// A ZRMIR file is canonical: the encoder has one way to write a module, so writing the decoded module again must
/// give the input back byte for byte. That makes the decoder's leniencies (a number where a name belongs, a string
/// where a number belongs) errors too, and proves that the schema here loses nothing the file had.
pub fn checkCanonical(
    arena: Allocator,
    module: *const schema.Module,
    input: []const u8,
    diagnostic: *Diagnostic,
) Diagnostic.Error!void {
    const output = try encode(arena, module);
    const offset = std.mem.findDiff(u8, input, output) orelse return;
    return diagnostic.fail(
        arena,
        "byte {d}: the file is not canonical: it has `{s}` where writing the decoded module gives `{s}`",
        .{ offset, excerpt(input, offset), excerpt(output, offset) },
    );
}
