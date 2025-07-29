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

/// Simple macro function for testing lisp statement and result.
fn testLispFn(statement: []const u8, expectedResult: []const u8) !void {
    return testLispFnCustom(statement, expectedResult, .{ .pre_statement = null });
}

const TestOption = struct {
    /// Pre-run statement.
    pre_statement: ?[]const u8,
};

/// Macro function for testing lisp statement and result with options set.
fn testLispFnCustom(statement: []const u8, expectedResult: []const u8, args: TestOption) !void {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    if (args.pre_statement) |pre_statement| {
        var reader_pre_statement = Reader.init(allocator, pre_statement);
        defer reader_pre_statement.deinit();

        _ = try env.apply(reader_pre_statement.ast_root, false);
    }

    var reader_statement = Reader.init(allocator, statement);
    defer reader_statement.deinit();

    const reader_statement_value = try env.apply(reader_statement.ast_root, false);
    defer reader_statement_value.decref();

    const result = printer.pr_str(reader_statement_value, true);
    try testing.expectEqualStrings(expectedResult, result);
}

//----------Preset function ends-------------

test {
    var leaking_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const leaking_allocator = leaking_gpa.allocator();
    // As the underlying using logz for further logging, it is required
    // to configure logz for testing environment.
    try logz.setup(leaking_allocator, .{ .pool_size = 5, .level = .None });
}

// NOTE: To skip certain test, add the following into the corresponding
// test
// if (true) return error.SkipZigTest;

test "plus function - simple case" {
    try testLispFn("(+ 1 2 3)", "6");
}

test "def function - simple case" {
    try testLispFn("(def! a 1)", "1");
}

test "def function - with list eval case" {
    try testLispFn("(def! a (+ 2 1))", "3");
}

test "let* function - simple case" {
    try testLispFn("(let* ((a 2)) (+ a 3))", "5");
}

test "let* function - multiple let* case" {
    try testLispFn("(let* ((a 2)) (let* ((b 3)) (+ a b)))", "5");
}

test "if function - normal truthy case" {
    try testLispFn("(if (= 2 2) (+ 1 1) (+ 10 0))", "2");
}

test "if function - normal falsy case" {
    try testLispFn("(if (= 2 1) (+ 1 1) (+ 10 0))", "10");
}

test "if function - incompleted truthy case" {
    try testLispFn("(if (= 2 2) 1)", "1");
}

test "if function - non-boolean case" {
    try testLispFn("(if 91 (+ 1 1) (+ 1 0))", "2");
}

test "lambda function - non-executed case" {
    try testLispFn("(lambda (a) (+ 1 a))", "#<function>");
}

test "lambda function - simple case - single variable" {
    try testLispFn("((lambda (a) (+ 1 a)) 2)", "3");
}

test "lambda function - simple case - multiple variables" {
    try testLispFn("((lambda (a b) (+ 1 a b)) 2 3)", "6");
}

test "list function - simple case" {
    try testLispFn("(list 1 2)", "(1 2)");
}

test "list function - string type case" {
    try testLispFn("(list \"1\")", "(\"1\")");
}

test "list function - multiple type case" {
    try testLispFn("(list 1 2 \"1\")", "(1 2 \"1\")");
}

test "list function - simple list in list case" {
    try testLispFn("(list (list 3 4))", "((3 4))");
}

test "list function - list in list case" {
    try testLispFn("(list (list 3 4) 1 2)", "((3 4) 1 2)");
}

test "listp function - truthy case" {
    try testLispFn("(listp (list 1 2))", "t");
}

test "listp function - falsy case" {
    try testLispFn("(listp nil)", "nil");
}

test "emptyp function - truthy case" {
    try testLispFn("(emptyp (list))", "t");
}

test "emptyp function - falsy case" {
    try testLispFn("(emptyp (list 1))", "nil");
}

test "count function" {
    try testLispFn("(count (list 1 2 \"1\"))", "3");
}

test "[] syntax to create vector - simple case" {
    try testLispFn("[1 2]", "[1 2]");
}

test "vector function - simple case" {
    try testLispFn("(vector 1 2)", "[1 2]");
}

test "vector function - simple symbol case" {
    try testLispFn("(vector a)", "[a]");
}

test "vectorp function - truthy case" {
    try testLispFn("(vectorp (vector 1 2))", "t");
}

test "vectorp function - falsy case" {
    try testLispFn("(vectorp nil)", "nil");
}

test "vectorp function - through let* to create variable case" {
    try testLispFn("(let* ((vector_param (vector 1 2))) (vectorp vector_param))", "t");
}

test "aref function - direct get from vector constructor" {
    try testLispFn("(aref [1 2 3] 1)", "2");
}

test "aref function - get from variable" {
    try testLispFnCustom("(aref a 1)", "2", .{
        .pre_statement = "(def! a [1 2 3]) ",
    });
}

test "pr-str function" {
    try testLispFn("(pr-str \"\\\"\")", "\"\\\"\\\\\\\"\\\"\"");
}

test "str function" {
    try testLispFn("(str \"\\\"\")", "\"\\\"\"");
}

test "read-string function" {
    try testLispFn("(read-string \"(1 2 (3 4) nil)\")", "(1 2 (3 4) nil)");

    try testLispFn("(read-string \"(+ 2 3)\")", "(+ 2 3)");

    try testLispFn("(read-string \"\\\"\n\\\"\")", "\"\\n\"");
}

test "eval function" {
    try testLispFn("(eval (read-string \"(+ 2 3)\"))", "5");
}

test "slurp function" {
    try testLispFn("(slurp \"./tests/sample/test_load.lisp\")",
        \\"(def! a 1)\na\n"
    );
}
