use super::{horizontal_drag_offset, horizontal_offset_at, horizontal_thumb_geometry};

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
    assert_eq!(horizontal_offset_at(120, 80, 12, 4), Some(0));
    assert_eq!(horizontal_offset_at(120, 80, 12, 6), Some(20));
    assert_eq!(horizontal_offset_at(120, 80, 12, 8), Some(40));
    assert_eq!(horizontal_offset_at(120, 80, 12, 11), Some(40));
}

#[test]
fn horizontal_thumb_center_round_trips_to_its_offset() {
    for offset in [0, 20, 40] {
        let (thumb_x, thumb_width) = horizontal_thumb_geometry(120, 80, offset, 12);
        assert_eq!(horizontal_offset_at(120, 80, 12, thumb_x + thumb_width / 2), Some(offset));
    }
}

#[test]
fn horizontal_drag_preserves_its_anchor_and_covers_the_range() {
    assert_eq!(horizontal_drag_offset(120, 80, 12, 40, 0), 40);
    assert_eq!(horizontal_drag_offset(120, 80, 12, 0, 4), 40);
    assert_eq!(horizontal_drag_offset(120, 80, 12, 40, -4), 0);
}

#[test]
fn horizontal_scrollbar_reaches_content_past_u16_extent() {
    let content_width = u64::from(u16::MAX) * 3;
    let maximum = content_width - 80;
    let (thumb_x, thumb_width) = horizontal_thumb_geometry(content_width, 80, maximum, 80);

    assert_eq!(thumb_x + thumb_width, 80);
    assert_eq!(
        horizontal_offset_at(content_width, 80, 80, thumb_x + thumb_width / 2),
        Some(maximum)
    );
}
