use super::hit;
use crate::app::OmnibarHit;
use cmux_tui_core::Rect;

#[test]
fn editing_omnibar_treats_entire_row_as_edit_text() {
    let rect = Rect { x: 10, y: 2, width: 20, height: 1 };
    assert_eq!(hit(rect, 0, 11, 2, true), Some(OmnibarHit::Edit));
    assert_eq!(hit(rect, 0, 13, 2, true), Some(OmnibarHit::Edit));
    assert_eq!(hit(rect, 0, 15, 2, true), Some(OmnibarHit::Edit));
}

#[test]
fn clipped_omnibar_hits_keep_their_logical_columns() {
    let rect = Rect { x: 20, y: 2, width: 8, height: 1 };
    assert_eq!(hit(rect, 4, 21, 2, false), Some(OmnibarHit::Reload));
    assert_eq!(hit(rect, 4, 23, 2, false), Some(OmnibarHit::Edit));
    assert_eq!(hit(rect, 4, 20, 2, false), None);
}
