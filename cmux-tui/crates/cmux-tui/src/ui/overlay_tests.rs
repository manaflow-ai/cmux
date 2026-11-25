use cmux_tui_core::Rect;
use ratatui::buffer::CellWidth;

use super::{label_width, toast_rect_for_label, wrapped_message_lines};
use crate::localization::catalog_for_locale;

#[test]
fn pairing_dialog_has_english_and_japanese_copy() {
    assert_eq!(catalog_for_locale("en_US.UTF-8").pairing.title, "Approve browser?");
    assert_eq!(catalog_for_locale("ja_JP.UTF-8").pairing.title, "ブラウザを承認しますか？");
}

#[test]
fn toast_occlusion_uses_the_rendered_character_clamp() {
    assert_eq!(
        toast_rect_for_label(Rect { x: 10, y: 2, width: 10, height: 5 }, " 界 "),
        Some(Rect { x: 15, y: 5, width: 4, height: 1 })
    );
}

#[test]
fn overlay_labels_and_wrapping_use_terminal_cell_width() {
    assert_eq!(label_width(" 界 "), 4);
    let lines = wrapped_message_lines("界界界", 4, 2);
    assert_eq!(lines, vec!["界界", "界"]);
    assert!(lines.iter().all(|line| line.cell_width() <= 4));
}

#[test]
#[allow(clippy::unicode_not_nfc)]
fn wrapping_trims_whitespace_graphemes_without_orphaning_marks() {
    let lines = wrapped_message_lines("a \u{301}b", 2, 2);
    assert_eq!(lines, vec!["a", "b"]);
}

#[test]
#[allow(clippy::unicode_not_nfc)]
fn wrapping_uses_terminal_cell_width_for_halfwidth_dakuten() {
    let lines = wrapped_message_lines("界ﾞ界ﾞ", 5, 2);
    assert_eq!(lines, vec!["界ﾞ", "界ﾞ"]);
}
