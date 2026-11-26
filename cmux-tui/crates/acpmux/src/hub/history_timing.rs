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
//!
//! `firstModelMs` mixes Claude Code's boot, its wait for every `--mcp-config` server, and the API
//! request (cmuxterm-hq `docs/findings/2026-11-24-first-model.md`). So a turn whose prompt met a
//! Claude Code that had just started also gets `claudeBootMs` (`initialize` sent to Claude Code's
//! own answer to it), `systemInitMs` (`initialize` sent to its `system/init`, which comes only once
//! every MCP server connected) and `mcpServers` (each server's status as that `system/init`
//! names it). On a spare that booted before the chat, `systemInitMs` also holds its idle wait.
//! Every Claude turn gets `promptToInitMs` (the prompt written to its `system/init`: the rest of a
//! cold boot and the MCP connects) and `initToModelMs` (that `system/init` to the model's first
//! output), which add up to `firstModelMs`, and `firstCallUsage` (the input, cache read and cache write tokens of its first
//! request's `message_start`).

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
    "claude.control_response",
    "claude.system.init",
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
    /// When `initialize` was last sent: Claude Code started then; cleared by its `system/init`.
    spawned_at: Option<u64>,
    /// Claude Code's own answer to that `initialize`, in ms after it was sent.
    boot_ms: Option<u64>,
    /// When the current turn's `system/init` came.
    init_at: Option<u64>,
    usage_seen: bool,
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
        let mut turn = turn;
        match (e.dir.as_str(), e.kind.as_str()) {
            ("out", method::INITIALIZE) => {
                self.spawned_at = Some(e.at);
                self.boot_ms = None;
            }
            ("in", "claude.control_response") => {
                let id = e.msg.pointer("/response/request_id").and_then(Value::as_str);
                if let Some(spawned) = self.spawned_at
                    && self.boot_ms.is_none()
                    && id.is_some_and(|id| id.starts_with("init-"))
                {
                    self.boot_ms = Some(e.at.saturating_sub(spawned));
                }
            }
            ("in", "claude.system.init") => self.note_init(e, turn.as_deref_mut()),
            ("in", "claude.stream_event") => self.note_usage(e, turn.as_deref_mut()),
            _ => {}
        }
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
                self.init_at = None;
                self.usage_seen = false;
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
                if let Some(init) = self.init_at {
                    t.insert("initToModelMs".into(), json!(e.at.saturating_sub(init)));
                }
                self.model_seen = true;
            }
            _ => {}
        }
    }

    /// The turn's `system/init`; the first one after an `initialize` also ends Claude Code's start.
    fn note_init(&mut self, e: &EventRecord, turn: Option<&mut serde_json::Map<String, Value>>) {
        let Some(t) = turn else { return };
        if self.written_at.is_none() || self.init_at.is_some() {
            return;
        }
        self.init_at = Some(e.at);
        if let Some(written) = self.written_at {
            t.insert("promptToInitMs".into(), json!(e.at.saturating_sub(written)));
        }
        let Some(spawned) = self.spawned_at.take() else { return };
        t.insert("systemInitMs".into(), json!(e.at.saturating_sub(spawned)));
        if let Some(boot) = self.boot_ms.take() {
            t.insert("claudeBootMs".into(), json!(boot));
        }
        // Left out when the session's last logged init had the same list (`logged_init.rs`).
        if let Some(servers) = e.msg.get("mcp_servers").and_then(Value::as_array) {
            let servers: Vec<Value> = servers
                .iter()
                .map(|s| json!({"name": s.get("name"), "status": s.get("status")}))
                .collect();
            t.insert("mcpServers".into(), Value::Array(servers));
        }
    }

    /// The token counts of the turn's first request, from its `message_start`.
    fn note_usage(&mut self, e: &EventRecord, turn: Option<&mut serde_json::Map<String, Value>>) {
        let Some(t) = turn else { return };
        if self.written_at.is_none() || self.usage_seen {
            return;
        }
        if e.msg.pointer("/event/type").and_then(Value::as_str) != Some("message_start") {
            return;
        }
        self.usage_seen = true;
        let Some(usage) = e.msg.pointer("/event/message/usage") else { return };
        let mut counts = serde_json::Map::new();
        for (from, to) in [
            ("input_tokens", "inputTokens"),
            ("cache_read_input_tokens", "cacheReadInputTokens"),
            ("cache_creation_input_tokens", "cacheCreationInputTokens"),
        ] {
            if let Some(n) = usage.get(from).and_then(Value::as_u64) {
                counts.insert(to.into(), json!(n));
            }
        }
        if !counts.is_empty() {
            t.insert("firstCallUsage".into(), Value::Object(counts));
        }
    }
}

#[cfg(test)]
#[path = "history_timing_tests.rs"]
mod tests;
