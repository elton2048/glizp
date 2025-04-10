/// NOTE: Likely corrsponds to cmds.c and editfns.c in Emacs
/// The actual insert function involves much more steps including bytes
/// checking, properties inheritance, before/after hook etc.
/// The design will be much simpler and to be developed until it is
/// necessary to be compatiable further.
const std = @import("std");
const lisp = @import("types/lisp.zig");

const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunctionWithOpaque = lisp.LispFunctionWithOpaque;

const EVAL_TABLE = std.StaticStringMap(LispFunctionWithOpaque).initComptime(.{
    .{ "insert", &insert },
});

fn insert(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    const bytes = try params[0].as_string();
    const pos = try params[1].as_number();

    const pluginEnv: *PluginEditing = @ptrCast(@alignCast(env));

    for (bytes.items) |byte| {
        pluginEnv.insert(pos.value, byte) catch |err| switch (err) {
            else => return MalTypeError.Unhandled,
        };
    }

    // Corresponds to nil
    // TODO: See if extract this as a new type like Qnil.
    return MalType{ .boolean = false };
}

pub const PluginEditing = struct {
    _fnTable: std.StaticStringMap(LispFunctionWithOpaque),

    /// Using buffer as a whole for such feature in future, currently
    /// it is a single local one.
    buffer: std.ArrayList(u8),
    /// Denotes the cursor position corresponds to the buffer
    pos: usize,

    pub fn init(allocator: std.mem.Allocator) *PluginEditing {
        const self = allocator.create(PluginEditing) catch @panic("OOM");

        const buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        self.* = .{
            ._fnTable = EVAL_TABLE,
            .buffer = buffer,
            .pos = 0,
        };

        return self;
    }

    pub fn insert(self: *PluginEditing, pos: usize, byte: u8) !void {
        const result = try self.buffer.insert(pos, byte);

        return result;
    }

    pub fn reset(self: *PluginEditing) void {
        self.pos = 0;
    }

    pub fn moveBackward(self: *PluginEditing, steps: usize) void {
        self.pos -= steps;
    }

    pub fn moveForward(self: *PluginEditing, steps: usize) void {
        self.pos += steps;
    }

    pub fn clear(self: *PluginEditing) void {
        self.pos = 0;
        return self.buffer.clearRetainingCapacity();
    }

    pub fn orderedRemove(self: *PluginEditing, pos: usize) void {
        _ = self.buffer.orderedRemove(pos);
    }
};
