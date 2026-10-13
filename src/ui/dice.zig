const std = @import("std");
const pixel = @import("pixel_canvas.zig");
const ui = @import("jirai.zig");
const c = @import("theme.zig").colors;
pub const State = @import("../dice/controller.zig").State;
pub const Reading = @import("../dice/controller.zig").Reading;
pub const core = @import("../dice/physics.zig");
const Vec = core.Vec;
const Rotation = core.Rotation;
pub const frame_period_ms = 33;
pub const idle_frame_period_ms = 80;

fn body(p: ui.Painter) void {
    p.canvas.clear(c.background);
    p.circle(58, 58, 56, c.border);
    p.circle(58, 58, 55, c.background);
    var extent: i32 = 52;
    var dy: i32 = 0;
    while (dy <= 52) : (dy += 1) {
        while (extent * extent + dy * dy > 52 * 52) extent -= 1;
        plaidRow(p, 58 + dy, extent);
        if (dy != 0) plaidRow(p, 58 - dy, extent);
    }
}

fn plaidRow(p: ui.Painter, y: i32, extent: i32) void {
    const left = 58 - extent;
    const right = 58 + extent + 1;
    p.rect(left, y, right - left, 1, if (@mod(y, 16) < 2) c.surface else c.panel);
    var x: i32 = 10;
    while (x < right) : (x += 16) {
        const start = @max(left, x);
        p.rect(start, y, @min(x + 2, right) - start, 1, c.surface);
    }
}

fn mascot(p: ui.Painter, now_ms: u64) void {
    p.panel(47, 4, 7, 17, c.surface);
    p.panel(62, 4, 7, 17, c.surface);
    p.rect(50, 7, 2, 8, c.berry);
    p.rect(64, 7, 2, 8, c.berry);
    p.panel(43, 15, 30, 13, c.surface);
    p.rect(45, 22, 4, 2, c.berry);
    p.rect(67, 22, 4, 2, c.berry);
    const blink = ui.phase(now_ms, 180, 23) == 0;
    p.rect(51, 20 + @as(i32, if (blink) 1 else 0), 2, if (blink) 1 else 3, c.highlight);
    p.rect(63, 20 + @as(i32, if (blink) 1 else 0), 2, if (blink) 1 else 3, c.highlight);
    p.dot(58, 23, c.rose);
    p.line(.{ 56, 24 }, .{ 60, 24 }, c.rose);
    p.bow(35, 13);
    p.heart(73, 18 + ui.bob(now_ms), c.rose);
}

const Face = struct { number: u8, normal: Vec, u: Vec, v: Vec, vertices: [4]u3 };
const cube_vertices = core.vertices;
const faces = [_]Face{
    .{ .number = 1, .normal = .{ .x = 0, .y = 0, .z = 1 }, .u = .{ .x = 1, .y = 0, .z = 0 }, .v = .{ .x = 0, .y = 1, .z = 0 }, .vertices = .{ 4, 5, 6, 7 } },
    .{ .number = 6, .normal = .{ .x = 0, .y = 0, .z = -1 }, .u = .{ .x = -1, .y = 0, .z = 0 }, .v = .{ .x = 0, .y = 1, .z = 0 }, .vertices = .{ 1, 0, 3, 2 } },
    .{ .number = 2, .normal = .{ .x = 1, .y = 0, .z = 0 }, .u = .{ .x = 0, .y = 0, .z = -1 }, .v = .{ .x = 0, .y = 1, .z = 0 }, .vertices = .{ 5, 1, 2, 6 } },
    .{ .number = 5, .normal = .{ .x = -1, .y = 0, .z = 0 }, .u = .{ .x = 0, .y = 0, .z = 1 }, .v = .{ .x = 0, .y = 1, .z = 0 }, .vertices = .{ 0, 4, 7, 3 } },
    .{ .number = 3, .normal = .{ .x = 0, .y = 1, .z = 0 }, .u = .{ .x = 1, .y = 0, .z = 0 }, .v = .{ .x = 0, .y = 0, .z = -1 }, .vertices = .{ 7, 6, 2, 3 } },
    .{ .number = 4, .normal = .{ .x = 0, .y = -1, .z = 0 }, .u = .{ .x = 1, .y = 0, .z = 0 }, .v = .{ .x = 0, .y = 0, .z = 1 }, .vertices = .{ 0, 1, 5, 4 } },
};
const pip_centers = [_][2]f32{ .{ -0.5, 0.5 }, .{ 0.5, -0.5 }, .{ 0.5, 0.5 }, .{ -0.5, -0.5 }, .{ -0.5, 0 }, .{ 0.5, 0 }, .{ 0, 0 } };
const pip_masks = [_]u7{ 0b1000000, 0b0000011, 0b1000011, 0b0001111, 0b1001111, 0b0111111 };
const tray_vertices = [_]Vec{
    .{ .x = -core.tray_x, .y = -core.tray_y },
    .{ .x = core.tray_x, .y = -core.tray_y },
    .{ .x = core.tray_x, .y = core.tray_y },
    .{ .x = -core.tray_x, .y = core.tray_y },
};
const Projection = struct {
    scale: f32 = @min(64 / (2 * core.tray_x), 35 / (2 * core.tray_y)),
    fn point(self: Projection, v: Vec) ui.Point {
        return .{ @intFromFloat(@round(58 + v.x * self.scale)), @intFromFloat(@round(62 - v.y * self.scale)) };
    }
};
const projection: Projection = .{};

const Mesh = struct {
    rotation: Rotation,
    center: Vec,
    screen: [8]ui.Point,
    fn init(state: *const State) Mesh {
        var mesh: Mesh = .{ .rotation = state.world.orientation.matrix(), .center = state.world.position, .screen = undefined };
        for (cube_vertices, &mesh.screen) |vertex, *p| p.* = projection.point(mesh.center.add(mesh.rotation.apply(vertex.scale(core.half))));
        return mesh;
    }
};

fn tray(p: ui.Painter, state: *const State) void {
    var points: [4]ui.Point = undefined;
    for (tray_vertices, &points) |v, *q| q.* = projection.point(v);
    p.quad(points, c.panel);
    const r = core.half * (1 + 0.12 * state.world.position.z);
    const height = @max(0, state.world.position.z - core.half);
    const pos = state.world.position.add(.{ .x = height * 0.22, .y = -height * 0.25 });
    const shadow = [_]Vec{ .{ .x = pos.x - r, .y = pos.y - r }, .{ .x = pos.x + r, .y = pos.y - r }, .{ .x = pos.x + r, .y = pos.y + r }, .{ .x = pos.x - r, .y = pos.y + r } };
    var corners: [4]ui.Point = undefined;
    for (shadow, &corners) |v, *q| q.* = projection.point(.{ .x = std.math.clamp(v.x, -core.tray_x, core.tray_x), .y = std.math.clamp(v.y, -core.tray_y, core.tray_y) });
    p.quad(corners, c.background);
    for (0..4) |i| p.line(points[i], points[(i + 1) % 4], c.berry);
}

fn shade(ink: u16, brightness: f32) u16 {
    const amount: u32 = @intFromFloat(std.math.clamp(brightness, 0, 1) * 256);
    return @intCast((((@as(u32, ink >> 11) * amount) >> 8) << 11) |
        (((@as(u32, (ink >> 5) & 63) * amount) >> 8) << 5) |
        ((@as(u32, ink & 31) * amount) >> 8));
}

fn polygon(p: ui.Painter, points: []const ui.Point, ink: u16) void {
    const a: ui.Point = .{ points[0][0] * p.k, points[0][1] * p.k };
    for (1..points.len - 1) |i| {
        const b: ui.Point = .{ points[i][0] * p.k, points[i][1] * p.k };
        const d: ui.Point = .{ points[i + 1][0] * p.k, points[i + 1][1] * p.k };
        p.canvas.triangle(a, b, d, ink);
    }
}

fn die(p: ui.Painter, state: *const State) void {
    const mesh = Mesh.init(state);
    const Visible = struct { index: usize, normal: Vec, depth: f32 };
    var visible: [6]Visible = undefined;
    var count: usize = 0;
    for (faces, 0..) |face, i| {
        const normal = mesh.rotation.apply(face.normal);
        if (normal.z <= 0.00001) continue;
        var j = count;
        while (j > 0 and visible[j - 1].depth > normal.z) : (j -= 1) visible[j] = visible[j - 1];
        visible[j] = .{ .index = i, .normal = normal, .depth = normal.z };
        count += 1;
    }
    for (visible[0..count]) |shown| {
        const face = faces[shown.index];
        const light = @max(0, shown.normal.dot(.{ .x = -0.35, .y = 0.55, .z = 0.76 }));
        var corners: [4]ui.Point = undefined;
        for (face.vertices, &corners) |index, *corner| corner.* = mesh.screen[index];
        polygon(p, &corners, shade(c.berry, 0.48 + 0.52 * light));
        const edge_color = shade(c.rose, 0.42 + 0.58 * light);
        for (0..4) |i| p.line(corners[i], corners[(i + 1) % 4], edge_color);
        const u = mesh.rotation.apply(face.u).scale(core.half);
        const v = mesh.rotation.apply(face.v).scale(core.half);
        const center = mesh.center.add(shown.normal.scale(core.half));
        const pip_color = shade(c.highlight, 0.70 + 0.30 * light);
        for (pip_centers, 0..) |pip, i| {
            if (pip_masks[face.number - 1] & (@as(u7, 1) << @as(u3, @intCast(i))) == 0) continue;
            const origin = center.add(u.scale(pip[0])).add(v.scale(pip[1]));
            var ring: [8]ui.Point = undefined;
            const outline = [_][2]f32{ .{ -1, -0.4142 }, .{ -0.4142, -1 }, .{ 0.4142, -1 }, .{ 1, -0.4142 }, .{ 1, 0.4142 }, .{ 0.4142, 1 }, .{ -0.4142, 1 }, .{ -1, 0.4142 } };
            for (outline, &ring) |offset, *point| point.* = projection.point(origin.add(u.scale(offset[0] * 0.15)).add(v.scale(offset[1] * 0.15)));
            polygon(p, &ring, pip_color);
        }
    }
}

pub fn draw(canvas: pixel.Canvas, state: *const State, now_ms: u64) void {
    const p = ui.Painter.init(canvas);
    body(p);
    p.laceWindow(18, 30, 80, 62);
    p.rect(22, 33, 72, 9, c.surface);
    p.line(.{ 22, 42 }, .{ 93, 42 }, c.berry);
    p.centeredText("DICE", 34, c.text);
    p.rect(23, 82, 70, 8, c.surface);
    mascot(p, now_ms);
    p.heart(7, 73 + ui.bob(now_ms + 250), c.rose);
    p.heart(102, 40 + ui.bob(now_ms + 500), c.rose);
    p.cross(10, 37, c.muted);
    p.cross(101, 74, c.muted);
    tray(p, state);
    die(p, state);
    if (state.rolling()) {
        p.centeredText("TUMBLING", 82, c.rose);
    } else if (state.has_result) {
        var result = "YOU GOT 0".*;
        result[result.len - 1] = '0' + state.face;
        p.centeredText(&result, 82, c.rose);
    } else p.centeredText(if (state.cocked) "TILT / TAP" else "SHAKE / TAP", 82, c.rose);
    p.button("TOSS!", 40, 92, 36, false);
    p.bow(16, 91);
    p.bow(86, 91);
    ui.navigation(canvas, 1, @import("navigation.zig").demo_count, c.rose, c.border);
}

test "physical dice projection and partial updates preserve all chrome at both scales" {
    for ([_]f32{ 0, core.half, core.tray_height }) |height| {
        try std.testing.expectEqualDeep(projection.point(.{ .x = -1, .y = 0.5 }), projection.point(.{ .x = -1, .y = 0.5, .z = height }));
        try std.testing.expectEqualDeep(projection.point(.{ .x = 1, .y = -0.5 }), projection.point(.{ .x = 1, .y = -0.5, .z = height }));
    }
    for ([_]u16{ 4, 2 }) |scale| {
        const viewport = pixel.Viewport.init(scale);
        const source = try std.testing.allocator.alloc(u16, @as(usize, viewport.logical_size) * viewport.logical_size);
        defer std.testing.allocator.free(source);
        const actual = try std.testing.allocator.alloc(u16, 466 * 466);
        defer std.testing.allocator.free(actual);
        const expected = try std.testing.allocator.alloc(u16, actual.len);
        defer std.testing.allocator.free(expected);
        const canvas = pixel.Canvas.init(source, viewport.logical_size, viewport.logical_size);
        var state: State = .{};
        state.reenter(0);
        draw(canvas, &state, 0);
        pixel.expandNearest(canvas, actual, viewport);
        _ = state.roll(0, 17421);
        var now: u64 = 0;
        while (now <= 5000) : (now += 33) {
            _ = state.advance(now, null);
            for (Mesh.init(&state).screen) |p| {
                try std.testing.expect(p[0] >= 25 and p[0] <= 91 and p[1] >= 44 and p[1] <= 80);
            }
            draw(canvas, &state, now);
            const damage = pixel.Damage.between(canvas, actual, viewport);
            for (damage.slice()) |region| pixel.expandNearestRegion(canvas, actual, viewport, region);
            pixel.expandNearest(canvas, expected, viewport);
            try std.testing.expectEqualSlices(u16, expected, actual);
        }
    }
}
