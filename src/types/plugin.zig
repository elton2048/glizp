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
/// Name of the plugin
name: []const u8,

env: *std.StringHashMap(MalType),
queue: *MessageQueue,

/// Function table key by string.
fnTable: ?std.StaticStringMap(LispFunctionWithOpaque),

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

    var name: []const u8 = "";
    var it = std.mem.splitScalar(u8, @typeName(Ptr), '.');
    while (it.next()) |str| {
        name = str;
    }

    const impl = struct {
        fn subscribe(context: *const anyopaque, inner_env: *std.StringHashMap(MalType)) !void {
            // _ = inner_env;
            // _ = context;
            const self: Ptr = @constCast(@ptrCast(@alignCast(context)));

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
            const self: Ptr = @constCast(@ptrCast(@alignCast(context)));

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
        .fnTable = obj.fnTable,
        .context = obj,
        .name = name,
        .vtable = &.{
            .subscribe = impl.subscribe,
            .subscribeEvent = impl.subscribeEvent,
        },
        .env = env,
        .queue = messages,
    };
}
