//! The LLVM target machine a ZRMIR module is compiled for.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const zrmir = @import("../zrmir.zig");

pub fn createMachine(
    arena: std.mem.Allocator,
    source: *const zrmir.schema.Module,
    diagnostic: *zrmir.Diagnostic,
) codegen.Error!llvm.LLVMTargetMachineRef {
    const target = &source.target;
    try initialize(arena, target.llvm_target, diagnostic);

    const triple = try arena.dupeSentinel(u8, target.llvm_target, 0);
    var found: llvm.LLVMTargetRef = null;
    var message: [*c]u8 = null;
    if (llvm.LLVMGetTargetFromTriple(triple, &found, &message) != 0) {
        defer llvm.LLVMDisposeMessage(message);
        return codegen.fail(diagnostic, arena, "LLVM has no target for `{s}`: {s}", .{ triple, std.mem.span(message) });
    }

    // The same mapping rustc's own LLVM backend uses, so both compile a crate for the same machine.
    const level: llvm.LLVMCodeGenOptLevel = switch (source.opt_level) {
        .none => llvm.LLVMCodeGenLevelNone,
        .less => llvm.LLVMCodeGenLevelLess,
        .more, .size, .size_min => llvm.LLVMCodeGenLevelDefault,
        .aggressive => llvm.LLVMCodeGenLevelAggressive,
    };
    const reloc: llvm.LLVMRelocMode = switch (target.relocation_model) {
        .static => llvm.LLVMRelocStatic,
        // LLVM has no relocation model for a position-independent executable: it is PIC code linked differently.
        .pic, .pie => llvm.LLVMRelocPIC,
        .dynamic_no_pic => llvm.LLVMRelocDynamicNoPic,
        .ropi => llvm.LLVMRelocROPI,
        .rwpi => llvm.LLVMRelocRWPI,
        .ropi_rwpi => llvm.LLVMRelocROPI_RWPI,
    };
    return llvm.LLVMCreateTargetMachine(
        found,
        triple,
        try arena.dupeSentinel(u8, target.cpu, 0),
        try arena.dupeSentinel(u8, target.features, 0),
        level,
        reloc,
        llvm.LLVMCodeModelDefault,
    ) orelse codegen.fail(diagnostic, arena, "LLVM cannot make a target machine for `{s}`", .{triple});
}

/// Registers the one LLVM backend the module needs. An architecture is listed here once its ABI lowering has been
/// checked against rustc's; LLVM itself is built with many more.
fn initialize(arena: std.mem.Allocator, llvm_target: []const u8, diagnostic: *zrmir.Diagnostic) codegen.Error!void {
    const arch = llvm_target[0 .. std.mem.findScalarPos(u8, llvm_target, 0, '-') orelse llvm_target.len];
    if (std.mem.eql(u8, arch, "aarch64") or std.mem.eql(u8, arch, "arm64")) {
        llvm.LLVMInitializeAArch64TargetInfo();
        llvm.LLVMInitializeAArch64Target();
        llvm.LLVMInitializeAArch64TargetMC();
        llvm.LLVMInitializeAArch64AsmPrinter();
    } else if (std.mem.eql(u8, arch, "x86_64")) {
        llvm.LLVMInitializeX86TargetInfo();
        llvm.LLVMInitializeX86Target();
        llvm.LLVMInitializeX86TargetMC();
        llvm.LLVMInitializeX86AsmPrinter();
    } else {
        return codegen.fail(diagnostic, arena, "the architecture `{s}` is not supported yet", .{arch});
    }
}
