const std = @import("std");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        var buffer: [64]u8 = undefined;
        var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
        try stdout.interface.print("zrust {s}\n", .{build_options.version});
        try stdout.interface.flush();
        return 0;
    }

    std.debug.print("zrust: only --version is implemented so far\n", .{});
    return 2;
}
