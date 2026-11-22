//! Ghostty color values: `#RRGGBB`, `RRGGBB`, `#RGB`, or an X11 color name.

use crate::Rgb;

/// Parses a Ghostty color value. Names cover the common X11 colors only
/// (Ghostty knows the whole X11 list; themes use hex).
pub fn parse_color(value: &str) -> Option<Rgb> {
    let v = value.trim();
    let hex = v.strip_prefix('#').unwrap_or(v);
    if hex.chars().all(|c| c.is_ascii_hexdigit()) {
        match hex.len() {
            6 => return u32::from_str_radix(hex, 16).ok().map(Rgb::hex),
            3 => {
                let n = u32::from_str_radix(hex, 16).ok()?;
                let (r, g, b) = ((n >> 8) & 0xf, (n >> 4) & 0xf, n & 0xf);
                return Some(Rgb::hex(((r * 17) << 16) | ((g * 17) << 8) | (b * 17)));
            }
            _ => {}
        }
    }
    let name: String =
        v.chars().filter(|c| !c.is_whitespace()).collect::<String>().to_ascii_lowercase();
    X11.iter().find(|(n, _)| *n == name).map(|(_, hex)| Rgb::hex(*hex))
}

const X11: &[(&str, u32)] = &[
    ("black", 0x000000),
    ("white", 0xffffff),
    ("red", 0xff0000),
    ("green", 0x00ff00),
    ("blue", 0x0000ff),
    ("yellow", 0xffff00),
    ("cyan", 0x00ffff),
    ("magenta", 0xff00ff),
    ("gray", 0xbebebe),
    ("grey", 0xbebebe),
    ("darkgray", 0xa9a9a9),
    ("darkgrey", 0xa9a9a9),
    ("lightgray", 0xd3d3d3),
    ("lightgrey", 0xd3d3d3),
    ("dimgray", 0x696969),
    ("dimgrey", 0x696969),
    ("orange", 0xffa500),
    ("purple", 0xa020f0),
    ("pink", 0xffc0cb),
    ("brown", 0xa52a2a),
    ("navy", 0x000080),
    ("navyblue", 0x000080),
    ("teal", 0x008080),
    ("maroon", 0xb03060),
    ("olive", 0x808000),
    ("silver", 0xc0c0c0),
    ("lime", 0x00ff00),
    ("gold", 0xffd700),
    ("ivory", 0xfffff0),
    ("beige", 0xf5f5dc),
    ("snow", 0xfffafa),
    ("whitesmoke", 0xf5f5f5),
    ("gainsboro", 0xdcdcdc),
    ("darkslategray", 0x2f4f4f),
    ("darkslategrey", 0x2f4f4f),
    ("slategray", 0x708090),
    ("slategrey", 0x708090),
    ("midnightblue", 0x191970),
];
