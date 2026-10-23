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

/// The `session/update` kinds that show the model at work: what it says or does (a message, a
/// thought, a tool call and its progress, a plan), a compaction (the model summarizing) and a
/// subagent's progress.
const MODEL_UPDATES: [&str; 8] = [
    "agent_message_chunk",
    "agent_thought_chunk",
    "tool_call",
    "tool_call_update",
    "plan",
    "compaction",
    "compaction_summary",
    "subagent_progress",
];

/// The raw harness lines only a responding model produces, which often come long before any
/// update a client shows: Claude's stream (its first event is the model's answer starting), its
/// messages, its thinking (redacted thinking sends no thought), a running tool's heartbeat (a
/// prompt queued behind it), and Codex's moderation notice on what the model generates (Codex
/// reasoning without summaries sends nothing else for minutes).
const MODEL_LINES: [&str; 5] = [
    RAW_STREAM_EVENT,
    "claude.assistant",
    "claude.system.thinking_tokens",
    "claude.tool_progress",
    "codex.turn/moderationMetadata",
];

/// Whether an agent's message shows its model at work (`silent_turn.rs`): an update or a raw line
/// above, or a request it makes (a permission, a file, a terminal). The agent's own bookkeeping is
/// not: usage, commands, modes, its turn and usage notices (Codex sends them as soon as the prompt
/// goes out), answers to acpmux's requests, its host's stderr and exit.
fn from_the_model(msg: &Message) -> bool {
    match msg {
        Message::Request { .. } => true,
        Message::Notification { method, params }
            if method == crate::rpc::method::SESSION_UPDATE =>
        {
            params
                .as_ref()
                .and_then(|p| p.pointer("/update/sessionUpdate"))
                .and_then(Value::as_str)
                .is_some_and(|kind| MODEL_UPDATES.contains(&kind))
        }
        Message::Notification { method, .. } => MODEL_LINES.contains(&method.as_str()),
        _ => false,
    }
}

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
        Arc::new(move |dir: Direction, msg: &Message, host_seq: Option<u64>| {
            if matches!(dir, Direction::In) && from_the_model(msg) {
                tap_session.heard.fetch_add(1, Ordering::SeqCst);
                tap_hub.heard_after_silence(&tap_session);
            }
            let (d, kind) = match (dir, msg) {
                // Agent host stderr and exit entries: logged here, in entry
                // order, before the entry is acknowledged.
                (Direction::In, Message::Notification { method, params })
                    if method == crate::agent::HOST_STDERR =>
                {
                    let text = params.as_ref().and_then(|p| p.get("text")).cloned();
                    let stored = tap_hub
                        .append_logged(
                            &tap_session,
                            "mux",
                            "stderr",
                            json!({"text": text}),
                            host_seq,
                        )
                        .1;
                    return tap_hub.ticket(&tap_session, stored);
                }
                (Direction::In, Message::Notification { method, params })
                    if method == crate::agent::HOST_EXIT =>
                {
                    let code = params.as_ref().and_then(|p| p.get("code")).cloned();
                    let intentional =
                        matches!(tap_session.status(), SessionStatus::Idle | SessionStatus::Closed);
                    let stored = tap_hub
                        .append_logged(
                            &tap_session,
                            "mux",
                            if intentional { "stopped" } else { "exited" },
                            json!({"code": code}),
                            host_seq,
                        )
                        .1;
                    return tap_hub.ticket(&tap_session, stored);
                }
                (Direction::In, Message::Notification { method, params }) => {
                    let mut kind = method.clone();
                    let timing = method == RAW_STREAM_EVENT
                        && params.as_ref().is_some_and(|p| times_request(p, &awaiting_first_delta));
                    if method == RAW_STREAM_EVENT && !timing {
                        // Kept nowhere: the entry counts as logged once the records before
                        // it are, so the host drops it.
                        tap_hub.touch(&tap_session);
                        return tap_hub.ticket(&tap_session, true);
                    }
                    if method.starts_with("claude.") {
                        // Raw stream-json line; translated messages follow.
                        let stored = tap_hub
                            .append_logged(
                                &tap_session,
                                "in",
                                &kind,
                                params.clone().unwrap_or(Value::Null),
                                host_seq,
                            )
                            .1;
                        return tap_hub.ticket(&tap_session, stored);
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
                    let stored = tap_hub
                        .append_logged(
                            &tap_session,
                            "out",
                            "claude.stdin",
                            params.clone().unwrap_or(Value::Null),
                            host_seq,
                        )
                        .1;
                    return tap_hub.ticket(&tap_session, stored);
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
                // The chat's own thread is never one of its subagents.
                let own = tap_session
                    .meta
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .agent_session_id
                    .clone();
                let mut tree = tap_session.subagents.lock().unwrap_or_else(|e| e.into_inner());
                tree.set_own(own.as_deref());
                subagent = tree.annotate(params);
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
            tap_hub.ticket(&tap_session, logged)
        })
    }

    /// The tap's answer for a message of `session`: None when its record was not stored, else
    /// the ticket covering every record of the session so far (`agent::WriteTicket`).
    fn ticket(&self, session: &Session, stored: bool) -> Option<crate::agent::WriteTicket> {
        stored.then(|| {
            crate::agent::WriteTicket::new(
                session.seq.load(Ordering::SeqCst),
                self.store.progress(&session.id),
            )
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
