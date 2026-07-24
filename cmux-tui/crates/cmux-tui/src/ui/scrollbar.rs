use ghostty_vt::Scrollbar;

/// Thumb position and length (in track cells) for a scrollbar state.
pub(crate) fn thumb_geometry(sb: &Scrollbar, track_height: u16) -> (u16, u16) {
    let track = track_height.max(1) as f64;
    let len = ((sb.len as f64 / sb.total as f64) * track).ceil().clamp(1.0, track) as u16;
    let denom = (sb.total - sb.len).max(1) as f64;
    let frac = (sb.offset as f64 / denom).clamp(0.0, 1.0);
    let y = (frac * (track_height.saturating_sub(len)) as f64).round() as u16;
    (y, len)
}

/// Thumb position and length for a horizontally scrollable viewport.
pub(crate) fn horizontal_thumb_geometry(
    content_width: u16,
    viewport_width: u16,
    offset: u16,
    track_width: u16,
) -> (u16, u16) {
    if content_width == 0 || viewport_width == 0 || track_width == 0 {
        return (0, 0);
    }
    let thumb_width = (u32::from(track_width) * u32::from(viewport_width))
        .div_ceil(u32::from(content_width))
        .clamp(1, u32::from(track_width)) as u16;
    let travel = track_width.saturating_sub(thumb_width);
    let maximum = content_width.saturating_sub(viewport_width);
    if maximum == 0 || travel == 0 {
        return (0, thumb_width);
    }
    let x = (u32::from(offset.min(maximum)) * u32::from(travel) + u32::from(maximum) / 2)
        / u32::from(maximum);
    (x as u16, thumb_width)
}

/// Viewport offset represented by a cell position inside a track.
pub(crate) fn horizontal_offset_at(
    content_width: u16,
    viewport_width: u16,
    track_width: u16,
    position: u16,
) -> Option<u16> {
    if content_width == 0 || viewport_width == 0 || track_width == 0 {
        return None;
    }
    let maximum = content_width.saturating_sub(viewport_width);
    if maximum == 0 || track_width == 1 {
        return Some(0);
    }
    let position = position.min(track_width - 1) as u32;
    let offset = (position * u32::from(maximum) + u32::from(track_width - 1) / 2)
        / u32::from(track_width - 1);
    Some(offset as u16)
}

#[cfg(test)]
mod tests {
    use super::{horizontal_offset_at, horizontal_thumb_geometry};

    #[test]
    fn horizontal_thumb_tracks_the_viewport() {
        assert_eq!(horizontal_thumb_geometry(0, 80, 0, 20), (0, 0));
        assert_eq!(horizontal_thumb_geometry(80, 80, 0, 20), (0, 20));
        assert_eq!(horizontal_thumb_geometry(120, 80, 0, 12), (0, 8));
        assert_eq!(horizontal_thumb_geometry(120, 80, 20, 12), (2, 8));
        assert_eq!(horizontal_thumb_geometry(120, 80, 40, 12), (4, 8));
    }

    #[test]
    fn horizontal_track_positions_map_to_offsets() {
        assert_eq!(horizontal_offset_at(0, 80, 10, 0), None);
        assert_eq!(horizontal_offset_at(120, 80, 11, 0), Some(0));
        assert_eq!(horizontal_offset_at(120, 80, 11, 5), Some(20));
        assert_eq!(horizontal_offset_at(120, 80, 11, 10), Some(40));
    }
}
