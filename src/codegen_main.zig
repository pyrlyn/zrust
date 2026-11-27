const std = @import("std");
const build_options = @import("build_options");
const llvm = @import("llvm_c");
const codegen = @import("codegen.zig");
const zrmir = @import("zrmir.zig");

const usage =
    \\usage: zrust-codegen --in <file.zrmir> --out <file> [--emit=obj|llvm-ir]
    \\       zrust-codegen --check --in <file.zrmir>...
    \\       zrust-codegen --version
    \\
    \\  --in       the ZRMIR module to compile, one codegen unit
    \\  --out      where to write the result
    \\  --emit     what to write: an object file (the default) or the LLVM IR as text
    \\  --check    decode and validate any number of modules, generate nothing
    \\
    \\The target, the CPU and the optimization level are the ones the module names.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    var check = false;
    var inputs: []const []const u8 = &.{};
    var out_path: ?[]const u8 = null;
    var output: codegen.Output = .obj;
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
        } else if (std.mem.eql(u8, arg, "--out") and at + 1 < args.len) {
            at += 1;
            out_path = args[at];
        } else if (std.mem.startsWith(u8, arg, "--emit=")) {
            const kind = arg["--emit=".len..];
            output = std.meta.stringToEnum(codegen.Output, kind) orelse {
                std.debug.print("zrust-codegen: unknown output kind `{s}`\n{s}", .{ kind, usage });
                return 2;
            };
        } else {
            std.debug.print("zrust-codegen: unknown argument `{s}`\n{s}", .{ arg, usage });
            return 2;
        }
    }

    if (inputs.len == 0) {
        std.debug.print("zrust-codegen: no input modules\n{s}", .{usage});
        return 2;
    }
    if (!check and (inputs.len != 1 or out_path == null)) {
        std.debug.print("zrust-codegen: compiling takes one input module and --out\n{s}", .{usage});
        return 2;
    }

    var failed = false;
    for (inputs) |path| {
        // A module and its source are dead weight once it is dealt with, and a crate has many of them.
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
        if (check) {
            try out.print("ok {s}: {d} functions, {d} statics, {d} types, {d} allocs\n", .{
                path,
                module.functions.len,
                module.statics.len,
                module.types.len,
                module.allocs.len,
            });
            continue;
        }
        codegen.compile(arena, &module, out_path.?, output, &diagnostic) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.CodegenFailed => {
                std.debug.print("zrust-codegen: {s}: {s}\n", .{ path, diagnostic.message });
                failed = true;
            },
        };
    }
    try out.flush();
    return @intFromBool(failed);
}
