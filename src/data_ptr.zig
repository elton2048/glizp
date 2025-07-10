const std = @import("std");

const logz = @import("logz");

const token_reader = @import("reader.zig");
const lisp = @import("types/lisp.zig");

const utils = @import("utils.zig");

const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunction = lisp.LispFunction;
const NumberType = lisp.NumberType;

// TODO: Parser part
pub const EVAL_TABLE = std.StaticStringMap(LispFunction).initComptime(.{
    .{ "+", &plus },
    .{ "-", &minus },
    .{ "*", &times },
    .{ "/", &quo },
    // The original arithcompare function store the three comparing cases
    // into three bits(less than/great than/equal) and masking the bit
    // return the result by given the corresponding opeartions.
    .{ "=", &eqlsign },
    .{ "<", &lss },
    .{ "<=", &leq },
    .{ ">", &gtr },
    .{ ">=", &geq },
});

const ARITHMETIC_OPERATION = enum {
    add,
    mult,
    sub,
    div,
};

/// ArithCompareResult denotes three result for comparing number,
/// thus using three bits to represents the result. The order is
/// equal, less than and greater than. i.e. The reverse order of
/// ARITHMETIC_COMPARE_OPERATION_BIT
const ArithCompareResult = u3;

const ARITHMETIC_COMPARE_OPERATION_BIT = enum(u2) {
    gt,
    lt,
    eq,
};

const ARITHMETIC_COMPARE_OPERATION = enum(ArithCompareResult) {
    gt = 1 << @intFromEnum(ARITHMETIC_COMPARE_OPERATION_BIT.gt),
    lt = 1 << @intFromEnum(ARITHMETIC_COMPARE_OPERATION_BIT.lt),
    eq = 1 << @intFromEnum(ARITHMETIC_COMPARE_OPERATION_BIT.eq),
};

fn eqlsign(params: []*MalType) MalTypeError!MalType {
    const result = try arithcompare_driver(params, @intFromEnum(ARITHMETIC_COMPARE_OPERATION.eq));

    return MalType{ .boolean = result };
}

fn lss(params: []*MalType) MalTypeError!MalType {
    const result = try arithcompare_driver(params, @intFromEnum(ARITHMETIC_COMPARE_OPERATION.lt));

    return MalType{ .boolean = result };
}

fn leq(params: []*MalType) MalTypeError!MalType {
    const result = try arithcompare_driver(params, @intFromEnum(ARITHMETIC_COMPARE_OPERATION.eq) | @intFromEnum(ARITHMETIC_COMPARE_OPERATION.lt));

    return MalType{ .boolean = result };
}

fn gtr(params: []*MalType) MalTypeError!MalType {
    const result = try arithcompare_driver(params, @intFromEnum(ARITHMETIC_COMPARE_OPERATION.gt));

    return MalType{ .boolean = result };
}

fn geq(params: []*MalType) MalTypeError!MalType {
    const result = try arithcompare_driver(params, @intFromEnum(ARITHMETIC_COMPARE_OPERATION.eq) | @intFromEnum(ARITHMETIC_COMPARE_OPERATION.gt));

    return MalType{ .boolean = result };
}

/// To perform arithmatic comparsion, perform AND operation with desired ArithCompareResult bits setting
/// to see if the result is truty or not.
// TODO: Fix potential error case
fn arithcompare(mal1: *MalType, mal2: *MalType) MalTypeError!ArithCompareResult {
    const number1 = try mal1.as_number();
    const number2 = try mal2.as_number();

    var result: ArithCompareResult = 0b000;

    const eq = @as(ArithCompareResult, @intFromBool(number1.value == number2.value)) << @intFromEnum(ARITHMETIC_COMPARE_OPERATION_BIT.eq);
    const lt = @as(ArithCompareResult, @intFromBool(number1.value < number2.value)) << @intFromEnum(ARITHMETIC_COMPARE_OPERATION_BIT.lt);
    const gt = @as(ArithCompareResult, @intFromBool(number1.value > number2.value)) << @intFromEnum(ARITHMETIC_COMPARE_OPERATION_BIT.gt);

    result = eq | lt | gt;

    return result;
}

fn arithcompare_driver(params: []*MalType, operations: ArithCompareResult) MalTypeError!bool {
    const len = params.len;
    for (1..len) |i| {
        const compareResult = try arithcompare(params[i - 1], params[i]);
        if ((compareResult & operations) == 0) {
            return false;
        }
    }
    return true;
}

/// Refer to Emacs original comment
/// Return the result of applying the arithmetic operation CODE to the
/// NARGS arguments starting at ARGS, with the first argument being the
/// number VAL.  2 <= NARGS.  Check that the remaining arguments are
/// numbers or markers.
fn arith_driver(oper: ARITHMETIC_OPERATION, params: []*MalType, val: *MalType) MalTypeError!MalType {
    var accum: NumberType = if (val.as_number()) |num| num.value else |_| {
        return MalTypeError.IllegalType;
    };

    var iter = std.mem.window(*MalType, params[1..], 1, 1);
    while (iter.next()) |items| {
        const num = try items[0].as_number();
        // TODO: Some assertion for the data?
        switch (oper) {
            .add => {
                accum = accum + num.value;
            },
            .sub => {
                accum = accum - num.value;
            },
            .mult => {
                accum = accum * num.value;
            },
            .div => {
                if (num.value == 0) {
                    return MalTypeError.ArithError;
                }
                accum = accum / num.value;
            },
            // else => return MalTypeError.IllegalType,
        }
    }

    return MalType{ .number = .{ .value = accum } };
}

fn plus(params: []*MalType) MalTypeError!MalType {
    const first = params[0];
    return arith_driver(.add, params, first);
}

fn minus(params: []*MalType) MalTypeError!MalType {
    const first = params[0];
    return arith_driver(.sub, params, first);
}

fn times(params: []*MalType) MalTypeError!MalType {
    const first = params[0];
    return arith_driver(.mult, params, first);
}

fn quo(params: []*MalType) MalTypeError!MalType {
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
    const param0_same = [_]MalType{ num0, num0 };
    const param0_same_multiple = [_]MalType{ num0, num0, num0 };

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
        try (std.testing.expectEqual(MalTypeError.ArithError, err));
    }

    const eqlsign_equal = try eqlsign(@constCast(&param0_same));
    try expectEqual(true, try eqlsign_equal.as_boolean());

    const eqlsign_equal_multiple = try eqlsign(@constCast(&param0_same_multiple));
    try expectEqual(true, try eqlsign_equal_multiple.as_boolean());

    const eqlsign_unequal = try eqlsign(@constCast(&param1));
    try expectEqual(false, try eqlsign_unequal.as_boolean());
}

test "data - compare" {
    const num0_1 = MalType{
        .number = .{ .value = 0 },
    };
    const num0_2 = MalType{
        .number = .{ .value = 0 },
    };

    const num1_1 = MalType{
        .number = .{ .value = 1 },
    };

    const result_eq = try arithcompare(num0_1, num0_2);
    try std.testing.expect(result_eq == 0b100);

    const result_lt = try arithcompare(num0_1, num1_1);
    try std.testing.expect(result_lt == 0b010);

    const result_gt = try arithcompare(num1_1, num0_1);
    try std.testing.expect(result_gt == 0b001);

    const driver_result_lt_true = try arithcompare_driver(@constCast(&[_]MalType{ num0_1, num1_1 }), 0b010);
    try expectEqual(true, driver_result_lt_true);

    const driver_result_lt_false = try arithcompare_driver(@constCast(&[_]MalType{ num1_1, num0_1 }), 0b010);
    try expectEqual(false, driver_result_lt_false);

    const driver_result_leq_1 = try arithcompare_driver(@constCast(&[_]MalType{ num0_1, num1_1 }), 0b110);
    try expectEqual(true, driver_result_leq_1);

    const driver_result_leq_2 = try arithcompare_driver(@constCast(&[_]MalType{ num0_1, num0_2 }), 0b110);
    try expectEqual(true, driver_result_leq_2);

    const driver_result_leq_3 = try arithcompare_driver(@constCast(&[_]MalType{ num1_1, num0_1 }), 0b110);
    try expectEqual(false, driver_result_leq_3);

    const driver_result_gt_true = try arithcompare_driver(@constCast(&[_]MalType{ num1_1, num0_1 }), 0b001);
    try expectEqual(true, driver_result_gt_true);

    const driver_result_gt_false = try arithcompare_driver(@constCast(&[_]MalType{ num0_1, num1_1 }), 0b001);
    try expectEqual(false, driver_result_gt_false);

    const driver_result_geq_1 = try arithcompare_driver(@constCast(&[_]MalType{ num1_1, num0_1 }), 0b101);
    try expectEqual(true, driver_result_geq_1);

    const driver_result_geq_2 = try arithcompare_driver(@constCast(&[_]MalType{ num0_1, num0_2 }), 0b101);
    try expectEqual(true, driver_result_geq_2);

    const driver_result_geq_3 = try arithcompare_driver(@constCast(&[_]MalType{ num0_1, num1_1 }), 0b101);
    try expectEqual(false, driver_result_geq_3);
}
