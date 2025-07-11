const std = @import("std");
const regex = @import("regex");
const logz = @import("logz");

const data = @import("data.zig");
const utils = @import("utils.zig");
const iterator = @import("iterator.zig");

const lisp = @import("types/lisp.zig");
const List = lisp.List;
const Vector = lisp.Vector;
const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;

const StringIterator = iterator.StringIterator;

const ArrayList = std.ArrayListUnmanaged;
const debug = std.debug;

const BOOLEAN_MAP = @import("semantic.zig").BOOLEAN_MAP;

const Token = []const u8;

const ReaderError = error{
    Overflow,
    EOF,

    UnmatchedSExpr,
    UnmatchedVectorExpr,
};

const SExprStart = '(';
const SExprEnd = ')';

const VectorExprStart = '[';
const VectorExprEnd = ']';

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

fn isSignChar(char: u8) bool {
    return char == '+' or char == '-';
}

fn isValidNumberChar(char: u8) bool {
    return isDigit(char) or char == '.' or isSignChar(char);
}

const LispEnv = @import("env.zig").LispEnv;

// NOTE: Currently the regex requires fix to allow repeater after pipe('|')
// char. Check isByteClass method in the library.
const MAL_REGEX = "[\\s,]*(~@|[\\[\\]\\{\\}\\(\\)'`~\\^@]|\"(?:\\\\.|[^\\\\\"])*\"?|;.*|[^\\s\\[\\]\\{\\}('\"`,;)]*)";

/// Reader object
pub const Reader = struct {
    allocator: std.mem.Allocator,
    tokens: ArrayList(Token),
    token_curr: usize,
    ast_root: *MalType,

    pub fn deinit(self: *Reader) void {
        utils.log("reader deinit ast_root before", "{any}", .{self.ast_root}, .{ .color = .BrightRed, .test_only = true });

        self.tokens.deinit(self.allocator);
        self.ast_root.decref();
        self.allocator.destroy(self);
    }

    /// Named as "read_str" in the mal doc
    pub fn init(allocator: std.mem.Allocator, statement: []const u8) *Reader {
        // var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
        // const allocator = gpa_allocator.allocator();

        const tokens: ArrayList(Token) = .empty;

        // NOTE: Create a pointer that requires `destroy` afterwards
        const self = allocator.create(Reader) catch @panic("OOM");
        self.* = Reader{
            .allocator = allocator,
            .tokens = tokens,
            .token_curr = 0,
            .ast_root = undefined,
        };

        self.tokenize(statement);

        const mal_root = self.read_form();
        self.*.ast_root = mal_root;

        logz.info()
            .fmt("[LOG]", "MAL head: {any}", .{mal_root})
            .log();

        return self;
    }

    /// tokenize reads statement and generate tokens based on tokenizer
    /// In current case the tokenizer is a regex.
    fn tokenize(self: *Reader, statement: []const u8) void {
        const statement_end_pos = statement.len;
        var statement_curr: usize = 0;
        // raw_statement indicates part not matched against tokenizer
        var raw_statement = statement;

        // The regex is constant so no error should be returned. For the
        // allocator, it should also contain no issue.
        var mal_regex = regex.Regex.compile(self.allocator, MAL_REGEX) catch unreachable;
        defer mal_regex.deinit();

        while (statement_curr < statement_end_pos and raw_statement.len > 0) {
            var captures = regex.Regex.captures(&mal_regex, raw_statement) catch |err| switch (err) {
                else => return,
            };
            defer captures.?.deinit();
            if (captures) |result| {
                statement_curr = statement_curr + (result.slots[1] orelse statement_end_pos - 1);
                raw_statement = statement[statement_curr..];

                // TODO: Handle the potential error
                // This is different to normal append case as the object pointer
                // is mutable normally, however this case gets the result
                // from struct which is const (now). Might need further
                // check to see if this implemenation is ok or not.
                @constCast(&self.tokens).append(self.allocator, result.sliceAt(1).?) catch unreachable;
            } else {
                // No match case
                statement_curr = statement_end_pos;
                raw_statement = "";
            }
        }

        return;
    }

    // peek and next error throwing need better consideration.
    fn peek(self: Reader) !Token {
        if (self.token_curr >= self.tokens.items.len) {
            return ReaderError.Overflow;
        }

        const token = self.tokens.items[self.token_curr];
        return token;
    }

    fn next(self: *Reader) !Token {
        const token = self.peek() catch unreachable;
        self.token_curr += 1;
        if (self.token_curr >= self.tokens.items.len) {
            return ReaderError.EOF;
        }

        return token;
    }

    pub fn read_form(self: *Reader) *MalType {
        var mal_ptr: *MalType = undefined;

        // Early return for empty case
        if (self.tokens.items.len == 0) {
            return MalType.INCOMPLETED;
        }

        const token = self.peek() catch @panic("Accessing invalid token.");
        for (token) |char| {
            // TODO: Currently check only the first char and handle that
            // This should be changed for a better algo
            // "token" should be with length 1 only for this case.
            // See if assertion is required
            if (char == SExprStart) {
                const list = self.read_list() catch |err| switch (err) {
                    ReaderError.UnmatchedSExpr => {
                        logz.err()
                            .fmt("[LOG]", "statement missed matched parenthesis", .{})
                            .log();

                        mal_ptr = MalType.INCOMPLETED;
                        break;
                    },
                    else => {
                        @panic("Unexpected error");
                    },
                };

                mal_ptr = MalType.new_list_ptr(self.allocator, list);
            } else if (char == SExprEnd) {
                mal_ptr = self.allocator.create(MalType) catch @panic("OOM");
                mal_ptr.* = .SExprEnd;

                defer self.allocator.destroy(mal_ptr);
            } else if (char == VectorExprStart) {
                const list = self.read_vector() catch |err| switch (err) {
                    ReaderError.UnmatchedVectorExpr => {
                        logz.err()
                            .fmt("[LOG]", "statement missed matched parenthesis", .{})
                            .log();

                        mal_ptr = MalType.INCOMPLETED;
                        break;
                    },
                    else => {
                        @panic("Unexpected error");
                    },
                };
                mal_ptr = MalType.new_list_ptr(self.allocator, list);
            } else if (char == VectorExprEnd) {
                mal_ptr = self.allocator.create(MalType) catch @panic("OOM");
                mal_ptr.* = .VectorExprEnd;

                defer self.allocator.destroy(mal_ptr);
            } else {
                mal_ptr = self.read_atom(token);
            }
            break;
        }

        logz.info()
            .fmt("[LOG]", "read_form result: {any}", .{mal_ptr})
            .log();

        return mal_ptr;
    }

    // As the list is not expected to be expanded, return slice instead
    // of array list.
    pub fn read_list(self: *Reader) !ArrayList(*MalType) {
        var list: ArrayList(*MalType) = .empty;
        errdefer {
            // For incompleted list case, the parsed elements require
            // deinited.
            for (list.items) |item| {
                item.deinit();
            }
            list.deinit(self.allocator);
        }

        var end = false;
        while (self.next()) |_| {
            const malType = self.read_form();
            // NOTE: append action could mutate the original object as it access
            // the pointer and expand memory.
            switch (malType.*) {
                .SExprEnd => {
                    // The object finishes its job to indicate end of
                    // expression, hence destroy here.
                    // TODO: Further check if this is needed
                    // defer self.allocator.destroy(malType);
                    end = true;
                    break;
                },
                else => {
                    try list.append(self.allocator, malType);
                },
            }
        } else |err| {
            switch (err) {
                // TODO: Need to handle, see if log or throw it out
                ReaderError.Overflow => {},
                // Expected case
                ReaderError.EOF => {},
                else => {},
            }
        }

        if (!end) {
            return ReaderError.UnmatchedSExpr;
        }

        // NOTE: Free the memory later to avoid memory leakage
        return list;
    }

    /// Reading vector from string, it appends a "vector" symbol at the
    /// beginning of the list then append all items within bracket to
    /// create vector data structure.
    // TODO: Need to handle double free vector case in running main program
    pub fn read_vector(self: *Reader) !Vector {
        var list: Vector = .empty;
        errdefer {
            list.deinit(self.allocator);
        }

        var end = false;
        const vectorLisp = MalType.new_symbol(self.allocator, "vector");
        try list.append(self.allocator, @constCast(vectorLisp));
        while (self.next()) |_| {
            const malType = self.read_form();

            // NOTE: append action could mutate the original object as it access
            // the pointer and expand memory.
            switch (malType.*) {
                .VectorExprEnd => {
                    // The object finishes its job to indicate end of
                    // expression, hence destroy here.
                    // defer self.allocator.destroy(malType);
                    end = true;
                    break;
                },
                else => {
                    try list.append(self.allocator, malType);
                },
            }
        } else |err| {
            switch (err) {
                // TODO: Need to handle, see if log or throw it out
                ReaderError.Overflow => {},
                // Expected case
                ReaderError.EOF => {},
                else => {},
            }
        }

        if (!end) {
            return ReaderError.UnmatchedVectorExpr;
        }

        return list;
    }

    /// Determine whether the type of representation for the input string,
    /// which could be boolean, number, string or symbol.
    /// This returns the lisp object.
    pub fn read_atom(self: *Reader, token: Token) *MalType {
        var str_al: ArrayList(u8) = .empty;

        var iter = StringIterator.init(token);

        var isNumber = true;
        var isString = false;
        var point: usize = 0;
        var i: usize = 0;
        while (iter.next()) |char| : (i += 1) {
            if (char == '.') {
                point += 1;
            }

            if ((token.len == 1 and isSignChar(char)) or
                !isValidNumberChar(char) or
                point > 1 or
                (i > 0 and isSignChar(char)))
            {
                isNumber = false;
            }
            if (!isString and iter.index == 1 and char == '\"' and token[token.len - 1] == '\"') {
                isString = true;
            }

            // Fallback to symbol immediately
            if (!isString and !isNumber) break;

            if (iter.index == 1 or iter.index == token.len) {
                // Skip character denoting string
                continue;
            }
            // Handle escape character cases
            if (char == '\\') {
                const peek_char = iter.peek();
                if (peek_char == '\"') {
                    // Skip the escape character
                    continue;
                } else if (peek_char == '\\') {
                    _ = iter.next();
                    str_al.append(self.allocator, char) catch unreachable;

                    continue;
                } else if (peek_char == 'n') {
                    _ = iter.next();
                    str_al.append(self.allocator, '\n') catch unreachable;

                    continue;
                }
            }

            str_al.append(self.allocator, char) catch unreachable;
        }
        const isBoolean = BOOLEAN_MAP.get(token);

        var mal_ptr: *MalType = undefined;

        // NOTE: Decide the return MalType based on different rules
        // Like keyword case (e.g. if)
        if (isNumber) {
            mal_ptr = MalType.new_number(self.allocator, std.fmt.parseFloat(f64, token) catch @panic("Unexpected overflow."));
        } else if (isBoolean) |mal_bool| {
            mal_ptr = MalType.new_boolean_ptr(mal_bool);
        } else if (isString) {
            mal_ptr = MalType.new_string_ptr(self.allocator, str_al);
            logz.info()
                .fmt("[LOG]", "str_al result: {any}", .{str_al.items})
                .log();
        } else {
            mal_ptr = MalType.new_symbol(self.allocator, token);
        }

        return mal_ptr;
    }
};

const testing = std.testing;

test {
    var leaking_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const leaking_allocator = leaking_gpa.allocator();
    // As the underlying using logz for further logging, it is required
    // to configure logz for testing environment.
    try logz.setup(leaking_allocator, .{ .pool_size = 5, .level = .None });
}

test "empty string case" {
    const allocator = std.testing.allocator;

    const empty1 = Reader.init(allocator, "");
    defer empty1.deinit();

    try testing.expect(empty1.ast_root.* == .Incompleted);
}

test "simple string case" {
    const allocator = std.testing.allocator;

    var sym1 = Reader.init(allocator, "test");
    defer sym1.deinit();

    try testing.expect(sym1.ast_root.* == .symbol);
}

test "boolean case - true case" {
    const allocator = std.testing.allocator;

    var boolean_true = Reader.init(allocator, "t");
    defer boolean_true.deinit();

    try testing.expect(boolean_true.ast_root.* == .boolean);
    const boolean1 = boolean_true.ast_root.as_boolean() catch unreachable;
    try testing.expectEqual(true, boolean1);
}

test "boolean case - false case" {
    const allocator = std.testing.allocator;

    var boolean_false = Reader.init(allocator, "nil");
    defer boolean_false.deinit();

    try testing.expect(boolean_false.ast_root.* == .boolean);
    const boolean1 = boolean_false.ast_root.as_boolean() catch unreachable;
    try testing.expectEqual(false, boolean1);
}

test "number case" {
    const allocator = std.testing.allocator;

    var number1 = Reader.init(allocator, "1");
    defer number1.deinit();
    try testing.expect(number1.ast_root.* == .number);
}

test "string case - simple case" {
    const allocator = std.testing.allocator;

    var str1 = Reader.init(allocator, "\"test\"");
    defer str1.deinit();

    try testing.expect(str1.ast_root.* == .string);
    const string1 = str1.ast_root.as_string() catch unreachable;
    try testing.expectEqualStrings("test", string1.items);
}

test "string case - with \" case" {
    const allocator = std.testing.allocator;

    // Read case: "te\"st"
    // Stored result: te"st
    var str2 = Reader.init(allocator, "\"te\\\"st\"");
    defer str2.deinit();

    try testing.expect(str2.ast_root.* == .string);
    const string2 = str2.ast_root.as_string() catch unreachable;
    try testing.expectEqualStrings("te\"st", string2.items);
}

test "string case - double back slash case" {
    const allocator = std.testing.allocator;

    var str3 = Reader.init(allocator, "\"te\\st\"");
    defer str3.deinit();

    try testing.expect(str3.ast_root.* == .string);
    const string3 = str3.ast_root.as_string() catch unreachable;
    try testing.expectEqualStrings("te\\st", string3.items);
}

test "string case - back slash case" {
    const allocator = std.testing.allocator;

    // NOTE: \\ corresponds to one \ as the first one is required for
    // escape purpose
    var single_backslash_str1 = Reader.init(allocator, "\"\\\\\"");
    defer single_backslash_str1.deinit();

    try testing.expect(single_backslash_str1.ast_root.* == .string);
    const string1 = single_backslash_str1.ast_root.as_string() catch unreachable;
    try testing.expectEqualStrings("\\", string1.items);

    var single_backslash_str2 = Reader.init(allocator, "\"\\\\\\\\\"");
    defer single_backslash_str2.deinit();

    try testing.expect(single_backslash_str2.ast_root.* == .string);
    const string2 = single_backslash_str2.ast_root.as_string() catch unreachable;
    try testing.expectEqualStrings("\\\\", string2.items);
}

test "list case - simple case" {
    const allocator = std.testing.allocator;

    var l1 = Reader.init(allocator, "(\"test\")");
    defer l1.deinit();

    try testing.expect(l1.ast_root.* == .list);

    const list1 = l1.ast_root.as_list() catch unreachable;
    try testing.expect(list1.items[0].* == .string);
    const string1 = list1.items[0].as_string() catch unreachable;
    try testing.expectEqualStrings("test", string1.items);
}

test "list case - multiple list case" {
    const allocator = std.testing.allocator;

    var l2 = Reader.init(allocator, "((1) (2))");
    defer l2.deinit();

    try testing.expect(l2.ast_root.* == .list);

    const list2 = l2.ast_root.as_list() catch unreachable;
    try testing.expect(list2.items[0].* == .list);
    const sub_list1 = list2.items[0].as_list() catch unreachable;
    try testing.expect(sub_list1.items[0].* == .number);
    const sub_list1_val = sub_list1.items[0].as_number() catch unreachable;
    try testing.expectEqual(1, sub_list1_val.value);

    const sub_list2 = list2.items[1].as_list() catch unreachable;
    try testing.expect(sub_list2.items[0].* == .number);
    const sub_list2_val = sub_list2.items[0].as_number() catch unreachable;
    try testing.expectEqual(2, sub_list2_val.value);
}

// NOTE: Vector cases are handled in future
// test "vector case - empty case" {
//     const allocator = std.testing.allocator;

//     // Vector cases
//     var empty_vector = Reader.init(allocator, "[]");
//     defer empty_vector.deinit();

//     const empty_vector_list = empty_vector.ast_root.as_list() catch unreachable;
//     const empty_vector_list_symbol = empty_vector_list.items[0].as_symbol() catch unreachable;
//     try testing.expectEqualStrings("vector", empty_vector_list_symbol);

//     try testing.expectEqual(1, empty_vector_list.items.len);
// }

// test "vector case - normal case" {
//     const allocator = std.testing.allocator;

//     var vector_statement = Reader.init(allocator, "[1]");
//     defer vector_statement.deinit();

//     try testing.expect(vector_statement.ast_root.* == .list);

//     const vector_statement_list = vector_statement.ast_root.as_list() catch unreachable;
//     const vector_statement_list_symbol = vector_statement_list.items[0].as_symbol() catch unreachable;
//     try testing.expectEqualStrings("vector", vector_statement_list_symbol);

//     const vector_statement_list_item_1 = vector_statement_list.items[1].as_number() catch unreachable;
//     try testing.expectEqual(1, vector_statement_list_item_1.value);
// }

// TODO: How to handle incompleted statement memory management?
test "incompleted statement case" {
    // if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var incompleted_list1 = Reader.init(allocator, "(1");
    defer incompleted_list1.deinit();

    try testing.expect(incompleted_list1.ast_root.* == .Incompleted);
}
