//! From a ZRMIR module to an object file, through LLVM.

const std = @import("std");
const llvm = @import("llvm_c");

const emit = @import("codegen/emit.zig");
const target = @import("codegen/target.zig");
const zrmir = @import("zrmir.zig");

pub const lowerModule = @import("codegen/module.zig").lowerModule;

pub const Error = error{ CodegenFailed, OutOfMemory };

/// What `--emit` can ask for.
pub const Output = enum { obj, @"llvm-ir" };

/// Records why a module cannot be compiled, in the diagnostic the caller prints.
pub fn fail(
    diagnostic: *zrmir.Diagnostic,
    arena: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) Error {
    diagnostic.message = try std.fmt.allocPrint(arena, format, args);
    return error.CodegenFailed;
}

/// Compiles `source` into the file at `path`.
pub fn compile(
    arena: std.mem.Allocator,
    source: *const zrmir.schema.Module,
    path: []const u8,
    output: Output,
    diagnostic: *zrmir.Diagnostic,
) Error!void {
    const machine = try target.createMachine(arena, source, diagnostic);
    defer llvm.LLVMDisposeTargetMachine(machine);
    // Owns the module: disposing of the context disposes of everything built in it.
    const context = llvm.LLVMContextCreate();
    defer llvm.LLVMContextDispose(context);

    const module = try lowerModule(arena, source, context, machine, diagnostic);
    try emit.verify(arena, module, diagnostic);
    try emit.optimize(arena, module, machine, source.opt_level, diagnostic);
    try emit.write(arena, module, machine, path, output, diagnostic);
}
