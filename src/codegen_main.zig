const std = @import("std");
const build_options = @import("build_options");
const llvm = @import("llvm_c");
const zrmir = @import("zrmir.zig");

const usage =
    \\usage: zrust-codegen --check --in <file.zrmir>...
    \\       zrust-codegen --version
    \\
    \\  --check    decode and validate the modules, generate nothing
    \\  --in       the ZRMIR modules to read, one per codegen unit
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    var check = false;
    var inputs: []const []const u8 = &.{};
    var at: usize = 1;
    while (at < args.len) : (at += 1) {
        const arg = args[at];
        if (std.mem.eql(u8, arg, "--version")) {
            var major: c_uint = 0;
            var minor: c_uint = 0;
            var patch: c_uint = 0;
            // Asked of the loaded library, not of the headers: this is the LLVM that will actually generate code.
            llvm.LLVMGetVersion(&major, &minor, &patch);
            try out.print(
                "zrust-codegen {s} (LLVM {d}.{d}.{d})\n",
                .{ build_options.version, major, minor, patch },
            );
            try out.flush();
            return 0;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try out.writeAll(usage);
            try out.flush();
            return 0;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arg, "--in")) {
            const first = at + 1;
            while (at + 1 < args.len and !std.mem.startsWith(u8, args[at + 1], "--")) at += 1;
            inputs = args[first .. at + 1];
        } else {
            std.debug.print("zrust-codegen: unknown argument `{s}`\n{s}", .{ arg, usage });
            return 2;
        }
    }

    if (inputs.len == 0) {
        std.debug.print("zrust-codegen: no input modules\n{s}", .{usage});
        return 2;
    }
    if (!check) {
        std.debug.print("zrust-codegen: code generation is not implemented yet, only --check is\n", .{});
        return 2;
    }

    var failed = false;
    for (inputs) |path| {
        // A module and its source are dead weight once it is checked, and a crate has many of them.
        var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const input = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited) catch |err| {
            std.debug.print("zrust-codegen: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            failed = true;
            continue;
        };

        var diagnostic: zrmir.Diagnostic = .{};
        const module = zrmir.check(arena, input, &diagnostic) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Malformed => {
                std.debug.print("zrust-codegen: {s}: {s}\n", .{ path, diagnostic.message });
                failed = true;
                continue;
            },
        };
        try out.print("ok {s}: {d} functions, {d} statics, {d} types, {d} allocs\n", .{
            path,
            module.functions.len,
            module.statics.len,
            module.types.len,
            module.allocs.len,
        });
    }
    try out.flush();
    return @intFromBool(failed);
}
