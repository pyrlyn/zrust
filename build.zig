const std = @import("std");

const version = @import("build.zig.zon").version;

/// The LLVM major version Zig 0.17.1 is built against. `zrust-codegen` must not drift from it.
const llvm_major = "22";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const llvm_config = b.option(
        []const u8,
        "llvm-config",
        "llvm-config of an LLVM " ++ llvm_major ++ " install (default: llvm-config from PATH)",
    ) orelse "llvm-config";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const zrust = b.addExecutable(.{
        .name = "zrust",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zrust.root_module.addOptions("build_options", options);
    b.installArtifact(zrust);

    const llvm = findLlvm(b, llvm_config);
    const llvm_c = b.addTranslateC(.{
        .root_source_file = b.path("src/llvm/c.h"),
        .target = target,
        .optimize = optimize,
    });
    llvm_c.addSystemIncludePath(.{ .cwd_relative = llvm.include_dir });

    const codegen = b.addExecutable(.{
        .name = "zrust-codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/codegen_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    codegen.root_module.addOptions("build_options", options);
    codegen.root_module.addImport("llvm_c", llvm_c.createModule());
    codegen.root_module.addLibraryPath(.{ .cwd_relative = llvm.lib_dir });
    // libLLVM lives outside the system search path (mise or a versioned prefix), so the binary carries its location.
    codegen.root_module.addRPath(.{ .cwd_relative = llvm.lib_dir });
    codegen.root_module.linkSystemLibrary("LLVM-" ++ llvm_major, .{ .use_pkg_config = .no });
    b.installArtifact(codegen);

    installShim(b);
}

const Llvm = struct {
    include_dir: []const u8,
    lib_dir: []const u8,
};

fn findLlvm(b: *std.Build, llvm_config: []const u8) Llvm {
    const found = trim(b.run(&.{ llvm_config, "--version" }));
    if (!std.mem.startsWith(u8, found, llvm_major ++ ".")) {
        std.process.fatal(
            "{s} reports LLVM {s}, but LLVM {s} is required; pass -Dllvm-config=<path>",
            .{ llvm_config, found, llvm_major },
        );
    }
    return .{
        .include_dir = trim(b.run(&.{ llvm_config, "--includedir" })),
        .lib_dir = trim(b.run(&.{ llvm_config, "--libdir" })),
    };
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Builds the rustc backend shim with cargo and copies it to `zig-out/lib`.
fn installShim(b: *std.Build) void {
    // rustc loads the shim into its own process, so it is always built for the host, whatever `-Dtarget` says.
    const host = &b.graph.host.result;
    const file_name = b.fmt("{s}zrust_shim{s}", .{ host.libPrefix(), host.dynamicLibSuffix() });

    const cargo = b.addSystemCommand(&.{ "cargo", "build", "--release", "--locked" });
    // rustup picks the pinned nightly from rust-toolchain.toml by walking up from the working directory.
    cargo.setCwd(b.path("shim"));
    // An inherited RUSTUP_TOOLCHAIN (mise exports one for a globally configured rust) outranks rust-toolchain.toml.
    cargo.removeEnvironmentVariable("RUSTUP_TOOLCHAIN");
    // Cargo tracks its own inputs; a cached Run step would hide edits to the shim.
    cargo.has_side_effects = true;

    const install = b.addInstallLibFile(b.path(b.fmt("shim/target/release/{s}", .{file_name})), file_name);
    install.step.dependOn(&cargo.step);
    b.getInstallStep().dependOn(&install.step);
}
