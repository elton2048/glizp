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
    .{ "delete-char", &deleteChar },
    // Shortcut now. The original implementation are in elisp.
    .{ "delete-backward-char", &deleteBackwardChar },
});

fn insert(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    const bytes = try params[0].as_string();

    const pluginEnv: *PluginEditing = @ptrCast(@alignCast(env));

    for (bytes.items) |byte| {
        pluginEnv.insert(pluginEnv.pos, byte) catch |err| switch (err) {
            else => return MalTypeError.Unhandled,
        };
    }

    pluginEnv.moveForward(1);

    // Corresponds to nil
    // TODO: See if extract this as a new type like Qnil.
    return MalType{ .boolean = false };
}

fn deleteChar(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    const pluginEnv: *PluginEditing = @ptrCast(@alignCast(env));

    if (pluginEnv.buffer.items.len > 0 and
        pluginEnv.pos < pluginEnv.buffer.items.len)
    {
        var len: lisp.Number = undefined;

        if (params.len > 0) {
            len = params[0].as_number() catch |err| switch (err) {
                else => .{ .value = 1 },
            };
        } else {
            len = .{ .value = 1 };
        }

        pluginEnv.replace(pluginEnv.pos, len.value, &.{});
        // pluginEnv.moveBackward(1);
    }

    return MalType{ .boolean = false };
}

fn deleteBackwardChar(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    const pluginEnv: *PluginEditing = @ptrCast(@alignCast(env));

    if (pluginEnv.buffer.items.len > 0 and pluginEnv.pos > 0) {
        var len: lisp.Number = undefined;

        if (params.len > 0) {
            len = params[0].as_number() catch |err| switch (err) {
                else => .{ .value = 1 },
            };
        } else {
            len = .{ .value = 1 };
        }

        pluginEnv.replace(pluginEnv.pos - 1, len.value, &.{});
        pluginEnv.moveBackward(1);
    }

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

    pub fn append(self: *PluginEditing, byte: u8) !void {
        return try self.buffer.append(byte);
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

    pub fn replace(self: *PluginEditing, start: usize, len: usize, new_items: []const u8) void {
        self.buffer.replaceRangeAssumeCapacity(start, len, new_items);
    }

    pub fn orderedRemove(self: *PluginEditing, pos: usize) void {
        _ = self.buffer.orderedRemove(pos);
    }
};
