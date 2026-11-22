use cmux_tui_core::LayoutUndoResult;
use serde_json::json;

use super::decode_layout_undo_result;

#[test]
fn decoder_accepts_only_complete_layout_undo_variants() {
    let messages = &crate::localization::catalog_for_locale("en").layout;
    assert_eq!(
        decode_layout_undo_result(&json!({"undone": true, "screen": 3, "revision": 9}), messages,)
            .unwrap(),
        LayoutUndoResult::Undone { screen: 3, revision: 9 }
    );
    assert_eq!(
        decode_layout_undo_result(
            &json!({
                "undone": false,
                "confirmation_required": true,
                "screen": 3,
                "revision": 8,
                "closes_panes": [15],
            }),
            messages,
        )
        .unwrap(),
        LayoutUndoResult::ConfirmationRequired { screen: 3, revision: 8, closes_panes: vec![15] }
    );

    for value in [
        json!({
            "undone": false,
            "confirmation_required": true,
            "screen": 3,
            "revision": 8,
        }),
        json!({
            "confirmation_required": true,
            "screen": 3,
            "revision": 8,
            "closes_panes": [15],
        }),
        json!({
            "undone": true,
            "confirmation_required": true,
            "screen": 3,
            "revision": 8,
            "closes_panes": [15],
        }),
        json!({
            "undone": false,
            "confirmation_required": true,
            "revision": 8,
            "closes_panes": [15],
        }),
        json!({
            "undone": false,
            "confirmation_required": true,
            "screen": 3,
            "revision": 8,
            "closes_panes": [15, "16"],
        }),
    ] {
        assert!(decode_layout_undo_result(&value, messages).is_err(), "accepted {value}");
    }
}
