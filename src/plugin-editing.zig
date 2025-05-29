/// NOTE: Likely corrsponds to cmds.c and editfns.c in Emacs
/// The actual insert function involves much more steps including bytes
/// checking, properties inheritance, before/after hook etc.
/// The design will be much simpler and to be developed until it is
/// necessary to be compatiable further.
const std = @import("std");
const lisp = @import("types/lisp.zig");

const Frontend = @import("Frontend.zig");

const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunctionWithOpaque = lisp.LispFunctionWithOpaque;

const EVAL_TABLE = std.StaticStringMap(LispFunctionWithOpaque).initComptime(.{
    // Likely to be in original.
    .{ "forward-char", forwardChar },
    .{ "backward-char", backwardChar },

    .{ "insert", &insert },
    .{ "delete-char", &deleteChar },
    // Shortcut now. The original implementation are in elisp.
    .{ "delete-backward-char", &deleteBackwardChar },
});

fn forwardChar(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    var steps: lisp.Number = undefined;

    if (params.len > 0) {
        steps = params[0].as_number() catch |err| switch (err) {
            else => .{ .value = 1 },
        };
    } else {
        steps = .{ .value = 1 };
    }

    const self: *PluginEditing = @ptrCast(@alignCast(env));

    if (self.buffer.items.len > self.pos) {
        const prevCursor = self.frontend.readCursorPos() catch |err| switch (err) {
            else => return MalTypeError.Unhandled,
        };
        if (prevCursor.x == self.frontend.frame_size.x) {
            self.frontend.move(prevCursor.x - 1, .Left) catch |err| switch (err) {
                else => return MalTypeError.Unhandled,
            };
            self.frontend.move(1, .Down) catch |err| switch (err) {
                else => return MalTypeError.Unhandled,
            };
        } else {
            self.frontend.move(1, .Right) catch |err| switch (err) {
                else => return MalTypeError.Unhandled,
            };
        }
    }

    const steps_value = try steps.to_usize();
    self.movePoint(steps_value, true);

    return .{ .boolean = false };
}

fn backwardChar(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    var steps: lisp.Number = undefined;

    if (params.len > 0) {
        steps = params[0].as_number() catch |err| switch (err) {
            else => .{ .value = 1 },
        };
    } else {
        steps = .{ .value = 1 };
    }

    const self: *PluginEditing = @ptrCast(@alignCast(env));

    if (self.pos > 0) {
        self.frontend.move(1, .Left) catch |err| switch (err) {
            else => return MalTypeError.Unhandled,
        };
    }

    const steps_value = try steps.to_usize();
    self.movePoint(steps_value, false);

    return .{ .boolean = false };
}

fn insert(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    const bytes = try params[0].as_string();

    const pluginEnv: *PluginEditing = @ptrCast(@alignCast(env));

    for (bytes.items) |byte| {
        pluginEnv.insert(pluginEnv.pos, byte) catch |err| switch (err) {
            else => return MalTypeError.Unhandled,
        };
    }

    pluginEnv.movePoint(1, true);

    pluginEnv.frontend.refresh(pluginEnv.pos - 1, 0, bytes.items) catch |err| switch (err) {
        else => return MalTypeError.Unhandled,
    };

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

        const len_value = try len.to_usize();
        pluginEnv.replace(pluginEnv.pos, len_value, &.{});

        pluginEnv.frontend.refresh(pluginEnv.pos, 1, "") catch |err| switch (err) {
            else => return MalTypeError.Unhandled,
        };
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

        const len_value = try len.to_usize();
        pluginEnv.replace(pluginEnv.pos - 1, len_value, &.{});
        pluginEnv.movePoint(1, false);

        pluginEnv.frontend.move(1, .Left) catch |err| switch (err) {
            else => return MalTypeError.Unhandled,
        };
        pluginEnv.frontend.refresh(pluginEnv.pos, 1, "") catch |err| switch (err) {
            else => return MalTypeError.Unhandled,
        };
    }

    return MalType{ .boolean = false };
}

pub const PluginEditing = struct {
    _fnTable: std.StaticStringMap(LispFunctionWithOpaque),
    /// Frontend interface
    frontend: Frontend,

    /// Using buffer as a whole for such feature in future, currently
    /// it is a single local one.
    buffer: std.ArrayList(u8),
    /// Denotes the cursor position corresponds to the buffer
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, frontend: Frontend) *PluginEditing {
        const self = allocator.create(PluginEditing) catch @panic("OOM");

        const buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        self.* = .{
            ._fnTable = EVAL_TABLE,
            .frontend = frontend,
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

    pub fn movePoint(self: *PluginEditing, steps: usize, forward: bool) void {
        // NOTE: As @intCast is used, very big number is lost now.
        const signed_steps: i64 = @intCast(steps);
        const signed_pos: i64 = @intCast(self.pos);

        var newPos = if (forward) signed_pos + signed_steps else signed_pos - signed_steps;

        if (self.buffer.items.len < newPos) {
            newPos = @intCast(self.buffer.items.len);
        }
        if (newPos < 0) {
            newPos = 0;
        }

        self.pos = @intCast(newPos);
    }
};
