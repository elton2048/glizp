/// NOTE: The original history in Emacs stored elsewhere. (add-to-history)
/// function barely set an input with history command appended by various
/// conditions given.
const std = @import("std");
const lisp = @import("types/lisp.zig");

const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunctionWithOpaque = lisp.LispFunctionWithOpaque;

const EVAL_TABLE = std.StaticStringMap(LispFunctionWithOpaque).initComptime(.{
    .{ "get-history-len", &historyLen },
    // .{ "add-plugin-value", &add },
    // .{ "set-plugin-value", &set },
});

fn historyLen(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    _ = params;

    const pluginEnv: *PluginHistory = @ptrCast(@alignCast(env));

    return MalType{ .number = .{ .value = pluginEnv.history.items.len } };
}

pub const PluginHistory = struct {
    _fnTable: std.StaticStringMap(LispFunctionWithOpaque),

    history: std.ArrayList([]u8),
    history_curr: usize,

    pub fn init(allocator: std.mem.Allocator) *PluginHistory {
        const self = allocator.create(PluginHistory) catch @panic("OOM");

        const historyArrayList = std.ArrayList([]u8).init(allocator);

        self.* = .{
            ._fnTable = EVAL_TABLE,
            .history = historyArrayList,
            .history_curr = 0,
        };

        return self;
    }

    pub fn getHistoryItem(self: *PluginHistory, index: usize) []const u8 {
        return self.history.items[index];
    }
};
