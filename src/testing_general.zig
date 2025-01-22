/// General test for a complete flow from reading lisp statement to
/// verifying the result.
const std = @import("std");
const logz = @import("logz");

const testing = std.testing;
const Reader = @import("reader.zig").Reader;
const LispEnv = @import("env.zig").LispEnv;
const printer = @import("printer.zig");

const utils = @import("utils.zig");

test {
    var leaking_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const leaking_allocator = leaking_gpa.allocator();
    // As the underlying using logz for further logging, it is required
    // to configure logz for testing environment.
    try logz.setup(leaking_allocator, .{ .pool_size = 5, .level = .None });
}

test "general" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    // plus function
    {
        var plus1_statement = Reader.init(allocator, "(+ 1 2)");
        defer plus1_statement.deinit();

        const plus1_statement_value = try env.apply(plus1_statement.ast_root);
        const plus1_statement_value_number = plus1_statement_value.as_number() catch unreachable;
        try testing.expectEqual(3, plus1_statement_value_number.value);

        const result = printer.pr_str(plus1_statement_value, true);
        try testing.expectEqualStrings("3", result);
    }
}
