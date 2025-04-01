const std = @import("std");

const constants = @import("constants.zig");
const u8_MAX = constants.u8_MAX;

const valuesFromEnum = @import("utils.zig").valuesFromEnum;
const log = @import("utils.zig").log;

pub const KeyError = error{
    UnknownBytes,
};

pub const FunctionalKey = enum(u8) {
    KeyNull,
    ArrowUp,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
};

// NOTE: ASCII reserves the first 32 code points
// (numbers 0–31 decimal) and the last one (number 127 decimal) for
// control characters.
// From 1-26 it corresponds to A-Z with Ctrl key.
pub const CharKey = enum(u8) {
    KeyNull,
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,
    Escape,

    // Extended character
    // TODO: How to handle characters with shift? Should they be mapped
    // into explicit character?
    Space = 0x20,
    ExclamationMark = 0x21,
    DoubleQuote = 0x22,

    Quote = 0x27,
    BracketLeft = 0x28,
    BracketRight = 0x29,
    Asterisk = 0x2a,
    Plus = 0x2b,
    Dash = 0x2d,
    Dot = 0x2e,
    Slash = 0x2f,
    Key0 = 0x30,
    Key1,
    Key2,
    Key3,
    Key4,
    Key5,
    Key6,
    Key7,
    Key8,
    Key9,
    SemiColon = 0x3b,
    Equal = 0x3d,

    BracketSquareLeft = 0x5b,
    BackSlash = 0x5c,
    BracketSquareRight = 0x5d,

    BackQuote = 0x60,
    Backspace = 0x7f,
};

pub const Key = union(enum) {
    char: CharKey,
    functional: FunctionalKey,
};

const charKeyValues = valuesFromEnum(u8, CharKey);

// Currently using simple key code
// Consider using InputEvent below for a more generic way
pub const KeyCode = enum {
    AltLeft,
    AltRight,
    ArrowDown,
    ArrowLeft,
    ArrowRight,
    ArrowUp,
    BackSlash,
    Backspace,
    BackTick,
    BracketLeft,
    BracketRight,
    BracketSquareLeft,
    BracketSquareRight,
    CapsLock,
    Comma,
    ControlLeft,
    ControlRight,
    Delete,
    End,
    Enter,
    Escape,
    Equals,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    Fullstop,
    Home,
    Insert,
    Key1,
    Key2,
    Key3,
    Key4,
    Key5,
    Key6,
    Key7,
    Key8,
    Key9,
    Key0,
    Menus,
    Minus,
    Numpad0,
    Numpad1,
    Numpad2,
    Numpad3,
    Numpad4,
    Numpad5,
    Numpad6,
    Numpad7,
    Numpad8,
    Numpad9,
    NumpadEnter,
    NumpadLock,
    NumpadSlash,
    NumpadStar,
    NumpadMinus,
    NumpadPeriod,
    NumpadPlus,
    PageDown,
    PageUp,
    PauseBreak,
    PrintScreen,
    ScrollLock,
    SemiColon,
    ShiftLeft,
    ShiftRight,
    Slash,
    Spacebar,
    Tab,
    Quote,
    DoubleQuote,
    WindowsLeft,
    WindowsRight,

    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,

    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,
    /// Not on US keyboards
    HashTilde,
    // Scan code set 1 unique codes
    PrevTrack,
    NextTrack,
    Mute,
    Calculator,
    Play,
    Stop,
    VolumeDown,
    VolumeUp,
    WWWHome,
    // Sent when the keyboard boots
    PowerOnTestOk,

    // Control key. Shall be better represented in InputEvent format
    EndOfStream,
    MetaN,
    MetaP,
};

pub const InputEvent = struct {
    // ASCII Note:
    // 0_0000001
    // Little Endian
    // [6]Ctrl to be 0
    // [5]Shift to be 0
    // ^[ for Alt/Escape key
    // 011: no ctrl and shift
    // 010: no ctrl and yes shift
    // 001: Use as char extension.
    // 000: yes ctrl and no shift
    // Default with Ctrl; 010 to change with Shift; 011 Disable both keys

    ctrl: bool,
    alt: bool,
    shift: bool,
    meta: bool,
    key: Key,
    raw: []u8,

    // NOTE: Using pointer for input param as dynamic bytes causing
    // dereferencing after return.
    pub fn init(bytes: []const u8) InputEvent {
        // Put the value(particularlly bytes) into heap memory to ensure
        // value persist.
        // NOTE: Accept using external allocator would be a more common way
        // and makes "the caller owns the returned memory",
        // but it makes the call more complicated.
        var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator_g = gpa_allocator.allocator();
        const inputEvent = allocator_g.create(InputEvent) catch @panic("OOM");

        var end_pos: u8 = 0;
        for (bytes) |byte| {
            if (byte != u8_MAX) {
                end_pos += 1;
            } else {
                break;
            }
        }

        const result = allocator_g.alloc(u8, end_pos) catch @panic("OOM");
        @memcpy(result[0..end_pos], bytes[0..end_pos]);
        inputEvent.raw = @constCast(result);

        var alt = false;

        // TODO: Complex handling for non-single byte case
        // e.g. Alt composite keys
        var key_byte: u8 = undefined;
        // TODO: Handle other raw bytes length cases
        if (inputEvent.raw.len == 1) {
            key_byte = bytes[0];
        } else if (inputEvent.raw.len == 2) {
            // Escape code for alt key in composite keys
            if (bytes[0] == 0x1b) {
                alt = true;
            }
            key_byte = bytes[1];
        }

        // TODO: Symbol would be complicated(?)
        // NOTE: Ctrl-I/J/M/Q maps to another code in macOS
        var ctrl = (key_byte & 0b1000000) >> 6 == 0;
        const extend = (key_byte & 0b0100000) >> 5 == 1;
        var shift = !ctrl and !extend;

        // TODO: Is exceptional a good way?
        const exceptional_chars = [_]u8{
            @intFromEnum(CharKey.BracketSquareLeft),
            @intFromEnum(CharKey.BracketSquareRight),
            @intFromEnum(CharKey.BackSlash),
            @intFromEnum(CharKey.Backspace),
        };

        var key_bits_layer: u8 = undefined;
        if (std.mem.indexOf(u8, &exceptional_chars, &[_]u8{key_byte})) |_| {
            // For exceptional chars, fix to have shift is false now.
            shift = false;
            key_bits_layer = 0b1111111;
        } else if (ctrl and extend) {
            // Extend to read another set of printable character
            key_bits_layer = 0b0111111;
            ctrl = false;
        } else {
            // For 26 Latin character
            key_bits_layer = 0b0011111;
        }

        var genericKey: Key = undefined;
        var charKey: CharKey = undefined;
        var functionalKey: FunctionalKey = .KeyNull;

        // NOTE: Manual handling to check if the byte returned is in
        // CharKey enum defination or not as there is no easy handling
        // using @enumFromInt now. Fallback to null key for undefined
        // case
        const _charKey = (key_byte & key_bits_layer);
        if (std.mem.indexOf(u8, charKeyValues, &[_]u8{_charKey})) |_| {
            charKey = @enumFromInt(_charKey);
            genericKey = .{ .char = charKey };
        } else {
            charKey = .KeyNull;
        }

        // TODO: Hardcoded for now
        if (inputEvent.raw.len == 3) {
            if (bytes[0] == 0x1b and bytes[1] == 0x5b) {
                const curr = bytes[2];

                if (curr == 0x41) {
                    functionalKey = .ArrowUp;
                } else if (curr == 0x42) {
                    functionalKey = .ArrowDown;
                } else if (curr == 0x43) {
                    functionalKey = .ArrowRight;
                } else if (curr == 0x44) {
                    functionalKey = .ArrowLeft;
                }
            }
            genericKey = .{ .functional = functionalKey };
        }

        // TODO: Decide the condition of these modifier keys
        const meta = false;

        inputEvent.ctrl = ctrl;
        inputEvent.alt = alt;
        inputEvent.shift = shift;
        inputEvent.meta = meta;
        inputEvent.key = genericKey;

        return inputEvent.*;
    }
};

fn bytesToU32(bytes: []const u8) u32 {
    // Change the byte to u32/u64 for comparsion purpose.
    const btv = std.mem.bytesToValue;
    const byte_u32 = btv(u32, bytes);

    return byte_u32;
}

fn u32ToBytes(str: []const u8) [4]u8 {
    var byte_out = [_]u8{u8_MAX} ** 4;
    for (str, 0..) |byte, i| {
        byte_out[i] = byte;
    }

    return byte_out;
}

/// LEGACY function
pub fn mapByteToKeyCode(byte: [4]u8) KeyError!KeyCode {
    const byte_u32 = bytesToU32(&byte);

    return switch (byte_u32) {
        bytesToU32("\x00\xff\xff\xff") => KeyError.UnknownBytes,
        bytesToU32("\x01\xff\xff\xff") => .Escape, // C-a
        bytesToU32("\x02\xff\xff\xff") => .Escape,
        bytesToU32("\x03\xff\xff\xff") => .Escape,
        bytesToU32("\x04\xff\xff\xff") => .EndOfStream,
        bytesToU32("\x05\xff\xff\xff") => .Escape,
        bytesToU32("\x06\xff\xff\xff") => .Escape,
        bytesToU32("\x07\xff\xff\xff") => .Escape,
        bytesToU32("\x08\xff\xff\xff") => .Escape,
        bytesToU32("\x09\xff\xff\xff") => .Tab, // C-i too
        bytesToU32("\x0a\xff\xff\xff") => .Enter, // C-j too
        bytesToU32("\x0b\xff\xff\xff") => .Escape,
        bytesToU32("\x0c\xff\xff\xff") => .Escape,
        bytesToU32("\x0d\xff\xff\xff") => .Escape,
        bytesToU32("\x0e\xff\xff\xff") => .Escape,
        bytesToU32("\x0f\xff\xff\xff") => .Escape,
        bytesToU32("\x10\xff\xff\xff") => .Escape,
        bytesToU32("\x11\xff\xff\xff") => .Escape,
        bytesToU32("\x12\xff\xff\xff") => .Escape,
        bytesToU32("\x13\xff\xff\xff") => .Escape,
        bytesToU32("\x14\xff\xff\xff") => .Escape,
        bytesToU32("\x15\xff\xff\xff") => .Escape,
        bytesToU32("\x16\xff\xff\xff") => .Escape,
        bytesToU32("\x17\xff\xff\xff") => .Escape,
        bytesToU32("\x18\xff\xff\xff") => .Escape,
        bytesToU32("\x19\xff\xff\xff") => .Escape,
        bytesToU32("\x1a\xff\xff\xff") => .Escape,
        bytesToU32("\x1b\xff\xff\xff") => .Escape,
        bytesToU32("\x20\xff\xff\xff") => .Spacebar,
        // TODO: x21 - x2f
        bytesToU32("\x22\xff\xff\xff") => .DoubleQuote,
        bytesToU32("\x27\xff\xff\xff") => .Quote,
        bytesToU32("\x28\xff\xff\xff") => .BracketLeft,
        bytesToU32("\x29\xff\xff\xff") => .BracketRight,

        bytesToU32("\x30\xff\xff\xff") => .Key0,
        bytesToU32("\x31\xff\xff\xff") => .Key1,
        bytesToU32("\x32\xff\xff\xff") => .Key2,
        bytesToU32("\x33\xff\xff\xff") => .Key3,
        bytesToU32("\x34\xff\xff\xff") => .Key4,
        bytesToU32("\x35\xff\xff\xff") => .Key5,
        bytesToU32("\x36\xff\xff\xff") => .Key6,
        bytesToU32("\x37\xff\xff\xff") => .Key7,
        bytesToU32("\x38\xff\xff\xff") => .Key8,
        bytesToU32("\x39\xff\xff\xff") => .Key9,
        // TODO: x3a - x3f
        bytesToU32("\x40\xff\xff\xff") => KeyError.UnknownBytes, // Shift - 2(?)
        bytesToU32("\x41\xff\xff\xff") => .A,
        bytesToU32("\x42\xff\xff\xff") => .B,
        bytesToU32("\x43\xff\xff\xff") => .C,
        bytesToU32("\x44\xff\xff\xff") => .D,
        bytesToU32("\x45\xff\xff\xff") => .E,
        bytesToU32("\x46\xff\xff\xff") => .F,
        bytesToU32("\x47\xff\xff\xff") => .G,
        bytesToU32("\x48\xff\xff\xff") => .H,
        bytesToU32("\x49\xff\xff\xff") => .I,
        bytesToU32("\x4a\xff\xff\xff") => .J,
        bytesToU32("\x4b\xff\xff\xff") => .K,
        bytesToU32("\x4c\xff\xff\xff") => .L,
        bytesToU32("\x4d\xff\xff\xff") => .M,
        bytesToU32("\x4e\xff\xff\xff") => .N,
        bytesToU32("\x4f\xff\xff\xff") => .O,
        bytesToU32("\x50\xff\xff\xff") => .P,
        bytesToU32("\x51\xff\xff\xff") => .Q,
        bytesToU32("\x52\xff\xff\xff") => .R,
        bytesToU32("\x53\xff\xff\xff") => .S,
        bytesToU32("\x54\xff\xff\xff") => .T,
        bytesToU32("\x55\xff\xff\xff") => .U,
        bytesToU32("\x56\xff\xff\xff") => .V,
        bytesToU32("\x57\xff\xff\xff") => .W,
        bytesToU32("\x58\xff\xff\xff") => .X,
        bytesToU32("\x59\xff\xff\xff") => .Y,
        bytesToU32("\x5a\xff\xff\xff") => .Z,
        bytesToU32("\x5b\xff\xff\xff") => .BracketSquareLeft,
        bytesToU32("\x5c\xff\xff\xff") => .BackSlash,
        bytesToU32("\x5d\xff\xff\xff") => .BracketSquareRight,
        bytesToU32("\x5e\xff\xff\xff") => KeyError.UnknownBytes, // Shift - 6
        bytesToU32("\x5f\xff\xff\xff") => KeyError.UnknownBytes, // Underscore(Shift - -)
        bytesToU32("\x60\xff\xff\xff") => .BackTick,
        bytesToU32("\x61\xff\xff\xff") => .a,
        bytesToU32("\x62\xff\xff\xff") => .b,
        bytesToU32("\x63\xff\xff\xff") => .c,
        bytesToU32("\x64\xff\xff\xff") => .d,
        bytesToU32("\x65\xff\xff\xff") => .e,
        bytesToU32("\x66\xff\xff\xff") => .f,
        bytesToU32("\x67\xff\xff\xff") => .g,
        bytesToU32("\x68\xff\xff\xff") => .h,
        bytesToU32("\x69\xff\xff\xff") => .i,
        bytesToU32("\x6a\xff\xff\xff") => .j,
        bytesToU32("\x6b\xff\xff\xff") => .k,
        bytesToU32("\x6c\xff\xff\xff") => .l,
        bytesToU32("\x6d\xff\xff\xff") => .m,
        bytesToU32("\x6e\xff\xff\xff") => .n,
        bytesToU32("\x6f\xff\xff\xff") => .o,
        bytesToU32("\x70\xff\xff\xff") => .p,
        bytesToU32("\x71\xff\xff\xff") => .q,
        bytesToU32("\x72\xff\xff\xff") => .r,
        bytesToU32("\x73\xff\xff\xff") => .s,
        bytesToU32("\x74\xff\xff\xff") => .t,
        bytesToU32("\x75\xff\xff\xff") => .u,
        bytesToU32("\x76\xff\xff\xff") => .v,
        bytesToU32("\x77\xff\xff\xff") => .w,
        bytesToU32("\x78\xff\xff\xff") => .x,
        bytesToU32("\x79\xff\xff\xff") => .y,
        bytesToU32("\x7a\xff\xff\xff") => .z,
        bytesToU32("\x7b\xff\xff\xff") => KeyError.UnknownBytes, // Shift - [
        bytesToU32("\x7c\xff\xff\xff") => KeyError.UnknownBytes, // Shift - \
        bytesToU32("\x7d\xff\xff\xff") => KeyError.UnknownBytes, // Shift - ]
        bytesToU32("\x7e\xff\xff\xff") => KeyError.UnknownBytes, // Shift - `
        bytesToU32("\x7f\xff\xff\xff") => .Backspace,
        //
        bytesToU32("\x1b\x6e\xff\xff") => .MetaN,
        bytesToU32("\x1b\x70\xff\xff") => .MetaP,
        bytesToU32("\x1b\x5b\x41\xff") => .ArrowUp,
        bytesToU32("\x1b\x5b\x42\xff") => .ArrowDown,
        bytesToU32("\x1b\x5b\x44\xff") => .ArrowLeft,
        bytesToU32("\x1b\x5b\x43\xff") => .ArrowRight,
        else => .A,
    };
}

const testing = std.testing;

test "InputEvent" {
    const inputEventKeyA = InputEvent.init(&u32ToBytes("\x41\xff\xff\xff"));
    try testing.expectEqual(.A, inputEventKeyA.key.char);
    try testing.expectEqual(false, inputEventKeyA.ctrl);
    try testing.expectEqual(false, inputEventKeyA.alt);
    try testing.expectEqual(true, inputEventKeyA.shift);
    try testing.expectEqualStrings("\x41", inputEventKeyA.raw);

    const inputEventKeya = InputEvent.init(&u32ToBytes("\x61\xff\xff\xff"));
    try testing.expectEqual(.A, inputEventKeya.key.char);
    try testing.expectEqual(false, inputEventKeya.ctrl);
    try testing.expectEqual(false, inputEventKeya.alt);
    try testing.expectEqual(false, inputEventKeya.shift);
    try testing.expectEqualStrings("\x61", inputEventKeya.raw);

    const inputEventKeyZ = InputEvent.init(&u32ToBytes("\x5a\xff\xff\xff"));
    try testing.expectEqual(.Z, inputEventKeyZ.key.char);
    try testing.expectEqual(false, inputEventKeyZ.ctrl);
    try testing.expectEqual(false, inputEventKeyZ.alt);
    try testing.expectEqual(true, inputEventKeyZ.shift);
    try testing.expectEqualStrings("\x5a", inputEventKeyZ.raw);

    const inputEventEof = InputEvent.init(&u32ToBytes("\x04\xff\xff\xff"));
    try testing.expectEqual(.D, inputEventEof.key.char);
    try testing.expectEqual(true, inputEventEof.ctrl);
    try testing.expectEqual(false, inputEventEof.alt);
    try testing.expectEqual(false, inputEventEof.shift);
    try testing.expectEqualStrings("\x04", inputEventEof.raw);

    const inputEventEscape = InputEvent.init(&u32ToBytes("\x1b\xff\xff\xff"));
    try testing.expectEqual(.Escape, inputEventEscape.key.char);
    try testing.expectEqual(true, inputEventEscape.ctrl);
    try testing.expectEqual(false, inputEventEscape.alt);
    try testing.expectEqual(false, inputEventEscape.shift);
    try testing.expectEqualStrings("\x1b", inputEventEscape.raw);

    const inputEventEscapeShort = InputEvent.init(&u32ToBytes("\x1b"));
    try testing.expectEqual(.Escape, inputEventEscapeShort.key.char);
    try testing.expectEqual(true, inputEventEscapeShort.ctrl);
    try testing.expectEqual(false, inputEventEscapeShort.alt);
    try testing.expectEqual(false, inputEventEscapeShort.shift);
    try testing.expectEqualStrings("\x1b", inputEventEscapeShort.raw);

    const inputEventKey0Short = InputEvent.init(&u32ToBytes("\x30"));
    try testing.expectEqual(.Key0, inputEventKey0Short.key.char);
    try testing.expectEqual(false, inputEventKey0Short.ctrl);
    try testing.expectEqual(false, inputEventKey0Short.alt);
    try testing.expectEqual(false, inputEventKey0Short.shift);
    try testing.expectEqualStrings("\x30", inputEventKey0Short.raw);

    const inputEventKey9Short = InputEvent.init(&u32ToBytes("\x39"));
    try testing.expectEqual(.Key9, inputEventKey9Short.key.char);
    try testing.expectEqual(false, inputEventKey9Short.ctrl);
    try testing.expectEqual(false, inputEventKey9Short.alt);
    try testing.expectEqual(false, inputEventKey9Short.shift);
    try testing.expectEqualStrings("\x39", inputEventKey9Short.raw);

    const inputEventSpace = InputEvent.init(&u32ToBytes("\x20\xff\xff\xff"));
    try testing.expectEqual(.Space, inputEventSpace.key.char);
    try testing.expectEqual(false, inputEventSpace.ctrl);
    try testing.expectEqual(false, inputEventSpace.alt);
    try testing.expectEqual(false, inputEventSpace.shift);
    try testing.expectEqualStrings("\x20", inputEventSpace.raw);

    const inputEventBackspaceShort = InputEvent.init(&u32ToBytes("\x7f"));
    try testing.expectEqual(.Backspace, inputEventBackspaceShort.key.char);
    try testing.expectEqual(false, inputEventBackspaceShort.ctrl);
    try testing.expectEqual(false, inputEventBackspaceShort.alt);
    try testing.expectEqual(false, inputEventBackspaceShort.shift);
    try testing.expectEqualStrings("\x7f", inputEventBackspaceShort.raw);

    const inputEventMetaN = InputEvent.init(&u32ToBytes("\x1b\x6e\xff\xff"));
    try testing.expectEqual(.N, inputEventMetaN.key.char);
    try testing.expectEqual(false, inputEventMetaN.ctrl);
    try testing.expectEqual(true, inputEventMetaN.alt);
    try testing.expectEqual(false, inputEventMetaN.shift);
    try testing.expectEqualStrings("\x1b\x6e", inputEventMetaN.raw);

    const inputEventArrowUp = InputEvent.init(&u32ToBytes("\x1b\x5b\x41\xff"));
    try testing.expectEqual(.ArrowUp, inputEventArrowUp.key.functional);
    try testing.expectEqual(false, inputEventArrowUp.ctrl);
    try testing.expectEqual(false, inputEventArrowUp.alt);
    try testing.expectEqual(false, inputEventArrowUp.shift);
    try testing.expectEqualStrings("\x1b\x5b\x41", inputEventArrowUp.raw);
}
