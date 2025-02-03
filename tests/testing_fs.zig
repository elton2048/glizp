const std = @import("std");
const testing = std.testing;

const fs = @import("glizp").fs;

test "load file - multi-line text" {
    const allocator = testing.allocator;

    const result = try fs.loadFile(allocator, "tests/sample/test_fs_file_1.txt");
    defer allocator.free(result);

    try testing.expectEqualStrings(result,
        \\Lorem ipsum dolor sit amet, consectetur
        \\adipiscing elit. Sed tincidunt erat sed nulla ornare, nec
        \\aliquet ex laoreet. Ut nec rhoncus nunc. Integer magna metus,
        \\ultrices eleifend porttitor ut, finibus ut tortor. Maecenas
        \\sapien justo, finibus tincidunt dictum ac, semper et lectus.
        \\Vivamus molestie egestas orci ac viverra. Pellentesque nec
        \\arcu facilisis, euismod eros eu, sodales nisl. Ut egestas
        \\sagittis arcu, in accumsan sapien rhoncus sit amet. Aenean
        \\neque lectus, imperdiet ac lobortis a, ullamcorper sed massa.
        \\Nullam porttitor porttitor erat nec dapibus. Ut vel dui nec
        \\nulla vulputate molestie eget non nunc. Ut commodo luctus ipsum,
        \\in finibus libero feugiat eget. Etiam vel ante at urna tincidunt
        \\posuere sit amet ut felis. Maecenas finibus suscipit tristique.
        \\Donec viverra non sapien id suscipit.
        \\
    );
}
