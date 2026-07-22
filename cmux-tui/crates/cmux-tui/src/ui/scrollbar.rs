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
