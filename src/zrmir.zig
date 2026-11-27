//! ZRMIR, the format `zrust_shim` hands a codegen unit over in. `docs/ZRMIR.md` is the specification.

const std = @import("std");

pub const Diagnostic = @import("zrmir/Diagnostic.zig");
pub const codec = @import("zrmir/codec.zig");
pub const schema = @import("zrmir/schema.zig");
pub const validate = @import("zrmir/validate.zig").validate;

/// Everything `zrust-codegen --check` promises about a file: it decodes strictly, its references hold, and it is in
/// canonical form. `input` must outlive the module.
pub fn check(arena: std.mem.Allocator, input: []const u8, diagnostic: *Diagnostic) Diagnostic.Error!schema.Module {
    const module = try codec.decode(arena, input, diagnostic);
    try validate(arena, &module, diagnostic);
    try codec.checkCanonical(arena, &module, input, diagnostic);
    return module;
}

test {
    _ = @import("zrmir/tests.zig");
}
