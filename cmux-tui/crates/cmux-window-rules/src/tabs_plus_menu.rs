//! Opt-in primary pane + menu (`tabs.plusMenu`). Empty or malformed settings
//! keep direct creation.

use serde::Serialize;
use serde_json::Value;

/// One menu row: the existing action it runs and where it runs.
#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub action: &'static str,
    /// Runs against the clicked pane (and its machine).
    pub pane_target: bool,
    /// Runs on the local machine, even when + belongs to a remote pane.
    pub local_workspace: bool,
}

const fn row(action: &'static str, pane_target: bool, local_workspace: bool) -> Row {
    Row { action, pane_target, local_workspace }
}

/// The setting is an ordered subset of `terminal`, `localWorkspace`,
/// `machineWorkspace` and `host`. Reject the whole malformed list, as the
/// settings validator does; never silently turn a typo into a different menu.
pub fn rows(setting: &Value) -> Vec<Row> {
    let Some(items) = setting.as_array() else {
        return Vec::new();
    };
    let mut rows: Vec<Row> = Vec::new();
    let mut seen: Vec<&str> = Vec::new();
    for item in items {
        let Some(name) = item.as_str() else {
            return Vec::new();
        };
        let next = match name {
            "terminal" => row("newSurface", true, false),
            "localWorkspace" => row("workspace.newOnMachine", false, true),
            // No machine argument: the action's own machine picker asks.
            "machineWorkspace" => row("workspace.newOnMachine", false, false),
            "host" => row("remote.connect", true, false),
            _ => return Vec::new(),
        };
        if seen.contains(&name) {
            return Vec::new();
        }
        seen.push(name);
        rows.push(next);
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn plus_menu_keeps_default_and_rejects_invalid_lists() {
        for value in [
            Value::Null,
            json!([]),
            json!(false),
            json!("terminal"),
            json!(["typo"]),
            json!(["terminal", 1]),
            json!(["host", "host"]),
            json!(["terminal", "localWorkspace", "terminal"]),
        ] {
            assert!(rows(&value).is_empty(), "{value}");
        }
    }

    #[test]
    fn plus_menu_preserves_order_and_destinations() {
        let rows = rows(&json!(["host", "machineWorkspace", "localWorkspace", "terminal"]));
        assert_eq!(
            rows,
            [
                row("remote.connect", true, false),
                row("workspace.newOnMachine", false, false),
                row("workspace.newOnMachine", false, true),
                row("newSurface", true, false),
            ]
        );
        assert_eq!(super::rows(&json!(["terminal"])).len(), 1);
    }

    #[test]
    fn plus_menu_rows_encode_for_the_app() {
        let encoded = serde_json::to_value(rows(&json!(["localWorkspace"]))).unwrap();
        assert_eq!(
            encoded,
            json!([{ "action": "workspace.newOnMachine", "paneTarget": false, "localWorkspace": true }])
        );
    }
}
