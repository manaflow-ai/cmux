//! A coordinator's chat as acpmux records, the lines a client reads from `_acpmux/attach`, `_acpmux/events` and
//! the live `_acpmux/event` stream: `{"sessionId","seq","at","dir","kind","msg"}`.
//!
//! Every surface reads the same records: the desktop pane bench (webviews/bench/coord-sim-load.bench.ts) serves them
//! from its stand-in daemon, the relay target sends them through circuits, the iOS rig replays them in a chat view.
//! The kind of each record and its size come from the shape (`kind_bytes`), the gaps between records from `gap_ms`;
//! text is `filler`, never transcript content. Kinds the pane draws are built as the agents send them (reply and
//! thought chunks, tool calls and their updates, a prompt, a turn's start and result); every other kind keeps its
//! size and direction under the method `_coord_sim/raw`, which a client logs and does not draw.

use crate::event::filler;
use crate::rng::Rng;
use crate::shape::{Hist, Shape};
use serde_json::{Value, json};

/// Fixed origin of the history clock (2026-11-19T00:00:00Z), so the same seed writes the same bytes.
const EPOCH_MS: u64 = 1_763_510_400_000;

#[derive(Debug, Clone)]
pub struct Plan {
    pub seed: u64,
    pub coordinators: u32,
    /// Records each chat already holds when a reader attaches.
    pub history: u32,
    /// Seconds of live stream (wall clock, after the rate).
    pub live_s: f64,
    /// Rate multiplier: gaps are divided by it.
    pub rate: f64,
    /// Largest record payload, bytes (the shape's tail reaches 29 MB; a surface caps what it can carry).
    pub max_event_bytes: u64,
    /// Longest gap between two records at 1x, ms (the shape's tail is days of nothing).
    pub max_gap_ms: u64,
}

impl Plan {
    pub fn from_args(args: &[String]) -> Result<Plan, String> {
        Ok(Plan {
            seed: crate::flag_or(args, "--seed", 1u64)?,
            coordinators: crate::flag_or(args, "--coordinators", 3u32)?.max(1),
            history: crate::flag_or(args, "--history", 5_000u32)?,
            live_s: crate::flag_or(args, "--seconds", 30.0f64)?,
            rate: crate::flag_or(args, "--rate", 10.0f64)?.max(0.001),
            max_event_bytes: crate::flag_or(args, "--max-event-bytes", 256 * 1024u64)?.max(64),
            max_gap_ms: crate::flag_or(args, "--max-gap-ms", 5_000u64)?,
        })
    }
}

/// The id of coordinator `index`: a UUID-shaped id of its own (the pane keys chats by it).
pub fn session_id(index: u32) -> String {
    format!("0190c000-0000-7000-8000-{:012x}", 0x5100_0000u64 + index as u64)
}

/// One coordinator's records: what it held before the reader came (`history`) and what streams while it reads
/// (`live`, each with its offset from the stream's start in ms, after the rate).
pub struct Chat {
    pub session_id: String,
    pub title: String,
    pub history: Vec<Value>,
    pub live: Vec<(u64, Value)>,
}

struct Kinds {
    names: Vec<String>,
    weights: Vec<u64>,
    sizes: Vec<Hist>,
}

impl Kinds {
    fn of(shape: &Shape) -> Kinds {
        let mut out = Kinds { names: vec![], weights: vec![], sizes: vec![] };
        for (name, hist) in &shape.acpmux.kind_bytes {
            // A replay is a resumed agent saying its history again: not new traffic.
            if hist.n == 0 || name.ends_with(".replay") {
                continue;
            }
            out.names.push(name.clone());
            out.weights.push(hist.n);
            out.sizes.push(hist.clone());
        }
        if out.names.is_empty() {
            out.names.push("in:agent_message_chunk".into());
            out.weights.push(1);
            out.sizes.push(Hist { n: 1, sum: 400, max: 400, ..Hist::default() });
        }
        out
    }
}

/// The generator's state for one chat: its clock, its sequence, its turn and its open tool calls.
struct Writer<'a> {
    rng: Rng,
    plan: &'a Plan,
    kinds: &'a Kinds,
    gaps: &'a Hist,
    turn_len: u64,
    id: String,
    seq: u64,
    in_turn: u64,
    turns: u64,
    open_calls: Vec<String>,
    calls: u64,
    tool_kinds: Vec<(String, u64)>,
}

impl<'a> Writer<'a> {
    fn record(&mut self, at: u64, dir: &str, kind: &str, msg: Value) -> Value {
        self.seq += 1;
        json!({ "sessionId": self.id, "seq": self.seq, "at": at, "dir": dir, "kind": kind, "msg": msg })
    }

    fn update(update: Value) -> Value {
        json!({ "method": "session/update", "params": { "sessionId": "agent-1", "update": update } })
    }

    fn text(&mut self, bytes: u64) -> String {
        let n = bytes.clamp(8, self.plan.max_event_bytes) as usize;
        filler(self.rng.next_u64(), n)
    }

    /// The records of one step: a turn boundary when one is due, else one record of a kind drawn from the mix.
    fn step(&mut self, at: u64, out: &mut Vec<Value>) {
        if self.in_turn == 0 {
            self.turns += 1;
            let prompt =
                format!("Coordinate round {}: {}", self.turns, filler(self.rng.next_u64(), 80));
            let m = json!({ "text": prompt, "promptId": format!("p-{}", self.turns), "turnId": format!("t-{}", self.turns) });
            out.push(self.record(at, "mux", "user_message", m));
            out.push(self.record(at, "mux", "turn_started", json!({})));
            self.in_turn = 1;
            return;
        }
        if self.in_turn >= self.turn_len {
            for call in std::mem::take(&mut self.open_calls) {
                let m = Self::update(
                    json!({ "sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed" }),
                );
                out.push(self.record(at, "in", "tool_call_update", m));
            }
            let tail = self.text(200);
            let text = format!("Answer {}: {}", self.turns, tail);
            let m = Self::update(
                json!({ "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": text } }),
            );
            out.push(self.record(at, "in", "agent_message_chunk", m));
            out.push(self.record(at, "mux", "turn_result", json!({ "status": "completed" })));
            self.in_turn = 0;
            return;
        }
        self.in_turn += 1;
        let pick = self.rng.weighted(&self.kinds.weights);
        let (name, size) = match (self.kinds.names.get(pick), self.kinds.sizes.get(pick)) {
            (Some(n), Some(s)) => (n.clone(), s.clone()),
            _ => return,
        };
        let bytes = size.sample(&mut self.rng);
        let (dir, kind) = name.split_once(':').unwrap_or(("in", name.as_str()));
        let (dir, kind) = (dir.to_string(), kind.to_string());
        let rec = match (dir.as_str(), kind.as_str()) {
            ("in", "agent_message_chunk" | "agent_thought_chunk") => {
                let text = self.text(bytes.saturating_sub(120));
                Some(Self::update(
                    json!({ "sessionUpdate": kind, "content": { "type": "text", "text": text } }),
                ))
            }
            ("in", "tool_call") => {
                self.calls += 1;
                let call = format!("call-{}", self.calls);
                let weights: Vec<u64> = self.tool_kinds.iter().map(|(_, n)| *n).collect();
                let tk = self.tool_kinds.get(self.rng.weighted(&weights)).map(|(k, _)| k.clone());
                let tail = self.text(bytes.saturating_sub(300).min(4000));
                let command = format!("glaeda-gh status pr {} {}", self.calls, tail);
                self.open_calls.push(call.clone());
                if self.open_calls.len() > 8 {
                    self.open_calls.remove(0);
                }
                Some(Self::update(json!({
                    "sessionUpdate": "tool_call", "toolCallId": call, "title": format!("glaeda-gh status pr {}", self.calls),
                    "kind": tk.unwrap_or_else(|| "execute".into()), "status": "in_progress", "rawInput": { "command": command },
                })))
            }
            ("in", "tool_call_update") => {
                let call = match self.open_calls.last() {
                    Some(c) => c.clone(),
                    None => {
                        self.calls += 1;
                        format!("call-{}", self.calls)
                    }
                };
                let text = self.text(bytes.saturating_sub(200));
                let done = self.rng.chance(0.5);
                if done {
                    self.open_calls.retain(|c| *c != call);
                }
                Some(Self::update(json!({
                    "sessionUpdate": "tool_call_update", "toolCallId": call,
                    "status": if done { "completed" } else { "in_progress" },
                    "content": [{ "type": "content", "content": { "type": "text", "text": text } }],
                })))
            }
            // Turn boundaries come from the turn length, not the mix.
            ("mux", "user_message" | "turn_started" | "turn_result" | "turn_end") => None,
            _ => {
                let text = self.text(bytes.saturating_sub(80));
                Some(
                    json!({ "method": "_coord_sim/raw", "params": { "kind": name, "text": text } }),
                )
            }
        };
        if let Some(msg) = rec {
            out.push(self.record(at, &dir, &kind, msg));
        }
    }

    /// The next gap at 1x, ms, capped at the plan's longest.
    fn gap(&mut self) -> u64 {
        self.gaps.sample(&mut self.rng).min(self.plan.max_gap_ms)
    }
}

/// Every coordinator's chat for `plan`, from `shape`. Same seed, same records.
pub fn chats(shape: &Shape, plan: &Plan) -> Vec<Chat> {
    let kinds = Kinds::of(shape);
    let per = &shape.acpmux.per_session;
    // Records per turn: a chat's records over its prompts (a coordinator's turns run long: about a thousand here).
    let turn_len = if per.user_turns.mean() >= 1.0 {
        (per.events.mean() / per.user_turns.mean()) as u64
    } else {
        400
    };
    let mut tool_kinds: Vec<(String, u64)> =
        shape.acpmux.tool_call_kinds.iter().map(|(k, n)| (k.clone(), *n)).collect();
    if tool_kinds.is_empty() {
        tool_kinds.push(("execute".into(), 1));
    }
    let mut root = Rng::new(plan.seed);
    (0..plan.coordinators)
        .map(|index| {
            let mut w = Writer {
                rng: root.fork(index as u64),
                plan,
                kinds: &kinds,
                gaps: &shape.acpmux.gap_ms,
                turn_len: turn_len.max(20),
                id: session_id(index),
                seq: 0,
                in_turn: 0,
                turns: 0,
                open_calls: vec![],
                calls: 0,
                tool_kinds: tool_kinds.clone(),
            };
            let mut history = Vec::new();
            let mut clock = EPOCH_MS;
            while history.len() < plan.history as usize {
                clock += w.gap();
                w.step(clock, &mut history);
            }
            // The live stream continues the same turn, the reader arriving in the middle of it.
            let mut live = Vec::new();
            let horizon = (plan.live_s * 1000.0) as u64;
            let mut at_1x = 0u64;
            loop {
                at_1x += w.gap();
                let offset = (at_1x as f64 / plan.rate) as u64;
                if offset > horizon {
                    break;
                }
                let mut step = Vec::new();
                w.step(EPOCH_MS, &mut step);
                live.extend(step.into_iter().map(|r| (offset, r)));
            }
            Chat {
                session_id: w.id.clone(),
                title: format!("Coordinator {}", index + 1),
                history,
                live,
            }
        })
        .collect()
}

/// `coord-sim surface --target app-host|ios --out DIR`: writes the records a surface's bench serves.
///   DIR/manifest.json            schema coord-sim-surface-records.v1: the plan and each chat's id, title, counts
///   DIR/history-<i>.ndjson       chat i's records before the reader attaches
///   DIR/live.ndjson              every chat's live records, merged in time order; `at` is the offset in ms
pub fn write(shape: &Shape, plan: &Plan, dir: &str) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("{dir}: {e}"))?;
    let chats = chats(shape, plan);
    let mut manifest = Vec::new();
    let mut live: Vec<(u64, usize, Value)> = Vec::new();
    for (i, chat) in chats.iter().enumerate() {
        let path = format!("{dir}/history-{i}.ndjson");
        let mut text = String::new();
        let mut bytes = 0usize;
        for r in &chat.history {
            let line = r.to_string();
            bytes += line.len();
            text.push_str(&line);
            text.push('\n');
        }
        std::fs::write(&path, text).map_err(|e| format!("{path}: {e}"))?;
        let live_bytes: usize = chat.live.iter().map(|(_, r)| r.to_string().len()).sum();
        manifest.push(json!({
            "sessionId": chat.session_id, "title": chat.title, "history": chat.history.len(), "historyBytes": bytes,
            "live": chat.live.len(), "liveBytes": live_bytes,
            "lastHistorySeq": chat.history.last().and_then(|r| r.get("seq")).cloned().unwrap_or(json!(0)),
        }));
        for (n, (at, r)) in chat.live.iter().enumerate() {
            live.push((*at, i * 1_000_000 + n, r.clone()));
        }
    }
    live.sort_by_key(|(at, order, _)| (*at, *order));
    let mut text = String::new();
    for (at, _, mut r) in live {
        if let Some(o) = r.as_object_mut() {
            o.insert("at".into(), json!(at));
        }
        text.push_str(&r.to_string());
        text.push('\n');
    }
    let path = format!("{dir}/live.ndjson");
    std::fs::write(&path, text).map_err(|e| format!("{path}: {e}"))?;
    let m = json!({
        "schema": "coord-sim-surface-records.v1", "seed": plan.seed, "coordinators": plan.coordinators,
        "rate": plan.rate, "seconds": plan.live_s, "history": plan.history, "maxEventBytes": plan.max_event_bytes,
        "chats": manifest,
    });
    let path = format!("{dir}/manifest.json");
    std::fs::write(&path, m.to_string()).map_err(|e| format!("{path}: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan() -> Plan {
        Plan {
            seed: 7,
            coordinators: 3,
            history: 500,
            live_s: 5.0,
            rate: 10.0,
            max_event_bytes: 8192,
            max_gap_ms: 5000,
        }
    }

    #[test]
    fn same_seed_same_records() {
        let shape = Shape::load(None).unwrap();
        let a = chats(&shape, &plan());
        let b = chats(&shape, &plan());
        assert_eq!(a.len(), 3);
        for (x, y) in a.iter().zip(&b) {
            assert_eq!(x.history, y.history);
            assert_eq!(x.live.len(), y.live.len());
        }
    }

    #[test]
    fn records_are_ordered_capped_and_shaped() {
        let shape = Shape::load(None).unwrap();
        for chat in chats(&shape, &plan()) {
            assert!(chat.history.len() >= 500);
            assert!(!chat.live.is_empty(), "a 5 s stream at 10x has records");
            let mut last = 0;
            for r in chat.history.iter().chain(chat.live.iter().map(|(_, r)| r)) {
                let seq = r["seq"].as_u64().unwrap();
                assert_eq!(seq, last + 1);
                last = seq;
                assert!(r.to_string().len() < 8192 + 2048);
                assert_eq!(r["sessionId"], chat.session_id.as_str());
            }
            assert!(chat.history.iter().any(|r| r["kind"] == "turn_started"));
            assert!(chat.history.iter().any(|r| r["kind"] == "tool_call"));
            assert!(chat.live.windows(2).all(|w| w[0].0 <= w[1].0));
        }
    }
}
