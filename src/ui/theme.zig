const palette = @This();

pub const name = "midnight-jirai";
pub const background: u24 = 0x09070D;
pub const panel: u24 = 0x18101E;
pub const surface: u24 = 0x261A2C;
pub const border: u24 = 0x51364F;
pub const accent: u24 = 0xAB8BD1;
pub const rose: u24 = 0xD18AA8;
pub const berry: u24 = 0x7D385B;
pub const highlight: u24 = 0xF4C8DB;
pub const text: u24 = 0xF0DBE9;
pub const muted: u24 = 0xAA90A7;

pub fn rgb565(rgb: u24) u16 {
    return @intCast(((rgb >> 8) & 0xF800) | ((rgb >> 5) & 0x07E0) | ((rgb >> 3) & 0x001F));
}

pub const colors = struct {
    pub const background = rgb565(palette.background);
    pub const panel = rgb565(palette.panel);
    pub const surface = rgb565(palette.surface);
    pub const border = rgb565(palette.border);
    pub const accent = rgb565(palette.accent);
    pub const rose = rgb565(palette.rose);
    pub const berry = rgb565(palette.berry);
    pub const highlight = rgb565(palette.highlight);
    pub const text = rgb565(palette.text);
    pub const muted = rgb565(palette.muted);
};
