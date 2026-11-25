//! `cmux app renderers [--interval-ms <n>]`: every Chromium renderer process
//! of the app (`cmux Helper (Renderer)`) with the page it hosts and the tab,
//! pane, workspace and agent session that own that page, busiest first. A
//! renderer at 100% CPU in Activity Monitor or `sample` is then a page, not a
//! bare pid.
//!
//! The app's `renderers.list` reports raw facts: its live Chromium pages
//! (URL, title, hidden, renderer client ids, owner) and its renderer helper
//! processes (pid, `--renderer-client-id`, CPU over the interval, footprint).
//! [`rows`] joins them here, one row per pid.

use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{AppCommand, GlobalArgs, Options, UsageError};

/// The app samples CPU over at most 1.5 s and answers within its 4 s deadline.
const TIMEOUT: Duration = Duration::from_secs(6);

/// `rest` starts with `renderers`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let options = Options::parse(&rest[1..], &["interval-ms"], &[])?;
    let mut params = Map::new();
    if let Some(value) = options.value("interval-ms") {
        // A bad value prints `cmux app`'s usage, which names `--interval-ms <n>`.
        let messages = &crate::localization::catalog().app_control;
        let milliseconds: u64 = value
            .parse()
            .map_err(|_| UsageError::new(messages.scope_usage.replace("{scope}", "app")))?;
        params.insert("interval_ms".into(), json!(milliseconds));
    }
    Ok(AppCommand::Renderers { params: Value::Object(params) })
}

/// Calls `renderers.list` and prints the joined rows.
pub(super) fn run(global: &GlobalArgs, stream: &mut UnixStream, params: Value) -> i32 {
    match super::wait::request(global, stream, "renderers.list", &params, Some(TIMEOUT)) {
        Ok(Ok(report)) => super::super::wire::print_local_success(&rows(&report), global.output),
        Ok(Err(mut error)) => {
            if super::error_code(&error) == Some("method_not_found") {
                super::skew::annotate(stream, "renderers.list", &mut error);
            }
            super::super::wire::print_local_error(&error, global.output, 1)
        }
        Err(error) => super::super::wire::print_local_error(&error, global.output, 3),
    }
}

/// One row per renderer pid, busiest first: the page it hosts (the first
/// visible one when it hosts several, `pages` lists them all) and that page's
/// owner. A renderer no live page names is `kind: "no-page"`; an extension's
/// renderer is `kind: "extension"`. Pages whose renderer has no live helper
/// are listed under `unmatched_pages`.
pub(super) fn rows(report: &Value) -> Value {
    let empty = Vec::new();
    let pages = report.get("pages").and_then(Value::as_array).unwrap_or(&empty);
    let helpers = report.get("helpers").and_then(Value::as_array).unwrap_or(&empty);
    let clients_of = |page: &Value| -> Vec<i64> {
        page.get("renderer_clients")
            .and_then(Value::as_array)
            .map(|ids| ids.iter().filter_map(Value::as_i64).collect())
            .unwrap_or_default()
    };
    let live_clients: Vec<i64> =
        helpers.iter().filter_map(|helper| helper.get("client").and_then(Value::as_i64)).collect();

    let mut rows: Vec<Value> = helpers
        .iter()
        .map(|helper| {
            let client = helper.get("client").and_then(Value::as_i64);
            let hosted: Vec<&Value> = match client {
                Some(client) => {
                    pages.iter().filter(|page| clients_of(page).contains(&client)).collect()
                }
                None => Vec::new(),
            };
            let mut row = Map::new();
            row.insert("pid".into(), helper.get("pid").cloned().unwrap_or(Value::Null));
            for key in ["cpu_percent", "memory_bytes", "client"] {
                row.insert(key.into(), helper.get(key).cloned().unwrap_or(Value::Null));
            }
            let primary = hosted
                .iter()
                .find(|page| page.get("hidden") != Some(&Value::Bool(true)))
                .or(hosted.first());
            match primary {
                Some(page) => {
                    for (key, value) in summary(page) {
                        row.insert(key, value);
                    }
                }
                None => {
                    let extension = helper.get("extension") == Some(&Value::Bool(true));
                    row.insert(
                        "kind".into(),
                        json!(if extension { "extension" } else { "no-page" }),
                    );
                }
            }
            row.insert(
                "pages".into(),
                Value::Array(hosted.iter().map(|page| Value::Object(summary(page))).collect()),
            );
            Value::Object(row)
        })
        .collect();
    rows.sort_by(|a, b| {
        let cpu = |row: &Value| row.get("cpu_percent").and_then(Value::as_f64).unwrap_or(-1.0);
        let pid = |row: &Value| row.get("pid").and_then(Value::as_i64).unwrap_or(0);
        cpu(b).total_cmp(&cpu(a)).then(pid(a).cmp(&pid(b)))
    });

    let unmatched: Vec<Value> = pages
        .iter()
        .filter(|page| !clients_of(page).iter().any(|client| live_clients.contains(client)))
        .map(|page| Value::Object(summary(page)))
        .collect();
    json!({
        "interval_ms": report.get("interval_ms").cloned().unwrap_or(Value::Null),
        "renderers": rows,
        "unmatched_pages": unmatched,
    })
}

/// A page's row fields: what it is, where it shows and who owns it.
fn summary(page: &Value) -> Map<String, Value> {
    let owner = page.get("owner").filter(|owner| owner.is_object());
    let url = page.get("url").and_then(Value::as_str).unwrap_or_default();
    let mut out = Map::new();
    out.insert("kind".into(), json!(page_kind(owner, url)));
    out.insert("url".into(), json!(url));
    out.insert("title".into(), page.get("title").cloned().unwrap_or(json!("")));
    out.insert("browser".into(), page.get("browser").cloned().unwrap_or(Value::Null));
    out.insert("visible".into(), json!(page.get("hidden") != Some(&Value::Bool(true))));
    for key in ["workspace", "workspace_title", "pane", "tab", "tab_title", "session", "machine"] {
        out.insert(
            key.into(),
            owner.and_then(|owner| owner.get(key)).cloned().unwrap_or(Value::Null),
        );
    }
    out
}

/// `browser` (a browser tab), `agent-pane` (a chat's page), a cmux page's
/// name (`home`, `settings`; `cmux-page://cmux.home/` is `home`), or `page`
/// for any other page no tab owns.
fn page_kind(owner: Option<&Value>, url: &str) -> String {
    match owner.and_then(|owner| owner.get("kind")).and_then(Value::as_str) {
        Some("browser") => return "browser".into(),
        Some("agent") => return "agent-pane".into(),
        _ => {}
    }
    let Some(rest) = url.strip_prefix("cmux-page://") else { return "page".into() };
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    match host.strip_prefix("cmux.").unwrap_or(host) {
        "" => "page".into(),
        "agent" => "agent-pane".into(),
        name => name.into(),
    }
}

#[cfg(test)]
#[path = "renderers_tests.rs"]
mod tests;
