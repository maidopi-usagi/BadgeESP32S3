const pixel = @import("pixel_canvas.zig");
const theme = @import("theme.zig").colors;

pub const color = struct {
    pub const ink = theme.background;
    pub const shadow = theme.border;
    pub const rose = theme.rose;
    pub const blush = theme.surface;
    pub const pale = theme.muted;
    pub const paper = theme.text;
    pub const lilac = theme.accent;
    pub const accent = theme.berry;
};

pub const Point = [2]i32;
pub fn phase(time_ms: u64, frame_ms: u64, count: u32) u32 {
    return @intCast(time_ms / frame_ms % count);
}
pub fn bob(time_ms: u64) i32 {
    return ([_]i32{ 0, -1, 0, 1 })[phase(time_ms, 250, 4)];
}

/// All widgets use a 116-unit grid, drawn at 1x, 2x or 4x logical size.
pub const Painter = struct {
    canvas: pixel.Canvas,
    k: i32,

    pub fn init(canvas: pixel.Canvas) Painter {
        return .{ .canvas = canvas, .k = if (canvas.width >= 464) 4 else if (canvas.width >= 232) 2 else 1 };
    }
    pub fn rect(self: Painter, x: i32, y: i32, w: i32, h: i32, ink: u16) void {
        self.canvas.rect(x * self.k, y * self.k, w * self.k, h * self.k, ink);
    }
    pub fn dot(self: Painter, x: i32, y: i32, ink: u16) void {
        self.rect(x, y, 1, 1, ink);
    }
    pub fn line(self: Painter, a: Point, b: Point, ink: u16) void {
        var x = a[0];
        var y = a[1];
        const dx: i32 = @intCast(@abs(b[0] - x));
        const dy: i32 = -@as(i32, @intCast(@abs(b[1] - y)));
        const sx: i32 = if (x < b[0]) 1 else -1;
        const sy: i32 = if (y < b[1]) 1 else -1;
        var err = dx + dy;
        while (true) {
            self.dot(x, y, ink);
            if (x == b[0] and y == b[1]) break;
            const twice = err * 2;
            if (twice >= dy) {
                err += dy;
                x += sx;
            }
            if (twice <= dx) {
                err += dx;
                y += sy;
            }
        }
    }
    pub fn circle(self: Painter, x: i32, y: i32, r: i32, ink: u16) void {
        if (r < 0) return;
        var extent = r;
        var dy: i32 = 0;
        while (dy <= r) : (dy += 1) {
            while (extent * extent + dy * dy > r * r) extent -= 1;
            self.rect(x - extent, y + dy, extent * 2 + 1, 1, ink);
            if (dy != 0) self.rect(x - extent, y - dy, extent * 2 + 1, 1, ink);
        }
    }
    pub fn quad(self: Painter, points: [4]Point, ink: u16) void {
        var scaled: [4]Point = undefined;
        for (points, 0..) |p, i| scaled[i] = .{ p[0] * self.k, p[1] * self.k };
        self.canvas.triangle(scaled[0], scaled[1], scaled[2], ink);
        self.canvas.triangle(scaled[0], scaled[2], scaled[3], ink);
        for (0..4) |i| self.line(points[i], points[(i + 1) % 4], theme.border);
    }
    pub fn text(self: Painter, value: []const u8, x: i32, y: i32, ink: u16) void {
        self.canvas.text(value, x * self.k, y * self.k, self.k, ink);
    }
    pub fn centeredText(self: Painter, value: []const u8, y: i32, ink: u16) void {
        self.text(value, @divTrunc(116 - (@as(i32, @intCast(value.len)) * 6 - 1), 2), y, ink);
    }
    pub fn sprite(self: Painter, rows: []const []const u8, x: i32, y: i32, inks: []const u16) void {
        for (rows, 0..) |row, dy| {
            for (row, 0..) |entry, dx| {
                if (entry >= '0' and entry <= '9' and entry - '0' < inks.len)
                    self.dot(x + @as(i32, @intCast(dx)), y + @as(i32, @intCast(dy)), inks[entry - '0']);
            }
        }
    }
    pub fn heart(self: Painter, x: i32, y: i32, ink: u16) void {
        self.sprite(&.{ ".00.00.", "0000000", "0000000", ".00000.", "..000..", "...0..." }, x, y, &.{ink});
    }
    pub fn bow(self: Painter, x: i32, y: i32) void {
        self.sprite(&.{
            ".000.......000.", "01100.....00110", "011100...001110", "011110000011110",
            "011100110001110", ".0000011100000.", "..00001110000..", "...001000100...",
            "..0010...0100..", ".00110...01100.", ".0000.....0000.",
        }, x, y, &.{ theme.rose, theme.berry });
    }
    pub fn cross(self: Painter, x: i32, y: i32, ink: u16) void {
        self.rect(x + 2, y, 1, 9, ink);
        self.rect(x, y + 2, 5, 1, ink);
        self.dot(x + 2, y + 8, theme.highlight);
    }
    pub fn sparkle(self: Painter, x: i32, y: i32, large: bool, ink: u16) void {
        const r: i32 = if (large) 3 else 1;
        self.rect(x - r, y, r * 2 + 1, 1, ink);
        self.rect(x, y - r, 1, r * 2 + 1, ink);
        if (large) self.rect(x - 1, y - 1, 3, 3, ink);
    }
    pub fn panel(self: Painter, x: i32, y: i32, w: i32, h: i32, fill: u16) void {
        self.rect(x + 2, y, w - 4, h, theme.border);
        self.rect(x, y + 2, w, h - 4, theme.border);
        self.rect(x + 2, y + 1, w - 4, h - 2, fill);
        self.rect(x + 1, y + 2, w - 2, h - 4, fill);
    }
    pub fn laceWindow(self: Painter, x: i32, y: i32, w: i32, h: i32) void {
        var xx = x + 3;
        while (xx < x + w) : (xx += 6) {
            self.circle(xx, y, 3, theme.border);
            self.circle(xx, y + h - 1, 3, theme.border);
            self.dot(xx, y - 1, theme.muted);
            self.dot(xx, y + h, theme.muted);
        }
        var yy = y + 3;
        while (yy < y + h) : (yy += 6) {
            self.circle(x, yy, 3, theme.border);
            self.circle(x + w - 1, yy, 3, theme.border);
            self.dot(x - 1, yy, theme.muted);
            self.dot(x + w, yy, theme.muted);
        }
        self.panel(x, y, w, h, theme.berry);
        self.panel(x + 2, y + 2, w - 4, h - 4, theme.panel);
    }
    pub fn button(self: Painter, label: []const u8, x: i32, y: i32, w: i32, pressed: bool) void {
        self.panel(x, y, w, 12, if (pressed) theme.berry else theme.surface);
        self.line(.{ x + 2, y + 1 }, .{ x + w - 3, y + 1 }, if (pressed) theme.border else theme.rose);
        self.line(.{ x + 1, y + 2 }, .{ x + 1, y + 9 }, if (pressed) theme.border else theme.rose);
        self.line(.{ x + 2, y + 10 }, .{ x + w - 3, y + 10 }, theme.background);
        const width = @as(i32, @intCast(label.len)) * 6 - 1;
        self.text(label, x + @divTrunc(w - width, 2), y + 2 + @as(i32, if (pressed) 1 else 0), theme.text);
    }
};

pub fn navigation(canvas: pixel.Canvas, active: usize, count: usize, ink: u16, dim: u16) void {
    const p = Painter.init(canvas);
    p.line(.{ 5, 54 }, .{ 8, 57 }, dim);
    p.line(.{ 8, 57 }, .{ 5, 60 }, dim);
    p.line(.{ 110, 54 }, .{ 107, 57 }, dim);
    p.line(.{ 107, 57 }, .{ 110, 60 }, dim);
    const start = @divTrunc(116 - @as(i32, @intCast(count)) * 6 + 3, 2);
    for (0..count) |i| p.rect(start + @as(i32, @intCast(i)) * 6, 110, 3, 2, if (i == active) ink else dim);
}

test "scaled circle spans preserve block coverage and clipping" {
    const std = @import("std");
    for ([_]u16{ 116, 233, 466 }) |size| {
        const actual = try std.testing.allocator.alloc(u16, @as(usize, size) * size);
        defer std.testing.allocator.free(actual);
        const expected = try std.testing.allocator.alloc(u16, actual.len);
        defer std.testing.allocator.free(expected);
        const p = Painter.init(pixel.Canvas.init(actual, size, size));
        const reference = Painter.init(pixel.Canvas.init(expected, size, size));
        for ([_]i32{ -1, 0, 1, 3, 12, 56 }) |radius| {
            for ([_]Point{ .{ -1, 7 }, .{ 58, 58 }, .{ 113, 115 } }) |center| {
                @memset(actual, 0);
                @memset(expected, 0);
                p.circle(center[0], center[1], radius, 0x1234);
                var y = -radius;
                while (y <= radius) : (y += 1) {
                    var x = -radius;
                    while (x <= radius) : (x += 1) {
                        if (x * x + y * y <= radius * radius) reference.dot(center[0] + x, center[1] + y, 0x1234);
                    }
                }
                try std.testing.expectEqualSlices(u16, expected, actual);
            }
        }
    }
}
