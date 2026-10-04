//! Field validation of the effectful topology operations.

use super::*;

pub(super) fn validate_effect_fields(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
) -> anyhow::Result<()> {
    match operation {
        ResourceOperation::WorkspaceCreate => {
            anyhow::ensure!(
                required_str(fields, "initial_content")? == "terminal",
                "effectful workspace creation requires terminal initial content"
            );
            if fields.contains_key("argv") || fields.contains_key("shell") {
                let _ = effect_command(fields)?;
            }
        }
        ResourceOperation::WorkspaceRun | ResourceOperation::PaneRun => {
            let _ = effect_command(fields)?;
            let _ = effect_cell_size(fields)?;
        }
        ResourceOperation::WorkspaceLayoutApply => {
            anyhow::ensure!(fields["layout"].is_object(), "layout must be an object");
        }
        ResourceOperation::PaneCreate | ResourceOperation::TabCreateTerminal => {
            let _ = effect_cell_size(fields)?;
            let _ = optional_effect_command(fields)?;
        }
        ResourceOperation::PaneSplit => {
            let direction = required_str(fields, "direction")?;
            anyhow::ensure!(
                matches!(direction, "left" | "right" | "up" | "down"),
                "invalid pane split direction"
            );
            if let Some(ratio) = fields.get("ratio").and_then(Value::as_f64) {
                anyhow::ensure!(
                    ratio.is_finite() && 0.0 < ratio && ratio < 1.0,
                    "invalid pane split ratio"
                );
                let ratio = ratio as f32;
                anyhow::ensure!(
                    ratio.is_finite() && 0.0 < ratio && ratio < 1.0,
                    "pane split ratio cannot be represented"
                );
            }
            if let Some(width) = fields.get("viewport_width").and_then(Value::as_f64) {
                anyhow::ensure!(
                    direction == "right"
                        && width.is_finite()
                        && (f64::from(MIN_VIEWPORT_PANE_WIDTH)
                            ..=f64::from(MAX_VIEWPORT_PANE_WIDTH))
                            .contains(&width),
                    "invalid viewport pane width"
                );
            }
            rows::validate_row_height_field(fields, direction)?;
            let _ = effect_cell_size(fields)?;
            let _ = optional_effect_command(fields)?;
        }
        ResourceOperation::TabCreateBrowser => {
            anyhow::ensure!(!required_str(fields, "url")?.is_empty(), "browser URL is empty");
            let dimensions = (
                fields.get("width_px").and_then(Value::as_u64),
                fields.get("height_px").and_then(Value::as_u64),
            );
            anyhow::ensure!(
                matches!(dimensions, (None, None) | (Some(_), Some(_))),
                "browser pixel dimensions must be paired"
            );
        }
        _ => {}
    }
    Ok(())
}
