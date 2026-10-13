const std = @import("std");
const pixel = @import("pixel_canvas.zig");
const theme = @import("theme.zig").colors;

pub fn horizon(height: u16) u16 {
    return height * 53 / 100;
}

pub fn drawSun(canvas: pixel.Canvas, shift_x: i32, shift_y: i32) void {
    const width: i32 = canvas.width;
    const height: i32 = canvas.height;
    const cx = @divTrunc(width, 2) + shift_x;
    const cy = @divTrunc(height * 40, 100) + shift_y;
    const radius = @divTrunc(height * 23, 100);
    const k: i32 = if (width >= 200) 2 else 1;
    var y = cy - radius;
    while (y < horizon(canvas.height)) : (y += 1) {
        if (y > cy and @mod(@divTrunc(y - cy, k), 5) >= 3) continue;
        const color = pixel.rgb565(if (y < cy - 6 * k) @as(u24, 0x61394E) else if (y < cy + 5 * k) 0x4A2944 else 0x36213C);
        var x = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius) canvas.pixel(x, y, color);
        }
    }
}

fn dot(canvas: pixel.Canvas, depth: []const u16, x: i32, y: i32, color: u16) void {
    if (x < 0 or y < 0 or x >= canvas.width or y >= canvas.height) return;
    const index = @as(usize, @intCast(y)) * canvas.width + @as(usize, @intCast(x));
    if (depth[index] == 0) canvas.pixels[index] = color;
}

fn line(canvas: pixel.Canvas, depth: []const u16, x0: i32, y0: i32, x1: i32, y1: i32, color: u16) void {
    var x = x0;
    var y = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        dot(canvas, depth, x, y, color);
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

pub fn drawFloor(canvas: pixel.Canvas, time_ms: u64, depth: []const u16, shift_x: i32) void {
    std.debug.assert(depth.len == canvas.pixels.len);
    const width: i32 = canvas.width;
    const height: i32 = canvas.height;
    const top: i32 = horizon(canvas.height);
    const bottom = height - 21 * (if (width >= 200) @as(i32, 2) else 1);
    const center = @divTrunc(width, 2) + shift_x;
    const far = theme.surface;
    const near = theme.border;
    for (@as(usize, @intCast(top))..@as(usize, @intCast(bottom + 1))) |y| {
        for (0..canvas.width) |x| {
            const index = y * canvas.width + x;
            if (depth[index] == 0) canvas.pixels[index] = theme.background;
        }
    }
    line(canvas, depth, 0, top, width - 1, top, theme.berry);
    for (0..11) |i| {
        const end_x = @divTrunc((@as(i32, @intCast(i)) - 5) * width, 5) + center;
        var end_y = bottom;
        var x = end_x;
        if (end_x < 0 or end_x >= width) {
            x = if (end_x < 0) 0 else width - 1;
            end_y = top + @divTrunc((bottom - top) * (x - center), end_x - center);
        }
        const middle_y = top + @divTrunc(end_y - top, 2);
        const middle_x = center + @divTrunc(x - center, 2);
        line(canvas, depth, center, top, middle_x, middle_y, far);
        line(canvas, depth, middle_x, middle_y, x, end_y, near);
    }
    const phase = @as(f32, @floatFromInt(time_ms % 1100)) / 1100;
    for (1..19) |row| {
        const z = @as(f32, @floatFromInt(row)) - phase;
        const offset = @as(f32, @floatFromInt(bottom - top)) / z;
        if (offset > @as(f32, @floatFromInt(bottom - top))) continue;
        const y = top + @as(i32, @intFromFloat(offset));
        line(canvas, depth, 0, y, width - 1, y, if (y < top + @divTrunc(bottom - top, 3)) far else near);
    }
}
