const std = @import("std");
const build_options = @import("build_options");
const llvm = @import("llvm_c");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        var major: c_uint = 0;
        var minor: c_uint = 0;
        var patch: c_uint = 0;
        // Asked of the loaded library, not of the headers: this is the LLVM that will actually generate code.
        llvm.LLVMGetVersion(&major, &minor, &patch);

        var buffer: [64]u8 = undefined;
        var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
        try stdout.interface.print(
            "zrust-codegen {s} (LLVM {d}.{d}.{d})\n",
            .{ build_options.version, major, minor, patch },
        );
        try stdout.interface.flush();
        return 0;
    }

    std.debug.print("zrust-codegen: only --version is implemented so far\n", .{});
    return 2;
}
