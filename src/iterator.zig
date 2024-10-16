/// Copy from zig-regex project
pub const StringIterator = struct {
    const Self = @This();

    slice: []const u8,
    index: usize,

    pub fn init(s: []const u8) Self {
        return StringIterator{
            .slice = s,
            .index = 0,
        };
    }

    /// Advance the stream and return the next token.
    pub fn next(it: *Self) ?u8 {
        if (it.index < it.slice.len) {
            const n = it.index;
            it.index += 1;
            return it.slice[n];
        } else {
            return null;
        }
    }

    /// Advance the stream.
    pub fn bump(it: *Self) void {
        if (it.index < it.slice.len) {
            it.index += 1;
        }
    }

    /// Reset the stream back one character
    pub fn bumpBack(it: *Self) void {
        if (it.index > 0) {
            it.index -= 1;
        }
    }

    /// Look at the nth character in the stream without advancing.
    fn peekAhead(it: *const Self, comptime n: usize) ?u8 {
        if (it.index + n < it.slice.len) {
            return it.slice[it.index + n];
        } else {
            return null;
        }
    }

    /// Return true if the next character in the stream is `ch`.
    pub fn peekNextIs(it: *const Self, ch: u8) bool {
        if (it.peekAhead(1)) |ok_ch| {
            return ok_ch == ch;
        } else {
            return false;
        }
    }

    /// Look at the next character in the stream without advancing.
    pub fn peek(it: *const Self) ?u8 {
        return it.peekAhead(0);
    }

    /// Return true if the next character in the stream is `ch`.
    pub fn peekIs(it: *const Self, ch: u8) bool {
        if (it.peek()) |ok_ch| {
            return ok_ch == ch;
        } else {
            return false;
        }
    }
};
