const std = @import("std");
const lisp = @import("types/lisp.zig");

const LispEnv = @import("env.zig").LispEnv;
const Plugin = @import("types/plugin.zig");
const Message = @import("types/plugin.zig").Message;

const MalType = lisp.MalType;
const LispFunctionWithEnv = lisp.LispFunctionWithEnv;

const MessageQueue = @import("message_queue.zig").MessageQueue;

const utils = @import("utils.zig");

pub const PluginExample = struct {
    /// Corresponding vtable for interface functions
    pub const vtable = &Plugin.VTable{
        .subscribe = _init,
        .subscribeEvent = subscribeEvent,
    };

    // The subscribe method for plugin
    pub fn _init(context: *const anyopaque, env: *std.StringHashMap(MalType)) !void {
        _ = context;
        // const self: *const PluginExample = @ptrCast(@alignCast(context));
        if (env.*.get("a")) |a| {
            utils.log("TEST", a);
        }

        if (env.*.get("after")) |a| {
            utils.log("TEST_2", a);
        }
    }

    // pub fn sub(self: *PluginExample) !void {
    //     _ = self;
    //     utils.log("EX", "sub");
    // }

    pub fn subscribeEvent(self: *PluginExample, messages: *MessageQueue) !void {
        _ = self;
        // TODO: The subscription shall filter out correct message.
        if (messages.getLastOrNull()) |item| {
            utils.log("TEST", item);
        }
    }

    pub fn init(allocator: std.mem.Allocator) *PluginExample {
        const self = allocator.create(PluginExample) catch @panic("OOM");

        return self;
    }

    pub fn plugin(self: *PluginExample, env: *std.StringHashMap(MalType), messages: *std.SinglyLinkedList(*Message)) Plugin {
        return .{
            .context = self,
            .vtable = vtable,
            .env = env,
            .messages = messages,
        };
    }
};
