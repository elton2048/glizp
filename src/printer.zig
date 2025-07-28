const std = @import("std");

const logz = @import("logz");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const debug = std.debug;
const mem = std.mem;

const lisp = @import("types/lisp.zig");
const MalType = lisp.MalType;
const List = lisp.List;

const semantic = @import("semantic.zig");

const BOOLEAN_TRUE = semantic.BOOLEAN_TRUE;
const BOOLEAN_FALSE = semantic.BOOLEAN_FALSE;

const iterator = @import("iterator.zig");

const StringIterator = iterator.StringIterator;

/// print_readably: For the false case, show the actual character, e.g. show newline for \n
pub fn pr_str(mal: *MalType, print_readably: bool) []u8 {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa_allocator.allocator();

    var string: ArrayList(u8) = .empty;
    defer string.deinit(allocator);

    switch (mal.*) {
        .boolean => |boolean| {
            if (boolean) {
                string.appendSlice(allocator, BOOLEAN_TRUE) catch @panic("allocator error");
            } else {
                string.appendSlice(allocator, BOOLEAN_FALSE) catch @panic("allocator error");
            }
        },
        .number => |value| {
            const result = std.fmt.allocPrint(allocator, "{d}", .{value.value}) catch @panic("allocator error");
            defer allocator.free(result);
            string.appendSlice(allocator, result) catch @panic("allocator error");
        },
        .string => |str| {
            var iter = StringIterator.init(str.data.items);

            if (print_readably) {
                string.appendSlice(allocator, "\"") catch @panic("allocator error");
            }
            while (iter.next()) |char| {
                if (char == 10) {
                    if (print_readably) {
                        string.appendSlice(allocator, "\\n") catch @panic("allocator error");
                        continue;
                    }
                }

                // Handle escape character
                if (char == '"') {
                    if (print_readably) {
                        // Append backslash to escape double quote
                        string.appendSlice(allocator, "\\\"") catch @panic("allocator error");
                        continue;
                    }
                }

                if (char == '\\') {
                    if (iter.peek()) |_| {
                        if (print_readably) {
                            string.append(allocator, '\\') catch @panic("allocator error");
                        } else {
                            // TODO: Handle non print_readably case
                        }
                    } else {
                        // NOTE: For single "\" case in data
                        // For multiple backslash case, there could be
                        // more data in iterator.
                        string.append(allocator, '\\') catch @panic("allocator error");
                    }
                }

                string.append(allocator, char) catch @panic("allocator error");
            }
            if (print_readably) {
                string.appendSlice(allocator, "\"") catch @panic("allocator error");
            }
        },
        .list => |list| {
            string.appendSlice(allocator, "(") catch @panic("allocator error");
            for (list.data.items, 1..) |item, index| {
                const result = pr_str(item, print_readably);
                string.appendSlice(allocator, result) catch @panic("allocator error");
                if (index != list.data.items.len) {
                    string.appendSlice(allocator, " ") catch @panic("allocator error");
                }
            }
            string.appendSlice(allocator, ")") catch @panic("allocator error");
        },
        .function => |_| {
            string.appendSlice(allocator, "#<function>") catch @panic("allocator error");
        },
        .vector => |vector| {
            string.appendSlice(allocator, "[") catch @panic("allocator error");
            for (vector.data.items) |item| {
                const result = pr_str(item, print_readably);
                string.appendSlice(allocator, result) catch @panic("allocator error");
                string.appendSlice(allocator, " ") catch @panic("allocator error");
            }
            // Remove the last space
            _ = string.pop();
            string.appendSlice(allocator, "]") catch @panic("allocator error");
        },
        .symbol => |symbol| {
            string.appendSlice(allocator, symbol.data) catch @panic("allocator error");
        },
        else => {},
    }

    return string.toOwnedSlice(allocator) catch unreachable;
}

fn initStringArrayList(allocator: mem.Allocator, str: []const u8) ArrayList(u8) {
    var al: ArrayList(u8) = .empty;
    al.appendSlice(allocator, str) catch unreachable;

    return al;
}

const testing = std.testing;

test "printer" {
    const allocator = std.testing.allocator;

    // Test for boolean case
    {
        var bool_true = MalType{ .boolean = true };

        const bool_true_result = pr_str(&bool_true, true);
        try testing.expectEqualStrings("t", bool_true_result);

        var bool_false = MalType{ .boolean = false };

        const bool_false_result = pr_str(&bool_false, true);
        try testing.expectEqualStrings("nil", bool_false_result);
    }

    // Test for string case
    {
        var str1_al = initStringArrayList(allocator, "test");
        defer str1_al.deinit(allocator);

        const str1 = MalType.new_string_ptr(allocator, str1_al);

        const str1_readably_result = pr_str(str1, true);
        try testing.expectEqualStrings("\"test\"", str1_readably_result);
        const str1_non_readably_result = pr_str(str1, false);
        try testing.expectEqualStrings("test", str1_non_readably_result);

        var str2_al = initStringArrayList(allocator, "te\"st");
        defer str2_al.deinit(allocator);

        const str2 = MalType.new_string_ptr(allocator, str2_al);

        // stored value: "te"st"
        // readably result: "te\"st" (escaped doublequote inside)
        const str2_readably_result = pr_str(str2, true);
        try testing.expectEqualStrings("\"te\\\"st\"", str2_readably_result);
        // TODO: No different currently
        const str2_non_readably_result = pr_str(str2, false);
        try testing.expectEqualStrings("te\"st", str2_non_readably_result);

        var str3_al = initStringArrayList(allocator, "\\");
        defer str3_al.deinit(allocator);

        const str3 = MalType.new_string_ptr(allocator, str3_al);

        // stored value: "\"
        // readably result: "\\" (escaped backslash inside)
        const str3_readably_result = pr_str(str3, true);
        try testing.expectEqualStrings("\"\\\\\"", str3_readably_result);
        const str3_non_readably_result = pr_str(str3, false);
        try testing.expectEqualStrings("\"\\\"", str3_non_readably_result);

        var str4_al = initStringArrayList(allocator, "te\\\"st");
        defer str4_al.deinit(allocator);

        const str4 = MalType.new_string_ptr(allocator, str4_al);

        // stored value: "te\"st"
        // readably result: "te\\\"st" (escaped backslash and doublequote inside)
        const str4_readably_result = pr_str(str4, true);
        try testing.expectEqualStrings("\"te\\\\\"st\"", str4_readably_result);
        const str4_non_readably_result = pr_str(str4, false);
        try testing.expectEqualStrings("\"te\\\"st\"", str4_non_readably_result);
    }

    // Test for list case
    {
        var str1_al = initStringArrayList(allocator, "1");
        defer str1_al.deinit(allocator);

        var str2_al = initStringArrayList(allocator, "2");
        defer str2_al.deinit(allocator);

        var list1_al: List = .empty;
        defer list1_al.deinit(allocator);

        list1_al.append(allocator, MalType.new_string_ptr(allocator, str1_al)) catch unreachable;
        list1_al.append(allocator, MalType.new_string_ptr(allocator, str2_al)) catch unreachable;

        const list1 = MalType.new_list_ptr(allocator, list1_al);
        const list1_result = pr_str(list1, true);

        try testing.expectEqualStrings("(\"1\" \"2\")", list1_result);
    }
}
