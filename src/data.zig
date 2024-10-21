const std = @import("std");
const token_reader = @import("reader.zig");

const MalType = token_reader.MalType;
const MalTypeError = token_reader.MalTypeError;
const LispFunction = token_reader.LispFunction;

// TODO: Parser part
pub const EVAL_TABLE = std.StaticStringMap(LispFunction).initComptime(.{
    .{ "+", &plus },
    .{ "-", &minus },
    .{ "*", &times },
    .{ "/", &quo },
});

const ARITHMETIC_OPERATION = enum {
    add,
    mult,
    sub,
    div,
};

/// Refer to Emacs original comment
/// Return the result of applying the arithmetic operation CODE to the
/// NARGS arguments starting at ARGS, with the first argument being the
/// number VAL.  2 <= NARGS.  Check that the remaining arguments are
/// numbers or markers.
fn arith_driver(oper: ARITHMETIC_OPERATION, params: []MalType, val: MalType) MalTypeError!MalType {
    var accum: u64 = if (val.as_number()) |num| num.value else |_| {
        return MalTypeError.IllegalType;
    };

    var iter = std.mem.window(MalType, params[1..], 1, 1);
    while (iter.next()) |items| {
        const num = try items[0].as_number();
        // TODO: Some assertion for the data?
        switch (oper) {
            .add => {
                accum = std.math.add(u64, accum, num.value) catch |err| switch (err) {
                    error.Overflow => return MalTypeError.Unhandled,
                };
            },
            .sub => {
                accum = std.math.sub(u64, accum, num.value) catch |err| switch (err) {
                    error.Overflow => return MalTypeError.Unhandled,
                };
            },
            .mult => {
                accum = std.math.mul(u64, accum, num.value) catch |err| switch (err) {
                    error.Overflow => return MalTypeError.Unhandled,
                };
            },
            .div => {
                accum = std.math.divExact(u64, accum, num.value) catch |err| switch (err) {
                    // TODO: Qarith_error in Emacs case
                    error.DivisionByZero => return MalTypeError.Unhandled,
                    error.UnexpectedRemainder => return MalTypeError.Unhandled,
                };
            },
            // else => return MalTypeError.IllegalType,
        }
    }

    return MalType{ .number = .{ .value = accum } };
}

fn plus(params: []MalType) MalTypeError!MalType {
    // TODO: Support integer only now
    const first = params[0];
    return arith_driver(.add, params, first);
}

fn minus(params: []MalType) MalTypeError!MalType {
    // TODO: Support integer only now
    const first = params[0];
    return arith_driver(.sub, params, first);
}

fn times(params: []MalType) MalTypeError!MalType {
    // TODO: Support integer only now
    const first = params[0];
    return arith_driver(.mult, params, first);
}

fn quo(params: []MalType) MalTypeError!MalType {
    // TODO: Support integer only now
    const first = params[0];
    return arith_driver(.div, params, first);
}

const expectEqual = std.testing.expectEqual;

test "data - arith" {
    const num0 = MalType{
        .number = .{ .value = 0 },
    };
    const num1 = MalType{
        .number = .{ .value = 1 },
    };
    const num2 = MalType{
        .number = .{ .value = 2 },
    };
    const num3 = MalType{
        .number = .{ .value = 3 },
    };
    const num4 = MalType{
        .number = .{ .value = 4 },
    };

    const param1 = [_]MalType{ num2, num1 };
    const param2 = [_]MalType{ num1, num2 };
    const param3 = [_]MalType{ num3, num2 };
    const param4 = [_]MalType{ num4, num2 };
    const param4_0 = [_]MalType{ num4, num0 };

    const plus1 = try plus(@constCast(&param1));
    try expectEqual(3, (try plus1.as_number()).value);
    const plus2 = try plus(@constCast(&param2));
    try expectEqual(3, (try plus2.as_number()).value);

    const minus1 = try minus(@constCast(&param1));
    try expectEqual(1, (try minus1.as_number()).value);

    // Negative case, not supported for now
    // const minus2 = try minus(@constCast(&param2));
    // try expectEqual(-1, (try minus2.as_number()).value);

    const times1 = try times(@constCast(&param1));
    try expectEqual(2, (try times1.as_number()).value);
    const times2 = try times(@constCast(&param3));
    try expectEqual(6, (try times2.as_number()).value);

    const quo1 = try quo(@constCast(&param4));
    try expectEqual(2, (try quo1.as_number()).value);

    if (quo(@constCast(&param4_0))) |_| unreachable else |err| {
        try (std.testing.expectEqual(MalTypeError.Unhandled, err));
    }
}
