//! The committed public value that a topology mutation's result carries
//! (`public_value`), taken from the deltas committed in the same
//! transaction.

use super::*;

pub(super) fn persist_public_topology_result(
    operation: &str,
    result: &mut Value,
    changes: &Value,
) -> anyhow::Result<()> {
    let Some((resource, identity_field)) = public_topology_result_target(operation) else {
        return Ok(());
    };
    let id = result
        .get(identity_field)
        .and_then(Value::as_str)
        .with_context(|| format!("{operation} result omitted its {identity_field} identity"))?;
    let value = changes
        .as_array()
        .context("public topology changes are not an array")?
        .iter()
        .rev()
        .find(|change| {
            change["kind"] == "upsert"
                && change["resource"] == resource
                && change["id"].as_str() == Some(id)
        })
        .and_then(|change| change.get("value"))
        .cloned()
        .with_context(|| {
            format!("{operation} changes omitted the committed {resource} value for {id}")
        })?;
    result
        .as_object_mut()
        .context("public topology result is not an object")?
        .insert("public_value".to_string(), value);
    Ok(())
}

fn public_topology_result_target(operation: &str) -> Option<(&'static str, &'static str)> {
    match operation {
        "workspace.rename" | "workspace.move" | "workspace.focus" | "workspace.layout.apply" => {
            Some(("workspace", "workspace"))
        }
        "screen.rename" | "screen.focus" | "screen.layout.undo" | "column.update" => {
            Some(("screen", "screen"))
        }
        "pane.rename"
        | "pane.focus"
        | "pane.focus_direction"
        | "pane.swap"
        | "pane.zoom"
        | "pane.split_ratio.set"
        | "pane.viewport_width.set" => Some(("pane", "pane")),
        "tab.rename" | "tab.move" | "tab.focus" => Some(("tab", "tab")),
        _ => None,
    }
}
