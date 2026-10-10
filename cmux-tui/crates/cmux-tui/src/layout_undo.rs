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
