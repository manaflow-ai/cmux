//! What the CLI says about something that was closed, so an agent checking its own work never
//! reads a closed pane, tab or terminal as live:
//!
//! - `terminal <t> screen read` of a terminal that shows in no tab (its tab, pane, screen or
//!   workspace was closed) still answers its last screen, since the shell runs on until the reap
//!   grace ends and a reopen shows it again, and adds `"closed": true`. Input to it is refused by
//!   the daemon (`terminal.closed`).
//! - `selector.not_found` for an id that is in the closed history says it was closed and names
//!   `cmux closed <id> reopen`; any other unknown id names the list command of its kind.
//!
//! Both are one more read on the same connection, only after the answer they qualify, with a
//! short timeout: a slow or older daemon leaves the answer as it was.

use std::time::Duration;

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value};

use super::command::{RequestPlan, WireOperation};
use super::resolve::read;

type Reader = std::io::BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>;

/// Selector params of a terminal request.
const SELECTORS: [&str; 7] =
    ["machine", "session", "workspace", "screen", "pane", "tab", "terminal"];
/// How long each lookup may wait; the answer it qualifies is already in hand.
const LOOKUP_TIMEOUT: Duration = Duration::from_millis(500);
/// Closed groups searched for an unknown id (the daemon's list limit).
const CLOSED_LIST_LIMIT: u64 = 200;
/// The kinds whose unknown id is looked up in the closed history.
const CLOSABLE: [&str; 6] = ["workspace", "screen", "pane", "tab", "terminal", "browser"];

/// `result` of a `terminal.screen.read`, with `"closed": true` when the terminal shows in no tab.
pub(super) fn mark_closed_read(
    plan: &RequestPlan,
    reader: &mut Reader,
    mut result: Value,
) -> Value {
    if !matches!(plan.operation, WireOperation::Typed(ResourceOperation::TerminalScreenRead)) {
        return result;
    }
    let Some(params) = plan.params.as_object() else { return result };
    if reader.get_mut().set_read_timeout(Some(LOOKUP_TIMEOUT)).is_err() {
        return result;
    }
    let selector: Map<String, Value> = SELECTORS
        .into_iter()
        .filter_map(|key| params.get(key).map(|value| (key.to_owned(), value.clone())))
        .collect();
    let Ok(terminal) = read(reader, ResourceOperation::TerminalGet, selector) else {
        return result;
    };
    if shows_in_no_tab(&terminal)
        && let Some(object) = result.as_object_mut()
    {
        object.insert("closed".into(), Value::Bool(true));
    }
    result
}

/// A running terminal record (`terminal.get`) with no tab: its tabs were closed.
fn shows_in_no_tab(terminal: &Value) -> bool {
    terminal["lifecycle"] != "exited"
        && terminal["tab_ids"].as_array().is_some_and(Vec::is_empty)
        && terminal["tab_id"].is_null()
}

/// Rewrites a `selector.not_found` error for an id: closed (in the closed history) names the
/// reopen, otherwise the list command of its kind.
pub(super) fn annotate_not_found(plan: &RequestPlan, reader: &mut Reader, error: &mut Value) {
    if error["code"] != "selector.not_found" {
        return;
    }
    let (Some(kind), Some(selector)) =
        (error["details"]["scope"].as_str(), error["details"]["selector"].as_str())
    else {
        return;
    };
    if !CLOSABLE.contains(&kind) || !is_id_of(kind, selector) {
        return;
    }
    let (kind, selector) = (kind.to_owned(), selector.to_owned());
    let closed = plan.params.as_object().and_then(|params| {
        reader.get_mut().set_read_timeout(Some(LOOKUP_TIMEOUT)).ok()?;
        let mut query = super::resolve::route(params);
        query.insert("limit".into(), Value::from(CLOSED_LIST_LIMIT));
        read(reader, ResourceOperation::ClosedList, query).ok()
    });
    let items = closed.as_ref().and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    let message = not_found_message(&kind, &selector, items);
    if let Some(object) = error.as_object_mut() {
        object.insert("message".into(), Value::String(message));
    }
}

/// The message for an unknown `kind` id `selector`, given the closed groups (`closed.list`).
pub(in crate::cli) fn not_found_message(kind: &str, selector: &str, closed: &[Value]) -> String {
    match closed.iter().find(|item| mentions(item, selector)) {
        Some(item) => {
            let group = item["id"].as_str().unwrap_or("<id>");
            format!(
                "{kind} {selector} was closed: `cmux closed {group} reopen` brings it back \
                 (`cmux closed list` shows what was closed)"
            )
        }
        None => format!(
            "no {kind} matches {selector:?}: `cmux {kind} list --json` lists the open ones, \
             `cmux closed list` what was closed"
        ),
    }
}

/// Whether `selector` names a `kind` resource id (`pane_…`, `term_…`), not a name.
fn is_id_of(kind: &str, selector: &str) -> bool {
    let prefix = match kind {
        "workspace" => "ws_",
        "terminal" => "term_",
        kind => return selector.strip_prefix(kind).is_some_and(|rest| rest.starts_with('_')),
    };
    selector.starts_with(prefix)
}

/// Whether any string in `value` is exactly `id`.
fn mentions(value: &Value, id: &str) -> bool {
    match value {
        Value::String(text) => text == id,
        Value::Array(values) => values.iter().any(|value| mentions(value, id)),
        Value::Object(map) => map.values().any(|value| mentions(value, id)),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_closed_pane_names_its_reopen_and_an_unknown_one_its_list() {
        let pane = format!("pane_{}", "a".repeat(32));
        let closed = [
            json!({"id": "closed_1", "pane_id": format!("pane_{}", "b".repeat(32))}),
            json!({"id": "closed_2", "members": [{"pane_id": pane, "screens": []}]}),
        ];
        let message = not_found_message("pane", &pane, &closed);
        assert!(message.contains(&format!("pane {pane} was closed")), "{message}");
        assert!(message.contains("`cmux closed closed_2 reopen`"), "{message}");

        let other = format!("pane_{}", "c".repeat(32));
        let message = not_found_message("pane", &other, &closed);
        assert!(message.contains("`cmux pane list --json`"), "{message}");
        assert!(message.contains("`cmux closed list`"), "{message}");
    }

    #[test]
    fn only_ids_are_looked_up_and_a_record_without_tabs_is_closed() {
        assert!(is_id_of("pane", "pane_0f"));
        assert!(is_id_of("workspace", "ws_0f"));
        assert!(is_id_of("terminal", "term_0f"));
        assert!(!is_id_of("pane", "build"));
        assert!(!is_id_of("tab", "tabby"));

        assert!(shows_in_no_tab(&json!({"lifecycle": "running", "tab_id": null, "tab_ids": []})));
        assert!(!shows_in_no_tab(
            &json!({"lifecycle": "running", "tab_id": "tab_1", "tab_ids": ["tab_1"]})
        ));
        assert!(!shows_in_no_tab(&json!({"lifecycle": "exited", "tab_id": null, "tab_ids": []})));
    }
}
