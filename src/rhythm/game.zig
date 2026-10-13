const std = @import("std");
const pointer = @import("../ui/pointer.zig");
pub const beat_ms = 500;
pub const duration_ms = 32_000;
pub const approach_ms = 1400;
pub const window_ms = 150;
pub const Difficulty = enum { easy, normal, five };
pub const vectors = [8][2]i32{ .{ 392, -946 }, .{ 946, -392 }, .{ 946, 392 }, .{ 392, 946 }, .{ -392, 946 }, .{ -946, 392 }, .{ -946, -392 }, .{ -392, -946 } };
pub const Kind = enum { tap, hold, slide };
pub const Grade = enum(u8) { miss, good, great, perfect };
pub const Note = struct { time_ms: u32, lane: u3, kind: Kind = .tap, length_ms: u16 = 0 };
pub const Chart = struct { notes: [128]Note = undefined, count: usize = 0 };
pub fn chart(five: bool) Chart {
    var result: Chart = .{};
    for (4..60) |beat| {
        const lane: u3 = @truncate(beat * 3 + beat / 8);
        const phase = beat % 8;
        if (phase == 3) continue;
        if (phase == 4) {
            for (0..@as(usize, if (five) 5 else 2)) |i| {
                result.notes[result.count] = .{ .time_ms = @intCast(beat * beat_ms), .lane = lane +% @as(u3, @truncate(i * 2 + i / 4)) };
                result.count += 1;
            }
        } else {
            result.notes[result.count] = .{ .time_ms = @intCast(beat * beat_ms), .lane = lane, .kind = if (phase == 2) .hold else if (phase == 7) .slide else .tap, .length_ms = if (phase == 2) 750 else if (phase == 7) 1000 else 0 };
            result.count += 1;
        }
    }
    return result;
}
pub const duet = chart(false);
pub const multi = chart(true);
pub const easy: Chart = blk: {
    const notes = [_]Note{
        .{ .time_ms = 4000, .lane = 5 },
        .{ .time_ms = 5500, .lane = 2 },
        .{ .time_ms = 7000, .lane = 5 },
        .{ .time_ms = 8500, .lane = 2 },
        .{ .time_ms = 10000, .lane = 5, .kind = .hold, .length_ms = 1000 },
        .{ .time_ms = 12000, .lane = 2, .kind = .hold, .length_ms = 1000 },
        .{ .time_ms = 14000, .lane = 5 },
        .{ .time_ms = 14000, .lane = 2 },
        .{ .time_ms = 16000, .lane = 6 },
        .{ .time_ms = 17500, .lane = 1 },
        .{ .time_ms = 19000, .lane = 7 },
        .{ .time_ms = 20500, .lane = 0 },
        .{ .time_ms = 22000, .lane = 5, .kind = .slide, .length_ms = 1500 },
        .{ .time_ms = 25000, .lane = 2, .kind = .slide, .length_ms = 1500 },
        .{ .time_ms = 28000, .lane = 5 },
        .{ .time_ms = 28000, .lane = 2 },
        .{ .time_ms = 30000, .lane = 3 },
    };
    var result: Chart = .{ .count = notes.len };
    @memcpy(result.notes[0..notes.len], &notes);
    break :blk result;
};
pub fn laneAt(x: i32, y: i32) ?u3 {
    const dx = x - 233;
    const dy = y - 233;
    const r2 = dx * dx + dy * dy;
    if (r2 < 128 * 128 or r2 >= 197 * 197) return null;
    var best: i32 = std.math.minInt(i32);
    var lane: u3 = 0;
    for (vectors, 0..) |v, i| {
        const dot = dx * v[0] + dy * v[1];
        if (dot > best) {
            best = dot;
            lane = @intCast(i);
        }
    }
    return lane;
}
pub fn expectedLane(note: Note, now: u32) u3 {
    if (note.kind != .slide) return note.lane;
    const stage: u3 = @intCast(@min(2, (now -| note.time_ms) * 3 / @as(u32, note.length_ms)));
    return note.lane +% stage;
}
pub const Record = struct {
    phase: enum { pending, holding, done } = .pending,
    head: Grade = .miss,
    owner: u8 = 255,
    gap_ms: ?u32 = null,
    visited: u8 = 0,
};
pub const State = struct {
    difficulty: Difficulty = .easy,
    phase: enum { ready, waiting, playing, paused, results, failed } = .ready,
    generation: u32 = 0,
    song_ms: u32 = 0,
    notes: [128]Record = @splat(.{}),
    contacts: [16]?u3 = @splat(null),
    grades: [4]u16 = @splat(0),
    combo: u16 = 0,
    max_combo: u16 = 0,
    score: u32 = 0,
    last_grade: ?Grade = null,
    grade_until: u32 = 0,
    resume_grace: u32 = 0,
    current_touches: u8 = 0,
    max_touches: u8 = 0,
    pub fn fiveAvailable(self: *const State) bool {
        return self.max_touches >= 5;
    }
    pub fn cycleChart(self: *State) bool {
        if (self.phase != .ready and self.phase != .results) return false;
        const next: Difficulty = switch (self.difficulty) {
            .easy => .normal,
            .normal => if (self.fiveAvailable()) .five else .easy,
            .five => .easy,
        };
        if (self.phase == .results) {
            self.* = .{ .difficulty = next, .generation = self.generation, .max_touches = self.max_touches };
        } else self.difficulty = next;
        return true;
    }
    pub fn selected(self: *const State) *const Chart {
        return switch (self.difficulty) {
            .easy => &easy,
            .normal => &duet,
            .five => &multi,
        };
    }
    pub fn approachMs(self: *const State) u32 {
        return if (self.difficulty == .easy) 2400 else approach_ms;
    }
    pub fn hitWindowMs(self: *const State) u32 {
        return if (self.difficulty == .easy) 220 else window_ms;
    }
    pub fn start(self: *State) void {
        const difficulty = self.difficulty;
        const generation = self.generation +% 1;
        const peak = self.max_touches;
        self.* = .{ .difficulty = difficulty, .generation = generation, .phase = .waiting, .max_touches = peak };
    }
    pub fn cancel(self: *State) void {
        self.contacts = @splat(null);
        self.current_touches = 0;
    }
    pub fn resumeSong(self: *State) void {
        self.cancel();
        self.phase = .waiting;
        self.resume_grace = self.song_ms + 250;
        for (&self.notes) |*r| if (r.phase == .holding) {
            r.owner = 255;
            r.gap_ms = null;
        };
    }
    fn finish(self: *State, index: usize, grade: Grade) void {
        self.notes[index].phase = .done;
        self.grades[@backingInt(grade)] += 1;
        self.score += switch (grade) {
            .perfect => 1000,
            .great => 750,
            .good => 400,
            .miss => 0,
        };
        if (grade == .miss) self.combo = 0 else self.combo += 1;
        self.max_combo = @max(self.max_combo, self.combo);
        self.last_grade = grade;
        self.grade_until = self.song_ms + 500;
    }
    pub fn touch(self: *State, event: pointer.Event, id: u8, x: i32, y: i32) void {
        if (id >= 16) return;
        const old = self.contacts[id];
        const lane = if (event == .up or event == .cancel) null else laneAt(x, y);
        self.contacts[id] = lane;
        if (self.phase != .playing or lane == null or old == lane) return;
        var best: ?usize = null;
        var distance: u32 = self.hitWindowMs() + 1;
        for (self.selected().notes[0..self.selected().count], 0..) |note, i| {
            if (self.notes[i].phase != .pending or note.lane != lane.?) continue;
            const difference = @abs(@as(i64, self.song_ms) - note.time_ms);
            if (difference < distance) {
                best = i;
                distance = @intCast(difference);
            }
        }
        if (best) |i| {
            const grade: Grade = if (distance <= (if (self.difficulty == .easy) @as(u32, 80) else 55)) .perfect else if (distance <= (if (self.difficulty == .easy) @as(u32, 140) else 105)) .great else .good;
            if (self.selected().notes[i].kind == .tap) self.finish(i, grade) else {
                self.notes[i] = .{ .phase = .holding, .head = grade, .owner = id, .visited = 1 };
                self.last_grade = grade;
                self.grade_until = self.song_ms + 300;
            }
        }
    }
    pub fn advance(self: *State, time_ms: u32) void {
        if (self.phase != .playing) return;
        self.song_ms = @max(self.song_ms, @min(time_ms, duration_ms));
        for (self.selected().notes[0..self.selected().count], 0..) |note, i| {
            const r = &self.notes[i];
            if (r.phase == .done) continue;
            if (r.phase == .pending) {
                if (self.song_ms > note.time_ms + self.hitWindowMs()) self.finish(i, .miss);
                continue;
            }
            const expected = expectedLane(note, self.song_ms);
            if (r.owner == 255 and self.song_ms <= self.resume_grace) {
                for (self.contacts, 0..) |lane, id| if (lane == expected) {
                    r.owner = @intCast(id);
                    break;
                };
            }
            const present = r.owner < 16 and self.contacts[r.owner] == expected;
            if (present) {
                r.gap_ms = null;
                const stage: u3 = if (note.kind == .slide) @intCast(@min(2, (self.song_ms -| note.time_ms) * 3 / @as(u32, note.length_ms))) else 0;
                r.visited |= @as(u8, 1) << stage;
            } else if (self.song_ms > self.resume_grace) {
                if (r.gap_ms == null) r.gap_ms = self.song_ms;
                if (self.song_ms - r.gap_ms.? > (if (self.difficulty == .easy) @as(u32, 220) else 140)) {
                    self.finish(i, .miss);
                    continue;
                }
            }
            if (self.song_ms >= note.time_ms + note.length_ms) {
                self.finish(i, if ((present or (r.gap_ms != null and self.song_ms - r.gap_ms.? <= (if (self.difficulty == .easy) @as(u32, 180) else 100))) and (note.kind != .slide or r.visited & 7 == 7)) r.head else .miss);
            }
        }
        if (self.song_ms == duration_ms) self.phase = .results;
    }
    pub fn accuracy(self: *const State) u32 {
        return self.score * 1000 / @as(u32, @intCast(self.selected().count * 1000));
    }
};
fn point(lane: u3) [2]i32 {
    const v = vectors[lane];
    return .{ 233 + @divTrunc(v[0] * 166, 1024), 233 + @divTrunc(v[1] * 166, 1024) };
}
test "five simultaneous heads score independently and held fingers cannot repeat taps" {
    var state: State = .{ .difficulty = .five };
    state.start();
    state.phase = .playing;
    state.advance(2000);
    var lanes: [5]u3 = undefined;
    var count: usize = 0;
    for (multi.notes[0..multi.count]) |note| if (note.time_ms == 2000) {
        lanes[count] = note.lane;
        count += 1;
    };
    for (lanes, 0..) |lane, id| {
        const p = point(lane);
        state.touch(.down, @intCast(id), p[0], p[1]);
    }
    try std.testing.expectEqual(@as(u16, 5), state.combo);
    try std.testing.expectEqual(@as(u32, 5000), state.score);
    for (lanes, 0..) |lane, id| {
        const p = point(lane);
        state.touch(.move, @intCast(id), p[0], p[1]);
    }
    try std.testing.expectEqual(@as(u32, 5000), state.score);
}

test "five-touch chart stays unavailable until five contacts have actually been observed" {
    var state: State = .{ .max_touches = 2 };
    try std.testing.expectEqual(Difficulty.easy, state.difficulty);
    try std.testing.expect(state.cycleChart());
    try std.testing.expectEqual(@as(usize, 56), state.selected().count);
    try std.testing.expect(state.cycleChart());
    try std.testing.expectEqual(Difficulty.easy, state.difficulty);
    state.max_touches = 4;
    _ = state.cycleChart();
    _ = state.cycleChart();
    try std.testing.expectEqual(Difficulty.easy, state.difficulty);
    state.max_touches = 5;
    _ = state.cycleChart();
    try std.testing.expect(state.cycleChart());
    try std.testing.expectEqual(@as(usize, 77), state.selected().count);
    state.start();
    try std.testing.expect(state.difficulty == .five and state.fiveAvailable());
    try std.testing.expect(!state.cycleChart());
}
test "all lane centers are content and sector selection agrees with rendering" {
    const navigation = @import("../ui/navigation.zig");
    for (0..8) |lane| {
        const p = point(@intCast(lane));
        try std.testing.expectEqual(@as(?u3, @intCast(lane)), laneAt(p[0], p[1]));
        try std.testing.expectEqual(navigation.Owner.content, navigation.zone(p[0], p[1]));
    }
    try std.testing.expectEqual(@as(?u3, null), laneAt(233, 233));
    try std.testing.expectEqual(@as(?u3, null), laneAt(455, 233));
}
test "hold requires continuity, misses expire, and pause freezes the timeline" {
    var state: State = .{ .difficulty = .normal };
    state.start();
    state.phase = .playing;
    var index: usize = 0;
    while (duet.notes[index].kind != .hold) : (index += 1) {}
    const note = duet.notes[index];
    state.advance(note.time_ms);
    const p = point(note.lane);
    state.touch(.down, 4, p[0], p[1]);
    state.advance(note.time_ms + 100);
    state.touch(.up, 4, p[0], p[1]);
    state.advance(note.time_ms + 120);
    state.advance(note.time_ms + 300);
    try std.testing.expect(state.notes[index].phase == .done);
    try std.testing.expect(state.grades[0] >= 1);
    state.phase = .paused;
    const before = state.song_ms;
    state.advance(30_000);
    try std.testing.expectEqual(before, state.song_ms);
}
test "slide must follow all three sectors with one contact" {
    var state: State = .{ .difficulty = .normal };
    state.start();
    state.phase = .playing;
    var index: usize = 0;
    while (duet.notes[index].kind != .slide) : (index += 1) {}
    const note = duet.notes[index];
    state.advance(note.time_ms);
    var p = point(note.lane);
    state.touch(.down, 3, p[0], p[1]);
    for (0..11) |step| {
        const now = note.time_ms + @as(u32, @intCast(step)) * 100;
        p = point(expectedLane(note, now));
        state.touch(.move, 3, p[0], p[1]);
        state.advance(now);
    }
    try std.testing.expectEqual(@as(u8, 7), state.notes[index].visited);
    try std.testing.expectEqual(@as(u16, 1), state.grades[3]);
}

test "all complete charts can finish with perfect score using their contact budget" {
    for ([_]Difficulty{ .easy, .normal, .five }) |difficulty| {
        var state: State = .{ .difficulty = difficulty };
        state.start();
        state.phase = .playing;
        var slots: [5]?usize = @splat(null);
        const budget: usize = if (difficulty == .five) 5 else 2;
        for (0..3201) |tick| {
            const now: u32 = @intCast(tick * 10);
            for (slots, 0..) |slot, id| if (slot) |index| {
                const p = point(expectedLane(state.selected().notes[index], now));
                state.touch(.move, @intCast(id), p[0], p[1]);
            };
            state.advance(now);
            for (&slots, 0..) |*slot, id| if (slot.*) |index| {
                if (state.notes[index].phase == .done) {
                    state.touch(.up, @intCast(id), 0, 0);
                    slot.* = null;
                }
            };
            for (state.selected().notes[0..state.selected().count], 0..) |note, index| {
                if (note.time_ms != now or state.notes[index].phase != .pending) continue;
                var id: usize = 0;
                while (id < budget and slots[id] != null) : (id += 1) {}
                try std.testing.expect(id < budget);
                slots[id] = index;
                const p = point(note.lane);
                state.touch(.down, @intCast(id), p[0], p[1]);
            }
            state.advance(now);
        }
        try std.testing.expect(state.phase == .results);
        try std.testing.expectEqual(@as(u32, @intCast(state.selected().count * 1000)), state.score);
        try std.testing.expectEqual(@as(u16, 0), state.grades[0]);
        try std.testing.expectEqual(@as(u32, 1000), state.accuracy());
    }
}

test "easy accepts early taps outside the normal judgment window" {
    var state: State = .{};
    state.start();
    state.phase = .playing;
    state.advance(3800);
    const p = point(easy.notes[0].lane);
    state.touch(.down, 0, p[0], p[1]);
    try std.testing.expectEqual(@as(u32, 400), state.score);
    var normal: State = .{ .difficulty = .normal };
    normal.start();
    normal.phase = .playing;
    normal.advance(1800);
    const n = point(duet.notes[0].lane);
    normal.touch(.down, 0, n[0], n[1]);
    try std.testing.expectEqual(@as(u32, 0), normal.score);
}

test "changing level after results returns to a fresh ready screen and keeps measured contact peak" {
    var state: State = .{ .difficulty = .normal, .phase = .results, .song_ms = duration_ms, .score = 3550, .max_touches = 2 };
    try std.testing.expect(state.cycleChart());
    try std.testing.expectEqual(Difficulty.easy, state.difficulty);
    try std.testing.expect(state.phase == .ready);
    try std.testing.expectEqual(@as(u32, 0), state.score);
    try std.testing.expectEqual(@as(u32, 0), state.song_ms);
    try std.testing.expectEqual(@as(u8, 2), state.max_touches);
}
