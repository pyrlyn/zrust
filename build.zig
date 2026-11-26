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
    options.addOption([]const u8, "rust_toolchain", rustToolchain(b));

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

    const shim = installShim(b);

    const test_step = b.step("test", "Run the tests");

    const zrmir_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zrmir.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zrmir_tests).step);

    test_step.dependOn(addShimTest(b, shim));
}

/// The channel rust-toolchain.toml pins. The driver asks rustup for exactly this toolchain: the shim is built
/// against its compiler crates and loads into no other rustc.
fn rustToolchain(b: *std.Build) []const u8 {
    const file = "rust-toolchain.toml";
    const key = "channel = \"";
    const path = b.root.joinString(b.allocator, file) catch @panic("OOM");
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(64 * 1024)) catch |err| {
        std.process.fatal("cannot read {s}: {s}", .{ file, @errorName(err) });
    };
    const start = (std.mem.find(u8, text, key) orelse std.process.fatal("{s} has no channel", .{file})) + key.len;
    const end = std.mem.findScalarPos(u8, text, start, '"') orelse std.process.fatal("{s} has no channel", .{file});
    return text[start..end];
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

const Shim = struct {
    /// The dylib inside cargo's target directory.
    path: std.Build.LazyPath,
    /// The cargo invocation that produces `path`.
    build: *std.Build.Step,
};

/// Builds the rustc backend shim with cargo and copies it to `zig-out/lib`.
fn installShim(b: *std.Build) Shim {
    // rustc loads the shim into its own process, so it is always built for the host, whatever `-Dtarget` says.
    const host = &b.graph.host.result;
    const file_name = b.fmt("{s}zrust_shim{s}", .{ host.libPrefix(), host.dynamicLibSuffix() });

    const cargo = addRustCommand(b, &.{ "cargo", "build", "--release", "--locked" });
    cargo.setCwd(b.path("shim"));

    const path = b.path(b.fmt("shim/target/release/{s}", .{file_name}));
    const install = b.addInstallLibFile(path, file_name);
    install.step.dependOn(&cargo.step);
    b.getInstallStep().dependOn(&install.step);

    return .{ .path = path, .build = &cargo.step };
}

/// Compiles `tests/run-pass/hello.rs` with the shim as rustc's backend. Until the backend generates
/// code, a pass means: rustc loaded the shim, the shim listed the crate's mono items, then refused.
fn addShimTest(b: *std.Build, shim: Shim) *std.Build.Step {
    const rustc = addRustCommand(b, &.{"rustc"});
    rustc.setCwd(b.path("."));
    rustc.addPrefixedFileArg("-Zcodegen-backend=", shim.path);
    rustc.addFileArg(b.path("tests/run-pass/hello.rs"));
    rustc.addArg("--out-dir");
    _ = rustc.addOutputDirectoryArg("hello");
    rustc.step.dependOn(shim.build);

    rustc.expectStdErrMatch("zrust: cgu hello.");
    rustc.expectStdErrMatch("zrust:   fn main [");
    rustc.expectStdErrMatch("error: zrust: code generation is not implemented yet");
    rustc.expectExitCode(1);
    return &rustc.step;
}

/// A command of the pinned Rust toolchain. Its working directory must be inside the repository:
/// rustup picks the nightly from rust-toolchain.toml by walking up from there.
fn addRustCommand(b: *std.Build, argv: []const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(argv);
    // An inherited RUSTUP_TOOLCHAIN (mise exports one for a globally configured rust) outranks rust-toolchain.toml.
    run.removeEnvironmentVariable("RUSTUP_TOOLCHAIN");
    // Neither cargo's nor rustc's real inputs (the shim sources, the sysroot) are visible to the build
    // graph; a cached Run step would hide changes to them.
    run.has_side_effects = true;
    return run;
}
