//! The last steps of a compilation: check the LLVM module, optimize it, write it out.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const zrmir = @import("../zrmir.zig");

/// Invalid IR is a bug in the lowering, and LLVM's later stages do not check for it: they crash or miscompile.
pub fn verify(arena: std.mem.Allocator, module: llvm.LLVMModuleRef, diagnostic: *zrmir.Diagnostic) codegen.Error!void {
    var message: [*c]u8 = null;
    // LLVM allocates the message on success too.
    defer llvm.LLVMDisposeMessage(message);
    if (llvm.LLVMVerifyModule(module, llvm.LLVMReturnStatusAction, &message) != 0) {
        return codegen.fail(
            diagnostic,
            arena,
            "LLVM rejected the generated IR, which is a bug in zrust-codegen:\n{s}",
            .{std.mem.span(message)},
        );
    }
}

pub fn optimize(
    arena: std.mem.Allocator,
    module: llvm.LLVMModuleRef,
    machine: llvm.LLVMTargetMachineRef,
    opt_level: zrmir.schema.OptLevel,
    diagnostic: *zrmir.Diagnostic,
) codegen.Error!void {
    // The unoptimized pipeline is not empty: it holds the passes a module needs to be correct, such as inlining
    // what is marked `alwaysinline`.
    const passes = switch (opt_level) {
        .none => "default<O0>",
        .less => "default<O1>",
        .more => "default<O2>",
        .aggressive => "default<O3>",
        .size => "default<Os>",
        .size_min => "default<Oz>",
    };
    const options = llvm.LLVMCreatePassBuilderOptions();
    defer llvm.LLVMDisposePassBuilderOptions(options);
    if (llvm.LLVMRunPasses(module, passes, machine, options)) |failure| {
        const message = llvm.LLVMGetErrorMessage(failure);
        defer llvm.LLVMDisposeErrorMessage(message);
        return codegen.fail(diagnostic, arena, "LLVM's `{s}` pipeline failed: {s}", .{ passes, std.mem.span(message) });
    }
}

pub fn write(
    arena: std.mem.Allocator,
    module: llvm.LLVMModuleRef,
    machine: llvm.LLVMTargetMachineRef,
    path: []const u8,
    output: codegen.Output,
    diagnostic: *zrmir.Diagnostic,
) codegen.Error!void {
    const path_z = try arena.dupeSentinel(u8, path, 0);
    var message: [*c]u8 = null;
    const failed = switch (output) {
        .obj => llvm.LLVMTargetMachineEmitToFile(machine, module, path_z, llvm.LLVMObjectFile, &message),
        .@"llvm-ir" => llvm.LLVMPrintModuleToFile(module, path_z, &message),
    };
    if (failed != 0) {
        defer llvm.LLVMDisposeMessage(message);
        return codegen.fail(diagnostic, arena, "cannot write {s}: {s}", .{ path, std.mem.span(message) });
    }
}
