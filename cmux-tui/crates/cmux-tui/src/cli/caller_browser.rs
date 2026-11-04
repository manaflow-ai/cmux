//! `current` as a browser selector means the browser nearest the caller
//! (#26648): one in its own workspace, then in its sidebar group, then in
//! its window, never the person's focused tab in another window. The daemon
//! reads `current` as its active tab, which follows the person's focus, so an
//! agent told to "use the cmux browser" drove whatever the person looked at
//! elsewhere. The app knows the windows and reports that browser in
//! `system.identify` (`browser`, BrowserCallerTarget in the app); the CLI
//! and the MCP server name its tab in place of the `current` chain before
//! the request leaves. A request with an explicit parent keeps it.

use serde_json::{Map, Value, json};

/// The selectors above a browser, which a `current` browser chain fills,
/// with the prefix of the daemon id each takes.
const PARENTS: [(&str, &str); 4] =
    [("workspace", "ws_"), ("screen", "screen_"), ("pane", "pane_"), ("tab", "tab_")];

/// Whether `params` names the `current` browser with nothing but `current`
/// (or nothing) above it.
pub(super) fn wants(params: &Map<String, Value>) -> bool {
    params.get("browser").and_then(Value::as_str) == Some("current")
        && PARENTS.iter().all(|(scope, _)| {
            params.get(*scope).is_none_or(|value| value.as_str() == Some("current"))
        })
}

/// Puts the place of the app's `browser` (from `system.identify`: its
/// workspace, screen, pane and tab) in place of the `current` chain of
/// `params`. `Ok(false)` leaves `params` as they are: the app does not place
/// the caller, it is an app from before #26648 that reports no `browser`,
/// or that browser's place is not four daemon ids. An error when the caller
/// has no browser near it, or that browser is in another session than the
/// request's.
pub(super) fn apply(params: &mut Map<String, Value>, identity: &Value) -> Result<bool, Value> {
    let Some(caller) = identity.get("caller") else { return Ok(false) };
    let workspace = caller.get("workspace").and_then(Value::as_str);
    if caller.get("found").and_then(Value::as_bool) == Some(false) || workspace.is_none() {
        return Ok(false);
    }
    let Some(browser) = identity.get("browser") else { return Ok(false) };
    let Some(tab) = browser.get("tab").and_then(Value::as_str) else {
        return Err(error(
            "selector.not_found",
            format!(
                "no browser in workspace {} or its window; list every tab with \
                 `cmux browser page tabs --all` and name one (`cmux browser tab_… <verb>`)",
                workspace.unwrap_or_default()
            ),
            json!({"workspace": workspace}),
        ));
    };
    if let Some(session) = browser.get("session").and_then(Value::as_str) {
        return Err(error(
            "selector.invalid",
            format!(
                "the browser nearest the caller ({tab}) is in session {session}; \
                 name it there: `cmux --session {session} browser …`"
            ),
            json!({"tab": tab, "session": session}),
        ));
    }
    // The daemon reads a `current` browser only below a full chain of
    // workspace, screen, pane and tab, so all four name that browser's place.
    // A place without four daemon ids (an app that reports no screen, a
    // daemon without resource ids) keeps the chain as it was.
    let place: Option<Vec<(&str, &str)>> = PARENTS
        .iter()
        .map(|(scope, prefix)| {
            let id = browser.get(*scope).and_then(Value::as_str)?;
            id.starts_with(prefix).then_some((*scope, id))
        })
        .collect();
    let Some(place) = place else { return Ok(false) };
    for (scope, id) in place {
        params.insert(scope.into(), Value::String(id.to_owned()));
    }
    Ok(true)
}

fn error(code: &str, message: String, details: Value) -> Value {
    json!({"code": code, "message": message, "details": details, "retryable": false})
}

#[cfg(test)]
#[path = "tests/caller_browser.rs"]
mod tests;
