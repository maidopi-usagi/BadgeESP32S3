const std = @import("std");
const theme = @import("theme.zig");
const ui = @import("jirai.zig");
const asset = @import("fumo_asset").bytes;
pub const pixel = @import("pixel_canvas.zig");
pub const interaction = @import("fumo_interaction.zig");
const grid = @import("synth_grid.zig");
pub const Pose = interaction.Pose;

pub const texture_size = std.mem.readInt(u16, asset[6..8], .little);
pub const vertex_count = std.mem.readInt(u32, asset[8..12], .little);
pub const triangle_count = std.mem.readInt(u32, asset[12..16], .little);
const texture_offset = std.mem.readInt(u32, asset[24..28], .little);

comptime {
    std.debug.assert(std.mem.eql(u8, asset[0..4], "FUM1"));
    std.debug.assert(std.mem.readInt(u16, asset[4..6], .little) == 1);
    std.debug.assert(std.mem.readInt(u16, asset[16..18], .little) == 16);
    std.debug.assert(std.mem.readInt(u32, asset[20..24], .little) == 16384);
    std.debug.assert(texture_offset == 32 + vertex_count * 16 + triangle_count * 6);
    std.debug.assert(asset.len == texture_offset + @as(usize, texture_size) * texture_size * 2);
}

const Vertex = struct { x: f32, y: f32, z: f32, nx: f32, ny: f32, nz: f32, u: f32, v: f32 };
const Projected = struct { x: i32, y: i32, z: f32, u: f32, v: f32, light: f32 };
pub const Bounds = pixel.Region;

pub fn dirtyBounds(width: u16, height: u16) Bounds {
    const x = width / 6;
    const y = height * 14 / 100;
    return .{ .x = x, .y = y, .width = width - 2 * x, .height = height * 84 / 100 - y };
}

pub fn dirtyRegions(width: u16, height: u16) [2]Bounds {
    const model = dirtyBounds(width, height);
    const horizon = grid.horizon(height);
    return .{
        .{ .x = model.x, .y = model.y, .width = model.width, .height = horizon - model.y },
        .{ .x = 0, .y = horizon, .width = width, .height = model.y + model.height - horizon },
    };
}

fn signed(bytes: *const [2]u8) f32 {
    return @as(f32, @floatFromInt(std.mem.readInt(i16, bytes, .little))) / 16384.0;
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    vertices: []Vertex,
    triangles: [][3]u16,
    texture: []u16,
    projected: []Projected,
    depth: []u16,
    width: u16,
    height: u16,
    ground_y: f32,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Renderer {
        const vertices = try allocator.alloc(Vertex, vertex_count);
        errdefer allocator.free(vertices);
        const triangles = try allocator.alloc([3]u16, triangle_count);
        errdefer allocator.free(triangles);
        const texture = try allocator.alloc(u16, @as(usize, texture_size) * texture_size);
        errdefer allocator.free(texture);
        const projected = try allocator.alloc(Projected, vertex_count);
        errdefer allocator.free(projected);
        const depth = try allocator.alloc(u16, @as(usize, width) * height);
        errdefer allocator.free(depth);
        var ground_y: f32 = 1;
        for (vertices, 0..) |*v, i| {
            const bytes = asset[32 + i * 16 ..][0..16];
            v.* = .{
                .x = signed(bytes[0..2]),
                .y = signed(bytes[2..4]),
                .z = signed(bytes[4..6]),
                .nx = signed(bytes[6..8]),
                .ny = signed(bytes[8..10]),
                .nz = signed(bytes[10..12]),
                .u = @as(f32, @floatFromInt(std.mem.readInt(u16, bytes[12..14], .little))) * (@as(f32, @floatFromInt(texture_size)) / 65535.0),
                .v = @as(f32, @floatFromInt(std.mem.readInt(u16, bytes[14..16], .little))) * (@as(f32, @floatFromInt(texture_size)) / 65535.0),
            };
            ground_y = @min(ground_y, v.y);
        }
        for (triangles, 0..) |*triangle, i| {
            for (triangle, 0..) |*index, j| {
                const offset = 32 + vertex_count * 16 + i * 6 + j * 2;
                index.* = std.mem.readInt(u16, asset[offset..][0..2], .little);
                if (index.* >= vertex_count) return error.InvalidMeshIndex;
            }
        }
        for (texture, 0..) |*color, i| color.* = std.mem.readInt(u16, asset[texture_offset + i * 2 ..][0..2], .little);
        return .{ .allocator = allocator, .vertices = vertices, .triangles = triangles, .texture = texture, .projected = projected, .depth = depth, .width = width, .height = height, .ground_y = ground_y };
    }

    pub fn deinit(self: Renderer) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.triangles);
        self.allocator.free(self.texture);
        self.allocator.free(self.projected);
        self.allocator.free(self.depth);
    }

    pub fn memoryBytes(self: Renderer) usize {
        return self.vertices.len * @sizeOf(Vertex) + self.triangles.len * @sizeOf([3]u16) + self.texture.len * 2 + self.projected.len * @sizeOf(Projected) + self.depth.len * 2;
    }

    fn project(self: Renderer, pose: Pose) void {
        const sy = @sin(pose.yaw + pose.view_yaw);
        const cy = @cos(pose.yaw + pose.view_yaw);
        const pitch = std.math.clamp(pose.pitch + pose.view_pitch, -0.55, 0.85);
        const sp = @sin(pitch);
        const cp = @cos(pitch);
        const scale = @as(f32, @floatFromInt(@min(self.width, self.height))) * 0.28;
        const shift = viewShift(pose, self.width);
        for (self.vertices, self.projected) |v, *p| {
            const body_y = (v.y - self.ground_y) * pose.scale_y + self.ground_y + pose.jump;
            const x = (v.x * cy + v.z * sy) * pose.scale_xz;
            const z = (-v.x * sy + v.z * cy) * pose.scale_xz;
            const y = body_y * cp - z * sp;
            const depth = body_y * sp + z * cp;
            const nx = v.nx * cy + v.nz * sy;
            const nz = -v.nx * sy + v.nz * cy;
            const ny = v.ny * cp - nz * sp;
            const normal_z = v.ny * sp + nz * cp;
            const diffuse = @max(@as(f32, 0), nx * 0.3 + ny * 0.8 + normal_z * 0.5);
            p.* = .{
                .x = @intFromFloat((@as(f32, @floatFromInt(self.width)) * 0.5 + x * scale + shift[0]) * 16 + 0.5),
                .y = @intFromFloat((@as(f32, @floatFromInt(self.height)) * 0.5 - y * scale + shift[1]) * 16 + 0.5),
                .z = 32768.0 + depth * 24000.0,
                .u = v.u,
                .v = v.v,
                .light = @min(@as(f32, 1), 0.82 + 0.18 * diffuse),
            };
        }
    }

    pub fn draw(self: Renderer, canvas: pixel.Canvas, pose: Pose, time_ms: u64) void {
        std.debug.assert(canvas.width == self.width and canvas.height == self.height);
        canvas.clear(theme.colors.background);
        @memset(self.depth, 0);
        const shift = backdropShift(pose, canvas.width);
        grid.drawSun(canvas, shift[0], shift[1]);
        grid.drawFloor(canvas, time_ms, self.depth, shift[0]);
        const k: i32 = if (canvas.width >= 200) 2 else 1;
        const p = ui.Painter.init(canvas);
        p.centeredText("FUMO", 9, theme.colors.text);
        p.bow(29, 8);
        p.bow(72, 8);
        p.line(.{ 13, 31 }, .{ 13, 40 }, theme.colors.border);
        p.line(.{ 103, 31 }, .{ 103, 40 }, theme.colors.border);
        p.cross(11, 41, theme.colors.muted);
        p.cross(101, 41, theme.colors.muted);
        drawCaption(canvas, k);
        self.drawShadow(canvas, pose);
        self.project(pose);
        for (self.triangles) |t| rasterTriangle(canvas, self.depth, self.texture, texture_size, self.projected[t[0]], self.projected[t[1]], self.projected[t[2]]);
    }

    pub fn drawBackdrop(self: Renderer, canvas: pixel.Canvas, pose: Pose, time_ms: u64) void {
        grid.drawFloor(canvas, time_ms, self.depth, backdropShift(pose, canvas.width)[0]);
        self.drawShadow(canvas, pose);
    }

    fn drawShadow(self: Renderer, canvas: pixel.Canvas, pose: Pose) void {
        const size = @as(f32, @floatFromInt(@min(self.width, self.height)));
        const shift = viewShift(pose, canvas.width);
        const pitch = std.math.clamp(pose.pitch + pose.view_pitch, -0.55, 0.85);
        const cx: i32 = @intFromFloat(@as(f32, @floatFromInt(canvas.width)) * 0.5 + shift[0]);
        const cy: i32 = @intFromFloat(@as(f32, @floatFromInt(canvas.height)) * 0.5 - self.ground_y * @cos(pitch) * size * 0.28 + shift[1]);
        const rx: i32 = @intFromFloat(size * 0.15 * (1 - pose.jump * 1.5));
        const ry: i32 = @max(2, @as(i32, @intFromFloat(size * 0.035)));
        const color = pixel.rgb565(if (pose.jump > 0.08) @as(u24, 0x100A19) else 0x1C102C);
        var y = -ry;
        while (y <= ry) : (y += 1) {
            var x = -rx;
            while (x <= rx) : (x += 1) {
                const px = cx + x;
                const py = cy + y;
                if (px < 0 or py < 0 or px >= canvas.width or py >= canvas.height) continue;
                const index = @as(usize, @intCast(py)) * canvas.width + @as(usize, @intCast(px));
                if (self.depth[index] == 0 and x * x * ry * ry + y * y * rx * rx <= rx * rx * ry * ry) canvas.pixels[index] = color;
            }
        }
    }
};

fn viewShift(pose: Pose, width: u16) [2]f32 {
    const distance = @as(f32, @floatFromInt(width)) / interaction.parallax_angle_limit;
    return .{ pose.view_yaw * distance * 0.032, -pose.view_pitch * distance * 0.015 };
}

fn backdropShift(pose: Pose, width: u16) [2]i32 {
    const distance: f32 = (if (width >= 200) @as(f32, 4) else 2) / interaction.parallax_angle_limit;
    return .{ @intFromFloat(@round(-pose.view_yaw * distance)), @intFromFloat(@round(pose.view_pitch * distance)) };
}

fn drawCaption(canvas: pixel.Canvas, k: i32) void {
    const p: ui.Painter = .{ .canvas = canvas, .k = k };
    p.text("YAKUI", 38, 99, theme.colors.accent);
    p.heart(70, 99, theme.colors.rose);
    var x: i32 = 30;
    while (x <= 86) : (x += 4) {
        p.dot(x, 97, theme.colors.border);
        p.dot(x + 1, 98, theme.colors.berry);
    }
}

fn edge(a: Projected, b: Projected, x: i32, y: i32) i32 {
    return (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x);
}

fn mix(a: f32, b: f32, c: f32, w0: i32, w1: i32, w2: i32, inverse_area: f32) f32 {
    return (@as(f32, @floatFromInt(w0)) * a + @as(f32, @floatFromInt(w1)) * b + @as(f32, @floatFromInt(w2)) * c) * inverse_area;
}

fn shade(color: u16, light: u32) u16 {
    const r = ((@as(u32, color >> 11) * light) >> 8) << 11;
    const g = ((@as(u32, (color >> 5) & 63) * light) >> 8) << 5;
    const b = (@as(u32, color & 31) * light) >> 8;
    return @intCast(r | g | b);
}

// Avoid a libm floorf call for every texel. Truncation is floor for positive UVs.
fn texel(value: f32, mask: u32) u32 {
    var index: i32 = @intFromFloat(value);
    if (value < 0 and value != @as(f32, @floatFromInt(index))) index -= 1;
    return @as(u32, @bitCast(index)) & mask;
}

/// Q4 screen edges, affine UVs (exact for orthographic projection) and uint16 Z.
fn rasterTriangle(canvas: pixel.Canvas, depth: []u16, texture: []const u16, size: u16, a: Projected, original_b: Projected, original_c: Projected) void {
    var b = original_b;
    var c = original_c;
    var area = edge(a, b, c.x, c.y);
    if (area == 0) return;
    // The source material is double-sided: retain both windings.
    if (area < 0) {
        std.mem.swap(Projected, &b, &c);
        area = -area;
    }
    const x0 = @max(0, @divFloor(@min(a.x, @min(b.x, c.x)), 16));
    const y0 = @max(0, @divFloor(@min(a.y, @min(b.y, c.y)), 16));
    const x1 = @min(@as(i32, canvas.width) - 1, @divFloor(@max(a.x, @max(b.x, c.x)), 16));
    const y1 = @min(@as(i32, canvas.height) - 1, @divFloor(@max(a.y, @max(b.y, c.y)), 16));
    if (x0 > x1 or y0 > y1) return;
    const inverse_area = 1.0 / @as(f32, @floatFromInt(area));
    const dx0 = -(c.y - b.y) * 16;
    const dx1 = -(a.y - c.y) * 16;
    const dx2 = -(b.y - a.y) * 16;
    const dy0 = (c.x - b.x) * 16;
    const dy1 = (a.x - c.x) * 16;
    const dy2 = (b.x - a.x) * 16;
    const du_x = mix(a.u, b.u, c.u, dx0, dx1, dx2, inverse_area);
    const dv_x = mix(a.v, b.v, c.v, dx0, dx1, dx2, inverse_area);
    const dz_x = mix(a.z, b.z, c.z, dx0, dx1, dx2, inverse_area);
    const du_y = mix(a.u, b.u, c.u, dy0, dy1, dy2, inverse_area);
    const dv_y = mix(a.v, b.v, c.v, dy0, dy1, dy2, inverse_area);
    const dz_y = mix(a.z, b.z, c.z, dy0, dy1, dy2, inverse_area);
    var row_w0 = edge(b, c, x0 * 16 + 8, y0 * 16 + 8);
    var row_w1 = edge(c, a, x0 * 16 + 8, y0 * 16 + 8);
    var row_w2 = edge(a, b, x0 * 16 + 8, y0 * 16 + 8);
    var row_u = mix(a.u, b.u, c.u, row_w0, row_w1, row_w2, inverse_area);
    var row_v = mix(a.v, b.v, c.v, row_w0, row_w1, row_w2, inverse_area);
    var row_z = mix(a.z, b.z, c.z, row_w0, row_w1, row_w2, inverse_area);
    const light: u32 = @intFromFloat((a.light + b.light + c.light) * (256.0 / 3.0) + 0.5);
    const mask: u32 = size - 1;
    var y = y0;
    while (y <= y1) : (y += 1) {
        var w0 = row_w0;
        var w1 = row_w1;
        var w2 = row_w2;
        var u = row_u;
        var v = row_v;
        var z = row_z;
        var x = x0;
        var index = @as(usize, @intCast(y)) * canvas.width + @as(usize, @intCast(x0));
        while (x <= x1) : (x += 1) {
            if (w0 >= 0 and w1 >= 0 and w2 >= 0 and z > @as(f32, @floatFromInt(depth[index]))) {
                const tx = texel(u, mask);
                const ty = texel(v, mask);
                canvas.pixels[index] = shade(texture[ty * size + tx], light);
                depth[index] = @intFromFloat(std.math.clamp(z, 0, 65535));
            }
            w0 += dx0;
            w1 += dx1;
            w2 += dx2;
            u += du_x;
            v += dv_x;
            z += dz_x;
            index += 1;
        }
        row_w0 += dy0;
        row_w1 += dy1;
        row_w2 += dy2;
        row_u += du_y;
        row_v += dv_y;
        row_z += dz_y;
    }
}

test "texture UVs preserve top-left origin and depth wins in either draw order" {
    try std.testing.expectEqual(@as(u32, 127), texel(-0.1, 127));
    try std.testing.expectEqual(@as(u32, 0), texel(128.0, 127));
    try std.testing.expectEqual(@as(u32, 0), texel(128.9, 127));
    var pixels: [8 * 8]u16 = undefined;
    var depth: [8 * 8]u16 = undefined;
    const canvas = pixel.Canvas.init(&pixels, 8, 8);
    const a: Projected = .{ .x = 16, .y = 16, .z = 300, .u = 0, .v = 0, .light = 1 };
    const b: Projected = .{ .x = 112, .y = 16, .z = 300, .u = 2, .v = 0, .light = 1 };
    const c: Projected = .{ .x = 16, .y = 112, .z = 300, .u = 0, .v = 2, .light = 1 };
    const texture = [_]u16{ 0xF800, 0x07E0, 0x001F, 0xFFFF };
    var far_a = a;
    var far_b = b;
    var far_c = c;
    far_a.z = 100;
    far_b.z = 100;
    far_c.z = 100;
    for ([_]bool{ true, false }) |far_first| {
        canvas.clear(0);
        @memset(&depth, 0);
        if (far_first) rasterTriangle(canvas, &depth, &.{0xFFFF}, 1, far_a, far_b, far_c);
        rasterTriangle(canvas, &depth, &texture, 2, a, c, b);
        if (!far_first) rasterTriangle(canvas, &depth, &.{0xFFFF}, 1, far_a, far_b, far_c);
        try std.testing.expectEqual(@as(u16, 0xF800), pixels[2 * 8 + 2]);
        try std.testing.expectEqual(@as(u16, 0x07E0), pixels[2 * 8 + 5]);
        try std.testing.expectEqual(@as(u16, 0x001F), pixels[5 * 8 + 2]);
        try std.testing.expectEqual(@as(u16, 300), depth[2 * 8 + 2]);
        try std.testing.expectEqual(@as(u16, 0), pixels[0]);
    }
}

test "orbit, parallax and jump extremes preserve static pixels outside refresh area" {
    var pixels: [233 * 233]u16 = undefined;
    const deformations = [_]Pose{
        .{},
        .{ .scale_xz = 1.16, .scale_y = 0.72 },
        .{ .scale_xz = 1.16, .scale_y = 1.16, .jump = 0.20 },
        .{ .scale_xz = 0.90, .scale_y = 0.72, .jump = 0.20 },
    };
    for ([_]u16{ 116, 233 }) |size| {
        const renderer = try Renderer.init(std.testing.allocator, size, size);
        defer renderer.deinit();
        const canvas = pixel.Canvas.init(pixels[0 .. @as(usize, size) * size], size, size);
        renderer.draw(canvas, .{}, 0);
        try std.testing.expect(for (renderer.depth) |depth| {
            if (depth != 0) break true;
        } else false);
        const first = try std.testing.allocator.dupe(u16, canvas.pixels);
        defer std.testing.allocator.free(first);
        const bounds = dirtyBounds(size, size);
        const regions = dirtyRegions(size, size);
        for ([_]f32{ -0.55, -0.25, 0, 0.12, 0.4, 0.6, 0.85 }) |pitch| {
            for (0..24) |step| {
                for (deformations) |deformation| {
                    for ([_][2]f32{ .{ -interaction.parallax_angle_limit, -interaction.parallax_angle_limit }, .{ -interaction.parallax_angle_limit, interaction.parallax_angle_limit }, .{ interaction.parallax_angle_limit, -interaction.parallax_angle_limit }, .{ interaction.parallax_angle_limit, interaction.parallax_angle_limit } }) |offset| {
                        var pose = deformation;
                        pose.yaw = @as(f32, @floatFromInt(step)) * (2 * std.math.pi / 24.0);
                        pose.pitch = pitch;
                        pose.view_yaw = offset[0];
                        pose.view_pitch = offset[1];
                        renderer.draw(canvas, pose, 0);
                        for (renderer.projected) |p| {
                            try std.testing.expect(p.x >= @as(i32, bounds.x) * 16 and p.x < @as(i32, bounds.x + bounds.width) * 16);
                            if (p.y < @as(i32, bounds.y) * 16 or p.y >= @as(i32, bounds.y + bounds.height) * 16) std.debug.print("size={d}, vertex_y={d}/16, pose={any}\n", .{ size, p.y, pose });
                            try std.testing.expect(p.y >= @as(i32, bounds.y) * 16 and p.y < @as(i32, bounds.y + bounds.height) * 16);
                            try std.testing.expect(p.z > 0 and p.z < 65535);
                        }
                        for (canvas.pixels, 0..) |color, i| {
                            const x = i % size;
                            const y = i / size;
                            var covered = false;
                            for (regions) |region| covered = covered or (x >= region.x and x < region.x + region.width and y >= region.y and y < region.y + region.height);
                            if (!covered) try std.testing.expectEqual(first[i], color);
                        }
                    }
                }
            }
        }
    }
}

test "moving grid cache matches full rendering and two-area expansion exactly" {
    for ([_]u16{ 4, 2 }) |scale| {
        const viewport = pixel.Viewport.init(scale);
        const size = viewport.logical_size;
        const renderer = try Renderer.init(std.testing.allocator, size, size);
        defer renderer.deinit();
        const pixels = try std.testing.allocator.alloc(u16, @as(usize, size) * size);
        defer std.testing.allocator.free(pixels);
        const canvas = pixel.Canvas.init(pixels, size, size);
        const cached = try std.testing.allocator.alloc(u16, pixels.len);
        defer std.testing.allocator.free(cached);
        const physical = try std.testing.allocator.alloc(u16, 466 * 466);
        defer std.testing.allocator.free(physical);
        const full = try std.testing.allocator.alloc(u16, physical.len);
        defer std.testing.allocator.free(full);
        renderer.draw(canvas, .{}, 0);
        pixel.expandNearest(canvas, physical, viewport);
        const regions = dirtyRegions(size, size);
        for ([_]Pose{ .{}, .{ .yaw = 1.6, .pitch = -0.55 }, .{ .yaw = -2.3, .pitch = 0.85, .scale_y = 0.72, .scale_xz = 1.16, .jump = 0.1 }, .{ .yaw = 2.4, .view_yaw = interaction.parallax_angle_limit, .view_pitch = -interaction.parallax_angle_limit }, .{ .pitch = -0.55, .view_yaw = -interaction.parallax_angle_limit, .view_pitch = interaction.parallax_angle_limit, .jump = 0.20, .scale_y = 1.16 } }) |pose| {
            renderer.draw(canvas, pose, 0);
            for (regions) |region| pixel.expandNearestRegion(canvas, physical, viewport, region);
            pixel.expandNearest(canvas, full, viewport);
            try std.testing.expectEqualSlices(u16, full, physical);
            for ([_]u64{ 1, 280, 700, 1099, 1100, 1800, 2200 }) |time| {
                renderer.drawBackdrop(canvas, pose, time);
                @memcpy(cached, pixels);
                pixel.expandNearestRegion(canvas, physical, viewport, regions[1]);
                renderer.draw(canvas, pose, time);
                try std.testing.expectEqualSlices(u16, pixels, cached);
                pixel.expandNearest(canvas, full, viewport);
                try std.testing.expectEqualSlices(u16, full, physical);
            }
        }
        renderer.draw(canvas, .{}, 0);
        @memcpy(cached, pixels);
        renderer.drawBackdrop(canvas, .{}, 550);
        try std.testing.expect(!std.mem.eql(u16, pixels, cached));
        renderer.drawBackdrop(canvas, .{}, 1100);
        try std.testing.expectEqualSlices(u16, cached, pixels);
    }
}
