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

/// Thumb position and length for a discrete set of horizontal columns.
pub(crate) fn horizontal_thumb_geometry(
    columns: usize,
    active: usize,
    track_width: u16,
) -> (u16, u16) {
    if columns == 0 || track_width == 0 {
        return (0, 0);
    }
    let thumb_width =
        usize::from(track_width).div_ceil(columns).clamp(1, usize::from(track_width)) as u16;
    let travel = track_width.saturating_sub(thumb_width);
    if columns == 1 || travel == 0 {
        return (0, thumb_width);
    }
    let active = active.min(columns - 1) as u32;
    let x = (active * u32::from(travel) + (columns as u32 - 1) / 2) / (columns as u32 - 1);
    (x as u16, thumb_width)
}

/// Nearest horizontal column for a cell position inside a track.
pub(crate) fn horizontal_column_at(
    columns: usize,
    track_width: u16,
    position: u16,
) -> Option<usize> {
    if columns == 0 || track_width == 0 {
        return None;
    }
    if columns == 1 || track_width == 1 {
        return Some(0);
    }
    let position = position.min(track_width - 1) as u32;
    let index = (position * (columns as u32 - 1) + u32::from(track_width - 1) / 2)
        / u32::from(track_width - 1);
    Some(index as usize)
}

#[cfg(test)]
mod tests {
    use super::{horizontal_column_at, horizontal_thumb_geometry};

    #[test]
    fn horizontal_thumb_tracks_discrete_columns() {
        assert_eq!(horizontal_thumb_geometry(0, 0, 20), (0, 0));
        assert_eq!(horizontal_thumb_geometry(1, 0, 20), (0, 20));
        assert_eq!(horizontal_thumb_geometry(3, 0, 12), (0, 4));
        assert_eq!(horizontal_thumb_geometry(3, 1, 12), (4, 4));
        assert_eq!(horizontal_thumb_geometry(3, 2, 12), (8, 4));
    }

    #[test]
    fn horizontal_track_positions_choose_the_nearest_column() {
        assert_eq!(horizontal_column_at(0, 10, 0), None);
        assert_eq!(horizontal_column_at(3, 11, 0), Some(0));
        assert_eq!(horizontal_column_at(3, 11, 5), Some(1));
        assert_eq!(horizontal_column_at(3, 11, 10), Some(2));
    }
}
