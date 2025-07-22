//! Plugin abstractation. This supports having additional functionality
//! in the lisp environment, which separates the core function of an
//! interpreter and different functions to work as a shell or editor
//! like Terminal and Emacs.
//!
//! The plugin holds the fields separately, and by setting the function
//! on "fnTable", it allows to use lisp-way to access such fields within
//! the lisp environment.
//! Check plugin-example.zig on how Plugin is created.
//!
//! TODO: Naming convention for the function; What if duplicate name occurs
const std = @import("std");
const MalType = @import("lisp.zig").MalType;
const LispFunctionWithOpaque = @import("lisp.zig").LispFunctionWithOpaque;

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
/// Name of the plugin.
name: []const u8,
/// Corresponding environment data.
envData: *std.StringHashMap(*MalType),
/// Corresponding queue data. Used for event subscription from async handler.
queue: *MessageQueue,

/// Function table key by string.
fnTable: ?std.StaticStringMap(LispFunctionWithOpaque),

pub const VTable = struct {
    subscribe: *const fn (context: *const anyopaque, *std.StringHashMap(MalType)) anyerror!void,
    subscribeEvent: *const fn (context: *const anyopaque, *MessageQueue) anyerror!void,
};

pub fn subscribe(self: Self) !void {
    try self.vtable.subscribe(self.context, self.envData);
}

pub fn subscribeEvent(self: Self) !void {
    try self.vtable.subscribeEvent(self.context, self.queue);
}

const Self = @This();

pub fn init(obj: anytype, envData: *std.StringHashMap(*MalType), messages: *MessageQueue) Self {
    const TypePtr = @TypeOf(obj);
    const Type = @TypeOf(obj.*);

    var name: []const u8 = "";
    if (@hasField(Type, "name")) {
        name = obj.name;
    } else {
        var it = std.mem.splitScalar(u8, @typeName(TypePtr), '.');
        while (it.next()) |str| {
            name = str;
        }
    }

    const impl = struct {
        // TODO: Consider generalize these functions.
        fn subscribe(context: *const anyopaque, inner_env: *std.StringHashMap(MalType)) !void {
            const self: TypePtr = @constCast(@ptrCast(@alignCast(context)));

            const method_name = "subscribe";
            if (@hasDecl(@TypeOf(self.*), method_name)) {
                self.subscribe(inner_env) catch @panic("PLUGIn");
            } else {
                utils.log("PLUGIN", "method \"{s}\" not implemented yet ", .{method_name}, .{});
            }
        }

        fn subscribeEvent(context: *const anyopaque, messageQueue: *MessageQueue) anyerror!void {
            const self: TypePtr = @constCast(@ptrCast(@alignCast(context)));

            const method_name = "subscribeEvent";
            if (@hasDecl(@TypeOf(self.*), method_name)) {
                self.subscribeEvent(messageQueue) catch @panic("PLUGIn");
            } else {
                utils.log("PLUGIN", "method \"{s}\" not implemented yet ", .{method_name}, .{});
            }
        }
    };

    return .{
        .fnTable = obj._fnTable,
        .context = obj,
        .name = name,
        .vtable = &.{
            .subscribe = impl.subscribe,
            .subscribeEvent = impl.subscribeEvent,
        },
        .envData = envData,
        .queue = messages,
    };
}
