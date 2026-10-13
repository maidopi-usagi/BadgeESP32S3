const std = @import("std");
const builtin = @import("builtin");
const idf = @import("esp_idf");
const board = @import("board");
const badge_ui = @import("ui/badge.zig");
const bgm = @import("audio/bgm.zig");
const theme = @import("ui/theme.zig");
const log = std.log.scoped(idf.log.default_log_scope);

pub fn run() void {
    log.info("Jirai Badge | {s}", .{board.name});
    log.info("Zig {s} | {d}x{d} | theme: {s}", .{
        builtin.zig_version_string,
        board.display.width,
        board.display.height,
        theme.name,
    });
    board.Power.configure() catch |err| log.err("Power configuration: {s}; retaining default clock", .{@errorName(err)});
    badge_ui.init() catch |err| {
        log.err("Display/touch startup failed: {s}", .{@errorName(err)});
        return;
    };
    if (bgm.autoplay_enabled) {
        bgm.start() catch |err| log.err("BGM startup failed: {s}", .{@errorName(err)});
    } else {
        log.info("BGM autoplay disabled; Orbit audio is page controlled", .{});
    }
    @import("power/service.zig").run();
}
