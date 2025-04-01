const std = @import("std");

const Plugin = @import("types/plugin.zig");
const MalType = @import("types/lisp.zig").MalType;

const MessageQueue = @import("message_queue.zig").MessageQueue;

const utils = @import("utils.zig");

pub const PluginExampleEmbedVtab = struct {
    // plugin_instance: Plugin,

    // pub fn init() *PluginExampleEmbedVtab {
    //     return .{
    //         .plugin_instance = .{},
    //     };
    // }

    pub fn init(allocator: std.mem.Allocator) *PluginExampleEmbedVtab {
        const self = allocator.create(PluginExampleEmbedVtab) catch @panic("OOM");

        return self;
    }

    pub fn plugin(self: *PluginExampleEmbedVtab, env: *std.StringHashMap(MalType), messages: *std.SinglyLinkedList(*Plugin.Message)) Plugin {
        const impl = struct {
            fn subscribe(context: *const anyopaque, inner_env: *std.StringHashMap(MalType)) !void {
                const inner_self: *PluginExampleEmbedVtab = @constCast(@ptrCast(context));
                try inner_self.subscribe(inner_env);
            }

            fn subscribeEvent(context: *const anyopaque, inner_env: *std.SinglyLinkedList(*Plugin.Message)) anyerror!void {
                _ = context;
                _ = inner_env;
            }
        };

        return .{
            .context = self,
            .vtable = &.{
                .subscribe = &impl.subscribe,
                .subscribeEvent = &impl.subscribeEvent,
            },
            .env = env,
            .messages = messages,
        };
    }

    pub fn sub(self: *PluginExampleEmbedVtab, env: *std.StringHashMap(MalType)) !void {
        _ = self;

        var iterator = env.iterator();
        while (iterator.next()) |iter| {
            utils.log("PEEV", iter.key_ptr.*);
        }

        // utils.log("PEEV", "sub");
    }

    pub fn subscribe(self: *PluginExampleEmbedVtab, env: *std.StringHashMap(MalType)) !void {
        _ = self;
        _ = env;

        utils.log("PEEV", "test");
    }

    pub fn subscribeEvent(self: *PluginExampleEmbedVtab, messageQueue: *MessageQueue) !void {
        _ = self;
        _ = messageQueue;
    }
};
