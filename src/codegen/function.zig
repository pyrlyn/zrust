//! Lowers one MIR body into the LLVM function declared for it.
//!
//! Every local that has a size lives in a stack slot, and every use reads or writes that slot. The result is naive on
//! purpose: it needs no analysis of the MIR to be correct, and LLVM's `sroa` turns the slots into registers.

const std = @import("std");
const llvm = @import("llvm_c");

const codegen = @import("../codegen.zig");
const schema = @import("../zrmir/schema.zig");
const abi = @import("abi.zig");
const consts = @import("consts.zig");
const Lowering = @import("module.zig").Lowering;
const types = @import("types.zig");

pub fn lower(
    l: *const Lowering,
    item: *const schema.Function,
    name: []const u8,
    fn_abi: *const schema.FnAbi,
    value: llvm.LLVMValueRef,
) codegen.Error!void {
    var function: Function = .{ .l = l, .body = &item.body, .fn_abi = fn_abi, .value = value };
    function.lowerBody() catch |err| {
        // A refusal is only useful with its place: the same construct may be fine a block earlier.
        if (err == error.CodegenFailed) {
            l.diagnostic.message = if (function.at) |at|
                try std.fmt.allocPrint(l.arena, "`{s}`, bb{d}[{d}]: {s}", .{ name, at.block, at.statement, l.diagnostic.message })
            else
                try std.fmt.allocPrint(l.arena, "`{s}`: {s}", .{ name, l.diagnostic.message });
        }
        return err;
    };
}

/// Where a local lives.
const Slot = struct {
    pointer: llvm.LLVMValueRef,
    layout: *const schema.Layout,
};

/// A scalar in the form it is stored in.
const Value = struct {
    value: llvm.LLVMValueRef,
    kind: schema.Scalar,
};

const Function = struct {
    l: *const Lowering,
    body: *const schema.Body,
    fn_abi: *const schema.FnAbi,
    value: llvm.LLVMValueRef,
    /// By local. A local without a size has no slot: there is nothing to store.
    slots: []const ?Slot = &.{},
    /// By MIR block.
    blocks: []const llvm.LLVMBasicBlockRef = &.{},
    /// The statement being lowered, as rustc counts them: the terminator comes after the last statement.
    at: ?struct { block: usize, statement: usize } = null,

    fn lowerBody(f: *Function) codegen.Error!void {
        const l = f.l;
        const body = f.body;
        if (body.spread_arg != null) return l.unsupported("a function that takes its arguments as one tuple", .{});
        if (body.arg_count != f.fn_abi.args.len) {
            return l.unsupported("a function whose ABI has arguments the body does not name", .{});
        }

        // LLVM's entry block cannot be jumped to, and MIR's first block can.
        const start = llvm.LLVMAppendBasicBlockInContext(l.context, f.value, "start");
        llvm.LLVMPositionBuilderAtEnd(l.builder, start);

        const slots = try l.arena.alloc(?Slot, body.locals.len);
        for (body.locals, slots) |declared, *slot| {
            const ty = l.typeOf(declared.ty);
            const layout = l.layoutOf(ty.layout orelse return l.unsupported("a local of the unsized type `{s}`", .{ty.name}));
            slot.* = if (layout.size == 0) null else .{
                .pointer = aligned(llvm.LLVMBuildAlloca(l.builder, try types.memory(l, layout), ""), layout),
                .layout = layout,
            };
        }
        f.slots = slots;

        var param: c_uint = 0;
        for (f.fn_abi.args, slots[1..][0..body.arg_count]) |*arg, slot| {
            const kind = try abi.directScalar(l, arg) orelse continue;
            const passed = types.toMemory(l, llvm.LLVMGetParam(f.value, param), kind);
            param += 1;
            try f.store(.{ .value = passed, .kind = kind }, slot);
        }

        const blocks = try l.arena.alloc(llvm.LLVMBasicBlockRef, body.blocks.len);
        for (blocks, 0..) |*block, index| {
            block.* = llvm.LLVMAppendBasicBlockInContext(l.context, f.value, try l.arena.printSentinel("bb{d}", .{index}, 0));
        }
        f.blocks = blocks;
        _ = llvm.LLVMBuildBr(l.builder, blocks[0]);

        for (body.blocks, blocks, 0..) |*block, llvm_block, index| {
            llvm.LLVMPositionBuilderAtEnd(l.builder, llvm_block);
            for (block.statements, 0..) |*statement, statement_index| {
                f.at = .{ .block = index, .statement = statement_index };
                try f.lowerStatement(statement);
            }
            f.at = .{ .block = index, .statement = block.statements.len };
            try f.lowerTerminator(&block.terminator);
        }
    }

    fn lowerStatement(f: *Function, statement: *const schema.Statement) codegen.Error!void {
        switch (statement.kind) {
            .assign => |*assign| {
                const operand = switch (assign.rvalue) {
                    .use => |*operand| operand,
                    else => |*other| return f.l.unsupported("the rvalue `{s}`", .{@tagName(other.*)}),
                };
                const value = try f.valueOf(operand);
                const slot = try f.slotOf(&assign.place);
                if (value) |stored| try f.store(stored, slot) else if (slot != null) {
                    return f.l.malformed("a value without a size is assigned to a place that has one", .{});
                }
            },
            // The slots live as long as the function. Telling LLVM when one is dead only lets it share stack space.
            .storage_live, .storage_dead => {},
            else => |*other| return f.l.unsupported("the statement `{s}`", .{@tagName(other.*)}),
        }
    }

    fn lowerTerminator(f: *Function, terminator: *const schema.Terminator) codegen.Error!void {
        const l = f.l;
        switch (terminator.kind) {
            .goto => |goto| _ = llvm.LLVMBuildBr(l.builder, f.blocks[goto.target.index()]),
            .@"return" => {
                const kind = try abi.directScalar(l, &f.fn_abi.ret) orelse {
                    _ = llvm.LLVMBuildRetVoid(l.builder);
                    return;
                };
                const slot = f.slots[0] orelse return l.malformed("a function returns a value its return place cannot hold", .{});
                const returned = try f.load(slot);
                if (!std.meta.eql(returned.kind.primitive, kind.primitive)) {
                    return l.malformed("a function returns a value of another kind than its ABI names", .{});
                }
                _ = llvm.LLVMBuildRet(l.builder, types.toImmediate(l, returned.value, kind));
            },
            .@"unreachable" => _ = llvm.LLVMBuildUnreachable(l.builder),
            else => |*other| return l.unsupported("the terminator `{s}`", .{@tagName(other.*)}),
        }
    }

    /// The value of an operand, or null if its type has no size.
    fn valueOf(f: *Function, operand: *const schema.Operand) codegen.Error!?Value {
        const l = f.l;
        switch (operand.*) {
            // A move leaves its source undefined, which asks nothing of the code that reads it.
            .copy, .move => |*place| return try f.load(try f.slotOf(place) orelse return null),
            .constant => |*constant| {
                const memory = switch (constant.value) {
                    .zero_sized => return null,
                    .memory => |*memory| memory,
                };
                const ty = l.typeOf(constant.ty);
                const layout = l.layoutOf(ty.layout orelse return l.malformed("a constant of the unsized type `{s}`", .{ty.name}));
                if (layout.size == 0) return null;
                const kind = switch (layout.repr) {
                    .scalar => |repr| repr.scalar,
                    else => return l.unsupported("a constant of the type `{s}`, which is not a scalar", .{ty.name}),
                };
                return .{ .value = try consts.scalar(l, memory, kind), .kind = kind };
            },
            .runtime_checks => return l.unsupported("a runtime-check flag as an operand", .{}),
        }
    }

    /// The slot of a place that is a whole local.
    fn slotOf(f: *Function, place: *const schema.Place) codegen.Error!?Slot {
        if (place.projection.len != 0) {
            return f.l.unsupported("a place inside a local (`{s}`)", .{@tagName(place.projection[0])});
        }
        return f.slots[place.local.index()];
    }

    fn load(f: *Function, slot: Slot) codegen.Error!Value {
        const l = f.l;
        const kind = switch (slot.layout.repr) {
            .scalar => |repr| repr.scalar,
            else => return l.unsupported("reading a local that is not a scalar", .{}),
        };
        const loaded = llvm.LLVMBuildLoad2(l.builder, try types.scalar(l, kind, .memory), slot.pointer, "");
        return .{ .value = aligned(loaded, slot.layout), .kind = kind };
    }

    fn store(f: *Function, value: Value, into: ?Slot) codegen.Error!void {
        const l = f.l;
        const slot = into orelse return l.malformed("a value with a size is assigned to a place that has none", .{});
        const kind = switch (slot.layout.repr) {
            .scalar => |repr| repr.scalar,
            else => return l.unsupported("writing a local that is not a scalar", .{}),
        };
        // LLVM would not notice: with opaque pointers a store of any type into any slot is valid IR.
        if (!std.meta.eql(value.kind.primitive, kind.primitive)) {
            return l.malformed("a value of one kind is assigned to a place of another", .{});
        }
        _ = aligned(llvm.LLVMBuildStore(l.builder, value.value, slot.pointer), slot.layout);
    }
};

/// Sets the alignment rustc computed on an alloca, a load or a store. LLVM would otherwise assume its own for the type,
/// and the two need not agree.
fn aligned(instruction: llvm.LLVMValueRef, layout: *const schema.Layout) llvm.LLVMValueRef {
    // The validator has bounded the alignment.
    llvm.LLVMSetAlignment(instruction, @intCast(layout.@"align"));
    return instruction;
}
