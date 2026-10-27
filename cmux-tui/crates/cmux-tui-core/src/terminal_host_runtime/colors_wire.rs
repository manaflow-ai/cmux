//! The terminal-host Colors frame payload: dynamic render metadata
//! (moved from `terminal_host_runtime.rs`).

use super::*;

/// Encode a complete dynamic render-metadata state.
///
/// Wire layout is little-endian: schema_version:u16, flags:u16 (foreground,
/// background, cursor color, cursor visual), palette_count:u16, reserved:u16,
/// each flagged RGB in that order, the atomic cursor style/blink pair when
/// flagged, then palette_count repetitions of index:u8 + RGB. RGB and palette
/// fields remain sparse theme overrides. Version 2 producers populate the
/// host-resolved cursor visual. An absent visual is the version 1 fallback:
/// the cursor state is unknown and the receiving renderer must preserve its
/// current raw-VT/default cursor rather than infer a reset.
pub fn encode_terminal_color_overrides(colors: &TerminalColorOverrides) -> Vec<u8> {
    // Version 2 producers always resolve the cursor visual. Without one the
    // payload is version 1: the receiver keeps its current cursor.
    let cursor_visual = colors.cursor_visual;
    let mut flags = 0u16;
    flags |= colors.foreground.is_some() as u16;
    flags |= (colors.background.is_some() as u16) << 1;
    flags |= (colors.cursor.is_some() as u16) << 2;
    flags |= u16::from(cursor_visual.is_some()) << 3;
    let version = if cursor_visual.is_some() {
        TERMINAL_COLORS_WIRE_VERSION
    } else {
        TERMINAL_COLORS_WIRE_VERSION_V1
    };
    let palette_count = colors.palette.iter().filter(|color| color.is_some()).count() as u16;
    let rgb_bytes = (flags & 0b111).count_ones() as usize * 3;
    let mut payload = Vec::with_capacity(8 + rgb_bytes + 2 + usize::from(palette_count) * 4);
    payload.extend_from_slice(&version.to_le_bytes());
    payload.extend_from_slice(&flags.to_le_bytes());
    payload.extend_from_slice(&palette_count.to_le_bytes());
    payload.extend_from_slice(&0u16.to_le_bytes());
    for color in [colors.foreground, colors.background, colors.cursor].into_iter().flatten() {
        payload.extend_from_slice(&[color.r, color.g, color.b]);
    }
    if let Some((style, blink)) = cursor_visual {
        let style = match style {
            ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => 1,
            ghostty_vt::CursorShape::Underline => 2,
            ghostty_vt::CursorShape::Bar => 3,
        };
        payload.extend_from_slice(&[style, blink as u8]);
    }
    for (index, color) in colors.palette.iter().enumerate() {
        if let Some(color) = color {
            payload.extend_from_slice(&[index as u8, color.r, color.g, color.b]);
        }
    }
    debug_assert!(payload.len() <= MAX_TERMINAL_COLORS_PAYLOAD);
    payload
}

pub fn decode_terminal_color_overrides(payload: &[u8]) -> anyhow::Result<TerminalColorOverrides> {
    if payload.len() < 8 || payload.len() > MAX_TERMINAL_COLORS_PAYLOAD {
        anyhow::bail!("terminal-host Colors payload length is out of range");
    }
    let header = |offset| {
        crate::terminal_host_protocol::wire_u16(payload, offset)
            .ok_or_else(|| anyhow::anyhow!("terminal-host Colors payload length is out of range"))
    };
    let version = header(0)?;
    let flags = header(2)?;
    let palette_count = usize::from(header(4)?);
    let reserved = header(6)?;
    let allowed_flags = match version {
        TERMINAL_COLORS_WIRE_VERSION_V1 => 0b111,
        TERMINAL_COLORS_WIRE_VERSION if flags & 0b1000 != 0 => 0b1111,
        TERMINAL_COLORS_WIRE_VERSION => {
            anyhow::bail!("terminal-host Colors v2 is missing the cursor visual")
        }
        _ => anyhow::bail!("unsupported terminal-host Colors payload version"),
    };
    if flags & !allowed_flags != 0 || reserved != 0 {
        anyhow::bail!("unsupported terminal-host Colors payload header");
    }
    if palette_count > 256 {
        anyhow::bail!("terminal-host Colors palette count is out of range");
    }
    let expected = 8
        + (flags & 0b111).count_ones() as usize * 3
        + usize::from(flags & 0b1000 != 0) * 2
        + palette_count * 4;
    if payload.len() != expected {
        anyhow::bail!("malformed terminal-host Colors payload");
    }
    // The length check above sized the body exactly; reads past it are still
    // errors, never panics.
    fn take_byte(body: &mut impl Iterator<Item = u8>) -> anyhow::Result<u8> {
        body.next().ok_or_else(|| anyhow::anyhow!("malformed terminal-host Colors payload"))
    }
    fn take_rgb(body: &mut impl Iterator<Item = u8>) -> anyhow::Result<Rgb> {
        Ok(Rgb { r: take_byte(body)?, g: take_byte(body)?, b: take_byte(body)? })
    }
    fn take_flagged_rgb(
        present: bool,
        body: &mut impl Iterator<Item = u8>,
    ) -> anyhow::Result<Option<Rgb>> {
        if present { take_rgb(body).map(Some) } else { Ok(None) }
    }
    let mut body = payload.get(8..).unwrap_or_default().iter().copied();
    let foreground = take_flagged_rgb(flags & 1 != 0, &mut body)?;
    let background = take_flagged_rgb(flags & 2 != 0, &mut body)?;
    let cursor = take_flagged_rgb(flags & 4 != 0, &mut body)?;
    let cursor_visual = if flags & 8 != 0 {
        let style = match take_byte(&mut body)? {
            1 => ghostty_vt::CursorShape::Block,
            2 => ghostty_vt::CursorShape::Underline,
            3 => ghostty_vt::CursorShape::Bar,
            _ => anyhow::bail!("terminal-host Colors cursor style is out of range"),
        };
        let blink = match take_byte(&mut body)? {
            0 => false,
            1 => true,
            _ => anyhow::bail!("terminal-host Colors cursor blink is out of range"),
        };
        Some((style, blink))
    } else {
        None
    };
    let mut palette = [None; 256];
    for _ in 0..palette_count {
        let index = usize::from(take_byte(&mut body)?);
        let Some(slot) = palette.get_mut(index) else {
            anyhow::bail!("terminal-host Colors palette index is out of range");
        };
        if slot.is_some() {
            anyhow::bail!("duplicate terminal-host Colors palette index");
        }
        *slot = Some(take_rgb(&mut body)?);
    }
    Ok(TerminalColorOverrides { foreground, background, cursor, cursor_visual, palette })
}
