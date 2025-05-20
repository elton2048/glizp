const std = @import("std");
const lisp = @import("types/lisp.zig");

const LispEnv = @import("env.zig").LispEnv;
const Plugin = @import("types/plugin.zig");
const Message = @import("types/plugin.zig").Message;

const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunction = lisp.LispFunction;
const LispFunctionWithOpaque = lisp.LispFunctionWithOpaque;
const NumberType = lisp.NumberType;

const MessageQueue = @import("message_queue.zig").MessageQueue;

const utils = @import("utils.zig");

const EVAL_TABLE = std.StaticStringMap(LispFunctionWithOpaque).initComptime(.{
    .{ "get-plugin-value", &get },
    .{ "add-plugin-value", &add },
    .{ "set-plugin-value", &set },
});

fn get(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    _ = params;

    const pluginEnv: *PluginExample = @ptrCast(@alignCast(env));

    const value: NumberType = @floatFromInt(pluginEnv.num);
    const result = MalType{ .number = .{ .value = value } };

    utils.log("get-plugin-value", pluginEnv.num);

    return result;
}

fn add(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    _ = params;

    const pluginEnv: *PluginExample = @ptrCast(@alignCast(env));

    pluginEnv.num += 1;

    const value: NumberType = @floatFromInt(pluginEnv.num);
    const result = MalType{ .number = .{ .value = value } };

    utils.log("set-plugin-value", pluginEnv.num);

    return result;
}

fn set(params: []MalType, env: *anyopaque) MalTypeError!MalType {
    const pluginEnv: *PluginExample = @ptrCast(@alignCast(env));

    const value = try params[0].as_number();

    pluginEnv.num = try value.integer();

    return params[0];
}

pub const PluginExample = struct {
    _fnTable: std.StaticStringMap(LispFunctionWithOpaque),

    num: i64,

    pub fn init(allocator: std.mem.Allocator) *PluginExample {
        const self = allocator.create(PluginExample) catch @panic("OOM");

        self.* = .{
            .num = 1,
            ._fnTable = EVAL_TABLE,
        };

        return self;
    }

    /// Common method for all plugin instance. Work as a hook.
    /// This is not useful for this plugin, only serves as example.
    pub fn subscribeEvent(self: *PluginExample, messages: *MessageQueue) !void {
        // TODO: The subscription shall filter out correct message.
        if (messages.getLastOrNull()) |item| {
            utils.log("TEST", item);

            utils.log("TEST", self.num);
        }
    }
};
