const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;

pub fn PrefixStringHashMap(comptime T: type) type {
    return struct {
        allocator: Allocator,
        map: std.StringHashMap(T),
        prefix: []const u8,

        // Shortcut for type
        const K = []const u8;
        const Self = @This();

        // Key count respect to the prefix
        var keyCount: usize = 0;

        pub fn init(allocator: Allocator, prefix: []const u8) Self {
            const map = std.StringHashMap(T).init(allocator);

            return .{
                .allocator = allocator,
                .map = map,
                .prefix = prefix,
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        pub fn put(self: *Self, value: T) Allocator.Error!void {
            const key = try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{
                self.prefix,
                keyCount,
            });
            const result = self.map.put(key, value);
            keyCount += 1;

            return result;
        }

        /// Manual method to put into the map, reference usage only.
        pub fn putManual(self: *Self, key: K, value: T) Allocator.Error!void {
            return self.map.put(key, value);
        }

        pub fn iterator(self: *Self) std.StringHashMap(T).Iterator {
            return self.map.iterator();
        }
    };
}
