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

const iterator = @import("iterator.zig");

const StringIterator = iterator.StringIterator;

pub fn pr_str(mal: MalType, print_readably: bool) []u8 {
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
            defer allocator.free(result);
            string.appendSlice(result) catch @panic("allocator error");
        },
        .string => |str| {
            var iter = StringIterator.init(str.items);

            string.appendSlice("\"") catch @panic("allocator error");
            while (iter.next()) |char| {
                // Handle escape character
                if (print_readably) {
                    if (char == '"' or char == '\\') {
                        string.append('\\') catch @panic("allocator error");
                    }
                }
                string.append(char) catch @panic("allocator error");
            }
            string.appendSlice("\"") catch @panic("allocator error");
        },
        .list => |list| {
            string.appendSlice("(") catch @panic("allocator error");
            for (list.items) |item| {
                const result = pr_str(item, print_readably);
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

fn initStringArrayList(allocator: mem.Allocator, str: []const u8) ArrayList(u8) {
    var al = ArrayList(u8).init(allocator);
    al.appendSlice(str) catch unreachable;

    return al;
}

const testing = std.testing;

test "printer" {
    const allocator = std.testing.allocator;

    // Test for boolean case
    {
        const bool_true = MalType{ .boolean = true };

        const bool_true_result = pr_str(bool_true, true);
        try testing.expectEqualStrings("t", bool_true_result);

        const bool_false = MalType{ .boolean = false };

        const bool_false_result = pr_str(bool_false, true);
        try testing.expectEqualStrings("nil", bool_false_result);
    }

    // Test for string case
    {
        const str1_al = initStringArrayList(allocator, "test");
        defer str1_al.deinit();

        const str1 = MalType{ .string = str1_al };

        const str1_readably_result = pr_str(str1, true);
        try testing.expectEqualStrings("\"test\"", str1_readably_result);
        const str1_non_readably_result = pr_str(str1, false);
        try testing.expectEqualStrings("\"test\"", str1_non_readably_result);

        const str2_al = initStringArrayList(allocator, "te\"st");
        defer str2_al.deinit();

        const str2 = MalType{ .string = str2_al };

        // stored value: "te"st"
        // readably result: "te\"st" (escaped doublequote inside)
        const str2_readably_result = pr_str(str2, true);
        try testing.expectEqualStrings("\"te\\\"st\"", str2_readably_result);
        const str2_non_readably_result = pr_str(str2, false);
        try testing.expectEqualStrings("\"te\"st\"", str2_non_readably_result);

        const str3_al = initStringArrayList(allocator, "\\");
        defer str3_al.deinit();

        const str3 = MalType{ .string = str3_al };

        // stored value: "\"
        // readably result: "\\" (escaped backslash inside)
        const str3_readably_result = pr_str(str3, true);
        try testing.expectEqualStrings("\"\\\\\"", str3_readably_result);
        const str3_non_readably_result = pr_str(str3, false);
        try testing.expectEqualStrings("\"\\\"", str3_non_readably_result);

        const str4_al = initStringArrayList(allocator, "te\\\"st");
        defer str4_al.deinit();

        const str4 = MalType{ .string = str4_al };

        // stored value: "te\"st"
        // readably result: "te\\\"st" (escaped backslash and doublequote inside)
        const str4_readably_result = pr_str(str4, true);
        try testing.expectEqualStrings("\"te\\\\\\\"st\"", str4_readably_result);
        const str4_non_readably_result = pr_str(str4, false);
        try testing.expectEqualStrings("\"te\\\"st\"", str4_non_readably_result);
    }

    // Test for list case
    {
        const str1_al = initStringArrayList(allocator, "1");
        defer str1_al.deinit();

        const str2_al = initStringArrayList(allocator, "2");
        defer str2_al.deinit();

        var list1_al = ArrayList(MalType).init(allocator);
        defer list1_al.deinit();

        list1_al.append(MalType{ .string = str1_al }) catch unreachable;
        list1_al.append(MalType{ .string = str2_al }) catch unreachable;

        const list1 = MalType{ .list = list1_al };
        const list1_result = pr_str(list1, true);

        try testing.expectEqualStrings("(\"1\" \"2\")", list1_result);
    }
}
