//! Ghostty config color syntax, shared by the OSC color overrides.

use super::{Rgb, check, sys};

/// Parse a color with Ghostty's config semantics.
///
/// This accepts Ghostty's hex, X11 name, `rgb:`, and `rgbi:` forms.
pub fn parse_color(value: &str) -> Option<Rgb> {
    let mut color = sys::GhosttyColorRgb::default();
    check(unsafe { sys::ghostty_color_parse(value.as_ptr().cast(), value.len(), &mut color) })
        .ok()?;
    Some(color.into())
}

/// Parse one Ghostty `palette = N=COLOR` value.
pub fn parse_palette_entry(value: &str) -> Option<(u8, Rgb)> {
    let mut index = 0;
    let mut color = sys::GhosttyColorRgb::default();
    check(unsafe {
        sys::ghostty_color_parse_palette_entry(
            value.as_ptr().cast(),
            value.len(),
            &mut index,
            &mut color,
        )
    })
    .ok()?;
    Some((index, color.into()))
}
