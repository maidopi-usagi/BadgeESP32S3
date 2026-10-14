//! Main-task power loop. No LVGL callback sleeps or waits for worker shutdown.
const std = @import("std");
const idf = @import("esp_idf");
const board = @import("board");
const ui = @import("../ui/badge.zig");
const Button = @import("button.zig").Button;
const log = std.log.scoped(idf.log.default_log_scope);

fn nowMs() u64 {
    return @intCast(@divTrunc(idf.sys.esp_timer_get_time(), 1000));
}

pub fn run() void {
    board.Power.init() catch |err| {
        log.err("PWR unavailable: {s}; demos remain active", .{@errorName(err)});
        while (true) idf.rtos.Task.delayMs(5000);
    };
    const battery = board.Battery.Monitor.open() catch |err| blk: {
        log.warn("Battery monitor unavailable: {s}", .{@errorName(err)});
        break :blk null;
    };
    if (battery) |monitor| {
        log.info("AXP2101 ready: addr=0x34, ID=0x4a; read-only battery telemetry", .{});
        pollBattery(monitor, true);
    }
    var button: Button = .{};
    var errors: u8 = 0;
    var heartbeat = nowMs();
    var battery_poll = heartbeat;
    var battery_report = heartbeat;
    log.info("PWR ready: TCA9554 EXIO4 active-high, 30ms debounce; press to sleep/wake; USB host keeps console alive", .{});
    while (true) {
        idf.rtos.Task.delayMs(20);
        const pressed = board.Power.pressed() catch {
            if (errors == 0) log.warn("PWR read failed", .{});
            errors +|= 1;
            _ = button.sample(null, nowMs());
            continue;
        };
        errors = 0;
        if (button.sample(pressed, nowMs())) {
            sleepCycle(&button) catch |err| log.err("Sleep cancelled/recovered: {s}", .{@errorName(err)});
            heartbeat = nowMs();
            battery_poll = 0;
        }
        if (nowMs() - battery_poll >= 1000) {
            const report = nowMs() - battery_report >= 5000;
            if (battery) |monitor| pollBattery(monitor, report);
            battery_poll = nowMs();
            if (report) battery_report = battery_poll;
        }
        if (nowMs() - heartbeat >= 5000) {
            log.info("badge runtime alive", .{});
            heartbeat = nowMs();
        }
    }
}

fn pollBattery(monitor: board.Battery.Monitor, report: bool) void {
    const reading = monitor.read() catch |err| blk: {
        log.warn("Battery read failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    board.Display.lock() catch |err| {
        log.warn("Battery UI lock failed: {s}", .{@errorName(err)});
        return;
    };
    ui.setBattery(if (reading) |value| .{
        .present = value.present,
        .percent = value.percent,
        .external_power = value.vbus_good,
        .charging = value.direction == .charging,
        .charge_done = value.phase == .done,
    } else null);
    board.Display.unlock();
    if (!report) return;
    const sample = reading orelse return;
    log.info("Battery: present={}, voltage_mv={?d}, gauge_percent={?d}, vbus_good={}, direction={s}, charge_phase={s}", .{
        sample.present, sample.millivolts, sample.percent, sample.vbus_good, @tagName(sample.direction), @tagName(sample.phase),
    });
}

fn sleepCycle(button: *Button) !void {
    try board.Display.pause();
    var prepared = false;
    var panel_attempted = false;
    defer {
        if (panel_attempted) board.Display.sleep(false) catch |err| log.err("Panel wake: {s}", .{@errorName(err)});
        if (prepared) {
            if (board.Display.lock()) |_| {
                ui.resumeAfterSleep(nowMs());
                board.Display.unlock();
            } else |err| log.err("UI wake lock: {s}", .{@errorName(err)});
        }
        board.Display.resumeAfterSleep() catch |err| log.err("LVGL wake: {s}", .{@errorName(err)});
    }
    try board.Display.lock();
    ui.pauseForSleep(nowMs());
    prepared = true;
    board.Display.unlock();
    const deadline = nowMs() + 3000;
    while (ui.busyWorkers() != 0) {
        if (nowMs() >= deadline) {
            log.err("Power: pause timeout, workers=0x{x}", .{ui.busyWorkers()});
            return error.WorkerPauseTimeout;
        }
        idf.rtos.Task.delayMs(10);
    }
    panel_attempted = true;
    try board.Display.sleep(true);
    const usb = board.Power.usbConnected();
    var light_sleep = !usb;
    log.info("Power: asleep mode={s}; all workers acknowledged; next PWR press wakes", .{if (usb) @as([]const u8, "usb-standby") else "light-sleep"});
    var errors: u8 = 0;
    var polls: u32 = 0;
    while (true) {
        board.Power.wait(light_sleep) catch {
            log.warn("Light-sleep rejected; continuing suspended standby", .{});
            light_sleep = false;
        };
        polls +%= 1;
        const pressed = board.Power.pressed() catch {
            _ = button.sample(null, nowMs());
            errors += 1;
            if (errors >= 5) return error.PowerKeyReadFailed;
            continue;
        };
        errors = 0;
        if (button.sample(pressed, nowMs())) break;
    }
    log.info("Power: PWR wake, polls={d}", .{polls});
}
