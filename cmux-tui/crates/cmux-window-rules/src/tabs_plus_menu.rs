//! Opt-in primary pane + menu. Empty or malformed settings keep direct creation.

use serde::Serialize;
use serde_json::Value;

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub action: &'static str,
    pub local_workspace: bool,
}

/// The setting is an ordered subset. Reject the whole malformed list, as the
/// settings validator does; never silently turn a typo into a different menu.
pub fn rows(setting: &Value) -> Vec<Row> {
    let Some(items) = setting.as_array() else {
        return Vec::new();
    };
    let mut rows = Vec::new();
    for item in items {
        let row = match item.as_str() {
            Some("terminal") => Row { action: "newSurface", local_workspace: false },
            Some("localWorkspace") => {
                Row { action: "workspace.newOnMachine", local_workspace: true }
            }
            Some("host") => Row { action: "remote.connect", local_workspace: false },
            _ => return Vec::new(),
        };
        if rows.contains(&row) {
            return Vec::new();
        }
        rows.push(row);
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
            json!(["typo"]),
            json!(["terminal", 1]),
            json!(["host", "host"]),
        ] {
            assert!(rows(&value).is_empty(), "{value}");
        }
    }

    #[test]
    fn plus_menu_preserves_order_and_explicit_local_destination() {
        let rows = rows(&json!(["host", "localWorkspace", "terminal"]));
        assert_eq!(
            rows.iter().map(|r| r.action).collect::<Vec<_>>(),
            ["remote.connect", "workspace.newOnMachine", "newSurface"]
        );
        assert_eq!(
            rows.iter().map(|r| r.local_workspace).collect::<Vec<_>>(),
            [false, true, false]
        );
        assert_eq!(super::rows(&json!(["terminal"])).len(), 1);
    }
}
