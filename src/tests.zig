test {
    _ = @import("ui/pixel_canvas.zig");
    _ = @import("ui/fumo.zig");
    _ = @import("ui/fumo_interaction.zig");
    _ = @import("ui/pointer.zig");
    _ = @import("ui/navigation.zig");
    _ = @import("ui/dice.zig");
    _ = @import("ui/cornell.zig");
    _ = @import("ui/doom.zig");
    _ = @import("ui/sandbox.zig");
    _ = @import("sandbox/world.zig");
    _ = @import("input/multitouch.zig");
    _ = @import("rhythm/game.zig");
    _ = @import("rhythm/music.zig");
    _ = @import("ui/rhythm.zig");
    _ = @import("ui/fluid.zig");
    _ = @import("physics/world.zig");
    _ = @import("ui/physics.zig");
    _ = @import("render/pathtracer.zig");
    _ = @import("audio/synth.zig");
    _ = @import("motion/parallax.zig");
    _ = @import("dice/physics.zig");
    _ = @import("dice/controller.zig");
    _ = @import("power/button.zig");
    _ = @import("power/pause.zig");
    _ = @import("simulation/clock.zig");
}

test "CST9217 BSP orientation routes wire contacts to the pad beneath each finger" {
    const std = @import("std");
    const touch = @import("input/multitouch.zig");
    const rhythm = @import("rhythm/game.zig");
    for (rhythm.vectors, 0..) |v, lane| {
        const screen_x: u16 = @intCast(233 + @divTrunc(v[0] * 166, 1024));
        const screen_y: u16 = @intCast(233 + @divTrunc(v[1] * 166, 1024));
        const raw_x = 465 - screen_x;
        const raw_y = 465 - screen_y;
        var report: [touch.report_bytes]u8 = @splat(0);
        report[0] = 0x76;
        report[1] = @intCast(raw_x >> 4);
        report[2] = @intCast(raw_y >> 4);
        report[3] = @as(u8, @intCast((raw_x & 15) << 4)) | @as(u8, @intCast(raw_y & 15));
        report[5] = 1;
        report[6] = 0xAB;
        const frame = try touch.decodeScreen(&report, .{ .mirror_x = true, .mirror_y = true });
        var tracker: touch.Tracker = .{};
        const events = tracker.update(frame);
        try std.testing.expectEqual(@as(usize, 1), events.count);
        try std.testing.expectEqual(@import("ui/navigation.zig").Owner.content, events.items[0].owner);
        var game: rhythm.State = .{};
        const event = events.items[0];
        game.touch(event.kind, event.point.id, event.point.x, event.point.y);
        try std.testing.expectEqual(@as(?u3, @intCast(lane)), game.contacts[7]);
    }
}
