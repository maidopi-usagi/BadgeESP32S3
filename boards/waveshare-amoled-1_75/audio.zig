const Handle = *anyopaque;
// esp_codec_dev_sample_info_t from the locked esp_codec_dev component.
const Format = extern struct {
    bits_per_sample: u8 = 16,
    channel: u8 = 1,
    channel_mask: u16 = 0,
    sample_rate: u32,
    mclk_multiple: c_int = 256,
};
comptime {
    if (@sizeOf(Format) != 12 or @offsetOf(Format, "sample_rate") != 4) @compileError("Audio sample-info ABI mismatch");
}
extern fn bsp_audio_codec_speaker_init() ?Handle;
extern fn badge_audio_prepare() c_int;
extern fn esp_codec_dev_open(handle: Handle, format: *Format) c_int;
extern fn esp_codec_dev_set_out_vol(handle: Handle, volume: c_int) c_int;
extern fn esp_codec_dev_set_out_mute(handle: Handle, muted: bool) c_int;
extern fn esp_codec_dev_write(handle: Handle, samples: *anyopaque, bytes: c_int) c_int;
extern fn esp_codec_dev_close(handle: Handle) c_int;
extern fn esp_codec_dev_get_out_vol(handle: Handle, volume: *c_int) c_int;
extern fn esp_codec_dev_read_reg(handle: Handle, reg: c_int, value: *c_int) c_int;
var speaker: ?Handle = null;

pub fn open(sample_rate: u32, volume: u8) !void {
    if (sample_rate != 22050) return error.UnsupportedSampleRate;
    if (volume > 100) return error.VolumeTooHigh;
    const handle = speaker orelse blk: {
        const created = bsp_audio_codec_speaker_init() orelse return error.SpeakerInitFailed;
        speaker = created;
        break :blk created;
    };
    if (badge_audio_prepare() != 0) return error.AudioReceiveDisableFailed;
    var format: Format = .{ .sample_rate = sample_rate };
    if (esp_codec_dev_open(handle, &format) != 0) return error.SpeakerOpenFailed;
    errdefer close();
    // BSP starts I2S with cleared DMA data; set gain while the DAC is muted.
    if (esp_codec_dev_set_out_mute(handle, true) != 0) return error.SpeakerMuteFailed;
    if (esp_codec_dev_set_out_vol(handle, volume) != 0) return error.SpeakerVolumeFailed;
    var silence: [512]i16 = @splat(0);
    try write(&silence);
    if (esp_codec_dev_set_out_mute(handle, false) != 0) return error.SpeakerUnmuteFailed;
}
pub const Status = struct { volume: c_int, mute: c_int, gain: c_int, format: c_int };
pub fn status() !Status {
    const handle = speaker orelse return error.SpeakerNotOpen;
    var result: Status = undefined;
    if (esp_codec_dev_get_out_vol(handle, &result.volume) != 0 or
        esp_codec_dev_read_reg(handle, 0x31, &result.mute) != 0 or
        esp_codec_dev_read_reg(handle, 0x32, &result.gain) != 0 or
        esp_codec_dev_read_reg(handle, 0x09, &result.format) != 0) return error.SpeakerReadbackFailed;
    return result;
}
pub fn write(samples: []i16) !void {
    const handle = speaker orelse return error.SpeakerNotOpen;
    if (samples.len > 512) return error.AudioBlockTooLarge;
    if (esp_codec_dev_write(handle, @ptrCast(samples.ptr), @intCast(samples.len * 2)) != 0) return error.AudioWriteFailed;
}
pub fn close() void {
    if (speaker) |handle| {
        _ = esp_codec_dev_set_out_mute(handle, true);
        _ = esp_codec_dev_close(handle);
    }
}
