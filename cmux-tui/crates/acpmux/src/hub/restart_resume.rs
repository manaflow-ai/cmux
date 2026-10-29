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
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::sync::Arc;

/// Longest quote of one cut prompt or steer, in characters.
const MAX_QUOTE_CHARS: usize = 4_000;
/// Longest prefix of one unfinished tool's input shown in a restart prompt.
const MAX_TOOL_INPUT_CHARS: usize = 300;
const MAX_TOOL_FIELD_CHARS: usize = 200;
/// Scan beyond the displayed prefix so secrets crossing its boundary are masked first.
const MAX_TOOL_SCAN_BYTES: usize = 4096;
/// Maximum unfinished calls listed in a restart prompt.
const MAX_UNFINISHED_TOOLS: usize = 32;

/// One tool call that started before the daemon restart and has no terminal update.
#[derive(Debug, Clone, PartialEq, Eq)]
struct UnfinishedTool {
    name: String,
    id: String,
    // Match the complete ID without retaining an arbitrarily large string or conflating
    // two IDs with the same displayed prefix.
    id_digest: [u8; 32],
    input: Option<String>,
}

/// The fields useful to a person resuming a cut turn. Tool updates are JSON-RPC notifications,
/// so the session update is nested under `params.update` in the journal record.
fn tool_update(record: &EventRecord) -> Option<&Value> {
    if record.msg.pointer("/params/_meta/acpmux/subagent").is_some()
        || record.msg.pointer("/_meta/acpmux/subagent").is_some()
    {
        return None;
    }
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
            let mut bytes = Vec::with_capacity(MAX_TOOL_SCAN_BYTES);
            let mut writer = BoundedJsonWriter { bytes: &mut bytes, limit: MAX_TOOL_SCAN_BYTES };
            let truncated = serde_json::to_writer(&mut writer, raw).is_err();
            let valid = match std::str::from_utf8(&bytes) {
                Ok(text) => text.len(),
                Err(error) => error.valid_up_to(),
            };
            bytes.truncate(valid);
            let text = String::from_utf8(bytes).expect("valid JSON prefix");
            let masked = safe_tool_text(&text, truncated, MAX_TOOL_INPUT_CHARS);
            // The input budget is also a byte budget, including multibyte characters.
            let end = masked
                .char_indices()
                .map(|(at, _)| at)
                .chain([masked.len()])
                .take_while(|at| *at <= MAX_TOOL_INPUT_CHARS)
                .last()
                .unwrap_or(0);
            masked[..end].to_owned()
        })
    })
}

struct BoundedJsonWriter<'a> {
    bytes: &'a mut Vec<u8>,
    limit: usize,
}

impl std::io::Write for BoundedJsonWriter<'_> {
    fn write(&mut self, input: &[u8]) -> std::io::Result<usize> {
        let remaining = self.limit.saturating_sub(self.bytes.len());
        self.bytes.extend_from_slice(&input[..input.len().min(remaining)]);
        if input.len() > remaining {
            // Stop serialization immediately, rather than visiting the rest of a large input.
            Err(std::io::Error::other("restart input prefix is full"))
        } else {
            Ok(input.len())
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn bounded_text(value: &str) -> String {
    let end = value
        .char_indices()
        .map(|(at, _)| at)
        .chain([value.len()])
        .take_while(|at| *at <= MAX_TOOL_SCAN_BYTES)
        .last()
        .unwrap_or(0);
    safe_tool_text(&value[..end], end < value.len(), MAX_TOOL_FIELD_CHARS)
}

/// Like the hand-off preview, discard the word crossing the scan boundary: its partial
/// secret may not match a scanner rule. Mask before the much smaller display cut.
fn safe_tool_text(text: &str, truncated: bool, max: usize) -> String {
    let head = if truncated {
        text.rfind(|c: char| c.is_whitespace() || c.is_control()).map_or("", |at| &text[..at])
    } else {
        text
    };
    let normalized: String = head.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    crate::hub::session::short_text(&crate::secret_scan::mask(&normalized), max)
        .chars()
        .take(max)
        .collect()
}

fn enrich_tool(existing: &mut UnfinishedTool, update: &Value) {
    if let Some(name) = update.get("title").and_then(Value::as_str).filter(|n| !n.is_empty()) {
        existing.name = bounded_text(name);
    }
    if let Some(input) = input_prefix(update) {
        existing.input = Some(input);
    }
}

/// Retain display metadata for at most 32 calls. Overflow keeps only fixed-size ID digests,
/// removed by terminal updates, so the omission notice describes calls still in flight.
fn note_unfinished_tool(
    open: &mut Vec<UnfinishedTool>,
    omitted: &mut HashSet<[u8; 32]>,
    update: &Value,
) {
    let Some(id) = update.get("toolCallId").and_then(Value::as_str).filter(|id| !id.is_empty())
    else {
        return;
    };
    let id_digest: [u8; 32] = Sha256::digest(id.as_bytes()).into();
    match update.get("status").and_then(Value::as_str) {
        Some("completed" | "failed") => {
            open.retain(|tool| tool.id_digest != id_digest);
            omitted.remove(&id_digest);
        }
        None if update.get("sessionUpdate").and_then(Value::as_str) == Some("tool_call_update") => {
            if let Some(existing) = open.iter_mut().find(|tool| tool.id_digest == id_digest) {
                enrich_tool(existing, update);
            }
        }
        _ => {
            if let Some(existing) = open.iter_mut().find(|tool| tool.id_digest == id_digest) {
                enrich_tool(existing, update);
            } else if omitted.contains(&id_digest) {
                // Its metadata was omitted already; repeated updates are not new calls.
            } else if open.len() < MAX_UNFINISHED_TOOLS {
                let name = update
                    .get("title")
                    .and_then(Value::as_str)
                    .filter(|name| !name.is_empty())
                    .or_else(|| {
                        update.get("kind").and_then(Value::as_str).filter(|name| !name.is_empty())
                    })
                    .unwrap_or("tool");
                open.push(UnfinishedTool {
                    name: bounded_text(name),
                    id: bounded_text(id),
                    id_digest,
                    input: input_prefix(update),
                });
            } else {
                omitted.insert(id_digest);
            }
        }
    }
}

/// Collects tool calls in the cut turn for the journal-fold regression test.
#[cfg(test)]
fn unfinished_tools(records: &[EventRecord]) -> (Vec<UnfinishedTool>, usize) {
    let mut open = Vec::<UnfinishedTool>::new();
    let mut omitted = HashSet::new();
    for record in records {
        if let Some(update) = tool_update(record) {
            note_unfinished_tool(&mut open, &mut omitted, update);
        }
    }
    (open, omitted.len())
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
        let mut omitted_tools = HashSet::new();
        let _ = self.store.scan_heads(&session.id, &mut |head: &RecordHead<'_>| {
            // Headers are cheap to inspect. Parse payloads only after the interrupted turn starts,
            // and stop at its result so a long session does not deserialize historical tool I/O.
            let kind = head.kind.strip_suffix(".replay").unwrap_or(head.kind);
            let needs_record = match kind {
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
                "tool_call"
                | "tool_call_update"
                | "tool_call.replay"
                | "tool_call_update.replay"
                    if started =>
                {
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
        let text = continue_text(&prompts, &unfinished, omitted_tools.len());
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
    use crate::store::EventRecord;

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
                id_digest: Sha256::digest(format!("call-{n}").as_bytes()).into(),
                input: None,
            })
            .collect::<Vec<_>>();
        let mut omitted = HashSet::new();
        note_unfinished_tool(
            &mut open,
            &mut omitted,
            &json!({"toolCallId": "call-overflow", "title": "overflow", "status": "in_progress"}),
        );
        assert_eq!(omitted.len(), 1);
        for n in 0..MAX_UNFINISHED_TOOLS {
            note_unfinished_tool(
                &mut open,
                &mut omitted,
                &json!({"toolCallId": format!("call-{n}"), "status": "completed"}),
            );
        }
        assert!(open.is_empty());
        let text = continue_text(&[], &open, omitted.len());
        assert!(text.contains("Tool calls started but not finished:"), "{text}");
        assert!(text.contains("additional unfinished tool calls omitted"), "{text}");
    }

    #[test]
    fn completed_overflow_tools_leave_no_unfinished_warning() {
        let mut records = Vec::new();
        let update = |id: usize, status: &str| EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: "tool_call_update".into(),
            msg: json!({"params": {"update": {"sessionUpdate": "tool_call_update",
                "toolCallId": format!("call-{id}"), "status": status}}}),
            host_seq: None,
        };
        for n in 0..MAX_UNFINISHED_TOOLS + 2 {
            records.push(update(n, "in_progress"));
        }
        // Repeated updates must not count the same overflow call more than once.
        records.push(update(MAX_UNFINISHED_TOOLS, "in_progress"));
        for n in 0..MAX_UNFINISHED_TOOLS {
            records.push(update(n, "completed"));
        }
        // Even with a free display slot, an overflow update remains the same tracked call.
        records.push(update(MAX_UNFINISHED_TOOLS, "in_progress"));
        records.push(update(MAX_UNFINISHED_TOOLS, "completed"));
        let (tools, omitted) = unfinished_tools(&records);
        assert!(tools.is_empty());
        assert_eq!(omitted, 1);
        assert!(continue_text(&[], &tools, omitted).contains("unfinished tool calls omitted"));
        records.push(update(MAX_UNFINISHED_TOOLS + 1, "failed"));
        let (tools, omitted) = unfinished_tools(&records);
        assert_eq!(omitted, 0, "completed overflow must not leave a permanent warning");
        assert!(!continue_text(&[], &tools, omitted).contains("Tool calls started"));
    }

    #[test]
    fn restart_tool_details_are_single_line_and_mask_secrets_before_truncation() {
        let credential = ["abcd", "1234"].repeat(8).join("");
        let record = EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"update": {"sessionUpdate": "tool_call",
                "toolCallId": "call\n\t\u{1b}1", "title": "Run\r\n\t\u{0} tests",
                "status": "in_progress", "rawInput": {"command": format!("curl -H 'Authorization: Bearer {credential}'")}}}}),
            host_seq: None,
        };
        let (tools, omitted) = unfinished_tools(&[record]);
        let text = continue_text(&[], &tools, omitted);
        assert!(text.contains("Run tests (id: call 1)"), "{text}");
        assert!(!text.contains(&credential), "credentials must not enter the continuation");
        assert!(text.contains("[auth token]"));
        assert!(!text.contains('\u{1b}') && !text.contains('\u{0}'));
        for prefix in [" ".repeat(270), "x".repeat(240)] {
            let masked = input_prefix(
                &json!({"rawInput": format!("{prefix} Authorization: Bearer {credential}")}),
            )
            .unwrap();
            assert!(!masked.contains(&credential[..24]), "secret straddles display cut");
        }
        let masked = input_prefix(&json!({"rawInput": {"password": credential}})).unwrap();
        assert!(!masked.contains(&credential));
        assert!(masked.contains("[secret]"));
        // A token longer than the scan budget is dropped whole, never exposed as a prefix.
        let huge = credential.repeat(MAX_TOOL_SCAN_BYTES);
        let masked =
            input_prefix(&json!({"rawInput": format!("Authorization: Bearer {huge}")})).unwrap();
        assert!(!masked.contains(&credential[..24]));
        assert!(
            !bounded_text(&format!("Authorization: Bearer {credential}")).contains(&credential)
        );
    }

    #[test]
    fn child_tool_updates_are_ignored_and_metadata_is_bounded() {
        let child = EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: "tool_call".into(),
            msg: json!({"params": {"_meta": {"acpmux": {"subagent": {"id": "child"}}}, "update": {"sessionUpdate": "tool_call", "toolCallId": "child-call", "status": "in_progress"}}}),
            host_seq: None,
        };
        assert!(tool_update(&child).is_none());

        let mut open = Vec::new();
        let mut omitted = HashSet::new();
        let huge = "x".repeat(MAX_TOOL_FIELD_CHARS + 100);
        note_unfinished_tool(
            &mut open,
            &mut omitted,
            &json!({"toolCallId": huge, "title": huge, "status": "in_progress", "rawInput": {"body": "x".repeat(10_000)}}),
        );
        assert_eq!(open[0].id.chars().count(), MAX_TOOL_FIELD_CHARS);
        assert_eq!(open[0].name.chars().count(), MAX_TOOL_FIELD_CHARS);
        assert!(open[0].input.as_ref().unwrap().len() <= MAX_TOOL_INPUT_CHARS);
        // Same displayed prefix, but a different full ID must remain a different call.
        note_unfinished_tool(
            &mut open,
            &mut omitted,
            &json!({"toolCallId": format!("{huge}2"), "status": "in_progress"}),
        );
        assert_eq!(open.len(), 2);
        note_unfinished_tool(
            &mut open,
            &mut omitted,
            &json!({"toolCallId": huge, "status": "completed"}),
        );
        assert_eq!(open.len(), 1);
        note_unfinished_tool(
            &mut open,
            &mut omitted,
            &json!({"toolCallId": format!("{huge}2"), "status": "failed"}),
        );
        assert!(open.is_empty());
    }

    #[test]
    fn input_serialization_stops_at_the_prefix_budget() {
        use serde::Serialize;
        struct Unvisited;
        impl Serialize for Unvisited {
            fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
                panic!("serialization must stop before the next value");
            }
        }
        let mut bytes = Vec::with_capacity(MAX_TOOL_INPUT_CHARS);
        let mut writer = BoundedJsonWriter { bytes: &mut bytes, limit: MAX_TOOL_INPUT_CHARS };
        assert!(serde_json::to_writer(&mut writer, &("x".repeat(10_000), Unvisited)).is_err());
        assert_eq!(bytes.len(), MAX_TOOL_INPUT_CHARS);
        let prefix = input_prefix(&json!({"rawInput": "世".repeat(10_000)})).unwrap();
        assert!(prefix.len() <= MAX_TOOL_INPUT_CHARS);
        assert!(!prefix.contains('\u{fffd}'));
    }

    #[tokio::test]
    async fn restart_journal_ignores_children_and_honors_replayed_completion() {
        use crate::config::{Config, StoreMode};
        let root =
            std::env::temp_dir().join(format!("acpmux-restart-tools-{}", uuid::Uuid::now_v7()));
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Local;
        let store = crate::store::open(&cfg.store, &root).unwrap();
        store.save(&serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
        })).unwrap()).unwrap();
        let hub = Hub::new(cfg, store);
        let session = hub.resolve("chat").unwrap();
        let tool = |id: &str, state: &str| {
            json!({"params": {"update": {
                "sessionUpdate": "tool_call", "toolCallId": id, "title": id, "status": state
            }}})
        };
        // Historical inputs must not enter the interrupted turn's summary.
        for _ in 0..100 {
            hub.append(&session, "in", "tool_call", tool("historical", "in_progress"));
        }
        hub.append(
            &session,
            "mux",
            "turn_started",
            json!({"turnId": "cut", "promptId": "p", "control": "local", "trustGate": false}),
        );
        // More child calls than the display cap, including replayed calls and an ID
        // shared with the parent, cannot consume or remove the parent's entries.
        for n in 0..=MAX_UNFINISHED_TOOLS {
            let mut child = tool(&format!("child-{n}"), "in_progress");
            child["params"]["_meta"] = json!({"acpmux": {"subagent": {"id": "child"}}});
            hub.append(&session, "in", "tool_call.replay", child);
        }
        hub.append(&session, "in", "tool_call", tool("finished", "in_progress"));
        let mut completion = tool("finished", "completed");
        completion["params"]["update"]["sessionUpdate"] = json!("tool_call_update");
        hub.append(&session, "in", "tool_call_update.replay", completion);
        hub.append(&session, "in", "tool_call.replay", tool("own", "in_progress"));
        let mut child = tool("own", "completed");
        child["params"]["_meta"] = json!({"acpmux": {"subagent": {"id": "child"}}});
        hub.append(&session, "in", "tool_call_update", child);
        assert!(hub.log_restart_continuation(&session, "cut").is_some());
        let records = hub.events("chat", 0, usize::MAX).unwrap();
        let text =
            records.iter().find(|e| e.kind == "queued").unwrap().msg["text"].as_str().unwrap();
        assert!(text.contains("own (id: own)"), "{text}");
        for absent in ["child-", "historical", "finished (id:", "omitted"] {
            assert!(!text.contains(absent), "{text}");
        }
        hub.shutdown_all().await;
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn replayed_terminal_tool_update_closes_the_call() {
        let update = |kind: &str, status: &str| EventRecord {
            seq: 1,
            at: 1,
            dir: "in".into(),
            kind: kind.into(),
            msg: json!({"params": {"update": {"sessionUpdate": "tool_call_update", "toolCallId": "call-1", "status": status}}}),
            host_seq: None,
        };
        let records = vec![
            EventRecord {
                kind: "tool_call".into(),
                msg: json!({"params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "call-1", "status": "in_progress"}}}),
                ..update("tool_call", "in_progress")
            },
            update("tool_call_update.replay", "completed"),
        ];
        let (tools, omitted) = unfinished_tools(&records);
        assert!(tools.is_empty());
        assert_eq!(omitted, 0);
    }
}
