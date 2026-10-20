use cmux_tui_core::LayoutUndoResult;
use serde_json::Value;

use crate::localization::LayoutMessages;

pub(crate) fn decode_layout_undo_result(
    value: &Value,
    messages: &LayoutMessages,
) -> anyhow::Result<LayoutUndoResult> {
    let screen = value
        .get("screen")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow::anyhow!(messages.layout_undo_missing_screen))?;
    let revision = value
        .get("revision")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow::anyhow!(messages.layout_undo_missing_revision))?;
    let undone = value.get("undone").and_then(Value::as_bool);
    let confirmation_required = value.get("confirmation_required").and_then(Value::as_bool);

    match (undone, confirmation_required) {
        (Some(true), None | Some(false)) => Ok(LayoutUndoResult::Undone { screen, revision }),
        (Some(false), Some(true)) => {
            let closes_panes = value
                .get("closes_panes")
                .and_then(Value::as_array)
                .ok_or_else(|| anyhow::anyhow!(messages.layout_undo_missing_closes_panes))?
                .iter()
                .map(|value| {
                    value.as_u64().ok_or_else(|| anyhow::anyhow!(messages.layout_undo_invalid_pane))
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            Ok(LayoutUndoResult::ConfirmationRequired { screen, revision, closes_panes })
        }
        _ => anyhow::bail!(messages.layout_undo_missing_outcome),
    }
}

#[cfg(test)]
mod tests {
    use cmux_tui_core::LayoutUndoResult;
    use serde_json::json;

    use super::decode_layout_undo_result;

    #[test]
    fn decoder_accepts_only_complete_layout_undo_variants() {
        let messages = &crate::localization::catalog_for_locale("en").layout;
        assert_eq!(
            decode_layout_undo_result(
                &json!({"undone": true, "screen": 3, "revision": 9}),
                messages,
            )
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
            LayoutUndoResult::ConfirmationRequired {
                screen: 3,
                revision: 8,
                closes_panes: vec![15],
            }
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
}
