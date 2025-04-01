const std = @import("std");

const xev = @import("xev");

const utils = @import("utils.zig");

pub const MessageQueue = struct {
    spsc: struct {
        // TODO: Decide the type later
        queue: std.ArrayList([]const u8),
        // queue: std.SinglyLinkedList([]const u8),
        wakeup: xev.Async align(64),
    },

    pub fn initSPSC(allocator: std.mem.Allocator) *MessageQueue {
        // _ = allocator;
        var queue = std.ArrayList([]const u8).init(allocator);
        errdefer queue.deinit();

        // const queue = std.SinglyLinkedList([]const u8){};

        var wakeup = xev.Async.init() catch @panic("Unexpected error");
        errdefer wakeup.deinit();

        // utils.log_pointer(&wakeup);

        const msgQueue = allocator.create(MessageQueue) catch @panic("OOM");

        msgQueue.* = .{
            .spsc = .{
                .wakeup = wakeup,
                .queue = queue,
            },
        };

        return msgQueue;
    }

    pub fn deinit(self: MessageQueue) void {
        self.spsc.wakeup.deinit();
    }

    pub fn append(self: *MessageQueue, item: []const u8) !void {
        try self.spsc.queue.append(item);
    }

    pub fn popOrNull(self: *MessageQueue) ?[]const u8 {
        return self.spsc.queue.pop();
    }

    pub fn getLastOrNull(self: *MessageQueue) ?[]const u8 {
        return self.spsc.queue.getLastOrNull();
    }

    pub fn wait(
        self: MessageQueue,
        loop: *xev.Loop,
        c: *xev.Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction,
    ) void {
        self.spsc.wakeup.wait(loop, c, Userdata, userdata, cb);
    }

    pub fn notify(self: *MessageQueue) !void {
        var spsc = self.spsc;
        try spsc.wakeup.notify();
        // catch |err| {
        //     utils.log("ERR", err);
        // };
    }
};
