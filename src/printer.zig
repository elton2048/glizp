const std = @import("std");

const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const debug = std.debug;
const mem = std.mem;

const MalType = @import("reader.zig").MalType;

const semantic = @import("semantic.zig");

const BOOLEAN_TRUE = semantic.BOOLEAN_TRUE;
const BOOLEAN_FALSE = semantic.BOOLEAN_FALSE;

pub fn pr_str(mal: MalType) []u8 {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa_allocator.allocator();

    var string = ArrayList(u8).init(allocator);
    defer string.deinit();

    switch (mal) {
        .boolean => |boolean| {
            if (boolean) {
                string.appendSlice(BOOLEAN_TRUE) catch @panic("allocator error");
            } else {
                string.appendSlice(BOOLEAN_FALSE) catch @panic("allocator error");
            }
        },
        .number => |value| {
            const result = std.fmt.allocPrint(allocator, "{d}", .{value.value}) catch @panic("allocator error");
            string.appendSlice(result) catch @panic("allocator error");
        },
        .string => |str| {
            string.appendSlice(str) catch @panic("allocator error");
        },
        .list => |list| {
            string.appendSlice("(") catch @panic("allocator error");
            for (list.items) |item| {
                const result = pr_str(item);
                string.appendSlice(result) catch @panic("allocator error");
                string.appendSlice(" ") catch @panic("allocator error");
            }
            // Remove the last space
            _ = string.pop();
            string.appendSlice(")") catch @panic("allocator error");
        },
        else => {},
    }

    return string.toOwnedSlice() catch unreachable;
}

test "printer" {
    const allocator = std.testing.allocator;

    // Test for boolean case
    {
        const bool_true = MalType{ .boolean = true };

        const bool_true_result = pr_str(bool_true);
        debug.assert(mem.eql(u8, bool_true_result, "t"));

        const bool_false = MalType{ .boolean = false };

        const bool_false_result = pr_str(bool_false);
        debug.assert(mem.eql(u8, bool_false_result, "nil"));
    }

    // Test for string case
    {
        const mal1 = MalType{ .string = "test" };

        const mal1_result = pr_str(mal1);
        debug.assert(mem.eql(u8, mal1_result, "test"));
    }

    // Test for list case
    {
        var list1 = ArrayList(MalType).init(allocator);
        defer list1.deinit();

        list1.append(MalType{ .string = "1" }) catch unreachable;
        list1.append(MalType{ .string = "2" }) catch unreachable;

        const mal2 = MalType{ .list = list1 };
        const mal2_result = pr_str(mal2);

        debug.assert(mem.eql(u8, mal2_result, "(1 2)"));
    }
}
