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
const rvalue = @import("rvalue.zig");
const types = @import("types.zig");

const Value = rvalue.Value;

pub fn lower(
    l: *const Lowering,
    item: *const schema.Function,
    name: []const u8,
    fn_abi: *const schema.FnAbi,
    value: llvm.LLVMValueRef,
) codegen.Error!void {
    if (llvm.LLVMCountBasicBlocks(value) != 0) return l.malformed("the function `{s}` is defined twice", .{name});

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

/// Where a value lives: a local, or a part of one.
const Place = struct {
    pointer: llvm.LLVMValueRef,
    layout: *const schema.Layout,
    /// What the pointer is known to be aligned to. A part of a packed local is aligned to less than its type asks.
    alignment: u64,

    /// The place `offset` bytes into this one.
    fn at(place: Place, l: *const Lowering, offset: u64, layout: *const schema.Layout) Place {
        if (offset == 0) return .{ .pointer = place.pointer, .layout = layout, .alignment = place.alignment };
        var index = llvm.LLVMConstInt(llvm.LLVMInt64TypeInContext(l.context), offset, 0);
        return .{
            .pointer = llvm.LLVMBuildInBoundsGEP2(l.builder, llvm.LLVMInt8TypeInContext(l.context), place.pointer, &index, 1, ""),
            .layout = layout,
            // An address that is a multiple of the alignment stays one after adding a multiple of it.
            .alignment = @min(place.alignment, @as(u64, 1) << @intCast(@ctz(offset))),
        };
    }
};

const Function = struct {
    l: *const Lowering,
    body: *const schema.Body,
    fn_abi: *const schema.FnAbi,
    value: llvm.LLVMValueRef,
    /// By local. A local without a size has no slot: there is nothing to store.
    slots: []const ?Place = &.{},
    /// By MIR block.
    blocks: []const llvm.LLVMBasicBlockRef = &.{},
    /// Where every failed assertion of the function ends; made when the first one needs it.
    trap: ?llvm.LLVMBasicBlockRef = null,
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

        const slots = try l.arena.alloc(?Place, body.locals.len);
        for (body.locals, slots) |declared, *slot| {
            const ty = l.typeOf(declared.ty);
            const layout = l.layoutOf(ty.layout orelse return l.unsupported("a local of the unsized type `{s}`", .{ty.name}));
            if (layout.size == 0) {
                slot.* = null;
                continue;
            }
            const pointer = llvm.LLVMBuildAlloca(l.builder, try types.memory(l, layout), "");
            // The validator has bounded the alignment.
            llvm.LLVMSetAlignment(pointer, @intCast(layout.@"align"));
            slot.* = .{ .pointer = pointer, .layout = layout, .alignment = layout.@"align" };
        }
        f.slots = slots;

        var param: c_uint = 0;
        for (f.fn_abi.args, slots[1..][0..body.arg_count]) |*arg, slot| {
            const kind = try abi.directScalar(l, arg) orelse continue;
            try f.store(.{ .value = llvm.LLVMGetParam(f.value, param), .kind = kind }, slot);
            param += 1;
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
        const l = f.l;
        switch (statement.kind) {
            .assign => |*assign| try f.lowerAssign(&assign.place, &assign.rvalue),
            // The slots live as long as the function. Telling LLVM when one is dead only lets it share stack space.
            .storage_live, .storage_dead => {},
            .assume => |*operand| _ = l.callIntrinsic("llvm.assume", &.{}, &.{(try f.scalarOf(operand, .bool)).value}),
            else => |*other| return l.unsupported("the statement `{s}`", .{@tagName(other.*)}),
        }
    }

    fn lowerAssign(f: *Function, place: *const schema.Place, assigned: *const schema.Rvalue) codegen.Error!void {
        const l = f.l;
        const into = try f.placeOf(place);
        const value: Value = switch (assigned.*) {
            .use => |*operand| try f.valueOf(operand) orelse {
                if (into != null) return l.malformed("a value without a size is assigned to a place that has one", .{});
                return;
            },
            .binary_op => |*op| try rvalue.binary(l, op.op, try f.scalarOf(&op.left, null), try f.scalarOf(&op.right, null)),
            .checked_binary_op => |*op| {
                const result = try rvalue.checked(l, op.op, try f.scalarOf(&op.left, .int), try f.scalarOf(&op.right, .int));
                // The result is the tuple `(T, bool)`, which rustc lays out as a pair of scalars.
                const tuple = into orelse return l.malformed("a checked operator assigns to a place without a size", .{});
                const pair = switch (tuple.layout.repr) {
                    .scalar_pair => |pair| pair,
                    else => return l.malformed("a checked operator assigns to a place that is not a pair of scalars", .{}),
                };
                try f.storeScalar(result.value, tuple, pair.a);
                try f.storeScalar(result.overflowed, tuple.at(l, pair.b_offset, tuple.layout), pair.b);
                return;
            },
            .unary_op => |*op| try rvalue.unary(l, op.op, try f.scalarOf(&op.operand, null)),
            .cast => |*cast| try f.lowerCast(cast.kind, &cast.operand, cast.ty),
            else => |*other| return l.unsupported("the rvalue `{s}`", .{@tagName(other.*)}),
        };
        try f.store(value, into);
    }

    fn lowerCast(f: *Function, kind: schema.CastKind, operand: *const schema.Operand, to: schema.TypeId) codegen.Error!Value {
        const l = f.l;
        const ty = l.typeOf(to);
        const layout = l.layoutOf(ty.layout orelse return l.malformed("a cast to the unsized type `{s}`", .{ty.name}));
        const scalar = switch (layout.repr) {
            .scalar => |repr| repr.scalar,
            else => return l.unsupported("the cast `{s}` to `{s}`, which is not a scalar", .{ @tagName(kind), ty.name }),
        };
        switch (kind) {
            // The operand is the function item itself, a value without a size: the pointer comes from its symbol.
            .reify_fn_pointer => |reified| {
                if (scalar.primitive != .pointer) return l.malformed("a function pointer that is not a pointer", .{});
                return .{ .value = try l.functionOf(reified.symbol), .kind = scalar };
            },
            else => return rvalue.cast(l, kind, try f.scalarOf(operand, null), scalar),
        }
    }

    fn lowerTerminator(f: *Function, terminator: *const schema.Terminator) codegen.Error!void {
        const l = f.l;
        switch (terminator.kind) {
            .goto => |goto| _ = llvm.LLVMBuildBr(l.builder, f.blocks[goto.target.index()]),
            .switch_int => |*switch_int| {
                const discr = try f.scalarOf(&switch_int.discr, null);
                switch (discr.kind.primitive) {
                    .bool, .int => {},
                    else => return l.malformed("a switch on a value that is neither an integer nor a boolean", .{}),
                }
                const ty = llvm.LLVMTypeOf(discr.value);
                const branches = switch_int.branches;
                const built = llvm.LLVMBuildSwitch(l.builder, discr.value, f.blocks[switch_int.otherwise.index()], @intCast(branches.len));
                for (branches) |branch| {
                    const words = [2]u64{ @truncate(branch.value), @truncate(branch.value >> 64) };
                    llvm.LLVMAddCase(built, llvm.LLVMConstIntOfArbitraryPrecision(ty, words.len, &words), f.blocks[branch.target.index()]);
                }
            },
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
                _ = llvm.LLVMBuildRet(l.builder, returned.value);
            },
            .@"unreachable" => _ = llvm.LLVMBuildUnreachable(l.builder),
            .assert => |*assert| {
                // A failed assertion is a panic. Until the panic functions can be called it is a trap, which ends the
                // program as a panic does when panics abort; where they unwind, that would be another program.
                if (l.source.panic_strategy == .unwind) return l.unsupported("an assertion in a crate whose panics unwind", .{});
                const cond = try f.scalarOf(&assert.cond, .bool);
                const target = f.blocks[assert.target.index()];
                const trap = try f.trapBlock();
                _ = if (assert.expected)
                    llvm.LLVMBuildCondBr(l.builder, cond.value, target, trap)
                else
                    llvm.LLVMBuildCondBr(l.builder, cond.value, trap, target);
            },
            .call => |*call| try f.lowerCall(call),
            else => |*other| return l.unsupported("the terminator `{s}`", .{@tagName(other.*)}),
        }
    }

    fn lowerCall(f: *Function, call: *const @FieldType(schema.TerminatorKind, "call")) codegen.Error!void {
        const l = f.l;
        if (call.rust_call) return l.unsupported("a call that passes a tuple as separate arguments", .{});
        if (call.caller_location != null) return l.unsupported("a call that passes the location of its caller", .{});
        switch (call.unwind) {
            // Nothing is done when the callee unwinds, so a plain call is the whole of it.
            .@"continue", .@"unreachable" => {},
            // Where panics abort nothing unwinds, and there is nothing to terminate.
            .terminate => if (l.source.panic_strategy == .unwind) {
                return l.unsupported("a call that must not unwind in a crate whose panics unwind", .{});
            },
            .cleanup => return l.unsupported("a call with a cleanup block", .{}),
        }

        const callee = switch (call.callee) {
            .direct => |direct| try l.functionOf(direct.symbol),
            .indirect => (try f.scalarOf(&call.func, .pointer)).value,
            .intrinsic => |intrinsic| return l.unsupported("the intrinsic `{s}`", .{intrinsic.name}),
            .llvm_intrinsic => |intrinsic| return l.unsupported("the LLVM intrinsic `{s}`", .{intrinsic.name}),
            .virtual => return l.unsupported("a call through a vtable", .{}),
        };
        // The validator has checked that only a call of an LLVM intrinsic has no ABI.
        const fn_abi = &l.source.fn_abis[call.abi.?.index()];
        if (fn_abi.args.len != call.args.len) {
            return l.malformed("a call passes {d} arguments to an ABI of {d}", .{ call.args.len, fn_abi.args.len });
        }

        var args: std.ArrayList(llvm.LLVMValueRef) = .empty;
        for (fn_abi.args, call.args) |*arg, *operand| {
            const kind = try abi.directScalar(l, arg) orelse continue;
            const passed = try f.scalarOf(operand, null);
            if (!std.meta.eql(passed.kind.primitive, kind.primitive)) {
                return l.malformed("a call passes a value of another kind than its ABI names", .{});
            }
            try args.append(l.arena, passed.value);
        }

        const result = llvm.LLVMBuildCall2(l.builder, try abi.signature(l, fn_abi), callee, args.items.ptr, @intCast(args.items.len), "");
        llvm.LLVMSetInstructionCallConv(result, try abi.convention(l, fn_abi));
        abi.attributes(l, fn_abi, .{ .call = result });

        const target = call.target orelse {
            _ = llvm.LLVMBuildUnreachable(l.builder);
            return;
        };
        if (try abi.directScalar(l, &fn_abi.ret)) |kind| {
            try f.store(.{ .value = result, .kind = kind }, try f.placeOf(&call.destination));
        }
        _ = llvm.LLVMBuildBr(l.builder, f.blocks[target.index()]);
    }

    fn trapBlock(f: *Function) codegen.Error!llvm.LLVMBasicBlockRef {
        if (f.trap) |trap| return trap;
        const l = f.l;
        const current = llvm.LLVMGetInsertBlock(l.builder);
        defer llvm.LLVMPositionBuilderAtEnd(l.builder, current);

        const trap = llvm.LLVMAppendBasicBlockInContext(l.context, f.value, "trap");
        llvm.LLVMPositionBuilderAtEnd(l.builder, trap);
        _ = l.callIntrinsic("llvm.trap", &.{}, &.{});
        _ = llvm.LLVMBuildUnreachable(l.builder);
        f.trap = trap;
        return trap;
    }

    /// The value of an operand, or null if its type has no size.
    fn valueOf(f: *Function, operand: *const schema.Operand) codegen.Error!?Value {
        const l = f.l;
        switch (operand.*) {
            // A move leaves its source undefined, which asks nothing of the code that reads it.
            .copy, .move => |*place| return try f.load(try f.placeOf(place) orelse return null),
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
            // rustc has already decided the check for this compilation.
            .runtime_checks => |checks| return .{
                .value = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(l.context), @intFromBool(checks.value), 0),
                .kind = types.boolean,
            },
        }
    }

    /// The value of an operand that has to be a scalar, of one kind if `kind` names it.
    fn scalarOf(f: *Function, operand: *const schema.Operand, kind: ?std.meta.Tag(schema.Primitive)) codegen.Error!Value {
        const value = try f.valueOf(operand) orelse return f.l.malformed("a value without a size where a scalar belongs", .{});
        if (kind) |expected| if (value.kind.primitive != expected) {
            return f.l.malformed("a `{s}` where a `{s}` belongs", .{ @tagName(value.kind.primitive), @tagName(expected) });
        };
        return value;
    }

    /// Where a place is, or null if it has no size.
    fn placeOf(f: *Function, place: *const schema.Place) codegen.Error!?Place {
        const l = f.l;
        var current = f.slots[place.local.index()];
        for (place.projection) |*element| switch (element.*) {
            .field => |field| {
                const ty = l.typeOf(field.ty);
                const layout = l.layoutOf(ty.layout orelse return l.unsupported("a field of the unsized type `{s}`", .{ty.name}));
                const parent = current orelse {
                    if (layout.size != 0) return l.malformed("a field with a size in a value without one", .{});
                    continue;
                };
                if (parent.layout.variants != .single) return l.unsupported("a field of a value that is not a struct or a tuple", .{});
                const offsets = switch (parent.layout.fields) {
                    .arbitrary => |fields| fields.offsets,
                    else => |other| return l.unsupported("a field of a value laid out as `{s}`", .{@tagName(other)}),
                };
                if (field.index >= offsets.len) return l.malformed("field {d} of a value with {d} fields", .{ field.index, offsets.len });
                const offset = offsets[field.index];
                if (offset > parent.layout.size or parent.layout.size - offset < layout.size) {
                    return l.malformed("a field that does not fit into its value", .{});
                }
                current = if (layout.size == 0) null else parent.at(l, offset, layout);
            },
            else => |*other| return l.unsupported("a place through `{s}`", .{@tagName(other.*)}),
        };
        return current;
    }

    fn load(f: *Function, place: Place) codegen.Error!Value {
        const l = f.l;
        const kind = switch (place.layout.repr) {
            .scalar => |repr| repr.scalar,
            else => return l.unsupported("reading a value that is not a scalar", .{}),
        };
        const loaded = llvm.LLVMBuildLoad2(l.builder, try types.scalar(l, kind, .memory), place.pointer, "");
        llvm.LLVMSetAlignment(loaded, @intCast(place.alignment));
        return .{ .value = types.toImmediate(l, loaded, kind), .kind = kind };
    }

    fn store(f: *Function, value: Value, into: ?Place) codegen.Error!void {
        const l = f.l;
        const place = into orelse return l.malformed("a value with a size is assigned to a place that has none", .{});
        const kind = switch (place.layout.repr) {
            .scalar => |repr| repr.scalar,
            else => return l.unsupported("writing a value that is not a scalar", .{}),
        };
        try f.storeScalar(value, place, kind);
    }

    /// Stores a scalar at the start of a place that holds one of the kind `kind` there.
    fn storeScalar(f: *Function, value: Value, place: Place, kind: schema.Scalar) codegen.Error!void {
        const l = f.l;
        // LLVM would not notice: with opaque pointers a store of any type through any pointer is valid IR.
        if (!std.meta.eql(value.kind.primitive, kind.primitive)) {
            return l.malformed("a value of one kind is assigned to a place of another", .{});
        }
        const stored = llvm.LLVMBuildStore(l.builder, types.toMemory(l, value.value, kind), place.pointer);
        llvm.LLVMSetAlignment(stored, @intCast(place.alignment));
    }
};
