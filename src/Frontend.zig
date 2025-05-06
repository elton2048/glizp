const ArrayList = @import("std").ArrayList;
/// Frontend interface to control the display behaviour.
const int_ptr = *const anyopaque;

/// Pointer to the actual instance.
context: *const anyopaque,
/// Virtual table to store the function pointers on actual implementations.
vtable: *const VTable,
/// Frame size of the frontend
frame_size: Position,

/// Available direction in two-dimension. The internal representation
/// is for terminal movement.
/// NOTE: The representation likely useful for terminal only.
pub const Direction = enum(u8) {
    Up = 'A',
    Down = 'B',
    Right = 'C',
    Left = 'D',
};

/// Two-dimensional position representation.
pub const Position = struct {
    x: usize,
    y: usize,
};

pub const VTable = struct {
    /// Print the string in corresponding frontend
    print: *const fn (context: *const anyopaque, string: []const u8) anyerror!void,

    /// deinit the implementation to free up memory
    deinit: *const fn (context: *const anyopaque) void,

    /// Move the cursor to certain direction in steps
    /// It is assume there is one cursor only. The interface and structure
    /// need changes when handling multiple cursor case.
    move: *const fn (context: int_ptr, steps: usize, direction: Direction) anyerror!void,

    /// Insert char from current position
    insert: *const fn (context: *const anyopaque, optional_arrayList: ?*ArrayList(u8), byte: u8, pos: usize) anyerror!void,

    /// Delete char backward from current position
    /// TODO: For multiple bytes case it is incorrect now, like emoji input.
    /// This is handled using CHARPOS and BYTEPOS in Emacs, which helps mapping
    /// to the correct position.
    deleteBackwardChar: *const fn (context: int_ptr, pos: usize) anyerror!void,

    /// Read current position of the cursor in Position form.
    readCursorPos: *const fn (context: int_ptr) anyerror!Position,

    /// Clear content stored in the frontend
    clearContent: *const fn (context: *const anyopaque, pos: usize) anyerror!void,

    /// Refresh the content in the frontend
    refresh: *const fn (context: *const anyopaque, posStart: usize, charbefore: usize, modification: ?[]const u8) anyerror!void,
};

pub fn print(self: Self, string: []const u8) !void {
    try self.vtable.print(self.context, string);
}

pub fn deinit(self: Self) void {
    self.vtable.deinit(self.context);
}

pub fn move(self: Self, steps: usize, direction: Direction) !void {
    try self.vtable.move(self.context, steps, direction);
}

pub fn insert(self: Self, optional_arrayList: ?*ArrayList(u8), byte: u8, pos: usize) !void {
    try self.vtable.insert(self.context, optional_arrayList, byte, pos);
}

pub fn deleteBackwardChar(self: Self, pos: usize) !void {
    try self.vtable.deleteBackwardChar(self.context, pos);
}

pub fn readCursorPos(self: Self) !Position {
    return try self.vtable.readCursorPos(self.context);
}

pub fn clearContent(self: Self, pos: usize) !void {
    return self.vtable.clearContent(self.context, pos);
}

pub fn refresh(self: Self, posStart: usize, charbefore: usize, modification: ?[]const u8) !void {
    return self.vtable.refresh(self.context, posStart, charbefore, modification);
}

const Self = @This();
