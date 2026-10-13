const std = @import("std");
const pointer = @import("../ui/pointer.zig");
const navigation = @import("../ui/navigation.zig");
pub const max_points = 5;
pub const report_bytes = 30;
pub const Point = extern struct { x: u16, y: u16, id: u8 };
pub const Frame = struct { points: [max_points]Point = undefined, count: u8 = 0 };
// Matches the bridge bit mask; apply only the transforms not handled by hardware.
pub const Orientation = packed struct(u8) {
    mirror_x: bool = false,
    mirror_y: bool = false,
    swap_xy: bool = false,
    reserved: u5 = 0,
};

pub fn decodeScreen(data: []const u8, orientation: Orientation) !Frame {
    var frame = try decode(data);
    for (frame.points[0..frame.count]) |*p| {
        if (orientation.mirror_x) p.x = 465 - p.x;
        if (orientation.mirror_y) p.y = 465 - p.y;
        if (orientation.swap_xy) std.mem.swap(u16, &p.x, &p.y);
    }
    return frame;
}

pub fn decode(data: []const u8) !Frame {
    if (data.len < 7 or data[6] != 0xAB) return error.InvalidReport;
    const count = data[5] & 0x7F;
    if (count > max_points) return error.TooManyContacts;
    var result: Frame = .{};
    if (count == 0 or data[0] == 0xAB or data[4] & 0x80 != 0) return result;
    if (data.len < @as(usize, count) * 5 + 2) return error.TruncatedReport;
    var ids: u16 = 0;
    for (0..count) |i| {
        const offset = i * 5 + @as(usize, if (i == 0) 0 else 2);
        const p = data[offset..][0..5];
        if (p[0] & 15 != 6) continue;
        const id: u4 = @intCast(p[0] >> 4);
        const x = @as(u16, p[1]) * 16 + (p[3] >> 4);
        const y = @as(u16, p[2]) * 16 + (p[3] & 15);
        if (x >= 466 or y >= 466 or ids & (@as(u16, 1) << id) != 0) return error.InvalidContact;
        ids |= @as(u16, 1) << id;
        result.points[result.count] = .{ .x = x, .y = y, .id = id };
        result.count += 1;
    }
    return result;
}
pub const Event = struct { kind: pointer.Event, point: Point, owner: navigation.Owner };
pub const Events = struct { items: [max_points * 2]Event = undefined, count: usize = 0 };
pub const Tracker = struct {
    contacts: [16]?Point = @splat(null),
    owners: [16]navigation.Owner = @splat(.none),
    count: u8 = 0,
    pub fn update(self: *Tracker, frame: Frame) Events {
        var next: [16]?Point = @splat(null);
        for (frame.points[0..frame.count]) |p| if (p.id < 16) {
            next[p.id] = p;
        };
        var result: Events = .{};
        for (self.contacts, 0..) |old, id| if (old) |p| {
            if (next[id] == null) {
                result.items[result.count] = .{ .kind = .up, .point = p, .owner = self.owners[id] };
                self.owners[id] = .none;
                result.count += 1;
            }
        };
        for (next, 0..) |current, id| if (current) |p| {
            if (self.contacts[id] == null) self.owners[id] = navigation.zone(p.x, p.y);
            result.items[result.count] = .{ .kind = if (self.contacts[id] == null) .down else .move, .point = p, .owner = self.owners[id] };
            result.count += 1;
        };
        self.contacts = next;
        self.count = frame.count;
        return result;
    }
};
fn encode(data: *[report_bytes]u8, i: usize, id: u8, x: u16, y: u16) void {
    const offset = i * 5 + @as(usize, if (i == 0) 0 else 2);
    data[offset] = id << 4 | 6;
    data[offset + 1] = @intCast(x >> 4);
    data[offset + 2] = @intCast(y >> 4);
    data[offset + 3] = @as(u8, @intCast((x & 15) << 4)) | @as(u8, @intCast(y & 15));
}
test "screen orientation preserves five contact ids and maps corners within pixel bounds" {
    var data: [report_bytes]u8 = @splat(0);
    data[5] = 5;
    data[6] = 0xAB;
    const positions = [5][2]u16{ .{ 0, 0 }, .{ 465, 0 }, .{ 0, 465 }, .{ 465, 465 }, .{ 110, 340 } };
    for (positions, 0..) |p, i| encode(&data, i, @intCast(i + 8), p[0], p[1]);
    for (0..8) |bits| {
        const orientation: Orientation = @bitCast(@as(u8, @intCast(bits)));
        const frame = try decodeScreen(&data, orientation);
        try std.testing.expectEqual(@as(u8, 5), frame.count);
        for (positions, frame.points[0..frame.count], 0..) |p, actual, i| {
            const x = if (orientation.mirror_x) 465 - p[0] else p[0];
            const y = if (orientation.mirror_y) 465 - p[1] else p[1];
            try std.testing.expectEqual(if (orientation.swap_xy) y else x, actual.x);
            try std.testing.expectEqual(if (orientation.swap_xy) x else y, actual.y);
            try std.testing.expectEqual(@as(u8, @intCast(i + 8)), actual.id);
        }
    }
}
test "five-point report compacts releases and rejects corruption and duplicate ids" {
    var data: [report_bytes]u8 = @splat(0);
    data[5] = 5;
    data[6] = 0xAB;
    for (0..5) |i| encode(&data, i, @intCast(i + 6), @intCast(70 + i * 60), @intCast(100 + i * 30));
    const frame = try decode(&data);
    try std.testing.expectEqual(@as(u8, 5), frame.count);
    try std.testing.expectEqual(@as(u8, 10), frame.points[4].id);
    data[7] &= 0xF0;
    try std.testing.expectEqual(@as(u8, 4), (try decode(&data)).count);
    encode(&data, 1, 6, 120, 130);
    try std.testing.expectError(error.InvalidContact, decode(&data));
    data[5] = 6;
    try std.testing.expectError(error.TooManyContacts, decode(&data));
    data[5] = 5;
    try std.testing.expectError(error.TruncatedReport, decode(data[0..10]));
}
test "contact reordering keeps identity and releases precede newly acquired contacts" {
    var tracker: Tracker = .{};
    var frame: Frame = .{ .count = 2 };
    frame.points[0] = .{ .x = 100, .y = 200, .id = 7 };
    frame.points[1] = .{ .x = 300, .y = 200, .id = 2 };
    _ = tracker.update(frame);
    std.mem.swap(Point, &frame.points[0], &frame.points[1]);
    const moved = tracker.update(frame);
    for (moved.items[0..moved.count]) |event| try std.testing.expectEqual(pointer.Event.move, event.kind);
    frame.points[1].id = 9;
    const changed = tracker.update(frame);
    try std.testing.expectEqual(pointer.Event.up, changed.items[0].kind);
    try std.testing.expectEqual(@as(u8, 7), changed.items[0].point.id);
    const released = tracker.update(.{});
    try std.testing.expectEqual(@as(usize, 2), released.count);
}

test "each contact keeps its origin owner when crossing from rim into game" {
    var tracker: Tracker = .{};
    var frame: Frame = .{ .count = 2 };
    frame.points[0] = .{ .x = 455, .y = 233, .id = 0 };
    frame.points[1] = .{ .x = 233, .y = 233, .id = 1 };
    _ = tracker.update(frame);
    frame.points[0].x = 300;
    frame.points[1].x = 455;
    const events = tracker.update(frame);
    try std.testing.expectEqual(navigation.Owner.edge, events.items[0].owner);
    try std.testing.expectEqual(navigation.Owner.content, events.items[1].owner);
    const up = tracker.update(.{});
    try std.testing.expectEqual(navigation.Owner.edge, up.items[0].owner);
}
