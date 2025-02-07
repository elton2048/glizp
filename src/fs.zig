const std = @import("std");
const Allocator = std.mem.Allocator;

// TODO: Pending to change, shall related to what's the definition of
// large file
const FILE_MAX_SIZE = 1000;

pub fn loadFile(allocator: Allocator, sub_path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(sub_path, .{});
    defer file.close();

    var buffered = std.io.bufferedReader(file.reader());
    var bufreader = buffered.reader();

    return try bufreader.readAllAlloc(allocator, FILE_MAX_SIZE);
}
