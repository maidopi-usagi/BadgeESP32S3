//! Decorations must stay outside the simulation surface for incremental erasure.
const pixel = @import("pixel_canvas.zig");
const jirai = @import("jirai.zig");
const navigation = @import("navigation.zig");
const colors = @import("theme.zig").colors;

pub const origin_x = 73;
pub const origin_y = 66;
pub const reset_region: pixel.Region = .{ .x = 194, .y = 389, .width = 78, .height = 22 };

pub fn contains(region: pixel.Region, x: i32, y: i32) bool {
    return x >= region.x and x < @as(i32, region.x) + region.width and y >= region.y and y < @as(i32, region.y) + region.height;
}

pub fn begin(canvas: pixel.Canvas, title: []const u8, subtitle: []const u8) void {
    canvas.clear(colors.background);
    const p: jirai.Painter = .{ .canvas = canvas, .k = 2 };
    p.bow(109, 3);
    canvas.line(183, 17, 209, 17, colors.border);
    canvas.line(257, 17, 283, 17, colors.border);
    canvas.rect(179, 16, 2, 3, colors.berry);
    canvas.rect(285, 16, 2, 3, colors.berry);
    canvas.centeredText(title, 30, 3, colors.text);
    canvas.centeredText(subtitle, 57, 1, colors.muted);
}

pub fn tank(canvas: pixel.Canvas) void {
    canvas.circle(233, 226, 150, colors.border);
    canvas.circle(233, 226, 148, colors.berry);
    canvas.circle(233, 226, 146, colors.surface);
    const offsets = [_][2]i32{ .{ 0, 157 }, .{ 41, 152 }, .{ 79, 136 }, .{ 111, 111 }, .{ 136, 79 }, .{ 152, 41 } };
    for (offsets) |point| for (0..4) |quadrant| {
        const x = 233 + switch (quadrant) {
            0 => point[0],
            1 => point[1],
            2 => -point[0],
            else => -point[1],
        };
        const y = 226 + switch (quadrant) {
            0 => point[1],
            1 => -point[0],
            2 => -point[1],
            else => point[0],
        };
        canvas.circle(x, y, 2, colors.border);
        canvas.pixel(x, y, colors.rose);
    };
}

pub fn button(canvas: pixel.Canvas, region: pixel.Region, label: []const u8, ink: u16) void {
    const x: i32 = region.x;
    const y: i32 = region.y;
    const w: i32 = region.width;
    const h: i32 = region.height;
    canvas.rect(x, y, w, h, colors.border);
    canvas.rect(x + 1, y + 1, w - 2, h - 2, colors.panel);
    canvas.line(x + 4, y + 1, x + w - 5, y + 1, colors.berry);
    const width = @as(i32, @intCast(label.len)) * 12 - 2;
    canvas.text(label, x + @divTrunc(w - width, 2), y + 4, 2, ink);
}

pub fn reset(canvas: pixel.Canvas) void {
    button(canvas, reset_region, "RESET", colors.rose);
}

pub fn finish(canvas: pixel.Canvas, page: usize) void {
    const p: jirai.Painter = .{ .canvas = canvas, .k = 2 };
    p.heart(113, 209, colors.berry);
    canvas.line(191, 424, 215, 424, colors.border);
    canvas.line(250, 424, 274, 424, colors.border);
    jirai.navigation(canvas, page, navigation.demo_count, colors.rose, colors.border);
}
