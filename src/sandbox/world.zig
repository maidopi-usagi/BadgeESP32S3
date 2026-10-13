const std = @import("std");
pub const size = 160;
pub const cell_count = size * size;
pub const locked: u8 = 0x40;
const visited: u8 = 0x80;
pub const Material = enum(u2) { empty, sand, water, wall };
pub const Tool = enum { sand, water, wall, erase };
pub const Direction = enum { down, down_left, left, up_left, up, up_right, right, down_right };
pub const Vector = struct { x: i32, y: i32 };
pub fn vector(direction: Direction) Vector {
    return switch (direction) {
        .down => .{ .x = 0, .y = 1 },
        .down_left => .{ .x = -1, .y = 1 },
        .left => .{ .x = -1, .y = 0 },
        .up_left => .{ .x = -1, .y = -1 },
        .up => .{ .x = 0, .y = -1 },
        .up_right => .{ .x = 1, .y = -1 },
        .right => .{ .x = 1, .y = 0 },
        .down_right => .{ .x = 1, .y = 1 },
    };
}
pub fn material(cell: u8) Material {
    return @fromBackingInt(@as(u2, @truncate(cell)));
}
pub const Region = struct { x: u16, y: u16, width: u16, height: u16 };
pub const Damage = struct {
    x0: u16 = size,
    y0: u16 = size,
    x1: u16 = 0,
    y1: u16 = 0,
    pub fn include(self: *Damage, index: usize) void {
        const x: u16 = @intCast(index % size);
        const y: u16 = @intCast(index / size);
        self.x0 = @min(self.x0, x);
        self.y0 = @min(self.y0, y);
        self.x1 = @max(self.x1, x + 1);
        self.y1 = @max(self.y1, y + 1);
    }
    pub fn region(self: Damage) ?Region {
        if (self.x1 <= self.x0 or self.y1 <= self.y0) return null;
        return .{ .x = self.x0, .y = self.y0, .width = self.x1 - self.x0, .height = self.y1 - self.y0 };
    }
};
pub const World = struct {
    allocator: std.mem.Allocator,
    cells: []align(16) u8,
    epoch: u8 = 0,
    random: u32 = 0x5A17D00D,
    counts: [4]u32 = @splat(0), // Mutable materials only; index 0 is unused.
    damage: Damage = .{ .x0 = 0, .y0 = 0, .x1 = size, .y1 = size },
    steps: u64 = 0,
    moves: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) !World {
        const cells = try allocator.alignedAlloc(u8, .@"16", cell_count);
        var self: World = .{ .allocator = allocator, .cells = cells };
        for (cells, 0..) |*cell, i| {
            const dx = 2 * @as(i32, @intCast(i % size)) - (size - 1);
            const dy = 2 * @as(i32, @intCast(i / size)) - (size - 1);
            const distance = dx * dx + dy * dy;
            cell.* = if (distance < 152 * 152) 0 else locked | @as(u8, if (distance <= 156 * 156) 3 else 0);
        }
        self.seedScene();
        return self;
    }
    pub fn deinit(self: *World) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
    fn rand(self: *World) u32 {
        var value = self.random;
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        self.random = value;
        return value;
    }
    fn set(self: *World, index: usize, value: Material) void {
        const old = self.cells[index];
        if (old & locked != 0 or material(old) == value) return;
        if (material(old) != .empty) self.counts[@backingInt(material(old))] -= 1;
        if (value != .empty) self.counts[@backingInt(value)] += 1;
        self.cells[index] = @as(u8, @backingInt(value)) | @as(u8, @intCast((self.rand() & 15) << 2)) | self.epoch;
        self.damage.include(index);
    }
    pub fn clear(self: *World) void {
        for (self.cells, 0..) |cell, i| if (cell & locked == 0) self.set(i, .empty);
    }
    fn seedScene(self: *World) void {
        for (97..100) |y| for (34..68) |x| self.set(y * size + x, .wall);
        for (111..114) |y| for (93..130) |x| self.set(y * size + x, .wall);
        for (39..62) |y| for (47..73) |x| {
            const dx = @as(i32, @intCast(x)) - 60;
            const dy = @as(i32, @intCast(y)) - 51;
            if (dx * dx + dy * dy < 12 * 12) self.set(y * size + x, .sand);
        };
        for (52..74) |y| for (95..116) |x| self.set(y * size + x, .water);
    }
    pub fn brush(self: *World, x: i32, y: i32, tool: Tool) void {
        const radius: i32 = if (tool == .erase) 5 else if (tool == .wall) 2 else 3;
        const value: Material = switch (tool) {
            .sand => .sand,
            .water => .water,
            .wall => .wall,
            .erase => .empty,
        };
        var py = @max(0, y - radius);
        while (py <= @min(size - 1, y + radius)) : (py += 1) {
            var px = @max(0, x - radius);
            while (px <= @min(size - 1, x + radius)) : (px += 1) {
                const dx = px - x;
                const dy = py - y;
                if (dx * dx + dy * dy > radius * radius) continue;
                const index = @as(usize, @intCast(py)) * size + @as(usize, @intCast(px));
                if ((tool == .sand or tool == .water) and material(self.cells[index]) != .empty) continue;
                self.set(index, value);
            }
        }
    }
    pub fn stroke(self: *World, from: Vector, to: Vector, tool: Tool) void {
        var x = from.x;
        var y = from.y;
        const dx: i32 = @intCast(@abs(to.x - x));
        const dy: i32 = -@as(i32, @intCast(@abs(to.y - y)));
        const sx: i32 = if (x < to.x) 1 else -1;
        const sy: i32 = if (y < to.y) 1 else -1;
        var error_value = dx + dy;
        while (true) {
            self.brush(x, y, tool);
            if (x == to.x and y == to.y) break;
            const twice = error_value * 2;
            if (twice >= dy) {
                error_value += dy;
                x += sx;
            }
            if (twice <= dx) {
                error_value += dx;
                y += sy;
            }
        }
    }
    fn adjacent(index: usize, delta: Vector) usize {
        // The sealed circle leaves a four-cell guard around the rectangular
        // grid. Even the longest sideways probe stays within that guard.
        return @intCast(@as(isize, @intCast(index)) + delta.x + delta.y * size);
    }
    fn move(self: *World, source: usize, dest: usize, sand: bool) bool {
        const target = self.cells[dest];
        if (target & locked != 0) return false;
        const kind = material(target);
        if (kind != .empty and !(sand and kind == .water and target & visited != self.epoch)) return false;
        self.cells[dest] = (self.cells[source] & ~visited) | self.epoch;
        self.cells[source] = (target & ~visited) | self.epoch;
        self.damage.include(source);
        self.damage.include(dest);
        self.moves += 1;
        return true;
    }
    fn update(self: *World, index: usize, direction: Vector, comptime kind: Material) void {
        const cell = self.cells[index];
        if (cell & locked != 0 or material(cell) != kind or cell & visited == self.epoch) return;
        self.cells[index] = (cell & ~visited) | self.epoch;
        const is_sand = kind == .sand;
        if (self.move(index, adjacent(index, direction), is_sand)) return;
        const side: Vector = .{ .x = -direction.y, .y = direction.x };
        const sign: i32 = if (self.rand() & 1 == 0) 1 else -1;
        for ([_]i32{ sign, -sign }) |s| {
            const diagonal: Vector = .{ .x = std.math.clamp(direction.x + side.x * s, -1, 1), .y = std.math.clamp(direction.y + side.y * s, -1, 1) };
            if (self.move(index, adjacent(index, diagonal), is_sand)) return;
        }
        if (is_sand) return;
        for ([_]i32{ sign, -sign }) |s| {
            const tangent: Vector = .{ .x = side.x * s, .y = side.y * s };
            var dest = index;
            for (0..3) |_| {
                const next = adjacent(dest, tangent);
                if (self.cells[next] & locked != 0 or material(self.cells[next]) != .empty) break;
                dest = next;
            }
            if (dest != index and self.move(index, dest, false)) return;
        }
    }
    pub fn step(self: *World, gravity: Direction) void {
        self.epoch ^= visited;
        if (self.counts[1] == 0 and self.counts[2] == 0) {
            self.steps += 1;
            return;
        }
        const g = vector(gravity);
        const reverse_side = self.steps & 1 != 0;
        const reverse_x = if (g.x == 0) reverse_side else g.x > 0;
        const reverse_y = if (g.y == 0) reverse_side else g.y > 0;
        // Sand first: a water parcel displaced by density is stamped and will
        // not update a second time in the water pass.
        inline for ([_]Material{ .sand, .water }) |kind| {
            if (self.counts[@backingInt(kind)] > 0) {
                const wanted = (self.epoch ^ visited) | @as(u8, @backingInt(kind));
                for (0..size) |row| {
                    const y = if (reverse_y) size - 1 - row else row;
                    const base = y * size;
                    for (0..size) |column| {
                        const x = if (reverse_x) size - 1 - column else column;
                        const index = base + x;
                        if (self.cells[index] & (locked | visited | 3) == wanted) self.update(index, g, kind);
                    }
                }
            }
        }
        self.steps += 1;
    }
    pub fn takeDamage(self: *World) ?Region {
        const region = self.damage.region();
        self.damage = .{};
        return region;
    }
};

test "sand moves exactly once per tick in all eight gravity directions" {
    for (std.enums.values(Direction)) |direction| {
        var world = try World.init(std.testing.allocator);
        defer world.deinit();
        world.clear();
        world.set(80 * size + 80, .sand);
        for (0..8) |_| world.step(direction);
        const g = vector(direction);
        const x: usize = @intCast(80 + 8 * g.x);
        const y: usize = @intCast(80 + 8 * g.y);
        try std.testing.expectEqual(Material.sand, material(world.cells[y * size + x]));
        try std.testing.expectEqual(@as(u32, 1), world.counts[1]);
    }
}
fn actualCounts(world: World) [4]u32 {
    var result: [4]u32 = @splat(0);
    for (world.cells) |cell| if (cell & locked == 0 and material(cell) != .empty) {
        result[@backingInt(material(cell))] += 1;
    };
    return result;
}
test "closed dish conserves sand water and walls across gravity changes" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    const before = actualCounts(world);
    const boundary = try std.testing.allocator.dupe(u8, world.cells);
    defer std.testing.allocator.free(boundary);
    for (std.enums.values(Direction)) |direction| for (0..45) |_| world.step(direction);
    try std.testing.expectEqual(before, actualCounts(world));
    try std.testing.expectEqual(before, world.counts);
    for (boundary, world.cells) |old, current| if (old & locked != 0) try std.testing.expectEqual(old, current);
}
test "sand sinks through water and water spreads on a solid shelf" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    world.clear();
    for (45..116) |x| world.set(130 * size + x, .wall);
    for (116..130) |y| for (60..101) |x| world.set(y * size + x, .water);
    world.set(114 * size + 80, .sand);
    const before = actualCounts(world);
    for (0..120) |_| world.step(.down);
    var sand_y: usize = 0;
    var water_min_x: usize = size;
    var water_max_x: usize = 0;
    for (world.cells, 0..) |cell, i| switch (material(cell)) {
        .sand => sand_y = i / size,
        .water => {
            water_min_x = @min(water_min_x, i % size);
            water_max_x = @max(water_max_x, i % size);
        },
        else => {},
    };
    try std.testing.expect(sand_y >= 129);
    try std.testing.expect(water_min_x < 60 and water_max_x > 100);
    try std.testing.expectEqual(before, actualCounts(world));
}
test "brush interpolation is continuous and erasing cannot damage the vessel" {
    var world = try World.init(std.testing.allocator);
    defer world.deinit();
    world.clear();
    world.stroke(.{ .x = 35, .y = 80 }, .{ .x = 125, .y = 80 }, .wall);
    for (35..126) |x| try std.testing.expectEqual(Material.wall, material(world.cells[80 * size + x]));
    world.stroke(.{ .x = 0, .y = 80 }, .{ .x = 159, .y = 80 }, .erase);
    for (35..126) |x| try std.testing.expectEqual(Material.empty, material(world.cells[80 * size + x]));
    try std.testing.expect(world.cells[80 * size] & locked != 0);
    try std.testing.expectEqual(@as(u32, 0), world.counts[3]);
}
