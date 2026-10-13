const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const app = @import("app.zig");

export fn app_main() callconv(.c) void {
    app.run();
}

pub const panic = idf.esp_panic.panic;
pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .debug) .debug else .info,
    .logFn = idf.log.espLogFn,
};
