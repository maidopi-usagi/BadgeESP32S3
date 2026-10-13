const std = @import("std");
const pointer = @import("pointer.zig");
const panel_size = @import("pixel_canvas.zig").Viewport.panel_size;

pub const Demo = @import("../demo.zig").Demo;
pub const demo_count = @typeInfo(Demo).@"enum".field_names.len;
pub const edge_width = 36;
pub const swipe_distance = 64;
pub const swipe_max_ms = 1400;
pub const Owner = enum { none, content, edge };
pub const Route = union(enum) { ignore, content, switched: Demo };

pub const Router = struct {
    active: Demo = .fumo,
    owner: Owner = .none,
    start_x: i32 = 0,
    start_y: i32 = 0,
    start_ms: u64 = 0,

    pub fn route(self: *Router, event: pointer.Event, x: i32, y: i32, now_ms: u64) Route {
        if (event == .down) {
            self.owner = zone(x, y);
            self.start_x = x;
            self.start_y = y;
            self.start_ms = now_ms;
        }
        const owner = self.owner;
        if (event == .up or event == .cancel) self.owner = .none;
        if (owner == .content) return .content;
        if (owner != .edge or event != .up or now_ms -| self.start_ms > swipe_max_ms) return .ignore;
        const nx: i64 = panel_size - 1 - 2 * self.start_x;
        const ny: i64 = panel_size - 1 - 2 * self.start_y;
        const dot = @as(i64, x - self.start_x) * nx + @as(i64, y - self.start_y) * ny;
        // Inward distance projected onto the rim normal, without sqrt or floats.
        if (dot <= 0 or dot * dot < swipe_distance * swipe_distance * (nx * nx + ny * ny)) return .ignore;
        const forward = if (@abs(nx) >= @abs(ny)) nx < 0 else ny < 0;
        const count = demo_count;
        const current: usize = @backingInt(self.active);
        self.active = @fromBackingInt(@intCast((current + if (forward) @as(usize, 1) else count - 1) % count));
        return .{ .switched = self.active };
    }
};

pub fn zone(x: i32, y: i32) Owner {
    if (x < 0 or y < 0 or x >= panel_size or y >= panel_size) return .none;
    const dx = 2 * x - (panel_size - 1);
    const dy = 2 * y - (panel_size - 1);
    const radius_squared = dx * dx + dy * dy;
    if (radius_squared > panel_size * panel_size) return .none;
    const inner = panel_size - 2 * edge_width;
    return if (radius_squared >= inner * inner) .edge else .content;
}

test "round rim reserves edge touches and center drag retains ownership" {
    try std.testing.expectEqual(Owner.none, zone(0, 0));
    try std.testing.expectEqual(Owner.edge, zone(455, 233));
    try std.testing.expectEqual(Owner.edge, zone(390, 390));
    try std.testing.expectEqual(Owner.content, zone(233, 233));
    var router: Router = .{};
    try std.testing.expectEqual(Route.content, router.route(.down, 233, 233, 0));
    try std.testing.expectEqual(Route.content, router.route(.move, 455, 233, 100));
    try std.testing.expectEqual(Route.content, router.route(.up, 455, 233, 200));
    try std.testing.expectEqual(Demo.fumo, router.active);
    try std.testing.expectEqual(Route.ignore, router.route(.up, 233, 233, 220));
}

test "all four inward rim swipes switch once and consume the complete gesture" {
    for ([_][2]i32{ .{ 455, 233 }, .{ 10, 233 }, .{ 233, 10 }, .{ 233, 455 } }) |start| {
        var router: Router = .{};
        const forward = start[0] == 455 or start[1] == 455;
        const expected = if (forward) [_]Demo{ .dice, .cornell, .doom, .sandbox, .rhythm, .fluid, .physics, .fumo } else [_]Demo{ .physics, .fluid, .rhythm, .sandbox, .doom, .cornell, .dice, .fumo };
        for (expected, 0..) |demo, i| {
            const time = i * 300;
            try std.testing.expectEqual(Route.ignore, router.route(.down, start[0], start[1], time));
            try std.testing.expectEqual(Route.ignore, router.route(.move, 233, 233, time + 100));
            try std.testing.expectEqual(Route{ .switched = demo }, router.route(.up, 233, 233, time + 200));
            try std.testing.expectEqual(Route.ignore, router.route(.up, 233, 233, time + 210));
        }
    }
}

test "edge taps, tangential drags, long holds and cancellation do not switch" {
    for ([_]struct { x: i32, y: i32, time: u64, event: pointer.Event }{
        .{ .x = 452, .y = 233, .time = 100, .event = .up },
        .{ .x = 455, .y = 330, .time = 100, .event = .up },
        .{ .x = 233, .y = 233, .time = 1500, .event = .up },
        .{ .x = 233, .y = 233, .time = 100, .event = .cancel },
    }) |end| {
        var router: Router = .{};
        _ = router.route(.down, 455, 233, 0);
        try std.testing.expectEqual(Route.ignore, router.route(end.event, end.x, end.y, end.time));
        try std.testing.expectEqual(Demo.fumo, router.active);
    }
}
