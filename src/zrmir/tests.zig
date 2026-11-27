const std = @import("std");
const testing = std.testing;

const zrmir = @import("../zrmir.zig");

/// The smallest module with one of everything a reference can point at: `fn f() {}`.
const minimal =
    \\{"magic":"ZRMIR","version":1,"crate_name":"t","cgu_name":"t.0",
++
    \\"target":{"triple":"aarch64-apple-darwin","llvm_target":"arm64-apple-macosx11.0.0","data_layout":"e","cpu":"generic","pointer_width":64,"endian":"little"},
++
    \\"panic_strategy":"abort","opt_level":"none","files":["t.rs"],
++
    \\"spans":[{"file":0,"start_line":1,"start_col":1,"end_line":1,"end_col":2}],
++
    \\"types":[{"name":"()","layout":0,"kind":{"tuple":{"fields":[]}}}],
++
    \\"layouts":[{"size":0,"align":1,"repr":{"aggregate":{"sized":true}},"fields":{"arbitrary":{"offsets":[]}},"variants":{"single":{"index":0}}}],
++
    \\"fn_abis":[{"conv":"rust","c_variadic":false,"fixed_count":0,"args":[],"ret":{"ty":0,"layout":0,"mode":{"ignore":{}}}}],
++
    \\"allocs":[{"memory":{"align":1,"mutable":false,"memory":{"bytes":"00__","relocs":[]}}}],
++
    \\"symbols":[{"name":"f","kind":{"fn":{"abi":0}}}],
++
    \\"functions":[{"symbol":0,"linkage":"external","visibility":"default","track_caller":false,
++
    \\"body":{"span":0,"arg_count":0,"spread_arg":null,"locals":[{"ty":0}],
++
    \\"blocks":[{"statements":[],"terminator":{"span":0,"kind":{"return":{}}}}]}}],
++
    \\"statics":[],"entry":null}
;

fn expectRejected(needle: []const u8, replacement: []const u8, message: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(std.mem.find(u8, minimal, needle) != null);
    const input = try std.mem.replaceOwned(u8, arena, minimal, needle, replacement);

    var diagnostic: zrmir.Diagnostic = .{};
    try testing.expectError(error.Malformed, zrmir.check(arena, input, &diagnostic));
    if (std.mem.find(u8, diagnostic.message, message) == null) {
        std.debug.print("expected `{s}` in the message `{s}`\n", .{ message, diagnostic.message });
        return error.TestExpectedEqual;
    }
}

test "a minimal module passes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    var diagnostic: zrmir.Diagnostic = .{};
    const module = zrmir.check(arena_state.allocator(), minimal, &diagnostic) catch |err| {
        std.debug.print("{s}\n", .{diagnostic.message});
        return err;
    };
    try testing.expectEqualStrings("f", module.symbols[module.functions[0].symbol.index()].name);
}

test "another format or version is named as such" {
    try expectRejected("\"magic\":\"ZRMIR\"", "\"magic\":\"ELF\"", "not a ZRMIR module: the magic is \"ELF\"");
    try expectRejected("\"version\":1", "\"version\":2", "ZRMIR version 2 is not supported");
    try expectRejected("{\"magic\"", "[{\"magic\"", "not a ZRMIR module");
}

test "an unknown tag or field is an error with its place" {
    try expectRejected("{\"return\":{}}", "{\"yield\":{}}", "unknown field or tag, near `");
    try expectRejected("\"arg_count\":0", "\"arg_count\":0,\"extra\":0", "unknown field or tag");
    try expectRejected("\"conv\":\"rust\"", "\"conv\":\"fortran\"", "unknown enum value");
    try expectRejected("\"track_caller\":false,", "", "a required field is missing");
    try expectRejected("\"arg_count\":0", "\"arg_count\":0,\"arg_count\":0", "duplicate field");
}

test "a dangling id is an error with its path" {
    try expectRejected(
        "\"locals\":[{\"ty\":0}]",
        "\"locals\":[{\"ty\":7}]",
        "functions[0].body.locals[0].ty: id 7 is out of range: `types` has 1 entries",
    );
    try expectRejected("\"kind\":{\"return\":{}}", "\"kind\":{\"goto\":{\"target\":1}}", "`blocks` has 1 entries");
    try expectRejected("\"entry\":null", "\"entry\":{\"main\":3,\"sigpipe\":0}", "entry: id 3 is out of range");
}

test "memory is checked" {
    try expectRejected("\"bytes\":\"00__\"", "\"bytes\":\"00_\"", "odd number of characters");
    try expectRejected("\"bytes\":\"00__\"", "\"bytes\":\"0G__\"", "neither a hex byte nor `__`");
    try expectRejected("\"relocs\":[]", "\"relocs\":[{\"offset\":0,\"alloc\":0}]", "does not fit into 2 bytes");
}

test "only the canonical form is accepted" {
    try expectRejected("\"version\":1", "\"version\": 1", "the file is not canonical");
    try expectRejected("\"endian\":\"little\"", "\"endian\":0", "the file is not canonical");
    try expectRejected("\"arg_count\":0,\"spread_arg\":null", "\"spread_arg\":null,\"arg_count\":0", "the file is not canonical");
}
