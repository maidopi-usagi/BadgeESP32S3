const std = @import("std");
pub const tracer = @import("../render/pathtracer.zig");
const pixel = @import("pixel_canvas.zig");
const ui = @import("jirai.zig");
const colors = @import("theme.zig").colors;
pub const resolution = 233;
pub const display_resolution = 466;
pub const display_scale = 2;
const viewport = pixel.Viewport.init(display_scale);
pub const Command = struct { active: bool, generation: u32, seed: u32, pause_ticket: u32 = 0 };
pub const Packet = struct { generation: u32, failed: bool = false, bucket: tracer.Bucket };

pub const View = struct {
    allocator: std.mem.Allocator,
    pixels: []align(16) u16,
    size: u16,
    generation: u32 = 1,
    seed: u32 = 0xC04E11,
    samples: u32 = 0,
    completed: u32 = 0,
    total: u32 = 1,
    failed: bool = false,
    shown_samples: u32 = 0,
    shown_progress: u32 = 0,
    last_hud_ms: u64 = 0,
    pub fn init(allocator: std.mem.Allocator, size: u16) !View {
        const pixels = try allocator.alignedAlloc(u16, .@"16", @as(usize, size) * size);
        @memset(pixels, 0);
        return .{ .allocator = allocator, .pixels = pixels, .size = size };
    }
    pub fn deinit(self: *View) void {
        self.allocator.free(self.pixels);
    }
    pub fn reset(self: *View, seed: u32) void {
        self.generation +%= 1;
        self.seed = seed;
        self.samples = 0;
        self.completed = 0;
        self.total = 1;
        self.shown_samples = 0;
        self.shown_progress = 0;
        self.last_hud_ms = 0;
        @memset(self.pixels, 0);
    }
    pub fn command(self: View, active: bool) Command {
        return .{ .active = active, .generation = self.generation, .seed = self.seed };
    }
    pub fn accept(self: *View, packet: Packet) bool {
        if (packet.failed) {
            // A terminated producer's allocation failure applies to the whole
            // session, including a reset that raced with its initialization.
            self.failed = true;
            return true;
        }
        if (packet.generation != self.generation) return false;
        const tile = packet.bucket;
        const r = tile.region;
        std.debug.assert(r.x + r.width <= self.size and r.y + r.height <= self.size);
        for (0..r.height) |dy| {
            const start = (@as(usize, r.y) + dy) * self.size + r.x;
            @memcpy(self.pixels[start..][0..r.width], tile.pixels[dy * tracer.bucket_size ..][0..r.width]);
        }
        self.samples = tile.samples - @as(u32, if (tile.completed_buckets == tile.total_buckets) 0 else 1);
        self.completed = if (tile.completed_buckets == tile.total_buckets) 0 else tile.completed_buckets;
        self.total = tile.total_buckets;
        return true;
    }
    pub fn advanceHud(self: *View, now_ms: u64) bool {
        const progress = self.completed * 200 / self.total;
        if (self.shown_samples == self.samples and self.shown_progress == progress) return false;
        if (self.shown_samples == self.samples and now_ms -| self.last_hud_ms < 500) return false;
        self.shown_samples = self.samples;
        self.shown_progress = progress;
        self.last_hud_ms = now_ms;
        return true;
    }
    pub fn paintRegion(self: View, canvas: pixel.Canvas, r: tracer.Region) void {
        if (canvas.width != self.size) {
            std.debug.assert(self.size == resolution and canvas.width == display_resolution and canvas.height == display_resolution);
            pixel.expandNearestRegion(pixel.Canvas.init(self.pixels, self.size, self.size), canvas.pixels, viewport, .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height });
            return;
        }
        std.debug.assert(canvas.height == self.size);
        for (0..r.height) |dy| {
            const start = (@as(usize, r.y) + dy) * self.size + r.x;
            @memcpy(canvas.pixels[start..][0..r.width], self.pixels[start..][0..r.width]);
        }
    }
    pub fn paint(self: View, canvas: pixel.Canvas) void {
        if (canvas.width != self.size) {
            std.debug.assert(self.size == resolution and canvas.width == display_resolution and canvas.height == display_resolution);
            pixel.expandNearest(pixel.Canvas.init(self.pixels, self.size, self.size), canvas.pixels, viewport);
        } else {
            std.debug.assert(canvas.pixels.len == self.pixels.len);
            @memcpy(canvas.pixels, self.pixels);
        }
        self.overlay(canvas);
    }
    pub fn overlay(self: View, canvas: pixel.Canvas) void {
        if (canvas.width != display_resolution) return;
        chrome(canvas);
        canvas.rect(126, 397, 214, 32, colors.background);
        canvas.rect(130, 398, 206, 1, colors.border);
        var buffer: [24]u8 = undefined;
        const label = if (self.failed) "UNAVAILABLE" else std.fmt.bufPrint(&buffer, "SPP {d}", .{self.shown_samples}) catch unreachable;
        canvas.centeredText(label, 404, 2, colors.text);
        canvas.rect(133, 426, 200, 3, colors.surface);
        canvas.rect(133, 426, @intCast(self.shown_progress), 3, colors.rose);
    }
};

pub fn physicalRegion(r: tracer.Region) pixel.Region {
    return .{ .x = r.x * display_scale, .y = r.y * display_scale, .width = r.width * display_scale, .height = r.height * display_scale };
}

pub fn chrome(canvas: pixel.Canvas) void {
    canvas.rect(139, 22, 188, 36, colors.background);
    canvas.rect(149, 23, 168, 1, colors.border);
    canvas.rect(149, 56, 168, 1, colors.border);
    canvas.centeredText("CORNELL", 29, 3, colors.text);
    const ornament: ui.Painter = .{ .canvas = canvas, .k = 2 };
    ornament.sparkle(72, 20, true, colors.berry);
    ornament.sparkle(160, 20, true, colors.berry);
    ui.navigation(canvas, 2, @import("navigation.zig").demo_count, colors.rose, colors.border);
}

pub fn waiting(canvas: pixel.Canvas) void {
    canvas.clear(colors.background);
    chrome(canvas);
    canvas.centeredText("STARTING", 404, 2, colors.muted);
}

test "partial Cornell expansion including clipped edge tiles matches complete display expansion" {
    var view = try View.init(std.testing.allocator, resolution);
    defer view.deinit();
    const partial = try std.testing.allocator.alloc(u16, display_resolution * display_resolution);
    defer std.testing.allocator.free(partial);
    const full = try std.testing.allocator.alloc(u16, display_resolution * display_resolution);
    defer std.testing.allocator.free(full);
    @memset(partial, 0);
    for (view.pixels, 0..) |*value, i| value.* = @truncate(i *% 31337);
    var y: u16 = 0;
    while (y < resolution) : (y += tracer.bucket_size) {
        var x: u16 = 0;
        while (x < resolution) : (x += tracer.bucket_size) {
            view.paintRegion(pixel.Canvas.init(partial, display_resolution, display_resolution), .{ .x = x, .y = y, .width = @min(tracer.bucket_size, resolution - x), .height = @min(tracer.bucket_size, resolution - y) });
        }
    }
    view.overlay(pixel.Canvas.init(partial, display_resolution, display_resolution));
    view.paint(pixel.Canvas.init(full, display_resolution, display_resolution));
    try std.testing.expectEqualSlices(u16, full, partial);
}

test "reset rejects an in-flight old generation and page reentry preserves the cache" {
    var view = try View.init(std.testing.allocator, 19);
    defer view.deinit();
    const bucket: tracer.Bucket = .{ .region = .{ .x = 16, .y = 16, .width = 3, .height = 3 }, .pixels = @splat(123), .samples = 1, .completed_buckets = 9, .total_buckets = 9, .counters = .{} };
    const packet: Packet = .{ .generation = view.generation, .bucket = bucket };
    try std.testing.expect(view.accept(packet));
    try std.testing.expect(!view.command(false).active);
    try std.testing.expect(view.command(true).active);
    try std.testing.expectEqual(@as(u16, 123), view.pixels[18 * 19 + 18]);
    view.reset(456);
    try std.testing.expect(!view.accept(packet));
    try std.testing.expectEqual(@as(u32, 0), view.samples);
    for (view.pixels) |value| try std.testing.expectEqual(@as(u16, 0), value);
    try std.testing.expect(view.accept(.{ .generation = view.generation, .bucket = bucket }));
    try std.testing.expectEqual(@as(u16, 123), view.pixels[18 * 19 + 18]);
    try std.testing.expect(view.accept(.{ .generation = packet.generation, .failed = true, .bucket = undefined }));
    try std.testing.expect(view.failed);
}
