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
];

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
            }
            ("in", "claude.stream_event" | "tool_call") if !self.model_seen => {
                let (Some(written), Some(t)) = (self.written_at, turn) else { return };
                t.insert("firstModelMs".into(), json!(e.at.saturating_sub(written)));
                self.model_seen = true;
            }
            _ => {}
        }
    }
}

/// The field of a `turn_result` that carries its turn's timing, as [`TurnClock`] saw it written:
/// `toAgentMs`, `firstModelMs` and, on a chat's first turn, `agentStart`.
pub(super) const RECEIPT: &str = "timing";

/// Whether [`TurnClock`] reads record `dir`/`kind`; every other record skips its lock.
pub(super) fn times(dir: &str, kind: &str) -> bool {
    (dir == "mux" && matches!(kind, "user_message" | "turn_result"))
        || (dir == "in" && kind == "tool_call")
        || KINDS.contains(&kind)
}

/// The running turn's timing as its records are written (`Hub::write_record_locked`): the fold
/// `history` runs over the log, run once as the log grows, so the turn's `turn_result` carries it
/// ([`RECEIPT`]). A transcript holds that record but none of the protocol records the times come
/// from, so this daemon's copy of a peer chat (`peer_snapshot.rs`) reads the same times as the
/// peer's own log (cmuxterm-hq finding of 2026-11-19 on first visible token latency: no turn of a
/// peer chat could be read once its peer was down).
#[derive(Default)]
pub(super) struct TurnClock {
    timing: Timing,
    turn: Option<serde_json::Map<String, Value>>,
}

impl TurnClock {
    /// Notes record `e` before it is stored; a `turn_result` takes the receipt of the turn it
    /// ends, unless it has one already (a fork's copy of its parent's turn).
    pub(super) fn note(&mut self, e: &mut EventRecord) {
        if e.dir == "mux" && e.kind == "turn_result" {
            let Some(turn) = self.turn.take() else { return };
            let receipt: serde_json::Map<String, Value> = turn
                .into_iter()
                .filter(|(k, _)| matches!(k.as_str(), "toAgentMs" | "firstModelMs" | "agentStart"))
                .collect();
            if let Some(msg) = e.msg.as_object_mut()
                && !receipt.is_empty()
                && !msg.contains_key(RECEIPT)
            {
                msg.insert(RECEIPT.into(), Value::Object(receipt));
            }
            return;
        }
        let opened = e.dir == "mux"
            && e.kind == "user_message"
            && e.msg.get("steer").and_then(Value::as_bool) != Some(true);
        if opened {
            let mut t = serde_json::Map::new();
            t.insert("startedAt".into(), json!(e.at));
            self.turn = Some(t);
        }
        self.timing.note(e, self.turn.as_mut(), opened);
    }
}

/// Fills the times `turn`'s own records did not give from its `turn_result`'s [`RECEIPT`].
pub(super) fn fill_from_receipt(turn: &mut serde_json::Map<String, Value>, result: &Value) {
    let Some(receipt) = result.get(RECEIPT).and_then(Value::as_object) else { return };
    for (k, v) in receipt {
        if !turn.contains_key(k) {
            turn.insert(k.clone(), v.clone());
        }
    }
}

#[cfg(test)]
#[path = "history_timing_tests.rs"]
mod tests;
