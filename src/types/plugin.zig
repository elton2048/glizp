const std = @import("std");
const MalType = @import("lisp.zig").MalType;

const LispEnv = @import("../env.zig").LispEnv;
const MessageQueue = @import("../message_queue.zig").MessageQueue;

const utils = @import("../utils.zig");

pub const Message = struct {
    name: u8,
};

/// Pointer to the actual instance.
context: *const anyopaque,
/// Virtual table to store the function pointers on actual implementations.
vtable: *const VTable,

env: *std.StringHashMap(MalType),
// messages: *std.SinglyLinkedList(*Message),
queue: *MessageQueue,

pub const VTable = struct {
    subscribe: *const fn (context: *const anyopaque, *std.StringHashMap(MalType)) anyerror!void,
    subscribeEvent: *const fn (context: *const anyopaque, *MessageQueue) anyerror!void,
};

pub fn subscribe(self: Self) !void {
    try self.vtable.subscribe(self.context, self.env);
}

pub fn subscribeEvent(self: Self) !void {
    try self.vtable.subscribeEvent(self.context, self.queue);
}

const Self = @This();

pub fn init(obj: anytype, env: *std.StringHashMap(MalType), messages: *MessageQueue) Self {
    const Ptr = @TypeOf(obj);
    // const alignment = @typeInfo(Ptr).Pointer.alignment;

    const impl = struct {
        fn subscribe(context: *const anyopaque, inner_env: *std.StringHashMap(MalType)) !void {
            // _ = inner_env;
            // _ = context;
            const self: Ptr = @constCast(@ptrCast(context));

            // self.vtable.subscribe(env) catch @panic("PLUGIn");
            const method_name = "sub";
            if (@hasDecl(@TypeOf(self.*), method_name)) {
                // const ptr: *const fn () void = @fieldParentPtr(method_name, self);
                // const method = @field(self, method_name);
                // @call(.auto, ptr, .{inner_env});
                self.sub(inner_env) catch @panic("PLUGIn");
            } else {
                utils.log("PLUGIN", std.fmt.comptimePrint("method \"{s}\" not implemented yet", .{method_name}));
            }
        }

        fn subscribeEvent(context: *const anyopaque, messageQueue: *MessageQueue) anyerror!void {
            // _ = context;
            // _ = inner_env;

            const self: Ptr = @constCast(@ptrCast(context));

            const method_name = "subscribeEvent";
            if (@hasDecl(@TypeOf(self.*), method_name)) {
                // const ptr: *const fn () void = @fieldParentPtr(method_name, self);
                // const method = @field(self, method_name);
                // @call(.auto, ptr, .{inner_env});
                self.subscribeEvent(messageQueue) catch @panic("PLUGIn");
            } else {
                utils.log("PLUGIN", std.fmt.comptimePrint("method \"{s}\" not implemented yet", .{method_name}));
            }
        }
    };

    return .{
        .context = obj,
        .vtable = &.{
            .subscribe = impl.subscribe,
            .subscribeEvent = impl.subscribeEvent,
        },
        .env = env,
        // .messages = messages,
        .queue = messages,
    };
}
