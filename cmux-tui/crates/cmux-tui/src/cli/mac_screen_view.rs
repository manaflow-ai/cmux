//! A Screen Sharing tab's state where an agent already reads a tab: `cmux tab <id> show --json`
//! carries `mac_screen`, and `cmux tab new-mac-screen --json` answers with the new tab's id and
//! the same `mac_screen`. Leo, 2026-11-18: "screen sharing, your response doesnt make sense. i
//! should be able to see into any connected mac or linux machine". An agent that opened a share
//! had no verb that said where it stood, so it guessed from screenshots.
//!
//! The app already says it: `mac_screen.state` (`cmux app mac-screens`, every build) gives one row
//! per Screen Sharing tab. This module reads that row for the tab and shapes the few fields an
//! agent acts on; the app side stays a plain read. The daemon's own record gives `route` (what
//! the tab shows, `extra.conversation.route`). Reading the app fails open: with no app, or a tab
//! the app does not list, `mac_screen` says why in `unavailable` and the daemon's record stands.

use std::os::unix::net::UnixStream;

use serde_json::{Map, Value, json};

use super::GlobalArgs;

/// The page id of a Screen Sharing tab (`InternalPageID.macScreen` in the app).
pub(super) const PAGE: &str = "mac-screen";

/// Whether a `tab.get` record is a Screen Sharing tab: a page tab whose page is [`PAGE`].
pub(super) fn is_mac_screen_tab(tab: &Value) -> bool {
    tab.pointer("/extra/conversation/page").and_then(Value::as_str) == Some(PAGE)
}

/// The agent's view of one `mac_screen.state` row: where the share stands and why it stopped.
/// `transport` is the stream's path as the pane says it (`Direct`, `Relayed`); `carrier` is the
/// transport under it. `route` is the daemon's (what the tab shows).
pub(super) fn shape(row: &Value, route: Option<&Value>) -> Value {
    let field = |key: &str| row.get(key).cloned().unwrap_or(Value::Null);
    json!({
        "tab": field("store_tab"),
        "device": field("device"),
        "device_id": field("device_id"),
        "route": route.cloned().unwrap_or(Value::Null),
        "state": field("state"),
        "connect_stage": field("connect_stage"),
        "hub_phase": field("hub_phase"),
        "hub_reason": field("hub_reason"),
        "phase": field("phase"),
        "connected": field("connected"),
        "has_frame": field("has_frame"),
        "first_frame_ms": field("first_frame_ms"),
        "fps": field("fps"),
        "transport": field("path"),
        "carrier": field("transport"),
        "scope": field("scope"),
        "error": field("error"),
        "failure": field("failure"),
        "timed_out_at": field("timed_out_at"),
    })
}

/// The `mac_screen.state` row for daemon tab `id` (its `store_tab`), or its provider key.
pub(super) fn row_for<'a>(state: &'a Value, id: &str) -> Option<&'a Value> {
    state.get("tabs").and_then(Value::as_array)?.iter().find(|row| {
        row.get("store_tab").and_then(Value::as_str) == Some(id)
            || row.get("tab").and_then(Value::as_str) == Some(id)
    })
}

/// The `mac_screen` field for daemon tab record `tab` from the app's `state` reply.
pub(super) fn field_for(tab: &Value, state: Result<Value, String>) -> Value {
    let id = tab.get("id").and_then(Value::as_str).unwrap_or_default();
    let route = tab.pointer("/extra/conversation/route");
    match state {
        Ok(state) => match row_for(&state, id) {
            Some(row) => shape(row, route),
            None => json!({
                "route": route.cloned().unwrap_or(Value::Null),
                "unavailable": format!("the app lists no Screen Sharing tab {id}"),
            }),
        },
        Err(reason) => {
            json!({"route": route.cloned().unwrap_or(Value::Null), "unavailable": reason})
        }
    }
}

/// `tab show`: adds `mac_screen` to a Screen Sharing tab's record. Any other tab is left as it is,
/// with no app call.
pub(super) fn with_tab_state(global: &GlobalArgs, mut tab: Value) -> Value {
    if !is_mac_screen_tab(&tab) || !tab.is_object() {
        return tab;
    }
    let id = tab.get("id").and_then(Value::as_str).unwrap_or_default().to_owned();
    let state = read_state(global, Some(&id));
    let field = field_for(&tab, state);
    if let Some(object) = tab.as_object_mut() {
        object.insert("mac_screen".into(), field);
    }
    tab
}

/// The app's `mac_screen.state`, for one tab or all.
fn read_state(global: &GlobalArgs, tab: Option<&str>) -> Result<Value, String> {
    let socket = super::app::socket_path(global)?;
    let mut stream = super::app::connect(&socket)?;
    request_state(&mut stream, tab)
}

pub(super) fn request_state(stream: &mut UnixStream, tab: Option<&str>) -> Result<Value, String> {
    let mut params = Map::new();
    if let Some(tab) = tab {
        params.insert("tab".into(), json!(tab));
    }
    match super::app::request(
        stream,
        super::app::MAC_SCREENS_METHOD,
        Value::Object(params),
        super::app::READ_TIMEOUT,
    )? {
        Ok(state) => Ok(state),
        Err(error) => Err(error
            .get("message")
            .and_then(Value::as_str)
            .or_else(|| error.get("code").and_then(Value::as_str))
            .unwrap_or("the app refused mac_screen.state")
            .to_owned()),
    }
}

/// Whether an app call opens a Screen Sharing tab: `action.run` of `macScreen.open` (by id, or
/// `tab new-mac-screen` by its CLI name).
pub(super) fn opens_tab(method: &str, params: &Value) -> bool {
    method == "action.run"
        && matches!(params["action"].as_str(), Some("macScreen.open" | "tab new-mac-screen"))
}

/// The provider keys of the Screen Sharing tabs before an open, so the open's own tab is the one
/// that was not there.
pub(super) fn keys(state: &Value) -> Vec<String> {
    state
        .get("tabs")
        .and_then(Value::as_array)
        .map(|rows| {
            rows.iter().filter_map(|row| row.get("tab")?.as_str().map(str::to_owned)).collect()
        })
        .unwrap_or_default()
}

/// The row of the tab an open made: the one whose key was not listed `before`, else (an open that
/// showed a tab already open) the one for the device it named.
pub(super) fn opened_row<'a>(
    before: &[String],
    after: &'a Value,
    device: Option<&str>,
) -> Option<&'a Value> {
    let rows = after.get("tabs").and_then(Value::as_array)?;
    let key = |row: &Value| row.get("tab").and_then(Value::as_str).map(str::to_owned);
    let new = rows.iter().find(|row| key(row).is_some_and(|key| !before.contains(&key)));
    new.or_else(|| {
        let device = device?.to_lowercase();
        rows.iter().find(|row| {
            ["device_id", "device"].iter().any(|field| {
                row.get(*field).and_then(Value::as_str).is_some_and(|v| v.to_lowercase() == device)
            })
        })
    })
}

/// `tab new-mac-screen`'s answer gains `tab` (the new tab's id, for `cmux tab <id> show`) and
/// `mac_screen`, when the app lists the tab the open made.
pub(super) fn with_opened(result: &mut Value, row: Option<&Value>) {
    let (Some(row), Some(object)) = (row, result.as_object_mut()) else { return };
    let tab = row.get("store_tab").cloned().filter(|id| !id.is_null());
    let tab = tab.or_else(|| row.get("tab").cloned()).unwrap_or(Value::Null);
    object.insert("tab".into(), tab);
    object.insert("mac_screen".into(), shape(row, None));
}

#[cfg(test)]
#[path = "mac_screen_view_tests.rs"]
mod tests;
