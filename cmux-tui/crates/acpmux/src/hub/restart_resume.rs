//! A turn a daemon restart cut off goes on by itself. Leo, 2026-10-22: "OUR SHIT IS HARDLY EVER
//! GOING TO GO IDLE ... YOU'LL JUST HAVE TO ACCEPT IT BREAKING AT SOME POINT BUT IT RESUMES
//! WHATEVER IT INTERRUPTED". An update restarts the daemon mid-turn instead of waiting for idle.
//!
//! An agent under a live agent host outlives the daemon and is adopted, turn and all
//! (`hosts.rs`). When the agent ended with the daemon (agent hosts off, a reboot, a host that
//! died), the new daemon settles the open turn `outcome_unknown` (`mod.rs`
//! `mark_unknown_outcomes`) and, here, queues one continuation of it at the head of the chat's
//! queue: an acpmux prompt that quotes the cut turn's prompt and every message steered into it,
//! and tells the agent to check what finished before it goes on.
//!
//! - It is an ordinary `queued` record, so it runs through the restored queue (`queue.rs`
//!   `restore_queues`, `resume_queues`) before the prompts that waited behind the cut turn, and a
//!   crash before it ran puts it back like any queued prompt.
//! - Its prompt id is the cut prompt's next attempt (`P~resume-n`, as `auto_resume.rs`), and it
//!   is written before the cut turn's `turn_result`: a crash between the two finds the turn
//!   open again and the continuation already logged, so it is queued once.
//! - `auto_resume_scheduled` with `reason: "daemon_restart"` records it, and its `user_message`
//!   carries `_meta.provenance = {kind: "auto_resume", reason: "daemon_restart", ...}`.
//! - `autoResumeDelaysMs: []` turns it off, as it does the transport continuation, and a chain
//!   of restarts gives up after [`MAX_ATTEMPTS`] continuations (`auto_resume_exhausted`).
//! - A crash between the continuation's `queued` record and its move to the head
//!   (`queue_order`) still restores it at the head (`queue.rs` `restore_queue`), and once.
//! - It goes through the trust gate as the cut turn did (`turn_started` records `trustGate`),
//!   and carries the images the cut turn's prompt and steers sent (`prompt_images.rs`).

use super::{MAX_ATTEMPTS, SUFFIX, split_attempt};
use crate::hub::{Hub, Session};
use crate::store::{EventRecord, RecordHead};
use serde_json::{Value, json};
use std::sync::Arc;

/// Longest quote of one cut prompt or steer, in characters.
const MAX_QUOTE_CHARS: usize = 4_000;
/// Longest prefix of one unfinished tool's input shown in a restart prompt.
const MAX_TOOL_INPUT_CHARS: usize = 300;
/// Maximum unfinished calls listed in a restart prompt.
const MAX_UNFINISHED_TOOLS: usize = 32;

/// One tool call that started before the daemon restart and has no terminal update.
#[derive(Debug, Clone, PartialEq, Eq)]
struct UnfinishedTool {
    name: String,
    id: String,
    input: Option<String>,
}

/// The fields useful to a person resuming a cut turn. Tool updates are JSON-RPC notifications,
/// so the session update is nested under `params.update` in the journal record.
fn tool_update(record: &EventRecord) -> Option<&Value> {
    record.msg.pointer("/params/update").filter(|update| {
        matches!(
            update.get("sessionUpdate").and_then(Value::as_str),
            Some("tool_call" | "tool_call_update")
        )
    })
}

fn input_prefix(update: &Value) -> Option<String> {
    update.get("rawInput").and_then(|raw| {
        (!raw.is_null()).then(|| {
            serde_json::to_string(raw)
                .unwrap_or_default()
                .chars()
                .take(MAX_TOOL_INPUT_CHARS)
                .collect()
        })
    })
}

fn enrich_tool(existing: &mut UnfinishedTool, update: &Value) {
    if let Some(name) = update.get("title").and_then(Value::as_str).filter(|n| !n.is_empty()) {
        existing.name = name.to_owned();
    }
    if let Some(input) = input_prefix(update) {
        existing.input = Some(input);
    }
}

/// Folds one model update into the bounded set of calls still in flight. Calls beyond the cap
/// are deliberately not retained: the prompt only promises a bounded list, and a later terminal
/// update for one of those calls does not affect any retained entry.
fn note_unfinished_tool(open: &mut Vec<UnfinishedTool>, omitted: &mut bool, update: &Value) {
    let Some(id) = update.get("toolCallId").and_then(Value::as_str).filter(|id| !id.is_empty())
    else {
        return;
    };
    match update.get("status").and_then(Value::as_str) {
        Some("completed" | "failed") => open.retain(|tool| tool.id != id),
        None if update.get("sessionUpdate").and_then(Value::as_str) == Some("tool_call_update") => {
            if let Some(existing) = open.iter_mut().find(|tool| tool.id == id) {
                enrich_tool(existing, update);
            }
        }
        _ => {
            if let Some(existing) = open.iter_mut().find(|tool| tool.id == id) {
                enrich_tool(existing, update);
            } else if open.len() < MAX_UNFINISHED_TOOLS {
                let name = update
                    .get("title")
                    .and_then(Value::as_str)
                    .filter(|name| !name.is_empty())
                    .or_else(|| {
                        update.get("kind").and_then(Value::as_str).filter(|name| !name.is_empty())
                    })
                    .unwrap_or("tool")
                    .to_owned();
                open.push(UnfinishedTool { name, id: id.to_owned(), input: input_prefix(update) });
            } else {
                *omitted = true;
            }
        }
    }
}

/// Collects tool calls in the cut turn for the journal-fold regression test.
#[cfg(test)]
fn unfinished_tools(records: &[EventRecord]) -> (Vec<UnfinishedTool>, usize) {
    let mut open = Vec::<UnfinishedTool>::new();
    let mut omitted = false;
    for record in records {
        if let Some(update) = tool_update(record) {
            note_unfinished_tool(&mut open, &mut omitted, update);
        }
    }
    (open, if omitted { 1 } else { 0 })
}

/// The text the agent gets: the cut turn's prompt, then what was steered into it.
fn continue_text(prompts: &[String], tools: &[UnfinishedTool], omitted_tools: usize) -> String {
    let mut text = String::from(
        "acpmux restarted (an update or a crash) while your previous turn was running, and the \
         turn was cut off.",
    );
    for (i, p) in prompts.iter().enumerate() {
        let quoted: String = p.chars().take(MAX_QUOTE_CHARS).collect();
        let what = if i == 0 { "Its prompt" } else { "A message sent into it" };
        text.push_str(&format!("\n\n{what}:\n<message>\n{quoted}\n</message>"));
    }
    if !tools.is_empty() || omitted_tools > 0 {
        text.push_str("\n\nTool calls started but not finished:");
        for tool in tools {
            text.push_str(&format!("\n- {} (id: {})", tool.name, tool.id));
            if let Some(input) = &tool.input {
                text.push_str(&format!(" input: {input}"));
            }
        }
        if omitted_tools > 0 {
            text.push_str("\n- additional unfinished tool calls omitted");
        }
    }
    text.push_str(
        "\n\nCheck what already finished (files, commands, messages), then continue from where it \
         stopped. Do not redo work that completed.",
    );
    text
}

impl Hub {
    /// Before the cut turn `turn_id` is settled: logs the continuation that goes on with it, and
    /// returns its prompt id; `None` when it gets none (turned off, or too many attempts).
    pub(in crate::hub) fn log_restart_continuation(
        &self,
        session: &Arc<Session>,
        turn_id: &str,
    ) -> Option<String> {
        let off = self
            .config
            .try_read()
            .is_ok_and(|c| c.auto_resume_delays_ms.as_ref().is_some_and(Vec::is_empty));
        if off {
            return None;
        }
        // The cut turn's prompt id, control, trust gate, texts and images: its `turn_started`,
        // the `user_message` that started it and those steered into it.
        let (mut prompt_id, mut control, mut gate) = (None::<String>, None::<String>, None);
        let mut prompts: Vec<String> = Vec::new();
        let mut images: Vec<Value> = Vec::new();
        // A Web steer made the turn a Web turn (`web_control.rs` `check_steer`).
        let mut raised_to_web = false;
        // These durable markers are normally applied to live sessions. A dead-host restart has
        // no host replay, so carry their terminal control state into this decision too: a Web
        // continuation must not cross a remote-floor cancellation or stale ended control.
        let mut started = false;
        let mut control_ended = false;
        let mut floor_cancelled = false;
        let mut unfinished = Vec::new();
        let mut omitted_tools = false;
        let _ = self.store.scan_heads(&session.id, &mut |head: &RecordHead<'_>| {
            // Headers are cheap to inspect. Parse payloads only after the interrupted turn starts,
            // and stop at its result so a long session does not deserialize historical tool I/O.
            let needs_record = match head.kind {
                "turn_started"
                | "user_message"
                | "turn_control"
                | "remote_control_ended"
                | "remote_control_restored"
                | "remote_floor_cancel"
                | "turn_result" => true,
                "tool_call" | "tool_call_update" => started,
                _ => false,
            };
            if !needs_record {
                return true;
            }
            let Some(e) = head.record() else { return true };
            let is_turn = e.msg.get("turnId").and_then(Value::as_str) == Some(turn_id);
            let field = |k: &str| e.msg.get(k).and_then(Value::as_str).map(str::to_owned);
            match e.kind.as_str() {
                "turn_started" if is_turn => {
                    started = true;
                    prompt_id = field("promptId");
                    control = field("control");
                    gate = e.msg.get("trustGate").and_then(Value::as_bool);
                }
                "turn_control" if is_turn => {
                    raised_to_web |= field("control").as_deref() == Some("web")
                }
                "remote_control_ended" if started => control_ended = true,
                "remote_control_restored" if started => control_ended = false,
                "remote_floor_cancel" if started && is_turn => floor_cancelled = true,
                "user_message" if is_turn => {
                    let named = e.msg.get("images").and_then(Value::as_array);
                    let shown = named.map_or(0, Vec::len);
                    images.extend(named.into_iter().flatten().cloned());
                    let text = field("text").filter(|t| !t.trim().is_empty());
                    prompts.extend(text.or_else(|| {
                        (shown > 0).then(|| format!("({shown} image(s), attached again below)"))
                    }));
                }
                "tool_call" | "tool_call_update" if started => {
                    if let Some(update) = tool_update(&e) {
                        note_unfinished_tool(&mut unfinished, &mut omitted_tools, update);
                    }
                }
                "turn_result" if is_turn => return false,
                _ => {}
            }
            true
        });
        let prompt_id = prompt_id.filter(|p| !p.is_empty())?;
        let (root, done) = split_attempt(&prompt_id);
        let attempt = done + 1;
        if attempt > MAX_ATTEMPTS {
            let msg = json!({"promptId": root, "attempts": done, "turnId": turn_id, "reason": "daemon_restart"});
            self.append(session, "mux", "auto_resume_exhausted", msg);
            return None;
        }
        let effective_web = control.as_deref() == Some("web") || raised_to_web;
        let blocked = if effective_web && floor_cancelled {
            Some("remote_floor_cancel")
        } else if effective_web && control_ended {
            Some("remote_control_ended")
        } else {
            None
        };
        if let Some(reason) = blocked {
            self.append(
                session,
                "mux",
                "auto_resume_skipped",
                json!({"promptId": root, "attempt": attempt, "turnId": turn_id, "skipped": reason}),
            );
            return None;
        }
        let id = format!("{root}{SUFFIX}{attempt}");
        // Logged by a daemon that crashed before it settled the turn: once is enough.
        if self.logged_prompt(session, &id).is_some() {
            return Some(id);
        }
        let msg = json!({"promptId": root, "attempt": attempt, "turnId": turn_id, "delayMs": 0, "reason": "daemon_restart"});
        self.append(session, "mux", "auto_resume_scheduled", msg);
        let text = continue_text(&prompts, &unfinished, if omitted_tools { 1 } else { 0 });
        let provenance = json!({"kind": "auto_resume", "reason": "daemon_restart", "promptId": root, "attempt": attempt, "turnId": turn_id});
        let control = if raised_to_web { "web" } else { control.as_deref().unwrap_or("web") };
        let mut blocks = vec![json!({"type": "text", "text": text})];
        blocks.extend(super::super::prompt_images::blocks_of(&images));
        let mut queued = json!({
            "text": text,
            "client": "acpmux",
            "position": 0,
            "promptId": id,
            "turnId": format!("{turn_id}{SUFFIX}{attempt}"),
            "prompt": blocks,
            "control": control,
            // Checked again as the cut turn was: the folder's trust may have changed across the
            // restart. A Web turn (by its start or a Web steer) is always checked again, as is
            // one from a log from before `turn_started` recorded its gate.
            "trustGate": control == "web" || gate.unwrap_or(false),
        });
        if !images.is_empty() {
            queued["images"] = Value::Array(images);
        }
        let queued = crate::prompt_provenance::marked(queued, Some(&provenance));
        self.append(session, "mux", "queued", queued);
        Some(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_continuation_quotes_the_cut_prompt_and_its_steers() {
        let text = continue_text(&["do the thing".into(), "also this".into()], &[], 0);
        assert!(text.contains("Its prompt:\n<message>\ndo the thing\n</message>"), "{text}");
        assert!(text.contains("A message sent into it:\n<message>\nalso this\n</message>"));
        assert!(text.ends_with("Do not redo work that completed."));
        let long = continue_text(&["x".repeat(MAX_QUOTE_CHARS + 10)], &[], 0);
        assert!(!long.contains(&"x".repeat(MAX_QUOTE_CHARS + 1)));
    }

    #[test]
    fn a_restart_prompt_lists_tool_calls_that_have_not_finished() {
        let update = |fields| {
            json!({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {"update": fields}
            })
        };
        let records = vec![
            EventRecord {
                seq: 1,
                at: 1,
                dir: "in".into(),
                kind: "tool_call".into(),
                msg: update(json!({
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call-1",
                    "status": "in_progress"
                })),
                host_seq: None,
            },
            EventRecord {
                seq: 2,
                at: 2,
                dir: "in".into(),
                kind: "tool_call_update".into(),
                msg: update(json!({
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call-1",
                    "title": "Run tests",
                    "rawInput": {"command": "cargo test -p acpmux"}
                })),
                host_seq: None,
            },
            EventRecord {
                seq: 3,
                at: 3,
                dir: "in".into(),
                kind: "tool_call".into(),
                msg: update(json!({
                    "sessionUpdate": "tool_call",
                    "toolCallId": "call-2",
                    "title": "Finished",
                    "status": "in_progress"
                })),
                host_seq: None,
            },
            EventRecord {
                seq: 4,
                at: 4,
                dir: "in".into(),
                kind: "tool_call_update".into(),
                msg: update(json!({
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "call-2",
                    "status": "completed"
                })),
                host_seq: None,
            },
        ];
        let (tools, omitted) = unfinished_tools(&records);
        let text = continue_text(&[], &tools, omitted);
        assert!(text.contains("Tool calls started but not finished:"), "{text}");
        assert!(text.contains("Run tests (id: call-1)"), "{text}");
        assert!(text.contains("input: {\"command\":\"cargo test -p acpmux\"}"), "{text}");
        assert!(!text.contains("Finished (id: call-2)"), "{text}");
    }

    #[test]
    fn an_omitted_unfinished_tool_is_still_reported_after_retained_calls_finish() {
        let mut open = (0..MAX_UNFINISHED_TOOLS)
            .map(|n| UnfinishedTool {
                name: format!("tool-{n}"),
                id: format!("call-{n}"),
                input: None,
            })
            .collect::<Vec<_>>();
        let mut omitted = false;
        note_unfinished_tool(
            &mut open,
            &mut omitted,
            &json!({"toolCallId": "call-overflow", "title": "overflow", "status": "in_progress"}),
        );
        assert!(omitted);
        for n in 0..MAX_UNFINISHED_TOOLS {
            note_unfinished_tool(
                &mut open,
                &mut omitted,
                &json!({"toolCallId": format!("call-{n}"), "status": "completed"}),
            );
        }
        assert!(open.is_empty());
        let text = continue_text(&[], &open, usize::from(omitted));
        assert!(text.contains("Tool calls started but not finished:"), "{text}");
        assert!(text.contains("additional unfinished tool calls omitted"), "{text}");
    }
}
