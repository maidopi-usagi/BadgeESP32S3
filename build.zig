const std = @import("std");
const Demo = @import("src/demo.zig").Demo;
const integration = @import("third_party/zig-esp-idf/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .xtensa,
            .cpu_model = .{ .explicit = &std.Target.xtensa.cpu.esp32s3 },
            .os_tag = .freestanding,
            .abi = .none,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const pixel_scale = b.option(u16, "pixel-scale", "Integer canvas scale: 2 or 4") orelse 4;
    if (pixel_scale != 2 and pixel_scale != 4) @panic("pixel-scale must be 2 or 4");
    const render_options = b.addOptions();
    render_options.addOption(u16, "pixel_scale", pixel_scale);
    const start_demo = b.option([]const u8, "start-demo", "Boot demo: fumo, dice, cornell, doom, sandbox, rhythm, fluid or physics") orelse "fumo";
    _ = std.meta.stringToEnum(Demo, start_demo) orelse @panic("Invalid start-demo; see src/demo.zig");
    render_options.addOption([]const u8, "start_demo", start_demo);
    render_options.addOption(bool, "rhythm_autoplay", b.option(bool, "rhythm-autoplay", "Play one Orbit track at boot for hardware measurement") orelse false);
    const python = b.option([]const u8, "python", "Python executable for model conversion") orelse
        if (b.graph.host.result.os.tag == .windows) "python" else "python3";
    const convert = b.addSystemCommand(&.{python});
    convert.addFileArg(b.path("scripts/convert-fumo.py"));
    convert.addFileArg(b.path("assets/models/fumo/source.glb"));
    const packed_fumo = convert.addOutputFileArg("fumo.bin");
    const generated = b.addWriteFiles();
    _ = generated.addCopyFile(packed_fumo, "fumo.bin");
    const asset_source = generated.add("fumo_asset.zig", "pub const bytes = @embedFile(\"fumo.bin\");\n");
    const firmware_asset = b.createModule(.{ .root_source_file = asset_source, .target = target, .optimize = optimize });
    const host_asset = b.createModule(.{ .root_source_file = asset_source, .target = b.graph.host, .optimize = optimize });
    const sys_bindings = b.option([]const u8, "sys-bindings", "Generated bindings path relative to project root") orelse "build/generated/idf-sys.zig";
    const firmware = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    firmware.addImport("esp_idf", integration.idf_wrapped_modules(b, b.path(sys_bindings)));
    firmware.addOptions("render_options", render_options);
    firmware.addImport("fumo_asset", firmware_asset);
    firmware.addImport("board", b.createModule(.{
        .root_source_file = b.path("boards/waveshare-amoled-1_75/board.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const object = b.addObject(.{ .name = "app_zig", .root_module = firmware });
    const install = b.addInstallArtifact(object, .{ .dest_dir = .{ .override = .{ .custom = "obj" } } });
    b.getInstallStep().dependOn(&install.step);
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("fumo_asset", host_asset);
    const run_tests = b.addRunArtifact(unit_tests);
    const convert_tests = b.addSystemCommand(&.{python});
    convert_tests.addFileArg(b.path("scripts/test_convert_fumo.py"));
    convert_tests.addFileArg(b.path("assets/models/fumo/source.glb"));
    convert_tests.addFileArg(b.path("scripts/convert-fumo.py"));
    const test_step = b.step("test", "Run app, model renderer and asset conversion tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&convert_tests.step);
    const source_tests = b.addSystemCommand(&.{python});
    source_tests.addFileArg(b.path("scripts/test_fetch_doom.py"));
    test_step.dependOn(&source_tests.step);

    const doom_smoke = b.addExecutable(.{
        .name = "doom_smoke",
        .root_module = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true }),
    });
    const pins = std.json.parseFromSlice(struct { doomgeneric: struct { path: []const u8 } }, b.allocator, @embedFile("dependencies.json"), .{ .ignore_unknown_fields = true }) catch @panic("Invalid dependencies.json");
    const doom_root = b.path(pins.value.doomgeneric.path);
    const fetch_doom = b.addSystemCommand(&.{python});
    fetch_doom.addFileArg(b.path("scripts/fetch-doom-engine.py"));
    // Validate the local source cache even when a prior compiler run is cached.
    fetch_doom.has_side_effects = true;
    doom_smoke.step.dependOn(&fetch_doom.step);
    var doom_sources: std.array_list.Managed([]const u8) = .init(b.allocator);
    var doom_lines = std.mem.tokenizeAny(u8, @embedFile("components/doom_engine/sources.txt"), "\r\n");
    while (doom_lines.next()) |name| doom_sources.append(name) catch @panic("out of memory");
    doom_sources.append("w_file_stdc.c") catch @panic("out of memory");
    doom_smoke.root_module.addCSourceFiles(.{
        .root = doom_root,
        .files = doom_sources.items,
        .flags = &.{ "-DNORMALUNIX", "-DLINUX", "-D_DEFAULT_SOURCE", "-DDOOMGENERIC_RESX=320", "-DDOOMGENERIC_RESY=200", "-DDOOMGENERIC_FB_BYTES_PER_PIXEL=2", "-fno-strict-aliasing", "-w" },
    });
    doom_smoke.root_module.addIncludePath(doom_root);
    doom_smoke.root_module.addCSourceFile(.{ .file = b.path("scripts/doom-smoke.c"), .flags = &.{ "-DDOOMGENERIC_RESX=320", "-DDOOMGENERIC_RESY=200" } });
    if (b.graph.host.result.os.tag == .windows) doom_smoke.root_module.linkSystemLibrary("user32", .{});
    const run_doom = b.addRunArtifact(doom_smoke);
    const fetch_wad = b.addSystemCommand(&.{python});
    fetch_wad.addFileArg(b.path("scripts/fetch-doom.py"));
    fetch_wad.has_side_effects = true;
    run_doom.step.dependOn(&fetch_wad.step);
    run_doom.addFileArg(b.path(".local/assets/doom1.wad"));
    run_doom.addArg(".local/doom-smoke.ppm");
    const doom_frame = run_doom.addOutputFileArg("doom-frame.rgb565");
    b.step("doom-smoke", "Render and exercise the real Doom engine with the cached shareware IWAD").dependOn(&run_doom.step);

    const preview = b.addExecutable(.{
        .name = "pixel_preview",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/pixel-preview.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    preview.root_module.addOptions("render_options", render_options);
    const preview_options = b.addOptions();
    preview_options.addOption(u64, "time_ms", b.option(u64, "preview-time-ms", "Model animation time for the preview") orelse 0);
    preview_options.addOption(?u64, "bounce_ms", b.option(u64, "preview-bounce-ms", "Milliseconds after a tap; holds the view still"));
    preview_options.addOption(f32, "pitch", b.option(f32, "preview-pitch", "Orbit pitch in radians") orelse 0.12);
    const preview_name = b.option([]const u8, "preview-demo", "Preview fumo, dice, cornell, doom, sandbox, rhythm, fluid or physics") orelse "fumo";
    const preview_demo = std.meta.stringToEnum(Demo, preview_name) orelse @panic("Invalid preview-demo; see src/demo.zig");
    preview_options.addOption(Demo, "demo", preview_demo);
    if (preview_demo == .doom) {
        // Keep engine diagnostics out of the preview's binary PPM stdout.
        _ = run_doom.captureStdOut(.{});
        const doom_assets = b.addWriteFiles();
        _ = doom_assets.addCopyFile(doom_frame, "doom-frame.rgb565");
        const source = doom_assets.add("frame.zig", "pub const bytes = @embedFile(\"doom-frame.rgb565\");\n");
        preview.root_module.addImport("doom_preview_frame", b.createModule(.{
            .root_source_file = source,
            .target = b.graph.host,
            .optimize = optimize,
        }));
    }
    preview_options.addOption([]const u8, "sandbox_gravity", b.option([]const u8, "preview-gravity", "Sandbox gravity: down/down_left/left/up_left/up/up_right/right/down_right") orelse "down");
    const preview_samples = b.option(u32, "preview-spp", "Cornell samples per pixel (1..65535)") orelse 16;
    if (preview_samples < 1 or preview_samples > 65535) @panic("preview-spp must be 1..65535");
    preview_options.addOption(u32, "samples", preview_samples);
    preview_options.addOption(u32, "dice_seed", b.option(u32, "preview-dice-seed", "Physical dice impulse seed; does not choose a face") orelse 17421);
    const roll_ms = b.option(u64, "preview-roll-ms", "Elapsed physical dice simulation, 0..60000ms; omit for welcome screen");
    if (roll_ms != null and roll_ms.? > 60000) @panic("preview-roll-ms must be <=60000");
    preview_options.addOption(?u64, "roll_ms", roll_ms);
    preview.root_module.addOptions("preview_options", preview_options);
    const model_renderer = b.createModule(.{
        .root_source_file = b.path("src/demos.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    model_renderer.addImport("fumo_asset", host_asset);
    preview.root_module.addImport("model_renderer", model_renderer);
    const run_preview = b.addRunArtifact(preview);
    b.step("preview", "Write a nearest-neighbor UI preview as PPM to stdout").dependOn(&run_preview.step);
}
