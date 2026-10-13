const std = @import("std");
const pixel = @import("pixel_canvas.zig");
const jirai = @import("jirai.zig");
const navigation = @import("navigation.zig");
const colors = @import("theme.zig").colors;
pub const game = @import("../rhythm/game.zig");
pub const viewport = pixel.Viewport.init(2);
const pink = colors.rose;
const cyan = pixel.rgb565(0x71E5ED);
const gold = pixel.rgb565(0xFFE69B);
const bg = colors.background;
pub fn radial(lane: u3, radius: i32) [2]i32 {
    const v = game.vectors[lane];
    return .{ 116 + @divTrunc(v[0] * radius, 1024), 116 + @divTrunc(v[1] * radius, 1024) };
}
fn ring(canvas: pixel.Canvas, x: i32, y: i32, radius: i32, color: u16, inside: u16) void {
    canvas.circle(x, y, radius, color);
    canvas.circle(x, y, radius - 2, inside);
}
fn pad(canvas: pixel.Canvas, lane: u3, held: bool) void {
    const p = radial(lane, 83);
    ring(canvas, p[0], p[1], 12, if (held) colors.highlight else colors.accent, if (held) colors.berry else colors.panel);
    const label = [_]u8{'1' + @as(u8, lane)};
    canvas.text(&label, p[0] - 2, p[1] - 3, 1, if (held) colors.text else colors.muted);
}
fn difficultyLabel(state: *const game.State) []const u8 {
    return switch (state.difficulty) {
        .easy => "EASY",
        .normal => "NORMAL",
        .five => "5 TOUCH",
    };
}
pub fn backdrop(canvas: pixel.Canvas) void {
    canvas.clear(bg);
    canvas.circle(116, 116, 98, colors.border);
    canvas.circle(116, 116, 96, bg);
    ring(canvas, 116, 116, 83, colors.border, bg);
    ring(canvas, 116, 116, 48, colors.surface, bg);
    for (0..8) |i| {
        const lane: u3 = @intCast(i);
        const p = radial(lane, 83);
        const inner = radial(lane, 49);
        canvas.line(inner[0], inner[1], p[0], p[1], colors.surface);
        pad(canvas, lane, false);
    }
    canvas.rect(94, 22, 45, 9, bg);
    canvas.centeredText("120 BPM", 23, 1, colors.muted);
    const ornament: jirai.Painter = .{ .canvas = canvas, .k = 1 };
    ornament.sparkle(17, 116, true, colors.berry);
    ornament.sparkle(215, 116, true, colors.berry);
    ornament.heart(113, 177, colors.berry);
    jirai.navigation(canvas, 5, navigation.demo_count, pink, colors.border);
}
pub fn foreground(canvas: pixel.Canvas, state: *const game.State) void {
    var held_lanes: u8 = 0;
    for (state.contacts) |contact| if (contact) |lane| {
        held_lanes |= @as(u8, 1) << lane;
    };
    for (0..8) |i| {
        const lane: u3 = @intCast(i);
        if (held_lanes & (@as(u8, 1) << lane) != 0) pad(canvas, lane, true);
    }
    if (state.phase == .playing or state.phase == .waiting or state.phase == .paused) {
        const lead = state.approachMs();
        const selected = state.selected();
        for (selected.notes[0..selected.count], 0..) |note, i| {
            const record = state.notes[i];
            if (record.phase == .done) continue;
            const delta: i64 = @as(i64, note.time_ms) - state.song_ms;
            if (delta > lead or delta < -@as(i64, state.hitWindowMs()) and record.phase != .holding) continue;
            const radius: i32 = @intCast(48 + @divTrunc((lead - std.math.clamp(delta, 0, lead)) * 35, lead));
            const p = radial(if (record.phase == .holding) game.expectedLane(note, state.song_ms) else note.lane, radius);
            const color = switch (note.kind) {
                .tap => pink,
                .hold => gold,
                .slide => cyan,
            };
            if (note.kind == .hold) {
                const tail = radial(note.lane, @max(49, radius - 17));
                canvas.line(p[0] - 1, p[1], tail[0] - 1, tail[1], color);
                canvas.line(p[0], p[1], tail[0], tail[1], color);
            }
            if (note.kind == .slide) {
                var previous = p;
                for (1..3) |step| {
                    const next = radial(note.lane +% @as(u3, @intCast(step)), radius);
                    canvas.line(previous[0], previous[1], next[0], next[1], colors.border);
                    previous = next;
                    canvas.circle(next[0], next[1], 3, cyan);
                }
            }
            ring(canvas, p[0], p[1], if (record.phase == .holding) 9 else 7, color, bg);
        }
    }
    canvas.circle(116, 116, 45, bg);
    const ornament: jirai.Painter = .{ .canvas = canvas, .k = 1 };
    ornament.bow(109, 68);
    canvas.centeredText("ORBIT", 81, 2, colors.text);
    var text: [64]u8 = undefined;
    switch (state.phase) {
        .ready => {
            canvas.centeredText("TAP START", 107, 1, colors.highlight);
            canvas.centeredText(difficultyLabel(state), 124, 1, colors.accent);
            canvas.centeredText("TAP LEVEL", 138, 1, colors.muted);
        },
        .waiting => canvas.centeredText("SYNC...", 115, 1, colors.highlight),
        .paused => {
            canvas.centeredText("PAUSED", 110, 1, colors.highlight);
            canvas.centeredText("TAP RESUME", 128, 1, colors.accent);
        },
        .failed => {
            canvas.centeredText("AUDIO ERROR", 110, 1, pink);
            canvas.centeredText("TAP RETRY", 128, 1, colors.accent);
        },
        .results => {
            const value = state.accuracy();
            canvas.centeredText(std.fmt.bufPrint(&text, "{d}.{d}%", .{ value / 10, value % 10 }) catch "", 107, 2, colors.highlight);
            canvas.centeredText(std.fmt.bufPrint(&text, "MAX {d}", .{state.max_combo}) catch "", 126, 1, colors.accent);
            canvas.centeredText(difficultyLabel(state), 140, 1, colors.accent);
        },
        .playing => {
            if (state.difficulty == .easy and state.song_ms < 4000) {
                canvas.centeredText("READY", 105, 2, colors.highlight);
            } else canvas.centeredText(std.fmt.bufPrint(&text, "{d}", .{state.combo}) catch "", 103, 3, colors.highlight);
            const hint = if (state.difficulty != .easy) "COMBO" else if (state.song_ms < 10_000 or state.song_ms >= 16_000 and state.song_ms < 22_000 or state.song_ms >= 29_000) "TAP AT RING" else if (state.song_ms < 14_000) "HOLD YELLOW" else if (state.song_ms < 16_000 or state.song_ms >= 27_000) "TAP BOTH" else "FOLLOW CYAN";
            canvas.centeredText(hint, 128, 1, colors.muted);
            if (state.last_grade != null and state.song_ms < state.grade_until) canvas.centeredText(@tagName(state.last_grade.?), 140, 1, if (state.last_grade.? == .miss) pink else colors.accent);
        },
    }
    canvas.centeredText(std.fmt.bufPrint(&text, "TOUCH {d} PEAK {d}", .{ state.current_touches, state.max_touches }) catch "", 154, 1, colors.muted);
    canvas.rect(43, 207, 146, 10, bg);
    canvas.centeredText(if (state.phase == .playing) "CTR PAUSE / RIM PAGE" else if (state.phase == .results) "CENTER RETRY / LEVEL" else "TAP HOLD ARC SLIDE", 209, 1, colors.muted);
    const progress: i32 = @intCast(@as(u64, state.song_ms) * 32 / game.duration_ms);
    canvas.rect(100, 190, 32, 2, colors.border);
    canvas.rect(100, 190, progress, 2, pink);
}
pub fn draw(canvas: pixel.Canvas, state: *const game.State) void {
    backdrop(canvas);
    foreground(canvas, state);
}
test "all pad pixels remain inside content touch zone at fixed 2x resolution" {
    for (0..8) |lane| {
        const p = radial(@intCast(lane), 83);
        for (0..25) |iy| for (0..25) |ix| {
            const dx: i32 = @as(i32, @intCast(ix)) - 12;
            const dy: i32 = @as(i32, @intCast(iy)) - 12;
            if (dx * dx + dy * dy > 144) continue;
            const x = (p[0] + dx) * 2;
            const y = (p[1] + dy) * 2;
            try std.testing.expectEqual(navigation.Owner.content, navigation.zone(x, y));
        };
    }
}

test "cached backdrop matches complete rendering across play pause results and five held pads" {
    const allocator = std.testing.allocator;
    const cached = try allocator.alloc(u16, 233 * 233);
    defer allocator.free(cached);
    const partial = try allocator.alloc(u16, 233 * 233);
    defer allocator.free(partial);
    const full = try allocator.alloc(u16, 233 * 233);
    defer allocator.free(full);
    backdrop(pixel.Canvas.init(cached, 233, 233));
    for ([_]@FieldType(game.State, "phase"){ .ready, .waiting, .playing, .paused, .results }) |phase| {
        var state: game.State = .{ .phase = phase, .song_ms = 3800 };
        for (0..5) |i| state.contacts[i] = @intCast(i);
        @memcpy(partial, cached);
        foreground(pixel.Canvas.init(partial, 233, 233), &state);
        draw(pixel.Canvas.init(full, 233, 233), &state);
        try std.testing.expectEqualSlices(u16, full, partial);
    }
}
