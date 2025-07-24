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

// NOTE: Need manual deinit previously as it the lambda function
// does not resolve at all.
// This makes the program has the potential leakage issue as
// the interrupter may store the function lisp value but never
// free.
// This is due to the ast_root is in list type, in that layer
// the lambda is not evaled but after the apply function, which
// makes the normal deinit function does not free the function lisp value.
// Current implementation checks if the lambda function run and
// defer deinit process.
//
// Using wrap to call lambda function shall consider one of the
// special case now as it breaks the normal rule to eval list.
// In Emacs using funcall to supply params is a more standard way
// in lisp semantic.
// i.e. (funcall (lambda (a b) (+ 1 a b)) a b)
//       ^       ^----------------------^ ^ ^
//  function call   The function part      params
//              vv----------------------v v v
// Current case ((lambda (a b) (+ 1 a b)) a b)
test "lambda function - non-executed case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var lambda_statement = Reader.init(allocator, "(lambda (a) (+ 1 a))");
    defer lambda_statement.deinit();

    try testing.expect(lambda_statement.ast_root.* == .list);

    const lambda_statement_value = try env.apply(lambda_statement.ast_root, false);
    defer lambda_statement_value.decref();
    try testing.expect(lambda_statement_value.* == .function);

    const result = printer.pr_str(lambda_statement_value, true);
    try testing.expectEqualStrings("#<function>", result);
}

test "lambda function - simple case - single variable" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var lambda_statement = Reader.init(allocator, "((lambda (a) (+ 1 a)) 2)");
    defer lambda_statement.deinit();

    try testing.expect(lambda_statement.ast_root.* == .list);

    const lambda_statement_value = try env.apply(lambda_statement.ast_root, false);
    defer lambda_statement_value.decref();

    const result = printer.pr_str(lambda_statement_value, true);
    try testing.expectEqualStrings("3", result);
}

test "lambda function - simple case - multiple variables" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var lambda_statement = Reader.init(allocator, "((lambda (a b) (+ 1 a b)) 2 3)");
    defer lambda_statement.deinit();

    try testing.expect(lambda_statement.ast_root.* == .list);

    const lambda_statement_value = try env.apply(lambda_statement.ast_root, false);
    defer lambda_statement_value.decref();

    const result = printer.pr_str(lambda_statement_value, true);
    try testing.expectEqualStrings("6", result);
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

test "emptyp function - truthy case" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var emptyp_statement = Reader.init(allocator, "(emptyp (list))");
    defer emptyp_statement.deinit();

    try testing.expect(emptyp_statement.ast_root.* == .list);

    const emptyp_statement_value = try env.apply(emptyp_statement.ast_root, false);
    emptyp_statement_value.decref();

    const result = printer.pr_str(emptyp_statement_value, true);
    try testing.expectEqualStrings("t", result);
}

test "emptyp function - falsy case" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var emptyp_statement = Reader.init(allocator, "(emptyp (list 1))");
    defer emptyp_statement.deinit();

    try testing.expect(emptyp_statement.ast_root.* == .list);

    const emptyp_statement_value = try env.apply(emptyp_statement.ast_root, false);
    emptyp_statement_value.decref();

    const result = printer.pr_str(emptyp_statement_value, true);
    try testing.expectEqualStrings("nil", result);
}

test "count function" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var count_statement = Reader.init(allocator, "(count (list 1 2 \"1\"))");
    defer count_statement.deinit();

    try testing.expect(count_statement.ast_root.* == .list);

    const count_statement_value = try env.apply(count_statement.ast_root, false);
    defer count_statement_value.deinit();

    const result = printer.pr_str(count_statement_value, true);
    try testing.expectEqualStrings("3", result);
}

test "[] syntax to create vector - simple case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var vector_statement = Reader.init(allocator, "[1 2]");
    defer vector_statement.deinit();

    try testing.expect(vector_statement.ast_root.* == .list);

    // NOTE: This is not a primitive value, thus require manual deinit.
    const vector_statement_value = try env.apply(vector_statement.ast_root, false);
    defer vector_statement_value.deinit();

    const result = printer.pr_str(vector_statement_value, true);
    try testing.expectEqualStrings("[1 2]", result);
}

test "vector function - simple case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var vector_statement = Reader.init(allocator, "(vector 1 2)");
    defer vector_statement.deinit();

    try testing.expect(vector_statement.ast_root.* == .list);

    // NOTE: This is not a primitive value, thus require manual deinit.
    const vector_statement_value = try env.apply(vector_statement.ast_root, false);
    defer vector_statement_value.deinit();

    const result = printer.pr_str(vector_statement_value, true);
    try testing.expectEqualStrings("[1 2]", result);
}

test "vector function - simple symbol case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var vector_statement = Reader.init(allocator, "(vector a)");
    defer vector_statement.deinit();

    try testing.expect(vector_statement.ast_root.* == .list);

    // NOTE: This is not a primitive value, thus require manual deinit.
    const vector_statement_value = try env.apply(vector_statement.ast_root, false);
    defer vector_statement_value.deinit();

    const result = printer.pr_str(vector_statement_value, true);
    try testing.expectEqualStrings("[a]", result);
}

test "vectorp function - truthy case" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var vectorp_statement = Reader.init(allocator, "(vectorp (vector 1 2))");
    defer vectorp_statement.deinit();

    try testing.expect(vectorp_statement.ast_root.* == .list);

    const vectorp_statement_value = try env.apply(vectorp_statement.ast_root, false);
    defer vectorp_statement_value.decref();

    const result = printer.pr_str(vectorp_statement_value, true);
    try testing.expectEqualStrings("t", result);
}

test "vectorp function - falsy case" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var vectorp_statement = Reader.init(allocator, "(vectorp nil)");
    defer vectorp_statement.deinit();

    try testing.expect(vectorp_statement.ast_root.* == .list);

    const vectorp_statement_value = try env.apply(vectorp_statement.ast_root, false);
    defer vectorp_statement_value.decref();

    const result = printer.pr_str(vectorp_statement_value, true);
    try testing.expectEqualStrings("nil", result);
}

test "vectorp function - through let* to create variable case" {
    // if (true) return error.SkipZigTest;
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var is_vector_var_statement = Reader.init(
        allocator,
        "(let* ((vector_param (vector 1 2))) (vectorp vector_param))",
    );
    defer is_vector_var_statement.deinit();

    const is_vector_var_statement_value = try env.apply(is_vector_var_statement.ast_root, false);
    defer is_vector_var_statement_value.decref();

    const result = printer.pr_str(is_vector_var_statement_value, true);
    try testing.expectEqualStrings("t", result);

    const is_vector_var_statement_value_bool = is_vector_var_statement_value.as_boolean() catch unreachable;
    try testing.expectEqual(true, is_vector_var_statement_value_bool);
}

test "aref function - direct get from vector constructor" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var aref_statement = Reader.init(allocator, "(aref [1 2 3] 1)");
    defer aref_statement.deinit();

    try testing.expect(aref_statement.ast_root.* == .list);

    const aref_statement_value = try env.apply(aref_statement.ast_root, false);
    defer aref_statement_value.decref();

    const result = printer.pr_str(aref_statement_value, true);
    try testing.expectEqualStrings("2", result);
}

test "aref function - get from variable" {
    const allocator = testing.allocator;

    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    var def_statement = Reader.init(allocator, "(def! a [1 2 3])");
    defer def_statement.deinit();

    _ = try env.apply(def_statement.ast_root, false);

    var aref_statement = Reader.init(allocator, "(aref a 1)");
    defer aref_statement.deinit();

    try testing.expect(aref_statement.ast_root.* == .list);

    const aref_statement_value = try env.apply(aref_statement.ast_root, false);
    defer aref_statement_value.decref();

    const result = printer.pr_str(aref_statement_value, true);
    try testing.expectEqualStrings("2", result);
}
