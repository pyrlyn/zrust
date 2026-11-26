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
    const run_pass_step = b.step("test-run-pass", "Build and run the programs in tests/run-pass");
    test_step.dependOn(run_pass_step);

    const zrmir_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zrmir.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zrmir_tests).step);

    for (runPassPrograms(b)) |*program| {
        test_step.dependOn(addDumpTest(b, program.source, program.rustc_flags));
        test_step.dependOn(addDumpTest(b, program.source, concat(b, program.rustc_flags, &.{"-O"})));
        addRunPassTests(b, run_pass_step, program);
    }

    // The largest Rust program in the repository whose license is ours to test with: about two thousand lines that
    // lean on generics, closures, trait objects and `std` collections far harder than `tests/run-pass` does.
    const shim_crate = b.path("shim/src/lib.rs");
    const crate_args: []const []const u8 = &.{ "--edition", "2024", "--crate-type", "rlib" };
    test_step.dependOn(addDumpTest(b, shim_crate, crate_args));
    test_step.dependOn(addDumpTest(b, shim_crate, crate_args ++ .{"-O"}));

    test_step.dependOn(addDriverlessTest(b, shim));
    test_step.dependOn(addFailingCodegenTest(b, shim, true));
    test_step.dependOn(addFailingCodegenTest(b, shim, false));
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

/// A program in `tests/run-pass` and what its header says about it. The header is the comment lines the file starts
/// with:
///
///     // expect-stdout: <a line the program prints>     (once per line)
///     // expect-exit: <the exit code, 0 if absent>
///     // rustc-flags: <arguments every compilation of the program needs>
///     // unsupported: <why zrust cannot compile the program yet>
const Program = struct {
    name: []const u8,
    source: std.Build.LazyPath,
    rustc_flags: []const []const u8 = &.{},
    stdout: []const u8 = "",
    exit_code: u8 = 0,
    unsupported: bool = false,
};

fn runPassPrograms(b: *std.Build) []const Program {
    const io = b.graph.io;
    const dir_path = "tests/run-pass";
    const full_path = b.root.joinString(b.allocator, dir_path) catch @panic("OOM");
    var dir = std.Io.Dir.cwd().openDir(io, full_path, .{ .iterate = true }) catch |err| {
        std.process.fatal("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
    };
    defer dir.close(io);

    var programs: std.ArrayList(Program) = .empty;
    var entries = dir.iterate();
    while (entries.next(io) catch |err| std.process.fatal("cannot list {s}: {s}", .{ dir_path, @errorName(err) })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".rs")) continue;
        const path = b.fmt("{s}/{s}", .{ dir_path, entry.name });
        const text = dir.readFileAlloc(io, entry.name, b.allocator, .limited(1024 * 1024)) catch |err| {
            std.process.fatal("cannot read {s}: {s}", .{ path, @errorName(err) });
        };
        var program: Program = .{ .name = b.dupe(entry.name), .source = b.path(path) };

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "// ")) break;
            const colon = std.mem.find(u8, line, ": ") orelse break;
            const key = line["// ".len..colon];
            const value = line[colon + ": ".len ..];
            if (std.mem.eql(u8, key, "expect-stdout")) {
                program.stdout = b.fmt("{s}{s}\n", .{ program.stdout, value });
            } else if (std.mem.eql(u8, key, "expect-exit")) {
                program.exit_code = std.fmt.parseInt(u8, value, 10) catch {
                    std.process.fatal("{s}: `{s}` is not an exit code", .{ path, value });
                };
            } else if (std.mem.eql(u8, key, "rustc-flags")) {
                var flags: std.ArrayList([]const u8) = .empty;
                var words = std.mem.tokenizeScalar(u8, value, ' ');
                while (words.next()) |word| flags.append(b.allocator, word) catch @panic("OOM");
                program.rustc_flags = flags.items;
            } else if (std.mem.eql(u8, key, "unsupported")) {
                program.unsupported = true;
            } else {
                // A misspelled directive would otherwise read as a comment and the test would check less than it says.
                std.process.fatal("{s}: unknown directive `{s}`", .{ path, key });
            }
        }
        programs.append(b.allocator, program) catch @panic("OOM");
    }
    return programs.items;
}

fn concat(b: *std.Build, first: []const []const u8, second: []const []const u8) []const []const u8 {
    return std.mem.concat(b.allocator, []const u8, &.{ first, second }) catch @panic("OOM");
}

/// The installed driver, not the one in the cache: it finds the shim and `zrust-codegen` relative to itself.
fn addZrustRustc(b: *std.Build, name: []const u8, source: std.Build.LazyPath, rustc_args: []const []const u8) *std.Build.Step.Run {
    const zrust = std.Build.Step.Run.create(b, name);
    zrust.addFileArg(b.graph.path(.install_bin, "zrust"));
    zrust.addArg("rustc");
    zrust.step.dependOn(b.getInstallStep());
    zrust.setCwd(b.path("."));
    // Its real inputs (the installed binaries, the sysroot) are invisible to the build graph.
    zrust.has_side_effects = true;
    zrust.addFileArg(source);
    zrust.addArgs(rustc_args);
    return zrust;
}

/// What the shim says when it has written the ZRMIR and stops there.
const dump_warning = "warning: zrust: only ZRMIR was asked for, nothing is compiled or linked";

/// Dumps the ZRMIR of a crate through the installed driver. `zrust-codegen` has to read back every codegen unit before
/// the shim reports success: a pass means the encoder and the decoder agree on all of them, whether or not the code
/// generator can compile them yet.
fn addDumpTest(b: *std.Build, source: std.Build.LazyPath, rustc_args: []const []const u8) *std.Build.Step {
    const zrust = addZrustRustc(b, describe(b, "dump", source.getDisplayName(), rustc_args), source, rustc_args);
    zrust.setEnvironmentVariable("ZRUST_ZRMIR_ONLY", "1");
    zrust.addArg("--out-dir");
    _ = zrust.addOutputDirectoryArg("zrmir");

    zrust.expectStdErrMatch(dump_warning);
    zrust.expectStdErrMatch("= note: wrote ");
    zrust.expectExitCode(0);
    return &zrust.step;
}

fn describe(b: *std.Build, verb: []const u8, name: []const u8, rustc_args: []const []const u8) []const u8 {
    const args = std.mem.join(b.allocator, " ", rustc_args) catch @panic("OOM");
    return b.fmt("{s} {s}{s}{s}", .{ verb, name, if (args.len == 0) "" else " ", args });
}

/// Builds a program with zrust, with and without optimizations, runs it and compares what it does with its header.
/// Stock rustc builds the same program once: a header it disagrees with is wrong about Rust, not about zrust.
fn addRunPassTests(b: *std.Build, step: *std.Build.Step, program: *const Program) void {
    const stem = std.fs.path.stem(program.name);

    const reference = addRustCommand(b, &.{"rustc"});
    reference.setName(describe(b, "rustc", program.name, program.rustc_flags));
    reference.setCwd(b.path("."));
    reference.addFileArg(program.source);
    reference.addArgs(program.rustc_flags);
    // Only the behaviour of the reference is compared; its lints would show up as noise in the test output.
    reference.addArgs(&.{ "--cap-lints", "allow" });
    reference.addArg("-o");
    const reference_exe = reference.addOutputFileArg(stem);
    reference.expectExitCode(0);
    step.dependOn(addRun(b, b.fmt("run {s} (rustc)", .{program.name}), reference_exe, program));

    if (program.unsupported) {
        // The marker has to go when the program starts to compile: a test nobody runs proves nothing.
        const zrust = addZrustRustc(b, b.fmt("refuse {s}", .{program.name}), program.source, program.rustc_flags);
        zrust.addArg("-o");
        _ = zrust.addOutputFileArg(stem);
        zrust.expectStdErrMatch(" is not supported yet");
        zrust.expectExitCode(1);
        step.dependOn(&zrust.step);
        return;
    }

    for ([_][]const []const u8{ &.{}, &.{"-O"} }) |variant| {
        const rustc_args = concat(b, program.rustc_flags, variant);
        const zrust = addZrustRustc(b, describe(b, "zrust", program.name, rustc_args), program.source, rustc_args);
        zrust.addArg("-o");
        const exe = zrust.addOutputFileArg(stem);
        zrust.expectExitCode(0);
        step.dependOn(addRun(b, describe(b, "run", program.name, variant), exe, program));
    }
}

fn addRun(b: *std.Build, name: []const u8, exe: std.Build.LazyPath, program: *const Program) *std.Build.Step {
    const run = std.Build.Step.Run.create(b, name);
    run.addFileArg(exe);
    run.expectStdOutEqual(program.stdout);
    run.expectExitCode(program.exit_code);
    return &run.step;
}

/// The shim cannot generate code on its own, and says where to get it rather than failing somewhere less obvious.
fn addDriverlessTest(b: *std.Build, shim: Shim) *std.Build.Step {
    const rustc = addShimRustc(b, shim);
    rustc.setName("refuse to build without the driver");
    rustc.removeEnvironmentVariable("ZRUST_CODEGEN");

    rustc.expectStdErrMatch("error: zrust: ZRUST_CODEGEN is not set; run rustc through the `zrust` driver");
    rustc.expectExitCode(1);
    return &rustc.step;
}

/// A module the code generator fails on fails the build that produced it, dump or not.
fn addFailingCodegenTest(b: *std.Build, shim: Shim, zrmir_only: bool) *std.Build.Step {
    const rustc = addShimRustc(b, shim);
    // Stands in for a `zrust-codegen` that finds a fault: it exits with a failure whatever it is given.
    rustc.setEnvironmentVariable("ZRUST_CODEGEN", "false");
    if (zrmir_only) {
        rustc.setName("fail the dump when the ZRMIR is rejected");
        rustc.setEnvironmentVariable("ZRUST_ZRMIR_ONLY", "1");
        rustc.expectStdErrMatch("error: zrust: false rejected the ZRMIR");
    } else {
        rustc.setName("fail the build when a module is not compiled");
        rustc.removeEnvironmentVariable("ZRUST_ZRMIR_ONLY");
        rustc.expectStdErrMatch("error: zrust: false could not compile `hello.");
    }
    rustc.expectExitCode(1);
    return &rustc.step;
}

/// rustc on `tests/run-pass/hello.rs` with the shim as its backend, bypassing the driver.
fn addShimRustc(b: *std.Build, shim: Shim) *std.Build.Step.Run {
    const rustc = addRustCommand(b, &.{"rustc"});
    rustc.setCwd(b.path("."));
    rustc.addPrefixedFileArg("-Zcodegen-backend=", shim.path);
    rustc.addFileArg(b.path("tests/run-pass/hello.rs"));
    rustc.addArg("--out-dir");
    _ = rustc.addOutputDirectoryArg("hello");
    rustc.step.dependOn(shim.build);
    return rustc;
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
