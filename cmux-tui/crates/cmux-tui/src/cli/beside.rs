//! Where an agent's new terminal goes when the agent names no place: beside
//! its own chat, in its own workspace. A workspace agent asked to "open it
//! to the right" opened a terminal in Home (Lawrence 2026-10-25): a
//! terminal creation with no pane went to the daemon's active pane, and an
//! open_url with no workspace to Home. One rule, shared by the CLI and the
//! MCP server: the app's `beside` answer (`system.identify`) names the
//! column right of the chat; a tab goes there, and with no such column a
//! split right of the chat makes it.
//!
//! This module only decides; each transport sends the requests.

use serde_json::{Map, Value, json};

/// The width a new column beside a chat takes, as a fraction of the
/// viewport: with the chat dock's third, the two fill the window.
pub(super) const NEW_COLUMN_WIDTH: f64 = 0.66;

/// The parent selectors a creation may name.
const PARENTS: [&str; 3] = ["workspace", "screen", "pane"];

/// Where a creation with no place goes, from the app's identity answer.
#[derive(Debug, PartialEq)]
pub(super) enum Placement {
    /// A tab in the existing column right of the chat.
    Pane { workspace: String, pane: String },
    /// No column yet: split right of the chat's pane as a new column.
    NewColumn { workspace: String, chat_pane: String },
}

/// Whether a `tab.create_terminal` names no place, so it goes beside the
/// caller.
pub(super) fn names_no_place(params: &Map<String, Value>) -> bool {
    PARENTS.iter().all(|key| params.get(*key).is_none())
}

/// The placement `identity` (the app's `system.identify` answer) gives, or
/// `None` when the app does not place the caller.
pub(super) fn placement(identity: &Value) -> Option<Placement> {
    let caller = identity.get("caller")?;
    if caller.get("found").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    let workspace = caller.get("workspace").and_then(Value::as_str)?.to_owned();
    let beside = identity.get("beside");
    if let Some(pane) = beside.and_then(|beside| beside.get("pane")).and_then(Value::as_str) {
        return Some(Placement::Pane { workspace, pane: pane.to_owned() });
    }
    let chat_pane = caller.get("pane").and_then(Value::as_str)?.to_owned();
    Some(Placement::NewColumn { workspace, chat_pane })
}

/// The `pane.split` params that open the terminal a `tab.create_terminal`
/// asked for as a new column right of `chat_pane`: its command, directory
/// and size carry over; `name` does not (a split has none), so the caller
/// renames the new tab after.
pub(super) fn split_params(
    create: &Map<String, Value>,
    workspace: &str,
    chat_pane: &str,
) -> Map<String, Value> {
    let mut split = Map::new();
    for key in ["machine", "session", "argv", "shell", "cwd", "cols", "rows", "correlation_key"] {
        if let Some(value) = create.get(key) {
            split.insert(key.into(), value.clone());
        }
    }
    split.insert("workspace".into(), json!(workspace));
    split.insert("pane".into(), json!(chat_pane));
    split.insert("direction".into(), json!("right"));
    split.insert("viewport_width".into(), json!(NEW_COLUMN_WIDTH));
    split
}

/// The `tab.rename` params that give the split's new tab the name its
/// creation asked for, when it asked for one.
pub(super) fn rename_params(
    create: &Map<String, Value>,
    workspace: &str,
    created: &Value,
) -> Option<Map<String, Value>> {
    let name = create.get("name")?;
    let tab = created.get("tab_id")?;
    let mut rename = Map::new();
    for key in ["machine", "session"] {
        if let Some(value) = create.get(key) {
            rename.insert(key.into(), value.clone());
        }
    }
    rename.insert("workspace".into(), json!(workspace));
    rename.insert("tab".into(), tab.clone());
    rename.insert("name".into(), name.clone());
    Some(rename)
}

/// What [`apply_cli`] did with a CLI request.
#[cfg(unix)]
pub(super) enum CliOutcome {
    /// Not a creation with no place, or the app does not place an agent.
    Unchanged,
    /// The request now names the column right of the chat.
    Placed,
    /// A new column was made in its stead; this is the exit code.
    Answered(i32),
}

/// [`placement`] for `cmux tab create terminal` run by an agent
/// (`CMUX_AGENT_SESSION`) with no `--workspace`, `--screen` or `--pane`, on
/// the request's own connection. A person's terminal keeps the daemon's
/// default, the pane they type in.
#[cfg(unix)]
pub(super) fn apply_cli(
    global: &super::GlobalArgs,
    plan: &mut super::command::RequestPlan,
    reader: &mut std::io::BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>,
    idempotency_key: Option<&str>,
) -> CliOutcome {
    use cmux_tui_core::resource::ResourceOperation;

    use super::command::WireOperation;

    let creates_terminal =
        matches!(plan.operation, WireOperation::Typed(ResourceOperation::TabCreateTerminal));
    let agent = std::env::var("CMUX_AGENT_SESSION").is_ok_and(|session| !session.is_empty());
    let Some(params) = plan.params.as_object_mut() else { return CliOutcome::Unchanged };
    if !creates_terminal || !agent || !names_no_place(params) {
        return CliOutcome::Unchanged;
    }
    let identity = super::app::socket_path(global)
        .and_then(|socket| super::app::connect(&socket))
        .and_then(|mut app| {
            super::app::request(&mut app, "system.identify", json!({}), super::app::READ_TIMEOUT)
        });
    let Some(placed) = identity.ok().and_then(Result::ok).and_then(|identity| placement(&identity))
    else {
        return CliOutcome::Unchanged;
    };
    match placed {
        Placement::Pane { workspace, pane } => {
            params.insert("workspace".into(), json!(workspace));
            params.insert("pane".into(), json!(pane));
            CliOutcome::Placed
        }
        Placement::NewColumn { workspace, chat_pane } => {
            let split = split_params(params, &workspace, &chat_pane);
            let key = idempotency_key.map(|key| format!("{key}-beside"));
            let created = match super::resolve::call(
                reader,
                ResourceOperation::PaneSplit,
                split,
                key.as_deref(),
            ) {
                Ok(created) => created,
                Err(failure) => return CliOutcome::Answered(failure.report(global.output)),
            };
            let path = created.get("value").filter(|value| value.is_object()).unwrap_or(&created);
            if let Some(rename) = rename_params(params, &workspace, path) {
                let key = idempotency_key.map(|key| format!("{key}-name"));
                if let Err(failure) = super::resolve::call(
                    reader,
                    ResourceOperation::TabRename,
                    rename,
                    key.as_deref(),
                ) {
                    return CliOutcome::Answered(failure.report(global.output));
                }
            }
            CliOutcome::Answered(super::wire::print_result(global, plan, created))
        }
    }
}

/// [`apply_cli`] at the CLI's send step (wire.rs): `Ok(Some(bytes))` for
/// a request that now names the column right of the chat, `Ok(None)` for
/// one left as it was, `Err(exit code)` when a new column answered it.
#[cfg(unix)]
pub(super) fn run_cli(
    global: &super::GlobalArgs,
    plan: &mut super::command::RequestPlan,
    request: &mut Value,
    reader: &mut std::io::BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>,
    caller_route: bool,
    key_report: &super::wire::KeyReport,
) -> Result<Option<Vec<u8>>, i32> {
    if !caller_route {
        return Ok(None);
    }
    let key = request.get("idempotency_key").and_then(Value::as_str).map(str::to_owned);
    match apply_cli(global, plan, reader, key.as_deref()) {
        CliOutcome::Unchanged => Ok(None),
        CliOutcome::Placed => {
            request["params"] = plan.params.clone();
            super::wire::encode_request(request).map(Some)
        }
        CliOutcome::Answered(code) => {
            if code == 0 {
                key_report.succeeded();
            }
            key_report.finish(global.output);
            Err(code)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(beside: Value) -> Value {
        json!({
            "caller": {"agent_session": "s", "workspace": "ws_a", "pane": "pane_chat", "screen": "screen_a"},
            "beside": beside,
        })
    }

    #[test]
    fn an_existing_column_right_of_the_chat_takes_the_tab() {
        let placed =
            placement(&identity(json!({"pane": "pane_right", "placement": "existing_column"})));
        assert_eq!(
            placed,
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_right".into() })
        );
    }

    #[test]
    fn no_column_right_of_the_chat_makes_one() {
        let placed = placement(&identity(json!({"pane": null, "placement": "new_column"})));
        assert_eq!(
            placed,
            Some(Placement::NewColumn { workspace: "ws_a".into(), chat_pane: "pane_chat".into() })
        );
    }

    #[test]
    fn a_caller_the_app_does_not_find_has_no_placement() {
        let unfound = json!({"caller": {"agent_session": "s", "found": false}, "beside": null});
        assert_eq!(placement(&unfound), None);
        assert_eq!(placement(&json!({"caller": null})), None);
    }

    #[test]
    fn a_split_keeps_the_command_and_a_rename_carries_the_name() {
        let create = json!({"session": "current", "shell": "make dev", "cwd": "/w", "name": "dev",
                            "cols": 80, "rows": 24})
        .as_object()
        .cloned()
        .unwrap_or_default();
        let split = split_params(&create, "ws_a", "pane_chat");
        assert_eq!(split["shell"], "make dev");
        assert_eq!(split["cwd"], "/w");
        assert_eq!(split["pane"], "pane_chat");
        assert_eq!(split["direction"], "right");
        assert_eq!(split["viewport_width"], NEW_COLUMN_WIDTH);
        assert!(split.get("name").is_none());
        let rename = rename_params(&create, "ws_a", &json!({"tab_id": "tab_new"}));
        assert_eq!(rename.as_ref().map(|r| r["tab"].clone()), Some(json!("tab_new")));
        assert_eq!(rename.as_ref().map(|r| r["name"].clone()), Some(json!("dev")));
        assert!(rename_params(&Map::new(), "ws_a", &json!({"tab_id": "tab_new"})).is_none());
    }
}
