//! Part of `Hub`; see `hub/mod.rs`. The tap that logs one session's wire
//! traffic into its event log.

use super::*;

/// Raw Claude `stream_event` lines (text and tool-input deltas) are mostly not logged: the
/// translated `session/update` records that follow carry their content. They were most of a
/// Claude chat's log (44,000 of 54,000 records in 24 minutes on huge-blue, 2026-10-21), and each
/// one went to every subscriber and into every read of the log. Two kinds stay, because
/// optchat-chief reads them back to time each model request (`fold.rs` `time_request`:
/// headers_ms and ttft_ms): every `message_start`, and the first `content_block_delta` after it.
const RAW_STREAM_EVENT: &str = "claude.stream_event";

impl Hub {
    /// Make sure a live child process exists for the session. Spawns, runs
    /// `initialize`, and either creates or loads the agent session.
    /// The tap that logs one session's wire traffic (and the agent host
    /// entry each record logs, `hostSeq`).
    pub(super) fn session_tap(self: &Arc<Self>, session: &Arc<Session>) -> crate::agent::Tap {
        let tap_session = session.clone();
        let tap_hub = self.clone();
        // A `message_start` was logged and its first delta was not yet.
        let awaiting_first_delta = AtomicBool::new(false);
        Arc::new(move |dir: Direction, msg: &Message, host_seq: Option<u64>| -> bool {
            if matches!(dir, Direction::In)
                && !msg
                    .method()
                    .is_some_and(|m| m == crate::agent::HOST_STDERR || m == crate::agent::HOST_EXIT)
            {
                tap_session.heard.fetch_add(1, Ordering::SeqCst);
            }
            let (d, kind) = match (dir, msg) {
                // Agent host stderr and exit entries: logged here, in entry
                // order, before the entry is acknowledged.
                (Direction::In, Message::Notification { method, params })
                    if method == crate::agent::HOST_STDERR =>
                {
                    let text = params.as_ref().and_then(|p| p.get("text")).cloned();
                    return tap_hub
                        .append_logged(
                            &tap_session,
                            "mux",
                            "stderr",
                            json!({"text": text}),
                            host_seq,
                        )
                        .1;
                }
                (Direction::In, Message::Notification { method, params })
                    if method == crate::agent::HOST_EXIT =>
                {
                    let code = params.as_ref().and_then(|p| p.get("code")).cloned();
                    let intentional =
                        matches!(tap_session.status(), SessionStatus::Idle | SessionStatus::Closed);
                    return tap_hub
                        .append_logged(
                            &tap_session,
                            "mux",
                            if intentional { "stopped" } else { "exited" },
                            json!({"code": code}),
                            host_seq,
                        )
                        .1;
                }
                (Direction::In, Message::Notification { method, params }) => {
                    let mut kind = method.clone();
                    let timing = method == RAW_STREAM_EVENT
                        && params.as_ref().is_some_and(|p| times_request(p, &awaiting_first_delta));
                    if method == RAW_STREAM_EVENT && !timing {
                        // Kept nowhere: the entry counts as logged, so the host drops it.
                        tap_hub.touch(&tap_session);
                        return true;
                    }
                    if method.starts_with("claude.") {
                        // Raw stream-json line; translated messages follow.
                        return tap_hub
                            .append_logged(
                                &tap_session,
                                "in",
                                &kind,
                                params.clone().unwrap_or(Value::Null),
                                host_seq,
                            )
                            .1;
                    }
                    if method == crate::rpc::method::SESSION_UPDATE {
                        if let Some(su) = params
                            .as_ref()
                            .and_then(|p| p.get("update"))
                            .and_then(|u| u.get("sessionUpdate"))
                            .and_then(Value::as_str)
                        {
                            kind = su.to_owned();
                        }
                        if tap_session.loading.load(Ordering::SeqCst) {
                            kind.push_str(".replay");
                        }
                    }
                    ("in", kind)
                }
                (Direction::In, Message::Request { method, .. }) => ("in", method.clone()),
                (Direction::In, Message::Response { .. }) => ("in", "response".to_owned()),
                (Direction::Out, Message::Request { method, .. }) => ("out", method.clone()),
                (Direction::Out, Message::Notification { method, params })
                    if method == "claude.stdin" =>
                {
                    return tap_hub
                        .append_logged(
                            &tap_session,
                            "out",
                            "claude.stdin",
                            params.clone().unwrap_or(Value::Null),
                            host_seq,
                        )
                        .1;
                }
                (Direction::Out, Message::Notification { method, .. }) => ("out", method.clone()),
                (Direction::Out, Message::Response { .. }) => ("out", "response".to_owned()),
            };
            // A subagent's updates are recorded with their subagent and
            // parent (`crate::subagents`); they are not the session's own
            // message stream.
            let mut value = msg.to_value();
            let mut subagent = None;
            if d == "in"
                && msg.method() == Some(crate::rpc::method::SESSION_UPDATE)
                && let Some(params) = value.get_mut("params")
            {
                subagent = tap_session
                    .subagents
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .annotate(params);
            }
            // Live agent updates (not a session/load replay) also feed the
            // stream watcher, which may record `message_superseded` first.
            let live_update = d == "in"
                && !kind.ends_with(".replay")
                && msg.method() == Some(crate::rpc::method::SESSION_UPDATE)
                && subagent.is_none();
            if live_update {
                tap_hub.before_agent_update(&tap_session, msg.params());
            }
            // A shell's output file stays in the registry, off the record.
            let output = if d == "in" && kind == "background_task_update" {
                super::processes::take_output_file(&mut value)
            } else {
                None
            };
            let (rec, logged) = tap_hub.append_logged(&tap_session, d, &kind, value, host_seq);
            if live_update {
                tap_hub.after_agent_update(&tap_session, &rec);
            }
            // A background shell, a subagent's too (`processes.rs`).
            if d == "in" && kind == "background_task_update" {
                tap_hub.note_process(&tap_session, &rec, output.as_deref());
            }
            logged
        })
    }
}

/// Whether a raw `stream_event` line is one a request's timing reads: a `message_start`, or the
/// first `content_block_delta` after one. Only the main agent's requests are timed; a subagent's
/// lines (`parent_tool_use_id`) stream alongside them and are never kept.
fn times_request(params: &Value, awaiting_first_delta: &AtomicBool) -> bool {
    if params.get("parent_tool_use_id").is_some_and(|p| !p.is_null()) {
        return false;
    }
    match params.pointer("/event/type").and_then(Value::as_str) {
        Some("message_start") => {
            awaiting_first_delta.store(true, Ordering::Relaxed);
            true
        }
        Some("content_block_delta") => awaiting_first_delta.swap(false, Ordering::Relaxed),
        _ => false,
    }
}
