/// Integration test for a complete flow from reading lisp statement to
/// verifying the result.
/// Consider this as examples how the lisp syntax works
const std = @import("std");
const logz = @import("logz");

const testing = std.testing;
const lisp = @import("glizp").lisp;
const printer = @import("glizp").printer;
const Reader = @import("glizp").Reader;
const LispEnv = @import("glizp").LispEnv;

const MalTypeError = lisp.MalTypeError;

const utils = @import("../src/utils.zig");

test {
    var leaking_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const leaking_allocator = leaking_gpa.allocator();
    // As the underlying using logz for further logging, it is required
    // to configure logz for testing environment.
    try logz.setup(leaking_allocator, .{ .pool_size = 5, .level = .None });
}

test "plus function - simple case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var plus_statement = Reader.init(allocator, "(+ 1 2 3)");
    defer plus_statement.deinit();

    // TODO: Can we handle deinit case in general for apply case?
    const plus_statement_value = try env.apply(plus_statement.ast_root, false);
    defer plus_statement_value.decref();

    const result = printer.pr_str(plus_statement_value, true);
    try testing.expectEqualStrings("6", result);
}

test "def function - simple case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    const def_statement = Reader.init(allocator, "(def! a 1)");
    defer def_statement.deinit();

    try testing.expect(def_statement.ast_root.* == .list);

    const def_statement_value = try env.apply(def_statement.ast_root, false);
    defer def_statement_value.decref();

    const result = printer.pr_str(def_statement_value, true);
    try testing.expectEqualStrings("1", result);
}

test "def function - with list eval case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var def_statment = Reader.init(allocator, "(def! a (+ 2 1))");
    defer def_statment.deinit();

    try testing.expect(def_statment.ast_root.* == .list);

    const def_statement_value = try env.apply(def_statment.ast_root, false);
    // TODO: Double free now
    defer def_statement_value.decref();

    const result = printer.pr_str(def_statement_value, true);
    try testing.expectEqualStrings("3", result);
}

test "let* function - simple case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var letx_statement = Reader.init(allocator, "(let* ((a 2)) (+ a 3))");
    defer letx_statement.deinit();

    try testing.expect(letx_statement.ast_root.* == .list);

    const letx_statement_value = try env.apply(letx_statement.ast_root, false);
    defer letx_statement_value.decref();

    const result = printer.pr_str(letx_statement_value, true);
    try testing.expectEqualStrings("5", result);
}

test "let* function - multiple let* case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var letx_statement = Reader.init(allocator, "(let* ((a 2)) (let* ((b 3)) (+ a b)))");
    defer letx_statement.deinit();

    try testing.expect(letx_statement.ast_root.* == .list);

    const letx_statement_value = try env.apply(letx_statement.ast_root, false);
    defer letx_statement_value.decref();

    const result = printer.pr_str(letx_statement_value, true);
    try testing.expectEqualStrings("5", result);
}

test "if function - normal truthy case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var if_statement = Reader.init(allocator, "(if (= 2 2) (+ 1 1) (+ 10 0))");
    defer if_statement.deinit();

    try testing.expect(if_statement.ast_root.* == .list);

    const if_statement_value = try env.apply(if_statement.ast_root, false);
    defer if_statement_value.decref();

    const result = printer.pr_str(if_statement_value, true);
    try testing.expectEqualStrings("2", result);
}

test "if function - normal falsy case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var if_statement = Reader.init(allocator, "(if (= 2 1) (+ 1 1) (+ 10 0))");
    defer if_statement.deinit();

    try testing.expect(if_statement.ast_root.* == .list);

    const if_statement_value = try env.apply(if_statement.ast_root, false);
    defer if_statement_value.decref();

    const result = printer.pr_str(if_statement_value, true);
    try testing.expectEqualStrings("10", result);
}

test "if function - incompleted truthy case" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var if_statement = Reader.init(allocator, "(if (= 2 2) 1)");
    defer if_statement.deinit();

    try testing.expect(if_statement.ast_root.* == .list);

    const if_statement_value = try env.apply(if_statement.ast_root, false);
    defer if_statement_value.decref();

    const result = printer.pr_str(if_statement_value, true);
    try testing.expectEqualStrings("1", result);
}

test "if function - non-boolean case" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var if_statement = Reader.init(allocator, "(if 91 (+ 1 1) (+ 1 0))");
    defer if_statement.deinit();

    try testing.expect(if_statement.ast_root.* == .list);

    const if_statement_value = try env.apply(if_statement.ast_root, false);
    defer if_statement_value.decref();

    const result = printer.pr_str(if_statement_value, true);
    try testing.expectEqualStrings("2", result);
}

test "list function - simple case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var list_statement = Reader.init(allocator, "(list 1 2)");
    defer list_statement.deinit();

    try testing.expect(list_statement.ast_root.* == .list);

    const list_statement_value = try env.apply(list_statement.ast_root, false);
    defer list_statement_value.decref();

    const result = printer.pr_str(list_statement_value, true);
    try testing.expectEqualStrings("(1 2)", result);
}

test "list function - string type case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var list_statement = Reader.init(allocator, "(list \"1\")");
    defer list_statement.deinit();

    try testing.expect(list_statement.ast_root.* == .list);

    const list_statement_value = try env.apply(list_statement.ast_root, false);
    defer list_statement_value.decref();

    const result = printer.pr_str(list_statement_value, true);
    try testing.expectEqualStrings("(\"1\")", result);
}

test "list function  - multiple type case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var list_statement = Reader.init(allocator, "(list 1 2 \"1\")");
    defer list_statement.deinit();

    try testing.expect(list_statement.ast_root.* == .list);

    const list_statement_value = try env.apply(list_statement.ast_root, false);
    defer list_statement_value.decref();

    const result = printer.pr_str(list_statement_value, true);
    try testing.expectEqualStrings("(1 2 \"1\")", result);
}

test "list function - simple list in list case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var list_statement = Reader.init(allocator, "(list (list 3 4))");
    defer list_statement.deinit();

    try testing.expect(list_statement.ast_root.* == .list);

    const list_statement_value = try env.apply(list_statement.ast_root, false);
    defer list_statement_value.deinit();

    const result = printer.pr_str(list_statement_value, true);
    try testing.expectEqualStrings("((3 4))", result);
}

test "list function - list in list case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var list_statement = Reader.init(allocator, "(list (list 3 4) 1 2)");
    defer list_statement.deinit();

    try testing.expect(list_statement.ast_root.* == .list);

    const list_statement_value = try env.apply(list_statement.ast_root, false);
    defer list_statement_value.decref();

    const result = printer.pr_str(list_statement_value, true);
    try testing.expectEqualStrings("((3 4) 1 2)", result);
}

test "listp function - truthy case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var listp_statement = Reader.init(allocator, "(listp (list 1 2))");
    defer listp_statement.deinit();

    try testing.expect(listp_statement.ast_root.* == .list);

    const listp_statement_value = try env.apply(listp_statement.ast_root, false);
    defer listp_statement_value.decref();

    const result = printer.pr_str(listp_statement_value, true);
    try testing.expectEqualStrings("t", result);
}

test "listp function - falsy case" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var listp_statement = Reader.init(allocator, "(listp nil)");
    defer listp_statement.deinit();

    try testing.expect(listp_statement.ast_root.* == .list);

    const listp_statement_value = try env.apply(listp_statement.ast_root, false);
    defer listp_statement_value.decref();

    const result = printer.pr_str(listp_statement_value, true);
    try testing.expectEqualStrings("nil", result);
}
