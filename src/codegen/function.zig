//! Lowers one MIR body into the LLVM function declared for it.
//!
//! Every local lives in memory, and every use reads or writes it there: a scalar is loaded and stored as one, anything
//! else is so many bytes, copied from place to place. The result is naive on purpose: it needs no analysis of the MIR
//! to be correct, and LLVM's `sroa` turns the memory into registers.

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

/// A pointer and what it is known to be aligned to. A part of a packed value is aligned to less than its type asks,
/// so the alignment travels with the pointer and every load, store and copy states it.
const Address = struct {
    pointer: llvm.LLVMValueRef,
    alignment: u64,

    /// The address `bytes` further, inside the same value.
    fn offset(address: Address, l: *const Lowering, bytes: u64) Address {
        if (bytes == 0) return address;
        var index = llvm.LLVMConstInt(types.pointerSized(l), bytes, 0);
        return .{
            .pointer = llvm.LLVMBuildInBoundsGEP2(l.builder, llvm.LLVMInt8TypeInContext(l.context), address.pointer, &index, 1, ""),
            .alignment = @min(address.alignment, lowestBit(bytes)),
        };
    }
};

/// An address that is a multiple of the alignment stays one after adding a multiple of it; this is the largest power
/// of two a nonzero distance is a multiple of.
fn lowestBit(distance: u64) u64 {
    return @as(u64, 1) << @intCast(@ctz(distance));
}

/// Where a value lives: a local, a part of one, or what a pointer points at.
const Place = struct {
    address: Address,
    ty: schema.TypeId,
    layout: *const schema.Layout,
};

/// What reading a place or an operand gives.
const Read = union(enum) {
    /// The type has no size: there is nothing to read or to write.
    nothing,
    scalar: Value,
    /// Anything else stays where it is until its bytes are copied.
    memory: Place,
};

/// An array as its layout and its type describe it together.
const Array = struct {
    element: schema.TypeId,
    layout: *const schema.Layout,
    stride: u64,
    count: u64,
};

const Function = struct {
    l: *const Lowering,
    body: *const schema.Body,
    fn_abi: *const schema.FnAbi,
    value: llvm.LLVMValueRef,
    /// How the result leaves the function.
    ret: abi.Passed = .ignore,
    /// By local.
    slots: []const Place = &.{},
    /// By MIR block.
    blocks: []const llvm.LLVMBasicBlockRef = &.{},
    /// The jump that ends the entry block, once it is there.
    entry_end: ?llvm.LLVMValueRef = null,
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

        const slots = try l.arena.alloc(Place, body.locals.len);
        var param: c_uint = 0;
        // Local 0 is the return place. A result returned in memory is written straight into the caller's.
        f.ret = try abi.classify(l, &f.fn_abi.ret);
        slots[0] = switch (f.ret) {
            .indirect => in_memory: {
                const layout = try f.passedLayout(&f.fn_abi.ret, body.locals[0].ty);
                defer param += 1;
                break :in_memory .{
                    .address = .{ .pointer = llvm.LLVMGetParam(f.value, param), .alignment = layout.@"align" },
                    .ty = body.locals[0].ty,
                    .layout = layout,
                };
            },
            else => try f.local(body.locals[0].ty),
        };
        const args = body.locals[1..][0..body.arg_count];
        for (f.fn_abi.args, args, slots[1..][0..args.len]) |*arg, declared, *slot| {
            slot.* = try f.argument(arg, declared.ty, &param);
        }
        for (body.locals[1 + args.len ..], slots[1 + args.len ..]) |declared, *slot| slot.* = try f.local(declared.ty);
        f.slots = slots;

        const blocks = try l.arena.alloc(llvm.LLVMBasicBlockRef, body.blocks.len);
        for (blocks, 0..) |*block, index| {
            block.* = llvm.LLVMAppendBasicBlockInContext(l.context, f.value, try l.arena.printSentinel("bb{d}", .{index}, 0));
        }
        f.blocks = blocks;
        f.entry_end = llvm.LLVMBuildBr(l.builder, blocks[0]);

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

    /// The memory of a local the function owns.
    fn local(f: *Function, ty: schema.TypeId) codegen.Error!Place {
        const layout = try f.sized(ty, "a local");
        return .{ .address = f.alloca(try types.memory(f.l, layout), layout.@"align"), .ty = ty, .layout = layout };
    }

    /// The memory of an argument, with the value the caller passed in it. `param` counts the LLVM parameters taken.
    fn argument(f: *Function, arg: *const schema.ArgAbi, ty: schema.TypeId, param: *c_uint) codegen.Error!Place {
        const l = f.l;
        const layout = try f.passedLayout(arg, ty);
        switch (try abi.classify(l, arg)) {
            .ignore => return f.local(ty),
            .direct => |kind| {
                const slot = try f.local(ty);
                try f.write(slot, .{ .scalar = .{ .value = f.takeParam(param), .kind = kind } });
                return slot;
            },
            .pair => |pair| {
                const slot = try f.local(ty);
                const a = f.takeParam(param);
                const b = f.takeParam(param);
                try f.storePair(slot.address, pair, .{ .value = a, .kind = pair.a }, .{ .value = b, .kind = pair.b });
                return slot;
            },
            .cast => |cast| {
                const slot = try f.local(ty);
                f.fromCast(f.takeParam(param), cast, slot);
                return slot;
            },
            .indirect => |indirect| {
                const passed: Address = .{ .pointer = f.takeParam(param), .alignment = indirect.alignment };
                // The caller made this memory for the call, so it is the argument's own, unless the ABI aligns it
                // to less than the type asks.
                if (passed.alignment >= layout.@"align") return .{ .address = passed, .ty = ty, .layout = layout };
                const slot = try f.local(ty);
                f.copyBytes(slot.address, passed, layout.size);
                return slot;
            },
        }
    }

    fn takeParam(f: *Function, param: *c_uint) llvm.LLVMValueRef {
        defer param.* += 1;
        return llvm.LLVMGetParam(f.value, param.*);
    }

    /// The layout of a local a value is passed in or out through, which the ABI has to describe as the body does.
    fn passedLayout(f: *Function, arg: *const schema.ArgAbi, ty: schema.TypeId) codegen.Error!*const schema.Layout {
        const l = f.l;
        const layout = try f.sized(ty, "a local");
        if (l.layoutOf(arg.layout).size != layout.size) {
            return l.malformed("`{s}` is passed as a value of another size", .{l.typeOf(ty).name});
        }
        return layout;
    }

    fn sized(f: *Function, id: schema.TypeId, comptime what: []const u8) codegen.Error!*const schema.Layout {
        const l = f.l;
        const ty = l.typeOf(id);
        return l.layoutOf(ty.layout orelse return l.unsupported(what ++ " of the unsized type `{s}`", .{ty.name}));
    }

    /// Stack memory that lives as long as the call. It is taken in the entry block whichever block needs it: an
    /// `alloca` anywhere else takes new memory every time a loop comes by.
    fn alloca(f: *Function, ty: llvm.LLVMTypeRef, alignment: u64) Address {
        const l = f.l;
        const current = llvm.LLVMGetInsertBlock(l.builder);
        if (f.entry_end) |end| llvm.LLVMPositionBuilderBefore(l.builder, end);
        // Everything else is built at the end of a block, so that is where the builder goes back to.
        defer if (f.entry_end != null) llvm.LLVMPositionBuilderAtEnd(l.builder, current);

        const pointer = llvm.LLVMBuildAlloca(l.builder, ty, "");
        // The validator has bounded the alignment.
        llvm.LLVMSetAlignment(pointer, @intCast(alignment));
        return .{ .pointer = pointer, .alignment = alignment };
    }

    fn lowerStatement(f: *Function, statement: *const schema.Statement) codegen.Error!void {
        const l = f.l;
        switch (statement.kind) {
            .assign => |*assign| try f.lowerAssign(&assign.place, &assign.rvalue),
            // The slots live as long as the function. Telling LLVM when one is dead only lets it share stack space.
            .storage_live, .storage_dead => {},
            .assume => |*operand| _ = l.callIntrinsic("llvm.assume", &.{}, &.{(try f.scalarOf(operand, .bool)).value}),
            .copy_nonoverlapping => |*copy| {
                const from = try f.typed(&copy.src);
                const src = try f.scalarIn(from.read, .pointer);
                const dst = try f.scalarOf(&copy.dst, .pointer);
                const count = try f.scalarOf(&copy.count, .int);
                const element = try f.sized(try f.pointeeOf(from.ty), "a copy of values");
                // MIR promises that the bytes exist, so their number fits.
                const size = llvm.LLVMBuildNUWMul(l.builder, count.value, llvm.LLVMConstInt(llvm.LLVMTypeOf(count.value), element.size, 0), "");
                const alignment: c_uint = @intCast(element.@"align");
                _ = llvm.LLVMBuildMemCpy(l.builder, dst.value, alignment, src.value, alignment, size);
            },
            else => |*other| return l.unsupported("the statement `{s}`", .{@tagName(other.*)}),
        }
    }

    fn lowerAssign(f: *Function, place: *const schema.Place, assigned: *const schema.Rvalue) codegen.Error!void {
        const l = f.l;
        const into = try f.placeOf(place);
        const value: Value = switch (assigned.*) {
            .use => |*operand| return f.write(into, try f.read(operand)),
            .copy_for_deref => |*source| return f.write(into, try f.readPlace(try f.placeOf(source))),
            .aggregate => |*aggregate| return f.lowerAggregate(into, aggregate),
            .repeat => |*repeat| return f.lowerRepeat(into, &repeat.operand, repeat.count),
            .ref => |*ref| try f.pointerTo(&ref.place, into),
            .address_of => |*raw| try f.pointerTo(&raw.place, into),
            .binary_op => |*op| switch (op.op) {
                .offset => moved: {
                    const pointer = try f.typed(&op.left);
                    const target = try f.sized(try f.pointeeOf(pointer.ty), "a pointer offset between values");
                    break :moved try rvalue.offset(l, try f.scalarIn(pointer.read, .pointer), try f.scalarOf(&op.right, .int), target.size);
                },
                else => try rvalue.binary(l, op.op, try f.scalarOf(&op.left, null), try f.scalarOf(&op.right, null)),
            },
            .checked_binary_op => |*op| {
                const result = try rvalue.checked(l, op.op, try f.scalarOf(&op.left, .int), try f.scalarOf(&op.right, .int));
                // The result is the tuple `(T, bool)`, which rustc lays out as a pair of scalars.
                const pair = switch (into.layout.repr) {
                    .scalar_pair => |pair| pair,
                    else => return l.malformed("a checked operator assigns to a place that is not a pair of scalars", .{}),
                };
                return f.storePair(into.address, pair, result.value, result.overflowed);
            },
            .unary_op => |*op| try rvalue.unary(l, op.op, try f.scalarOf(&op.operand, null)),
            .cast => |*cast| try f.lowerCast(cast.kind, &cast.operand, cast.ty),
            else => |*other| return l.unsupported("the rvalue `{s}`", .{@tagName(other.*)}),
        };
        try f.write(into, .{ .scalar = value });
    }

    /// The address of a place as the pointer or reference `into` holds.
    fn pointerTo(f: *Function, place: *const schema.Place, into: Place) codegen.Error!Value {
        const l = f.l;
        const target = try f.placeOf(place);
        const kind = switch (into.layout.repr) {
            .scalar => |repr| repr.scalar,
            else => return l.malformed("a pointer to a value with a size is not a scalar", .{}),
        };
        if (kind.primitive != .pointer) return l.malformed("the address of a place is assigned to something that is not a pointer", .{});
        return .{ .value = target.address.pointer, .kind = kind };
    }

    /// Writes the parts of a new value where they belong in it, one after another.
    fn lowerAggregate(f: *Function, into: Place, aggregate: *const @FieldType(schema.Rvalue, "aggregate")) codegen.Error!void {
        const l = f.l;
        const ty = l.typeOf(aggregate.ty);
        const operands = aggregate.operands;
        switch (aggregate.kind) {
            .array => {
                const array = try f.arrayOf(into);
                if (operands.len != array.count) return l.malformed("an array of {d} is built from {d} values", .{ array.count, operands.len });
                for (operands, 0..) |*operand, index| {
                    const element: Place = .{ .address = into.address.offset(l, index * array.stride), .ty = array.element, .layout = array.layout };
                    try f.write(element, try f.read(operand));
                }
            },
            .tuple => {
                const fields = switch (ty.kind) {
                    .tuple => |tuple| tuple.fields,
                    else => return l.malformed("`{s}` is built as a tuple", .{ty.name}),
                };
                if (operands.len != fields.len) return l.malformed("`{s}` is built from {d} values", .{ ty.name, operands.len });
                for (operands, fields, 0..) |*operand, field, index| {
                    try f.write(try f.fieldOf(into, @intCast(index), field), try f.read(operand));
                }
            },
            .adt => |adt| {
                const declared = switch (ty.kind) {
                    .adt => |declared| declared,
                    else => return l.malformed("`{s}` is built as a struct", .{ty.name}),
                };
                if (declared.kind == .@"enum") return l.unsupported("a value of the enum `{s}`", .{ty.name});
                if (adt.variant != 0 or declared.variants.len != 1) return l.malformed("`{s}` has no variant {d}", .{ ty.name, adt.variant });
                const fields = declared.variants[0].fields;
                if (adt.active_field) |active| {
                    // A union is built from the one field that is written.
                    if (operands.len != 1 or active >= fields.len) return l.malformed("`{s}` is built from a field it does not have", .{ty.name});
                    return f.write(try f.fieldOf(into, active, fields[active].ty), try f.read(&operands[0]));
                }
                if (operands.len != fields.len) return l.malformed("`{s}` is built from {d} values", .{ ty.name, operands.len });
                for (operands, fields, 0..) |*operand, field, index| {
                    try f.write(try f.fieldOf(into, @intCast(index), field.ty), try f.read(operand));
                }
            },
            else => |other| return l.unsupported("a value built as `{s}`", .{@tagName(other)}),
        }
    }

    /// Writes one value into every element of an array.
    fn lowerRepeat(f: *Function, into: Place, operand: *const schema.Operand, count: u64) codegen.Error!void {
        const l = f.l;
        const b = l.builder;
        const array = try f.arrayOf(into);
        if (array.count != count) return l.malformed("an array of {d} is filled with {d} values", .{ array.count, count });
        const value = try f.read(operand);
        if (count == 0 or array.layout.size == 0) return;

        const index_ty = types.pointerSized(l);
        const before = llvm.LLVMGetInsertBlock(b);
        const loop = llvm.LLVMAppendBasicBlockInContext(l.context, f.value, "repeat");
        const after = llvm.LLVMAppendBasicBlockInContext(l.context, f.value, "repeated");
        _ = llvm.LLVMBuildBr(b, loop);

        llvm.LLVMPositionBuilderAtEnd(b, loop);
        const index = llvm.LLVMBuildPhi(b, index_ty, "");
        try f.write(elementAt(l, into, array, index), value);
        const next = llvm.LLVMBuildNUWAdd(b, index, llvm.LLVMConstInt(index_ty, 1, 0), "");
        var incoming = [_]llvm.LLVMValueRef{ llvm.LLVMConstInt(index_ty, 0, 0), next };
        var from = [_]llvm.LLVMBasicBlockRef{ before, loop };
        llvm.LLVMAddIncoming(index, &incoming, &from, incoming.len);
        const done = llvm.LLVMBuildICmp(b, llvm.LLVMIntEQ, next, llvm.LLVMConstInt(index_ty, count, 0), "");
        _ = llvm.LLVMBuildCondBr(b, done, after, loop);

        llvm.LLVMPositionBuilderAtEnd(b, after);
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
            .@"return" => try f.lowerReturn(),
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

    fn lowerReturn(f: *Function) codegen.Error!void {
        const l = f.l;
        const slot = f.slots[0];
        _ = switch (f.ret) {
            // A result returned in memory has been written where the caller wants it all along.
            .ignore, .indirect => llvm.LLVMBuildRetVoid(l.builder),
            .direct => |kind| returned: {
                const result = switch (try f.readPlace(slot)) {
                    .scalar => |scalar| scalar,
                    else => return l.malformed("a function returns a scalar its return place does not hold", .{}),
                };
                if (!std.meta.eql(result.kind.primitive, kind.primitive)) {
                    return l.malformed("a function returns a value of another kind than its ABI names", .{});
                }
                break :returned llvm.LLVMBuildRet(l.builder, result.value);
            },
            .pair => |pair| returned: {
                const a, const b = try f.loadPair(slot.address, pair);
                const both = llvm.LLVMGetPoison(llvm.LLVMGetReturnType(llvm.LLVMGlobalGetValueType(f.value)));
                const first = llvm.LLVMBuildInsertValue(l.builder, both, a.value, 0, "");
                break :returned llvm.LLVMBuildRet(l.builder, llvm.LLVMBuildInsertValue(l.builder, first, b.value, 1, ""));
            },
            .cast => |cast| llvm.LLVMBuildRet(l.builder, f.toCast(slot, cast)),
        };
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

        const destination = try f.placeOf(&call.destination);
        const returned = try abi.classify(l, &fn_abi.ret);
        if (returned != .ignore and l.layoutOf(fn_abi.ret.layout).size != destination.layout.size) {
            return l.malformed("a call returns a value of another size than its destination", .{});
        }

        var args: std.ArrayList(llvm.LLVMValueRef) = .empty;
        // Where the callee writes a result it returns in memory: the destination itself when that will do.
        var result_memory: ?Address = null;
        if (returned == .indirect) {
            const required = destination.layout.@"align";
            // A call that does not return has no destination worth the name.
            const memory = if (call.target != null and destination.address.alignment >= required)
                destination.address
            else
                f.alloca(types.bytes(l, destination.layout.size), required);
            try args.append(l.arena, memory.pointer);
            result_memory = memory;
        }
        for (fn_abi.args, call.args) |*arg, *operand| try f.passArgument(&args, arg, operand);

        const result = llvm.LLVMBuildCall2(l.builder, try abi.signature(l, fn_abi), callee, args.items.ptr, @intCast(args.items.len), "");
        llvm.LLVMSetInstructionCallConv(result, try abi.convention(l, fn_abi));
        abi.attributes(l, fn_abi, .{ .call = result });

        const target = call.target orelse {
            _ = llvm.LLVMBuildUnreachable(l.builder);
            return;
        };
        switch (returned) {
            .ignore => {},
            .direct => |kind| try f.write(destination, .{ .scalar = .{ .value = result, .kind = kind } }),
            .pair => |pair| try f.storePair(
                destination.address,
                pair,
                .{ .value = llvm.LLVMBuildExtractValue(l.builder, result, 0, ""), .kind = pair.a },
                .{ .value = llvm.LLVMBuildExtractValue(l.builder, result, 1, ""), .kind = pair.b },
            ),
            .cast => |cast| f.fromCast(result, cast, destination),
            .indirect => if (result_memory.?.pointer != destination.address.pointer) {
                f.copyBytes(destination.address, result_memory.?, destination.layout.size);
            },
        }
        _ = llvm.LLVMBuildBr(l.builder, f.blocks[target.index()]);
    }

    /// Appends what a call passes for one argument, in the form its pass mode asks for.
    fn passArgument(
        f: *Function,
        args: *std.ArrayList(llvm.LLVMValueRef),
        arg: *const schema.ArgAbi,
        operand: *const schema.Operand,
    ) codegen.Error!void {
        const l = f.l;
        const layout = l.layoutOf(arg.layout);
        switch (try abi.classify(l, arg)) {
            .ignore => {},
            .direct => |kind| {
                const passed = try f.scalarOf(operand, null);
                if (!std.meta.eql(passed.kind.primitive, kind.primitive)) {
                    return l.malformed("a call passes a value of another kind than its ABI names", .{});
                }
                try args.append(l.arena, passed.value);
            },
            .pair => |pair| {
                const place = try f.inMemory(try f.read(operand), arg, layout.@"align");
                const a, const b = try f.loadPair(place.address, pair);
                try args.append(l.arena, a.value);
                try args.append(l.arena, b.value);
            },
            .cast => |cast| try args.append(l.arena, f.toCast(try f.inMemory(try f.read(operand), arg, layout.@"align"), cast)),
            .indirect => |indirect| {
                const required = @max(indirect.alignment, layout.@"align");
                const value = try f.read(operand);
                // The callee may change the memory it is given. A moved value is given up, so its own memory will
                // do; a copied one or a constant has to stay as it is, and gets a copy made for the call.
                const given_up = operand.* == .move and value == .memory and value.memory.address.alignment >= required;
                const place = if (given_up)
                    try f.inMemory(value, arg, required)
                else
                    try f.copied(value, arg, required);
                try args.append(l.arena, place.address.pointer);
            },
        }
    }

    /// A value where a pass mode needs it, in memory: where it already is, or in new memory if it is not in any.
    fn inMemory(f: *Function, value: Read, arg: *const schema.ArgAbi, alignment: u64) codegen.Error!Place {
        const l = f.l;
        switch (value) {
            .memory => |place| {
                if (place.layout.size != l.layoutOf(arg.layout).size) {
                    return l.malformed("a call passes a value of another size than its ABI names", .{});
                }
                return place;
            },
            .nothing, .scalar => return f.copied(value, arg, alignment),
        }
    }

    /// A value in memory made for it.
    fn copied(f: *Function, value: Read, arg: *const schema.ArgAbi, alignment: u64) codegen.Error!Place {
        const l = f.l;
        const layout = l.layoutOf(arg.layout);
        const place: Place = .{ .address = f.alloca(try types.memory(l, layout), alignment), .ty = arg.ty, .layout = layout };
        try f.write(place, value);
        return place;
    }

    /// The registers of a `cast` pass mode, filled with the bytes of a value.
    ///
    /// The value goes through memory of the registers' type: that type may be larger than the value, with padding
    /// the value does not have, or smaller, and reading it straight from the value's memory would read past its end.
    fn toCast(f: *Function, from: Place, cast: llvm.LLVMTypeRef) llvm.LLVMValueRef {
        const l = f.l;
        const scratch = f.alloca(cast, types.abiAlignment(l, cast));
        f.copyBytes(scratch, from.address, @min(from.layout.size, types.allocSize(l, cast)));
        const loaded = llvm.LLVMBuildLoad2(l.builder, cast, scratch.pointer, "");
        llvm.LLVMSetAlignment(loaded, @intCast(scratch.alignment));
        return loaded;
    }

    /// The other direction: the bytes of a value that arrived in the registers of a `cast` pass mode.
    fn fromCast(f: *Function, value: llvm.LLVMValueRef, cast: llvm.LLVMTypeRef, into: Place) void {
        const l = f.l;
        const scratch = f.alloca(cast, types.abiAlignment(l, cast));
        const stored = llvm.LLVMBuildStore(l.builder, value, scratch.pointer);
        llvm.LLVMSetAlignment(stored, @intCast(scratch.alignment));
        f.copyBytes(into.address, scratch, @min(into.layout.size, types.allocSize(l, cast)));
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

    /// An operand read, with the type it has.
    const Typed = struct {
        read: Read,
        /// Null for the answer to a runtime check, whose type nothing asks for.
        ty: ?schema.TypeId,
    };

    fn typed(f: *Function, operand: *const schema.Operand) codegen.Error!Typed {
        const l = f.l;
        switch (operand.*) {
            // A move leaves its source undefined, which asks nothing of the code that reads it.
            .copy, .move => |*source| {
                const place = try f.placeOf(source);
                return .{ .read = try f.readPlace(place), .ty = place.ty };
            },
            .constant => |*constant| {
                const memory = switch (constant.value) {
                    .zero_sized => return .{ .read = .nothing, .ty = constant.ty },
                    .memory => |*memory| memory,
                };
                const layout = try f.sized(constant.ty, "a constant");
                if (layout.size == 0) return .{ .read = .nothing, .ty = constant.ty };
                const value: Read = switch (layout.repr) {
                    .scalar => |repr| .{ .scalar = .{ .value = try consts.scalar(l, memory, repr.scalar), .kind = repr.scalar } },
                    else => .{ .memory = .{
                        .address = .{ .pointer = try consts.global(l, memory, layout), .alignment = layout.@"align" },
                        .ty = constant.ty,
                        .layout = layout,
                    } },
                };
                return .{ .read = value, .ty = constant.ty };
            },
            // rustc has already decided the check for this compilation.
            .runtime_checks => |checks| return .{
                .read = .{ .scalar = .{
                    .value = llvm.LLVMConstInt(llvm.LLVMInt1TypeInContext(l.context), @intFromBool(checks.value), 0),
                    .kind = types.boolean,
                } },
                .ty = null,
            },
        }
    }

    fn read(f: *Function, operand: *const schema.Operand) codegen.Error!Read {
        return (try f.typed(operand)).read;
    }

    /// The value of an operand that has to be a scalar, of one kind if `kind` names it.
    fn scalarOf(f: *Function, operand: *const schema.Operand, kind: ?std.meta.Tag(schema.Primitive)) codegen.Error!Value {
        return f.scalarIn(try f.read(operand), kind);
    }

    fn scalarIn(f: *Function, value: Read, kind: ?std.meta.Tag(schema.Primitive)) codegen.Error!Value {
        const scalar = switch (value) {
            .scalar => |scalar| scalar,
            .nothing => return f.l.malformed("a value without a size where a scalar belongs", .{}),
            .memory => return f.l.malformed("a value that is not a scalar where one belongs", .{}),
        };
        if (kind) |expected| if (scalar.kind.primitive != expected) {
            return f.l.malformed("a `{s}` where a `{s}` belongs", .{ @tagName(scalar.kind.primitive), @tagName(expected) });
        };
        return scalar;
    }

    /// What a pointer or a reference of this type points at.
    fn pointeeOf(f: *Function, pointer: ?schema.TypeId) codegen.Error!schema.TypeId {
        const l = f.l;
        const ty = l.typeOf(pointer orelse return l.malformed("the answer to a runtime check is used as a pointer", .{}));
        return switch (ty.kind) {
            .ref => |ref| ref.pointee,
            .raw_ptr => |raw| raw.pointee,
            else => l.unsupported("a dereference of `{s}`", .{ty.name}),
        };
    }

    fn placeOf(f: *Function, place: *const schema.Place) codegen.Error!Place {
        const l = f.l;
        var current = f.slots[place.local.index()];
        for (place.projection) |*element| current = switch (element.*) {
            .deref => pointee: {
                const target = try f.pointeeOf(current.ty);
                const layout = try f.sized(target, "a place");
                const pointer = try f.scalarIn(try f.readPlace(current), .pointer);
                break :pointee .{ .address = .{ .pointer = pointer.value, .alignment = layout.@"align" }, .ty = target, .layout = layout };
            },
            .field => |field| try f.fieldOf(current, field.index, field.ty),
            .index => |index| at: {
                const array = try f.arrayOf(current);
                const position = try f.scalarIn(try f.readPlace(f.slots[index.local.index()]), .int);
                // MIR asserts that the index is in bounds before it uses it.
                break :at elementAt(l, current, array, position.value);
            },
            .constant_index => |constant| at: {
                if (constant.from_end) return l.unsupported("an element counted from the end", .{});
                const array = try f.arrayOf(current);
                if (constant.offset >= array.count) return l.malformed("element {d} of an array of {d}", .{ constant.offset, array.count });
                break :at .{ .address = current.address.offset(l, constant.offset * array.stride), .ty = array.element, .layout = array.layout };
            },
            else => |*other| return l.unsupported("a place through `{s}`", .{@tagName(other.*)}),
        };
        return current;
    }

    /// The field of a struct, a tuple or a union.
    fn fieldOf(f: *Function, parent: Place, index: u32, ty: schema.TypeId) codegen.Error!Place {
        const l = f.l;
        const layout = try f.sized(ty, "a field");
        if (parent.layout.variants != .single) return l.unsupported("a field of a value that is not a struct, a tuple or a union", .{});
        const offset = switch (parent.layout.fields) {
            .arbitrary => |fields| if (index < fields.offsets.len) fields.offsets[index] else {
                return l.malformed("field {d} of a value with {d} fields", .{ index, fields.offsets.len });
            },
            // Every field of a union starts where the union does.
            .@"union" => |fields| if (index < fields.count) 0 else {
                return l.malformed("field {d} of a union with {d} fields", .{ index, fields.count });
            },
            else => |other| return l.unsupported("a field of a value laid out as `{s}`", .{@tagName(other)}),
        };
        if (offset > parent.layout.size or parent.layout.size - offset < layout.size) {
            return l.malformed("a field that does not fit into its value", .{});
        }
        return .{ .address = parent.address.offset(l, offset), .ty = ty, .layout = layout };
    }

    fn arrayOf(f: *Function, place: Place) codegen.Error!Array {
        const l = f.l;
        const ty = l.typeOf(place.ty);
        const element = switch (ty.kind) {
            .array => |array| array.elem,
            else => return l.unsupported("an element of `{s}`", .{ty.name}),
        };
        const shape = switch (place.layout.fields) {
            .array => |array| array,
            else => return l.malformed("`{s}` is not laid out as an array", .{ty.name}),
        };
        const layout = try f.sized(element, "an element");
        const fits = layout.size <= shape.stride and (shape.count == 0 or shape.stride <= place.layout.size / shape.count);
        if (!fits) return l.malformed("the elements of `{s}` do not fit into it", .{ty.name});
        return .{ .element = element, .layout = layout, .stride = shape.stride, .count = shape.count };
    }

    fn readPlace(f: *Function, place: Place) codegen.Error!Read {
        if (place.layout.size == 0) return .nothing;
        return switch (place.layout.repr) {
            .scalar => |repr| .{ .scalar = try f.loadScalar(place.address, repr.scalar) },
            else => .{ .memory = place },
        };
    }

    fn write(f: *Function, into: Place, value: Read) codegen.Error!void {
        const l = f.l;
        switch (value) {
            .nothing => if (into.layout.size != 0) {
                return l.malformed("a value without a size is assigned to a place that has one", .{});
            },
            .scalar => |scalar| switch (into.layout.repr) {
                .scalar => |repr| try f.storeScalar(scalar, into.address, repr.scalar),
                else => return l.malformed("a scalar is assigned to a place that holds none", .{}),
            },
            .memory => |from| {
                if (from.layout.size != into.layout.size) {
                    return l.malformed("a value of {d} bytes is assigned to a place of {d}", .{ from.layout.size, into.layout.size });
                }
                f.copyBytes(into.address, from.address, into.layout.size);
            },
        }
    }

    /// MIR never assigns a value to a place that overlaps it, which is what `memcpy` asks for.
    fn copyBytes(f: *Function, into: Address, from: Address, size: u64) void {
        const l = f.l;
        if (size == 0) return;
        _ = llvm.LLVMBuildMemCpy(
            l.builder,
            into.pointer,
            @intCast(into.alignment),
            from.pointer,
            @intCast(from.alignment),
            llvm.LLVMConstInt(types.pointerSized(l), size, 0),
        );
    }

    fn loadScalar(f: *Function, from: Address, kind: schema.Scalar) codegen.Error!Value {
        const l = f.l;
        const loaded = llvm.LLVMBuildLoad2(l.builder, try types.scalar(l, kind, .memory), from.pointer, "");
        llvm.LLVMSetAlignment(loaded, @intCast(from.alignment));
        return .{ .value = types.toImmediate(l, loaded, kind), .kind = kind };
    }

    /// Stores a scalar where one of the kind `kind` belongs.
    fn storeScalar(f: *Function, value: Value, into: Address, kind: schema.Scalar) codegen.Error!void {
        const l = f.l;
        // LLVM would not notice: with opaque pointers a store of any type through any pointer is valid IR.
        if (!std.meta.eql(value.kind.primitive, kind.primitive)) {
            return l.malformed("a value of one kind is assigned to a place of another", .{});
        }
        const stored = llvm.LLVMBuildStore(l.builder, types.toMemory(l, value.value, kind), into.pointer);
        llvm.LLVMSetAlignment(stored, @intCast(into.alignment));
    }

    fn loadPair(f: *Function, from: Address, pair: abi.Passed.Pair) codegen.Error![2]Value {
        return .{ try f.loadScalar(from, pair.a), try f.loadScalar(from.offset(f.l, pair.b_offset), pair.b) };
    }

    fn storePair(f: *Function, into: Address, pair: abi.Passed.Pair, a: Value, b: Value) codegen.Error!void {
        try f.storeScalar(a, into, pair.a);
        try f.storeScalar(b, into.offset(f.l, pair.b_offset), pair.b);
    }
};

/// The element of an array at an index known only when the program runs.
fn elementAt(l: *const Lowering, place: Place, array: Array, index: llvm.LLVMValueRef) Place {
    var indices = [_]llvm.LLVMValueRef{index};
    return .{
        .address = .{
            .pointer = llvm.LLVMBuildInBoundsGEP2(l.builder, types.bytes(l, array.stride), place.address.pointer, &indices, indices.len, ""),
            .alignment = if (array.stride == 0) place.address.alignment else @min(place.address.alignment, lowestBit(array.stride)),
        },
        .ty = array.element,
        .layout = array.layout,
    };
}
