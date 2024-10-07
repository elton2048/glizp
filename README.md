# Lisp Interpreter in zig

Build script
```sh
zig build
```

# Note

Zig requires manual memory management, some memory are required to be freed for better main program and test cases, noticeably the following items
- ArrayList (by `arrayList.deinit()`)
- Slice from ArrayList (Could be `allocator.free(SLICE)`, by then the array list is not required to be freed. If it is not wrapped in allocator some manual way shall be used.)

# Patch note

The [regex library](https://github.com/tiehuis/zig-regex) used requires patch in order to support non-capturing group for tokenization process. Please refer to https://github.com/elton2048/zig-regex/tree/feat-complex-group-support

Another fix for allowing repeat tokens shows as follow:

In `src/regex.zig`
```
    pub fn isByteClass(re: *const Expr) bool {
        switch (re.*) {
            .Literal,
            .ByteClass,
            .AnyCharNotNL,
            // TODO: Don't keep capture here, but allow on repeat operators.
            .Capture,
+           .Repeat,
            => return true,
            else => return false,
        }
    }
```
