//! Part of `Hub`; see `hub/mod.rs`. How to try what a chat finished: the `try`, `verify` and
//! `report` of its newest wrap-up that gave any (`acpmux_mcp_wrap_up.rs`), kept in its meta
//! (`SessionMeta::try_it`) and served on its summary as `tryIt`, so the sidebar row of the chat's
//! workspace and the phone's chat list draw a Try button without reading the transcript. Aziz,
//! 2026-11-09: "since all workspaces are units of tasks, make it so that whenever a workspace
//! agent finished its task, there's a direct way for me to try out and verify its work in
//! addition to the artifact."
//!
//! The wrap-up is recognised under every name a harness gives it, a `cmux_exec` script that
//! called it included (`wrap_up_suggestion::recognise`), and counts once its call completes. Its
//! input is checked again with the tool's own rules, so a call the tool refused leaves nothing.
//! A later wrap-up with no `try`, `verify` or `report` (a status answer, a question) keeps the
//! last one: the work it points at is still there to try. A replayed history sets nothing.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

use super::*;
use crate::protocol::session::TryIt;
use crate::wrap_up_suggestion::{Call, recognise, shown_in_output};

/// Wrap-up calls still running, by session and tool call id: a later update may carry only the
/// status.
/// More open wrap-up calls than any set of live turns has: past it the stale ones are dropped.
const MAX_OPEN_CALLS: usize = 256;

static CALLS: LazyLock<Mutex<HashMap<(String, String), Call>>> = LazyLock::new(Default::default);

/// Notes one `tool_call` or `tool_call_update` of `session` into `m`.
pub(super) fn absorb(session: &str, update: &Value, m: &mut SessionMeta, replayed: bool, at: u64) {
    if replayed {
        return;
    }
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
    let status = update.get("status").and_then(Value::as_str);
    let found = recognise(update);
    // Most calls are not wrap-ups and do not end: they never take the lock.
    if found.is_none() && !matches!(status, Some("completed" | "failed")) {
        return;
    }
    let key = (session.to_owned(), id.to_owned());
    let mut calls = CALLS.lock().unwrap_or_else(|e| e.into_inner());
    // A wrap-up cut off by a cancelled turn or a crash never completes: bound what it leaves.
    if calls.len() >= MAX_OPEN_CALLS && !calls.contains_key(&key) {
        calls.clear();
    }
    match found {
        Some(call @ Call::Args(_)) => {
            calls.insert(key.clone(), call);
        }
        Some(Call::Script) => {
            calls.entry(key.clone()).or_insert(Call::Script);
        }
        None => {}
    }
    if !matches!(status, Some("completed" | "failed")) {
        return;
    }
    let Some(call) = calls.remove(&key) else { return };
    drop(calls);
    if status != Some("completed") {
        return;
    }
    let args = match call {
        Call::Args(args) => Some(args),
        Call::Script => shown_in_output(update),
    };
    if let Some(found) = args.as_ref().and_then(|a| read(a, at)) {
        m.try_it = Some(found);
    }
}

/// The Try of one wrap-up's arguments (a JSON string for some harnesses), checked as the tool
/// checks them; none when it gave no `try`, `verify` or `report`, or the tool refused it.
pub(crate) fn read(args: &Value, at: u64) -> Option<TryIt> {
    let args = match args {
        Value::String(s) => serde_json::from_str::<Value>(s).ok()?,
        other => other.clone(),
    };
    let shown = crate::acpmux_mcp::wrap_up_check(&args).ok()?;
    let text = |v: Option<&Value>| v.and_then(Value::as_str).map(str::to_owned);
    let try_it = shown.get("try");
    let found = TryIt {
        label: text(try_it.and_then(|t| t.get("label"))),
        url: text(try_it.and_then(|t| t.get("url"))),
        command: text(try_it.and_then(|t| t.get("command"))),
        verify: shown
            .get("verify")
            .and_then(Value::as_array)
            .map(|steps| steps.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default(),
        report: text(shown.get("report")),
        at,
    };
    let empty = found.label.is_none() && found.verify.is_empty() && found.report.is_none();
    (!empty).then_some(found)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn meta() -> SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s", "name": "s",
            "harness": "fake", "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap()
    }

    #[test]
    fn a_completed_wrap_up_with_a_try_sets_it_and_a_plain_one_keeps_it() {
        let mut m = meta();
        let start = json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "mcp__acpmux__wrap_up",
            "status": "in_progress",
            "rawInput": {"recap": "Done.", "try": {"label": "Open build", "url": "http://127.0.0.1:17320/try-agent-work"},
                "verify": ["Finish a task: its row shows Try."], "report": "/tmp/r.html"}});
        absorb("s-try-1", &start, &mut m, false, 5);
        assert!(m.try_it.is_none(), "counts only once the call completes");
        absorb("s-try-1", &json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"}), &mut m, false, 6);
        let got = m.try_it.clone().expect("set");
        assert_eq!(got.url.as_deref(), Some("http://127.0.0.1:17320/try-agent-work"));
        assert_eq!(got.label.as_deref(), Some("Open build"));
        assert_eq!(got.verify, vec!["Finish a task: its row shows Try.".to_owned()]);
        assert_eq!(got.report.as_deref(), Some("/tmp/r.html"));
        assert_eq!(got.at, 6);
        // A recap alone afterwards keeps it.
        absorb("s-try-1", &json!({"sessionUpdate": "tool_call", "toolCallId": "t2", "title": "mcp__acpmux__wrap_up",
            "status": "completed", "rawInput": {"recap": "Checked CI."}}), &mut m, false, 7);
        assert_eq!(m.try_it, Some(got));
    }

    #[test]
    fn a_failed_refused_or_replayed_wrap_up_sets_nothing() {
        let mut m = meta();
        let call = |id: &str, status: &str, input: Value| json!({"sessionUpdate": "tool_call", "toolCallId": id,
            "title": "mcp__acpmux__wrap_up", "status": status, "rawInput": input});
        absorb("s-try-2", &call("a", "failed", json!({"recap": "x", "try": {"url": "https://a.b"}})), &mut m, false, 1);
        absorb("s-try-2", &call("b", "completed", json!({"recap": "x", "try": {"url": "javascript:alert(1)"}})), &mut m, false, 1);
        absorb("s-try-2", &call("c", "completed", json!({"recap": "x", "try": {"url": "https://a.b"}})), &mut m, true, 1);
        assert!(m.try_it.is_none());
    }

    #[test]
    fn a_cmux_exec_script_that_called_the_wrap_up_counts_from_its_call_log() {
        let mut m = meta();
        let shown = json!({"recap": "Done.", "ask": null, "actions": [], "try": {"label": "Try it", "command": "make demo"}});
        let update = json!({"sessionUpdate": "tool_call", "toolCallId": "e1", "title": "mcp__cmux__cmux_exec",
            "status": "completed", "rawInput": {"code": "await cmux.acpmux_wrap_up({recap: 'Done.'})"},
            "rawOutput": {"call_log": [{"name": "acpmux_wrap_up", "ok": true, "shown": shown}]}});
        absorb("s-try-3", &update, &mut m, false, 9);
        assert_eq!(m.try_it.and_then(|t| t.command).as_deref(), Some("make demo"));
    }
}
