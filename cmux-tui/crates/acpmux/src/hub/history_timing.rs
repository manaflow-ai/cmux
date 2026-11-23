//! Part of `Hub`; see `hub/mod.rs`. Where a turn's wait went, for `acpmux history` (Leo,
//! 2026-11-05, a new chat that read "Thinking 46s": "yeah like 44s no response idk if this is
//! mostly just sr2 tho"). Telling acpmux's part from the model's took a whole session to read out
//! of the log by hand: the agent's start and its start settings took 24 s on a busy Mac, and the
//! model answered about 2 s after the prompt went out.
//!
//! Each turn gets `toAgentMs` (its prompt accepted to the prompt written to the agent: an agent
//! start or resume inside the prompt, its checks) and `firstModelMs` (the prompt written to the
//! model's first output: a Claude stream event or a tool call; the route and the API). A chat's
//! first turn also gets `agentStart`: how long after the chat was created its first prompt came,
//! when the agent was ready, and each request acpmux sent it before that with its answer's time
//! (`initialize`, the start model, effort and mode). Every time is read from records the log
//! already holds, a few per turn.
//!
//! A prompt written while the agent was still at work waits there, and that wait is no model
//! time (cmuxterm-hq `docs/findings/2026-11-23-lane-vm-first-token.md`: 92 of 3,416 turns on a
//! lane VM waited p50 47 s, max 476 s, all read as MODEL; 35 of them behind a compaction). Claude
//! Code holds the prompt line in its queue (`command_lifecycle` `queued`, then `started` once its
//! own work ends), and a compaction before the prompt's first output runs ahead of it
//! (`compaction` `running`, then `completed`). `queuedMs` is the prompt written to the later of
//! those ends, with `queuedOn` `busy` or `compacting`; `firstModelMs` counts from there, so
//! `toAgentMs + queuedMs + firstModelMs` is the prompt accepted to the first output. A hold under
//! [`HELD_MS`] is Claude Code taking the line at once, and counts 0.

use super::*;
use cmux_json::JsonSet as _;

/// The kinds the timing reads beyond `history`'s own: the chat's creation, acpmux's requests to
/// the agent and their answers, and the model's first stream events (`tap.rs` keeps only a
/// request's `message_start` and its first delta of these).
pub(super) const KINDS: &[&str] = &[
    "created",
    method::INITIALIZE,
    method::SESSION_NEW,
    method::SESSION_SET_MODEL,
    method::SESSION_SET_MODE,
    method::SESSION_SET_CONFIG_OPTION,
    method::SESSION_PROMPT,
    "response",
    "claude.stream_event",
    "claude.command_lifecycle",
    "compaction",
];

/// A hold of the prompt line shorter than this is Claude Code reading it as it came (an idle
/// chat's `queued` and `started` are a millisecond or two apart), not a wait behind other work.
pub(super) const HELD_MS: u64 = 250;

/// The requests a chat's start sends before its first prompt.
const START_REQUESTS: [&str; 5] = [
    method::INITIALIZE,
    method::SESSION_NEW,
    method::SESSION_SET_MODEL,
    method::SESSION_SET_MODE,
    method::SESSION_SET_CONFIG_OPTION,
];

/// The fold `history` feeds each record it reads, after its own handling of the record.
#[derive(Default)]
pub(super) struct Timing {
    created_at: Option<u64>,
    /// Start requests not answered yet: id, method, when sent.
    asked: Vec<(Value, String, u64)>,
    steps: Vec<Value>,
    ready_at: Option<u64>,
    prompted: bool,
    /// When the current turn's prompt was written to the agent.
    written_at: Option<u64>,
    model_seen: bool,
    /// A compaction runs (its `running` seen, no end yet), whichever turn it began in.
    compacting: bool,
    /// The current prompt's wait ahead of the model (module docs), while it is read.
    queue: Queue,
}

/// The current prompt's wait, from its write to the model's first output.
#[derive(Default)]
struct Queue {
    /// Claude Code's id of the prompt line: the first `queued` after the write.
    command: Option<String>,
    /// The line was queued and is not started yet.
    held: bool,
    /// The latest end of a wait: the line's `started`, a compaction's end.
    until: Option<u64>,
    /// A compaction ran between the write and the first output.
    compacted: bool,
}

impl Timing {
    /// Notes record `e`; `turn` is the turn `history` holds open after it, `opened` whether `e`
    /// opened it.
    pub(super) fn note(
        &mut self,
        e: &EventRecord,
        turn: Option<&mut serde_json::Map<String, Value>>,
        opened: bool,
    ) {
        match (e.dir.as_str(), e.kind.as_str()) {
            ("mux", "created") => self.created_at = Some(e.at),
            ("out", m) if !self.prompted && START_REQUESTS.contains(&m) => {
                if let Some(id) = e.msg.get("id") {
                    self.asked.push((id.clone(), m.to_owned(), e.at));
                }
            }
            ("in", "response") if !self.prompted => {
                let Some(id) = e.msg.get("id") else { return };
                if let Some(i) = self.asked.iter().position(|(asked, _, _)| asked == id) {
                    let (_, m, at) = self.asked.remove(i);
                    self.steps.push(json!({"method": m, "ms": e.at.saturating_sub(at)}));
                    self.ready_at = Some(e.at);
                }
            }
            ("mux", "user_message") if opened => {
                self.written_at = None;
                self.model_seen = false;
                self.queue = Queue::default();
                if std::mem::replace(&mut self.prompted, true) {
                    return;
                }
                if let (Some(created), Some(t)) = (self.created_at, turn) {
                    let mut start = json!({
                        "firstPromptMs": e.at.saturating_sub(created),
                        "steps": std::mem::take(&mut self.steps),
                    });
                    if let Some(ready) = self.ready_at {
                        start.set("readyMs", json!(ready.saturating_sub(created)));
                    }
                    t.insert("agentStart".into(), start);
                }
            }
            ("out", method::SESSION_PROMPT) => {
                let Some(t) = turn else { return };
                if t.contains_key("toAgentMs") {
                    return;
                }
                let accepted = t.get("startedAt").and_then(Value::as_u64).unwrap_or(e.at);
                t.insert("toAgentMs".into(), json!(e.at.saturating_sub(accepted)));
                self.written_at = Some(e.at);
                self.queue = Queue { compacted: self.compacting, ..Queue::default() };
            }
            ("in", "compaction") => {
                let state = e.msg.pointer("/params/update/state").and_then(Value::as_str);
                let waiting = self.written_at.is_some() && !self.model_seen;
                match state {
                    Some("running") => {
                        self.compacting = true;
                        if waiting {
                            self.queue.compacted = true;
                        }
                    }
                    Some("completed" | "failed") => {
                        self.compacting = false;
                        if waiting && self.queue.compacted {
                            self.queue.until = self.queue.until.max(Some(e.at));
                        }
                    }
                    _ => {}
                }
            }
            ("in", "claude.command_lifecycle") if self.written_at.is_some() && !self.model_seen => {
                let Some(command) = e.msg.get("command_uuid").and_then(Value::as_str) else {
                    return;
                };
                match (e.msg.get("state").and_then(Value::as_str), &self.queue.command) {
                    (Some("queued"), None) => {
                        self.queue.command = Some(command.to_owned());
                        self.queue.held = true;
                    }
                    (Some(_), Some(ours)) if ours == command && self.queue.held => {
                        self.queue.held = false;
                        self.queue.until = self.queue.until.max(Some(e.at));
                    }
                    _ => {}
                }
            }
            ("in", "claude.stream_event" | "tool_call") if !self.model_seen => {
                let (Some(written), Some(t)) = (self.written_at, turn) else { return };
                // A line still held at the first output (its `started` not logged) waited to it.
                let until = if self.queue.held { Some(e.at) } else { self.queue.until };
                let mut queued = until.map_or(0, |u| u.min(e.at).saturating_sub(written));
                if queued < HELD_MS && !self.queue.compacted {
                    queued = 0;
                }
                t.insert("queuedMs".into(), json!(queued));
                if queued > 0 {
                    let on = if self.queue.compacted { "compacting" } else { "busy" };
                    t.insert("queuedOn".into(), json!(on));
                }
                t.insert("firstModelMs".into(), json!(e.at.saturating_sub(written + queued)));
                self.model_seen = true;
            }
            _ => {}
        }
    }
}

#[cfg(test)]
#[path = "history_timing_tests.rs"]
mod tests;
