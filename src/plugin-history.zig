/// NOTE: The original history in Emacs stored elsewhere. (add-to-history)
/// function barely set an input with history command appended by various
/// conditions given.
const std = @import("std");
const lisp = @import("types/lisp.zig");

const ArrayList = std.ArrayListUnmanaged;
const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunctionWithOpaque = lisp.LispFunctionWithOpaque;

const EVAL_TABLE = std.StaticStringMap(LispFunctionWithOpaque).initComptime(.{
    .{ "get-history-len", &historyLen },
    // .{ "add-plugin-value", &add },
    // .{ "set-plugin-value", &set },
});

fn historyLen(params: []*MalType, env: *anyopaque) MalTypeError!*MalType {
    _ = params;

    const pluginEnv: *PluginHistory = @ptrCast(@alignCast(env));

    const value: lisp.NumberType = @floatFromInt(pluginEnv.history.items.len);
    // TODO: This shouldn't work as it should allocate the memory
    // properly.

    return MalType.new_number(pluginEnv.allocator, value);
}

pub const PluginHistory = struct {
    _fnTable: std.StaticStringMap(LispFunctionWithOpaque),

    allocator: std.mem.Allocator,
    history: ArrayList([]u8),
    history_curr: usize,

    pub fn init(allocator: std.mem.Allocator) *PluginHistory {
        const self = allocator.create(PluginHistory) catch @panic("OOM");

        const historyArrayList: ArrayList([]u8) = .empty;

        self.* = .{
            ._fnTable = EVAL_TABLE,
            .allocator = allocator,
            .history = historyArrayList,
            .history_curr = 0,
        };

        return self;
    }

    pub fn getHistoryItem(self: *PluginHistory, index: usize) []const u8 {
        return self.history.items[index];
    }
};
