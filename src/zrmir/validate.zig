//! Checks what the JSON shape cannot express: that every id points into its table, and the few invariants the code
//! generator relies on without looking.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Diagnostic = @import("Diagnostic.zig");
const schema = @import("schema.zig");

pub fn validate(arena: Allocator, module: *const schema.Module, diagnostic: *Diagnostic) Diagnostic.Error!void {
    var validator: Validator = .{ .arena = arena, .module = module, .diagnostic = diagnostic };
    switch (module.target.pointer_width) {
        16, 32, 64 => {},
        else => |width| return validator.fail("a pointer width of {d} bits is not supported", .{width}),
    }
    try validator.walk(schema.Module, module);
}

const Validator = struct {
    arena: Allocator,
    module: *const schema.Module,
    diagnostic: *Diagnostic,
    /// The body block and local ids are resolved against.
    body: ?*const schema.Body = null,
    path: [max_depth]Segment = undefined,
    depth: usize = 0,

    /// Deeper than the schema nests; the schema has no recursive types.
    const max_depth = 32;

    const Segment = union(enum) { field: []const u8, index: usize };

    fn fail(v: *Validator, comptime format: []const u8, args: anytype) Diagnostic.Error {
        var out: std.Io.Writer.Allocating = .init(v.arena);
        const writer = &out.writer;
        for (v.path[0..v.depth], 0..) |segment, i| {
            switch (segment) {
                .field => |name| writer.print("{s}{s}", .{ if (i == 0) "" else ".", name }) catch return error.OutOfMemory,
                .index => |index| writer.print("[{d}]", .{index}) catch return error.OutOfMemory,
            }
        }
        if (v.depth != 0) writer.writeAll(": ") catch return error.OutOfMemory;
        writer.print(format, args) catch return error.OutOfMemory;
        v.diagnostic.message = out.written();
        return error.Malformed;
    }

    fn push(v: *Validator, segment: Segment) void {
        v.path[v.depth] = segment;
        v.depth += 1;
    }

    fn pop(v: *Validator) void {
        v.depth -= 1;
    }

    fn walk(v: *Validator, comptime T: type, value: *const T) Diagnostic.Error!void {
        switch (T) {
            schema.Body => {
                if (value.blocks.len == 0) return v.fail("a body needs at least one block", .{});
                if (value.locals.len <= value.arg_count) {
                    return v.fail(
                        "{d} locals cannot hold the return place and {d} arguments",
                        .{ value.locals.len, value.arg_count },
                    );
                }
                const outer = v.body;
                v.body = value;
                defer v.body = outer;
                return v.walkParts(T, value);
            },
            schema.Memory => try v.memory(value),
            schema.Function => try v.symbol(value.symbol, .@"fn"),
            schema.Static => try v.symbol(value.symbol, .static),
            schema.Entry => try v.symbol(value.main, .@"fn"),
            schema.GlobalAlloc => switch (value.*) {
                .function => |function| try v.symbol(function.symbol, .@"fn"),
                .static => |static| try v.symbol(static.symbol, .static),
                .vtable => |vtable| {
                    try v.reference(.allocs, vtable.alloc.index());
                    if (v.module.allocs[vtable.alloc.index()] != .memory) {
                        return v.fail("the vtable's alloc {d} is not memory", .{vtable.alloc.index()});
                    }
                },
                .memory, .type_id => {},
            },
            schema.Callee => switch (value.*) {
                .direct => |direct| try v.symbol(direct.symbol, .@"fn"),
                .intrinsic => |intrinsic| if (intrinsic.fallback) |fallback| try v.symbol(fallback, .@"fn"),
                .virtual, .indirect => {},
            },
            else => {},
        }
        try v.walkParts(T, value);
    }

    fn walkParts(v: *Validator, comptime T: type, value: *const T) Diagnostic.Error!void {
        switch (@typeInfo(T)) {
            .bool, .int => {},
            .@"enum" => if (@hasDecl(T, "refers_to")) try v.reference(T.refers_to, value.index()),
            .optional => |info| if (value.*) |*inner| try v.walk(info.child, inner),
            .pointer => |info| {
                comptime assert(info.size == .slice);
                if (info.child == u8) return;
                for (value.*, 0..) |*item, i| {
                    v.push(.{ .index = i });
                    defer v.pop();
                    try v.walk(info.child, item);
                }
            },
            .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
                v.push(.{ .field = name });
                defer v.pop();
                try v.walk(Field, &@field(value, name));
            },
            .@"union" => |info| inline for (info.field_names, info.field_types) |name, Payload| {
                if (value.* == @field(info.tag_type.?, name) and Payload != void) {
                    v.push(.{ .field = name });
                    defer v.pop();
                    try v.walk(Payload, &@field(value, name));
                }
            },
            else => @compileError("the validator cannot walk " ++ @typeName(T)),
        }
    }

    fn reference(v: *Validator, table: schema.Table, index: u32) Diagnostic.Error!void {
        const len = switch (table) {
            .files => v.module.files.len,
            .spans => v.module.spans.len,
            .types => v.module.types.len,
            .layouts => v.module.layouts.len,
            .fn_abis => v.module.fn_abis.len,
            .allocs => v.module.allocs.len,
            .symbols => v.module.symbols.len,
            .blocks => (v.body orelse return v.fail("a block id outside of a body", .{})).blocks.len,
            .locals => (v.body orelse return v.fail("a local id outside of a body", .{})).locals.len,
        };
        if (index >= len) {
            return v.fail("id {d} is out of range: `{s}` has {d} entries", .{ index, @tagName(table), len });
        }
    }

    fn symbol(v: *Validator, id: schema.SymbolId, kind: std.meta.Tag(schema.SymbolKind)) Diagnostic.Error!void {
        try v.reference(.symbols, id.index());
        const found = std.meta.activeTag(v.module.symbols[id.index()].kind);
        if (found != kind) {
            return v.fail("symbol {d} is a `{s}` where a `{s}` belongs", .{ id.index(), @tagName(found), @tagName(kind) });
        }
    }

    fn memory(v: *Validator, value: *const schema.Memory) Diagnostic.Error!void {
        if (value.bytes.len % 2 != 0) return v.fail("`bytes` has an odd number of characters", .{});
        var at: usize = 0;
        while (at < value.bytes.len) : (at += 2) {
            const pair = value.bytes[at..][0..2];
            if (std.mem.eql(u8, pair, "__")) continue;
            for (pair) |char| switch (char) {
                '0'...'9', 'a'...'f' => {},
                else => return v.fail("`bytes` has `{s}` at character {d}, which is neither a hex byte nor `__`", .{ pair, at }),
            };
        }

        const size = value.bytes.len / 2;
        const pointer_size = v.module.target.pointer_width / 8;
        for (value.relocs) |reloc| {
            if (reloc.offset > size or size - reloc.offset < pointer_size) {
                return v.fail("a pointer at offset {d} does not fit into {d} bytes", .{ reloc.offset, size });
            }
        }
    }
};
