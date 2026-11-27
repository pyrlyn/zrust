const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const usage =
    \\usage: zrust rustc <rustc arguments>
    \\       zrust build <file.rs> [-O] [-o <output>] [rustc arguments]
    \\       zrust dump-zrmir <file.rs> [rustc arguments]
    \\       zrust --version
    \\
    \\  rustc        run the pinned rustc with zrust as its code generator
    \\  build        the same, writing into `target/` unless told where to
    \\  dump-zrmir   keep the ZRMIR of every codegen unit and print the paths
    \\
;

/// Where `build` puts its output when the command line names no place.
const default_out_dir = "target";

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var buffer: [1024]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &stdout.interface;

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const command = args[1];
    const rest = args[2..];

    if (std.mem.eql(u8, command, "--version")) {
        try out.print("zrust {s}\n", .{build_options.version});
        try out.flush();
        return 0;
    }
    if (std.mem.eql(u8, command, "--help")) {
        try out.writeAll(usage);
        try out.flush();
        return 0;
    }
    if (std.mem.eql(u8, command, "rustc")) {
        return runRustc(init, rest, .{});
    }
    if (std.mem.eql(u8, command, "build")) {
        if (namesOutput(rest)) return runRustc(init, rest, .{});
        return runRustc(init, try std.mem.concat(arena, []const u8, &.{ rest, &.{ "--out-dir", default_out_dir } }), .{});
    }
    if (std.mem.eql(u8, command, "dump-zrmir")) {
        return dumpZrmir(init, rest, out);
    }

    std.debug.print("zrust: unknown command `{s}`\n{s}", .{ command, usage });
    return 2;
}

fn namesOutput(rustc_args: []const []const u8) bool {
    for (rustc_args) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.startsWith(u8, arg, "--out-dir")) return true;
    }
    return false;
}

const RustcOptions = struct {
    keep_zrmir: bool = false,
};

/// Runs the pinned rustc with the shim as its backend, and returns rustc's exit code.
fn runRustc(init: std.process.Init, rustc_args: []const []const u8, options: RustcOptions) !u8 {
    const arena = init.arena.allocator();

    // The shim and the code generator are installed next to this binary, and rustc needs both by absolute path:
    // it resolves a relative `-Zcodegen-backend` against the sysroot, and the shim runs wherever rustc was started.
    const self_path = try std.process.executablePathAlloc(init.io, arena);
    const bin_dir = std.fs.path.dirname(self_path) orelse ".";
    const host = &builtin.target;
    const shim = try std.fs.path.resolve(arena, &.{
        bin_dir,
        "..",
        "lib",
        try std.fmt.allocPrint(arena, "{s}zrust_shim{s}", .{ host.libPrefix(), host.dynamicLibSuffix() }),
    });
    const codegen = try std.fs.path.resolve(arena, &.{
        bin_dir,
        try std.fmt.allocPrint(arena, "zrust-codegen{s}", .{host.exeFileExt()}),
    });

    var environ = try init.environ_map.clone(arena);
    try environ.put("ZRUST_CODEGEN", codegen);
    if (options.keep_zrmir) try environ.put("ZRUST_KEEP_ZRMIR", "1");

    // `rustup run` rather than a bare `rustc`: the shim is built against one nightly's unstable compiler crates and
    // loads into no other, whatever toolchain the directory or the environment would otherwise select.
    const argv = try std.mem.concat(arena, []const u8, &.{
        &.{ "rustup", "run", build_options.rust_toolchain, "rustc" },
        &.{try std.fmt.allocPrint(arena, "-Zcodegen-backend={s}", .{shim})},
        rustc_args,
    });

    var child = std.process.spawn(init.io, .{ .argv = argv, .environ_map = &environ }) catch |err| {
        std.debug.print("zrust: cannot run `rustup run {s} rustc`: {s}\n", .{ build_options.rust_toolchain, @errorName(err) });
        return 2;
    };
    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => |term| {
            std.debug.print("zrust: rustc was terminated: {f}\n", .{term});
            return 1;
        },
    };
}

fn dumpZrmir(init: std.process.Init, rustc_args: []const []const u8, out: *std.Io.Writer) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const source = for (rustc_args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) break arg;
    } else {
        std.debug.print("zrust: dump-zrmir needs a source file\n{s}", .{usage});
        return 2;
    };

    // A directory of its own per source file: what is in it afterwards is exactly this dump, so stale modules of an
    // earlier run can be removed without touching anything the user put anywhere.
    const out_dir = try std.fs.path.join(arena, &.{ default_out_dir, "zrmir", std.fs.path.stem(source) });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, out_dir);
    for (try zrmirFiles(arena, io, out_dir)) |name| {
        var dir = try cwd.openDir(io, out_dir, .{});
        defer dir.close(io);
        try dir.deleteFile(io, name);
    }

    const argv = try std.mem.concat(arena, []const u8, &.{ rustc_args, &.{ "--out-dir", out_dir } });
    const code = try runRustc(init, argv, .{ .keep_zrmir = true });
    if (code != 0) return code;

    for (try zrmirFiles(arena, io, out_dir)) |name| {
        try out.print("{s}\n", .{try std.fs.path.join(arena, &.{ out_dir, name })});
    }
    try out.flush();
    return 0;
}

/// The names of the ZRMIR modules in `path`, sorted.
fn zrmirFiles(arena: std.mem.Allocator, io: std.Io, path: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zrmir")) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.items;
}
