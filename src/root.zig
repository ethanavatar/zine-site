const std = @import("std");

pub export fn sayHello() void {
    std.debug.print("Hello, World\n", .{});
}

