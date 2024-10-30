const std = @import("std");
const regex = @import("regex");
const logz = @import("logz");

const data = @import("data.zig");
const utils = @import("utils.zig");
const iterator = @import("iterator.zig");

const StringIterator = iterator.StringIterator;

const ArrayList = std.ArrayList;
const debug = std.debug;

const BOOLEAN_MAP = @import("semantic.zig").BOOLEAN_MAP;

const Token = []const u8;

const ReaderError = error{
    Overflow,
    EOF,

    UnmatchedSExpr,
};

const SExprStart = '(';
const SExprEnd = ')';

fn isDigit(char: u8) bool {
    return char >= '0' and char <= '9';
}

pub const MalTypeError = error{
    Unhandled,
    IllegalType,
};

const LispEnv = @import("env.zig").LispEnv;

pub const LispFunction = *const fn ([]MalType) MalTypeError!MalType;

pub const LispFunctionWithEnv = *const fn ([]MalType, *LispEnv) MalTypeError!MalType;

pub const GenericLispFunction = union(enum) {
    simple: LispFunction,
    with_env: LispFunctionWithEnv,
};

pub const Number = struct {
    // TODO: Support for floating point
    value: u64,
};

pub const List = ArrayList(MalType);

pub const MalType = union(enum) {
    boolean: bool,
    number: Number,
    /// An array which is ordered sequence of characters. The basic way
    /// to create is by using double quotes.
    string: ArrayList(u8),
    list: List,
    /// General symbol type including function
    symbol: []const u8,

    SExprEnd,
    /// Incompleted type from parser
    Incompleted,

    pub fn deinit(self: MalType) void {
        switch (self) {
            .string => |string| {
                string.deinit();
            },
            .list => |list| {
                for (list.items) |item| {
                    item.deinit();
                }
                list.deinit();
            },
            else => {},
        }
    }

    pub fn as_symbol(self: MalType) MalTypeError![]const u8 {
        switch (self) {
            .symbol => |symbol| {
                return symbol;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_boolean(self: MalType) MalTypeError!bool {
        switch (self) {
            .boolean => |boolean| {
                return boolean;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_number(self: MalType) MalTypeError!Number {
        switch (self) {
            .number => |num| {
                return num;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_string(self: MalType) MalTypeError!ArrayList(u8) {
        switch (self) {
            .string => |str| {
                return str;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_list(self: MalType) MalTypeError!ArrayList(MalType) {
        switch (self) {
            .list => |list| {
                return list;
            },
            else => return MalTypeError.IllegalType,
        }
    }
};

// NOTE: Currently the regex requires fix to allow repeater after pipe('|')
// char. Check isByteClass method in the library.
const MAL_REGEX = "[\\s,]*(~@|[\\[\\]\\{\\}\\(\\)'`~\\^@]|\"(?:\\\\.|[^\\\\\"])*\"?|;.*|[^\\s\\[\\]\\{\\}('\"`,;)]*)";

/// Reader object
pub const Reader = struct {
    allocator: std.mem.Allocator,
    tokens: ArrayList(Token),
    token_curr: usize,
    ast_root: MalType,

    fn createList(self: Reader) List {
        const list = List.init(self.allocator);

        errdefer {
            self.allocator.destroy(list);
        }

        return list;
    }

    pub fn deinit(self: *Reader) void {
        self.tokens.deinit();
        self.ast_root.deinit();
        self.allocator.destroy(self);
    }

    /// Named as "read_str" in the mal doc
    pub fn init(allocator: std.mem.Allocator, statement: []const u8) *Reader {
        // var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
        // const allocator = gpa_allocator.allocator();

        const tokens = ArrayList(Token).init(allocator);

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
                @constCast(&self.*.tokens).append(result.sliceAt(1).?) catch unreachable;
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

    pub fn read_form(self: *Reader) MalType {
        var mal: MalType = undefined;

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

                        mal = .Incompleted;
                        break;
                    },
                    else => {
                        @panic("Unexpected error");
                    },
                };
                mal = MalType{
                    .list = list,
                };
            } else if (char == SExprEnd) {
                mal = .SExprEnd;
            } else {
                mal = self.read_atom(token);
            }
            break;
        }

        logz.info()
            .fmt("[LOG]", "read_form result: {any}", .{mal})
            .log();

        return mal;
    }

    // As the list is not expected to be expanded, return slice instead
    // of array list.
    pub fn read_list(self: *Reader) !ArrayList(MalType) {
        var list = self.createList();
        errdefer {
            list.deinit();
        }

        var end = false;
        while (self.next()) |_| {
            const malType = self.read_form();

            // NOTE: append action could mutate the original object as it access
            // the pointer and expand memory.
            switch (malType) {
                .SExprEnd => {
                    end = true;
                    break;
                },
                else => {
                    try list.append(malType);
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

    pub fn read_atom(self: *Reader, token: Token) MalType {
        var str_al = ArrayList(u8).init(self.allocator);

        var iter = StringIterator.init(token);

        var isNumber = true;
        var isString = false;
        while (iter.next()) |char| {
            if (!isDigit(char)) {
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
                if (iter.peek() == '\"') {
                    // Skip the escape character
                    continue;
                }
            }

            str_al.append(char) catch unreachable;
        }
        const isBoolean = BOOLEAN_MAP.get(token);

        var mal: MalType = undefined;

        // NOTE: Decide the return MalType based on different rules
        // Like keyword case (e.g. if)
        if (isNumber) {
            mal = MalType{
                .number = .{
                    .value = utils.parseU64(token, 10) catch @panic("Unexpected overflow."),
                },
            };
        } else if (isBoolean) |mal_bool| {
            mal = MalType{
                .boolean = mal_bool,
            };
        } else if (isString) {
            mal = MalType{
                .string = str_al,
            };
        } else {
            mal = MalType{
                .symbol = token,
            };
        }

        return mal;
    }
};

const testing = std.testing;

test "Reader" {
    const allocator = std.testing.allocator;

    // Simple cases
    {
        var sym1 = Reader.init(allocator, "test");
        defer sym1.deinit();

        try testing.expect(sym1.ast_root == .symbol);
    }

    // Boolean cases
    {
        var b1 = Reader.init(allocator, "t");
        defer b1.deinit();

        try testing.expect(b1.ast_root == .boolean);
        const boolean1 = b1.ast_root.as_boolean() catch unreachable;
        try testing.expectEqual(true, boolean1);

        var b2 = Reader.init(allocator, "nil");
        defer b2.deinit();

        try testing.expect(b2.ast_root == .boolean);
        const boolean2 = b2.ast_root.as_boolean() catch unreachable;
        try testing.expectEqual(false, boolean2);
    }

    // Number cases
    {
        var n1 = Reader.init(allocator, "1");
        defer n1.deinit();
        try testing.expect(n1.ast_root == .number);
    }

    // String cases
    {
        var str1 = Reader.init(allocator, "\"test\"");
        defer str1.deinit();

        try testing.expect(str1.ast_root == .string);
        const string1 = str1.ast_root.as_string() catch unreachable;
        try testing.expectEqualStrings("test", string1.items);

        // Read case: "te\"st"
        // Stored result: te"st
        var str2 = Reader.init(allocator, "\"te\\\"st\"");
        defer str2.deinit();

        try testing.expect(str2.ast_root == .string);
        const string2 = str2.ast_root.as_string() catch unreachable;
        try testing.expectEqualStrings("te\"st", string2.items);

        var str3 = Reader.init(allocator, "\"te\\st\"");
        defer str3.deinit();

        try testing.expect(str3.ast_root == .string);
        const string3 = str3.ast_root.as_string() catch unreachable;
        try testing.expectEqualStrings("te\\st", string3.items);
    }

    // Simple list cases
    {
        var l1 = Reader.init(allocator, "(\"test\")");
        defer l1.deinit();

        try testing.expect(l1.ast_root == .list);

        const list1 = l1.ast_root.as_list() catch unreachable;
        try testing.expect(list1.items[0] == .string);
        const string1 = list1.items[0].as_string() catch unreachable;
        try testing.expectEqualStrings("test", string1.items);
    }

    // Multiple lists cases
    {
        var l2 = Reader.init(allocator, "((1) (2))");
        defer l2.deinit();

        try testing.expect(l2.ast_root == .list);

        const list2 = l2.ast_root.as_list() catch unreachable;
        try testing.expect(list2.items[0] == .list);
        const sub_list1 = list2.items[0].as_list() catch unreachable;
        try testing.expect(sub_list1.items[0] == .number);
        const sub_list1_val = sub_list1.items[0].as_number() catch unreachable;
        try testing.expectEqual(1, sub_list1_val.value);

        const sub_list2 = list2.items[1].as_list() catch unreachable;
        try testing.expect(sub_list2.items[0] == .number);
        const sub_list2_val = sub_list2.items[0].as_number() catch unreachable;
        try testing.expectEqual(2, sub_list2_val.value);
    }

    // Incompleted cases
    {
        var incompleted_list1 = Reader.init(allocator, "(1");
        defer incompleted_list1.deinit();

        try testing.expect(incompleted_list1.ast_root == .Incompleted);
    }
}
