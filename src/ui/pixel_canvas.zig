const std = @import("std");
const theme = @import("theme.zig");

pub const Point = struct { x: u16, y: u16 };
pub const Region = struct { x: u16, y: u16, width: u16, height: u16 };

pub const Viewport = struct {
    pub const panel_size = 466;
    scale: u16,
    logical_size: u16,
    offset: u16,

    pub fn init(scale: u16) Viewport {
        std.debug.assert(scale == 2 or scale == 4);
        const logical_size = panel_size / scale;
        return .{
            .scale = scale,
            .logical_size = logical_size,
            .offset = (panel_size - logical_size * scale) / 2,
        };
    }

    pub fn logicalPoint(self: Viewport, x: u16, y: u16) ?Point {
        const end = self.offset + self.logical_size * self.scale;
        if (x < self.offset or y < self.offset or x >= end or y >= end) return null;
        return .{ .x = (x - self.offset) / self.scale, .y = (y - self.offset) / self.scale };
    }
};

pub const rgb565 = theme.rgb565;

pub const Canvas = struct {
    pixels: []u16,
    width: u16,
    height: u16,

    pub fn init(pixels: []u16, width: u16, height: u16) Canvas {
        std.debug.assert(pixels.len == @as(usize, width) * height);
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    pub fn clear(self: Canvas, color: u16) void {
        @memset(self.pixels, color);
    }

    pub fn pixel(self: Canvas, x: i32, y: i32, color: u16) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))] = color;
    }

    pub fn line(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, color: u16) void {
        var x = x0;
        var y = y0;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx + dy;
        while (true) {
            self.pixel(x, y, color);
            if (x == x1 and y == y1) break;
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

    pub fn rect(self: Canvas, x: i32, y: i32, width: i32, height: i32, color: u16) void {
        const x0 = @max(0, x);
        const y0 = @max(0, y);
        const x1 = @min(@as(i32, self.width), x + width);
        const y1 = @min(@as(i32, self.height), y + height);
        if (x0 >= x1 or y0 >= y1) return;
        for (@as(usize, @intCast(y0))..@as(usize, @intCast(y1))) |row| {
            const start = row * self.width;
            @memset(self.pixels[start + @as(usize, @intCast(x0)) .. start + @as(usize, @intCast(x1))], color);
        }
    }

    pub fn circle(self: Canvas, cx: i32, cy: i32, radius: i32, color: u16) void {
        if (radius < 0) return;
        var remaining = @as(i64, radius) * radius;
        var extent_squared = remaining;
        var extent = radius;
        var dy: i32 = 0;
        while (dy <= radius) : (dy += 1) {
            while (extent_squared > remaining) {
                extent_squared -= 2 * @as(i64, extent) - 1;
                extent -= 1;
            }
            self.rect(cx - extent, cy + dy, extent * 2 + 1, 1, color);
            if (dy != 0) self.rect(cx - extent, cy - dy, extent * 2 + 1, 1, color);
            remaining -= 2 * @as(i64, dy) + 1;
        }
    }

    pub fn triangle(self: Canvas, a: [2]i32, b: [2]i32, c: [2]i32, color: u16) void {
        const area = edge(a, b, c);
        if (area == 0) return;
        const x0 = @max(0, @min(a[0], @min(b[0], c[0])));
        const x1 = @min(@as(i32, self.width) - 1, @max(a[0], @max(b[0], c[0])));
        const y0 = @max(0, @min(a[1], @min(b[1], c[1])));
        const y1 = @min(@as(i32, self.height) - 1, @max(a[1], @max(b[1], c[1])));
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const p = [2]i32{ x, y };
                const e0 = edge(a, b, p);
                const e1 = edge(b, c, p);
                const e2 = edge(c, a, p);
                if (if (area > 0) e0 >= 0 and e1 >= 0 and e2 >= 0 else e0 <= 0 and e1 <= 0 and e2 <= 0) self.pixel(x, y, color);
            }
        }
    }

    fn edge(a: [2]i32, b: [2]i32, p: [2]i32) i32 {
        return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
    }

    pub fn text(self: Canvas, value: []const u8, x: i32, y: i32, scale: i32, color: u16) void {
        var cursor = x;
        for (value) |character| {
            for (glyph(std.ascii.toUpper(character)), 0..) |bits, row| {
                for (0..5) |column| {
                    if (bits & (@as(u5, 1) << @as(u3, @intCast(4 - column))) != 0) {
                        self.rect(cursor + @as(i32, @intCast(column)) * scale, y + @as(i32, @intCast(row)) * scale, scale, scale, color);
                    }
                }
            }
            cursor += 6 * scale;
        }
    }

    pub fn centeredText(self: Canvas, value: []const u8, y: i32, scale: i32, color: u16) void {
        const width = (@as(i32, @intCast(value.len)) * 6 - 1) * scale;
        self.text(value, @divTrunc(@as(i32, self.width) - width, 2), y, scale, color);
    }
};

pub const Damage = struct {
    regions: [32]Region = undefined,
    len: usize = 0,

    pub fn between(canvas: Canvas, target: []const u16, viewport: Viewport) Damage {
        std.debug.assert(canvas.width == viewport.logical_size and canvas.height == viewport.logical_size);
        std.debug.assert(target.len == Viewport.panel_size * Viewport.panel_size);
        var result: Damage = .{};
        var band: u16 = 0;
        while (band < canvas.height) : (band += 8) {
            const end = @min(band + 8, canvas.height);
            var x0 = canvas.width;
            var x1: u16 = 0;
            var y0 = end;
            var y1 = band;
            var y = band;
            while (y < end) : (y += 1) {
                const row = (@as(usize, viewport.offset) + @as(usize, y) * viewport.scale) * Viewport.panel_size + viewport.offset;
                var x: u16 = 0;
                while (x < canvas.width) : (x += 1) {
                    if (canvas.pixels[@as(usize, y) * canvas.width + x] == target[row + @as(usize, x) * viewport.scale]) continue;
                    x0 = @min(x0, x);
                    x1 = @max(x1, x + 1);
                    y0 = @min(y0, y);
                    y1 = @max(y1, y + 1);
                }
            }
            if (x0 == canvas.width) continue;
            if (result.len > 0) {
                const last = &result.regions[result.len - 1];
                if (last.x == x0 and last.width == x1 - x0 and last.y + last.height == y0) {
                    last.height = y1 - last.y;
                    continue;
                }
            }
            result.regions[result.len] = .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
            result.len += 1;
        }
        return result;
    }

    pub fn slice(self: *const Damage) []const Region {
        return self.regions[0..self.len];
    }
};

pub fn expandNearest(canvas: Canvas, target: []u16, viewport: Viewport) void {
    const panel: usize = Viewport.panel_size;
    const offset: usize = viewport.offset;
    const scale: usize = viewport.scale;
    const size: usize = viewport.logical_size;
    std.debug.assert(canvas.width == size and canvas.height == size);
    std.debug.assert(target.len == panel * panel);
    @memset(target[0 .. offset * panel], 0);
    @memset(target[(panel - offset) * panel ..], 0);
    for (0..size) |y| {
        const physical_y = offset + y * scale;
        const row = target[physical_y * panel ..][0..panel];
        @memset(row[0..offset], 0);
        @memset(row[offset + size * scale ..], 0);
        for (canvas.pixels[y * size ..][0..size], 0..) |color, x| {
            @memset(row[offset + x * scale ..][0..scale], color);
        }
        for (1..scale) |repeat| {
            @memcpy(target[(physical_y + repeat) * panel ..][0..panel], row);
        }
    }
}

/// The target must have been initialized once with expandNearest.
pub fn expandNearestRegion(canvas: Canvas, target: []u16, viewport: Viewport, region: Region) void {
    const panel: usize = Viewport.panel_size;
    const scale: usize = viewport.scale;
    const size: usize = viewport.logical_size;
    std.debug.assert(canvas.width == size and canvas.height == size and target.len == panel * panel);
    std.debug.assert(region.x + region.width <= size and region.y + region.height <= size);
    const physical_x: usize = viewport.offset + region.x * viewport.scale;
    const width = @as(usize, region.width) * scale;
    for (region.y..@as(usize, region.y) + region.height) |y| {
        const physical_y = viewport.offset + y * scale;
        const row = target[physical_y * panel + physical_x ..][0..width];
        for (canvas.pixels[y * size + region.x ..][0..region.width], 0..) |color, x| {
            @memset(row[x * scale ..][0..scale], color);
        }
        for (1..scale) |repeat| @memcpy(target[(physical_y + repeat) * panel + physical_x ..][0..width], row);
    }
}

fn glyph(character: u8) [7]u5 {
    return switch (character) {
        'A' => .{ 14, 17, 17, 31, 17, 17, 17 },
        'B' => .{ 30, 17, 17, 30, 17, 17, 30 },
        'C' => .{ 14, 17, 16, 16, 16, 17, 14 },
        'D' => .{ 30, 17, 17, 17, 17, 17, 30 },
        'E' => .{ 31, 16, 16, 30, 16, 16, 31 },
        'F' => .{ 31, 16, 16, 30, 16, 16, 16 },
        'G' => .{ 14, 17, 16, 23, 17, 17, 15 },
        'H' => .{ 17, 17, 17, 31, 17, 17, 17 },
        'I' => .{ 14, 4, 4, 4, 4, 4, 14 },
        'J' => .{ 7, 2, 2, 2, 2, 18, 12 },
        'K' => .{ 17, 18, 20, 24, 20, 18, 17 },
        'L' => .{ 16, 16, 16, 16, 16, 16, 31 },
        'M' => .{ 17, 27, 21, 21, 17, 17, 17 },
        'N' => .{ 17, 25, 21, 19, 17, 17, 17 },
        'O' => .{ 14, 17, 17, 17, 17, 17, 14 },
        'P' => .{ 30, 17, 17, 30, 16, 16, 16 },
        'Q' => .{ 14, 17, 17, 17, 21, 18, 13 },
        'R' => .{ 30, 17, 17, 30, 20, 18, 17 },
        'S' => .{ 15, 16, 16, 14, 1, 1, 30 },
        'T' => .{ 31, 4, 4, 4, 4, 4, 4 },
        'U' => .{ 17, 17, 17, 17, 17, 17, 14 },
        'V' => .{ 17, 17, 17, 17, 17, 10, 4 },
        'W' => .{ 17, 17, 17, 21, 21, 21, 10 },
        'X' => .{ 17, 17, 10, 4, 10, 17, 17 },
        'Y' => .{ 17, 17, 10, 4, 4, 4, 4 },
        'Z' => .{ 31, 1, 2, 4, 8, 16, 31 },
        '0' => .{ 14, 17, 19, 21, 25, 17, 14 },
        '1' => .{ 4, 12, 4, 4, 4, 4, 14 },
        '2' => .{ 14, 17, 1, 2, 4, 8, 31 },
        '3' => .{ 30, 1, 1, 14, 1, 1, 30 },
        '4' => .{ 2, 6, 10, 18, 31, 2, 2 },
        '5' => .{ 31, 16, 16, 30, 1, 1, 30 },
        '6' => .{ 14, 16, 16, 30, 17, 17, 14 },
        '7' => .{ 31, 1, 2, 4, 8, 8, 8 },
        '8' => .{ 14, 17, 17, 14, 17, 17, 14 },
        '9' => .{ 14, 17, 17, 15, 1, 1, 14 },
        '.' => .{ 0, 0, 0, 0, 0, 12, 12 },
        '!' => .{ 4, 4, 4, 4, 4, 0, 4 },
        '-' => .{ 0, 0, 0, 31, 0, 0, 0 },
        '+' => .{ 0, 4, 4, 31, 4, 4, 0 },
        '/' => .{ 1, 1, 2, 4, 8, 16, 16 },
        '%' => .{ 25, 25, 2, 4, 8, 19, 19 },
        else => .{ 0, 0, 0, 0, 0, 0, 0 },
    };
}

test "4x viewport keeps a one-pixel border and maps touch blocks" {
    const viewport = Viewport.init(4);
    try std.testing.expectEqual(@as(u16, 116), viewport.logical_size);
    try std.testing.expectEqual(@as(u16, 1), viewport.offset);
    try std.testing.expectEqual(null, viewport.logicalPoint(0, 1));
    try std.testing.expectEqual(null, viewport.logicalPoint(465, 1));
    try std.testing.expectEqual(@as(?Point, .{ .x = 0, .y = 0 }), viewport.logicalPoint(4, 4));
    try std.testing.expectEqual(@as(?Point, .{ .x = 1, .y = 1 }), viewport.logicalPoint(5, 5));
    try std.testing.expectEqual(@as(?Point, .{ .x = 115, .y = 115 }), viewport.logicalPoint(464, 464));
}

test "2x viewport fills the panel and reaches the last logical pixel" {
    const viewport = Viewport.init(2);
    try std.testing.expectEqual(@as(u16, 233), viewport.logical_size);
    try std.testing.expectEqual(@as(u16, 0), viewport.offset);
    try std.testing.expectEqual(@as(?Point, .{ .x = 232, .y = 232 }), viewport.logicalPoint(465, 465));
}

test "lines include endpoints in all octants and clip at canvas edges" {
    var buffer: [11 * 11]u16 = undefined;
    const canvas = Canvas.init(&buffer, 11, 11);
    for ([_][2]i32{ .{ 9, 7 }, .{ 7, 9 }, .{ 3, 9 }, .{ 1, 7 }, .{ 1, 3 }, .{ 3, 1 }, .{ 7, 1 }, .{ 9, 3 }, .{ 5, 5 } }) |end| {
        canvas.clear(0);
        canvas.line(5, 5, end[0], end[1], 1);
        try std.testing.expectEqual(@as(u16, 1), buffer[5 * 11 + 5]);
        try std.testing.expectEqual(@as(u16, 1), buffer[@as(usize, @intCast(end[1] * 11 + end[0]))]);
        var count: usize = 0;
        for (buffer) |color| count += color;
        try std.testing.expectEqual(@as(usize, @max(@abs(end[0] - 5), @abs(end[1] - 5))) + 1, count);
    }
    canvas.clear(0);
    canvas.line(-2, -2, 12, 12, 1);
    for (buffer, 0..) |color, index| try std.testing.expectEqual(@as(u16, if (index / 11 == index % 11) 1 else 0), color);
}

test "scanline circles exactly match distance coverage at clipped edges and zero radius" {
    var buffer: [53 * 47]u16 = undefined;
    const canvas = Canvas.init(&buffer, 53, 47);
    for ([_]i32{ -1, 0, 1, 2, 3, 7, 15, 24, 50, 150 }) |radius| {
        for ([_][2]i32{ .{ 26, 23 }, .{ 0, 0 }, .{ 52, 46 }, .{ -8, 20 }, .{ 40, 55 } }) |center| {
            canvas.clear(0x1234);
            canvas.circle(center[0], center[1], radius, 0xABCD);
            for (buffer, 0..) |ink, i| {
                const dx = @as(i32, @intCast(i % 53)) - center[0];
                const dy = @as(i32, @intCast(i / 53)) - center[1];
                const expected: u16 = if (radius >= 0 and dx * dx + dy * dy <= radius * radius) 0xABCD else 0x1234;
                try std.testing.expectEqual(expected, ink);
            }
        }
    }
}

test "row expansion matches every nearest-neighbor pixel and clears panel borders" {
    var source: [233 * 233]u16 = undefined;
    var target: [Viewport.panel_size * Viewport.panel_size]u16 = @splat(0xFFFF);
    for ([_]u16{ 4, 2 }) |scale| {
        const viewport = Viewport.init(scale);
        const canvas = Canvas.init(source[0 .. @as(usize, viewport.logical_size) * viewport.logical_size], viewport.logical_size, viewport.logical_size);
        for (canvas.pixels, 0..) |*color, index| color.* = @intCast(index);
        expandNearest(canvas, &target, viewport);
        for (target, 0..) |color, index| {
            const point = viewport.logicalPoint(@intCast(index % Viewport.panel_size), @intCast(index / Viewport.panel_size));
            const expected = if (point) |p| canvas.pixels[@as(usize, p.y) * canvas.width + p.x] else 0;
            try std.testing.expectEqual(expected, color);
        }
    }
}

test "damage refresh matches full refresh after sparse changes at both pixel scales" {
    var source: [233 * 233]u16 = undefined;
    var target: [Viewport.panel_size * Viewport.panel_size]u16 = undefined;
    var expected: [Viewport.panel_size * Viewport.panel_size]u16 = undefined;
    for ([_]u16{ 4, 2 }) |scale| {
        const viewport = Viewport.init(scale);
        const canvas = Canvas.init(source[0 .. @as(usize, viewport.logical_size) * viewport.logical_size], viewport.logical_size, viewport.logical_size);
        canvas.clear(0x1234);
        expandNearest(canvas, &target, viewport);
        try std.testing.expectEqual(@as(usize, 0), Damage.between(canvas, &target, viewport).len);
        canvas.rect(-2, 7, 17, 26, 0xABCD);
        canvas.circle(90, 80, 7, 0x4321);
        canvas.pixel(canvas.width - 1, canvas.height - 1, 0xFFFF);
        const damage = Damage.between(canvas, &target, viewport);
        try std.testing.expect(damage.len > 0 and damage.len < 16);
        for (damage.slice()) |region| expandNearestRegion(canvas, &target, viewport, region);
        expandNearest(canvas, &expected, viewport);
        try std.testing.expectEqualSlices(u16, &expected, &target);
        try std.testing.expectEqual(@as(usize, 0), Damage.between(canvas, &target, viewport).len);
        canvas.clear(0x9876);
        const full_damage = Damage.between(canvas, &target, viewport);
        for (full_damage.slice()) |region| expandNearestRegion(canvas, &target, viewport, region);
        expandNearest(canvas, &expected, viewport);
        try std.testing.expectEqualSlices(u16, &expected, &target);
    }
}
