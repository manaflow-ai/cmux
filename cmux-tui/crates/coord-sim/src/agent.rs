//! `coord-sim agent`: a stand-in ACP agent that replays one coordinator script (`event.rs` NDJSON).
//!
//!   coord-sim agent --script FILE --rate X [--coord C] [--emit-log DIR]
//!
//! JSON-RPC 2.0 over stdio, one message per line, the handshake acpmux expects of an agent (as
//! `acpmux/tests/fake_agent.py`): `initialize`, `session/new`, `session/load`, `session/fork`,
//! `session/prompt`, `session/cancel`, `session/set_*`.
//!
//! Turns. The script is cut into segments at its `user_turn` ops: the driver sends one prompt
//! `coord-sim:run t0=<epoch us>` per segment, and this agent streams that segment's events as ACP
//! `session/update` notifications, each at `t0 + at_ms / rate`, then answers `end_turn`. Events
//! that come due while the agent is behind go at once (their `emit_us` shows the lag). Any other
//! prompt (another coordinator's `acpmux send`) is acknowledged with one short chunk and
//! `end_turn`, and does not move the script.
//!
//! Every emitted update carries a tag `[[cs:C:SEQ:K:EMIT_US]]` in its payload text (coordinator,
//! script seq, sub-index for a subagent's events, emit time in epoch microseconds), so the
//! daemon's store and every reader can count loss and duplication downstream. With `--emit-log`,
//! each emitted event is also one line of `DIR/emit-C-PID.ndjson` (`EmitRecord`).
//!
//! Kind mapping: `in:X` (and `in:X.replay`) where X is an ACP update this agent can shape
//! (`SHAPED`) is sent as X; any other `in:` kind (a harness's raw line: `claude.*`, `codex.*`,
//! `response`, ...) as `agent_thought_chunk` of the same size. `out:` and `mux:` kinds are written
//! by acpmux itself, so the agent sends nothing for them. `subagent` streams its events tagged
//! `_meta.acpmux.subagent`; `compaction` and `attachment` are sent as `agent_message_chunk`;
//! `send_to` and `user_turn` are the driver's.

use crate::event::{Op, SimEvent, filler};
use crate::{flag, flag_or};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{BufRead, Write};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// ACP `sessionUpdate`s the agent sends as themselves. Not `plan`: acpmux drops an agent to-do
/// list before the log (`todo_tools.rs`), so a recorded one is sent as a thought.
pub const SHAPED: &[&str] = &[
    "agent_message_chunk",
    "agent_thought_chunk",
    "user_message_chunk",
    "tool_call",
    "tool_call_update",
    "usage_update",
    "available_commands_update",
    "session_info_update",
];

/// The prompt text that runs the next segment.
pub const RUN_PREFIX: &str = "coord-sim:run";
/// A subagent's events are capped at this many per op.
const SUBAGENT_CAP: u32 = 2000;

/// One emitted event (`emit-*.ndjson`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct EmitRecord {
    pub c: u32,
    pub seq: u64,
    #[serde(default)]
    pub k: u32,
    /// The script kind; for an `in:` kind the update actually sent is `update`.
    pub kind: String,
    pub update: String,
    pub bytes: u64,
    pub due_us: u64,
    pub emit_us: u64,
}

pub fn now_us() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_micros() as u64).unwrap_or(0)
}

/// `[[cs:C:SEQ:K:EMIT_US]]`.
pub fn tag(c: u32, seq: u64, k: u32, emit_us: u64) -> String {
    format!("[[cs:{c}:{seq}:{k}:{emit_us}]]")
}

/// A tag found in text: (coordinator, seq, k, emit_us).
pub type Tag = (u32, u64, u32, u64);

/// Every tag in `text`, in order.
pub fn find_tags(text: &str) -> Vec<Tag> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(i) = rest.find("[[cs:") {
        rest = rest.get(i + 5..).unwrap_or_default();
        let Some(end) = rest.find("]]") else { break };
        let mut parts = rest.get(..end).unwrap_or_default().split(':');
        let parsed = (|| {
            let c = parts.next()?.parse().ok()?;
            let seq = parts.next()?.parse().ok()?;
            let k = parts.next()?.parse().ok()?;
            let t = parts.next()?.parse().ok()?;
            Some((c, seq, k, t))
        })();
        // One record may carry its tag in two fields (a tool call's title and input): once.
        if let Some(t) = parsed
            && !out.contains(&t)
        {
            out.push(t);
        }
        rest = rest.get(end + 2..).unwrap_or_default();
    }
    out
}

/// The ACP update an `in:` script kind is sent as; None for kinds acpmux writes itself.
pub fn update_for(kind: &str) -> Option<&'static str> {
    let rest = kind.strip_prefix("in:")?;
    let base = rest.strip_suffix(".replay").unwrap_or(rest);
    Some(SHAPED.iter().copied().find(|s| *s == base).unwrap_or("agent_thought_chunk"))
}

/// The `update` object of one event: `tagged` text padded to about `bytes` on the wire.
pub fn update_json(update: &str, tagged: &str, bytes: u64, seed: u64, tool_id: &str) -> Value {
    // The envelope (method, sessionId, field names) is roughly 120 bytes.
    let pad = (bytes as usize).saturating_sub(120 + tagged.len());
    let text = format!("{tagged} {}", filler(seed, pad));
    match update {
        "tool_call" => json!({"sessionUpdate": "tool_call", "toolCallId": tool_id, "title": tagged,
            "kind": "execute", "status": "in_progress", "rawInput": {"command": text}}),
        "tool_call_update" => json!({"sessionUpdate": "tool_call_update", "toolCallId": tool_id,
            "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": text}}]}),
        "usage_update" => json!({"sessionUpdate": "usage_update", "used": 1000 + seed % 100_000,
            "size": 200_000, "_meta": {"coordSim": text}}),
        "available_commands_update" => json!({"sessionUpdate": "available_commands_update",
            "availableCommands": [{"name": "coord-sim", "description": text}]}),
        "session_info_update" => {
            json!({"sessionUpdate": "session_info_update", "_meta": {"coordSim": text}})
        }
        other => json!({"sessionUpdate": other, "content": {"type": "text", "text": text}}),
    }
}

/// The script cut at its `user_turn` ops: segment 0 is what comes before the first one.
pub fn segments(script: &[SimEvent]) -> Vec<Vec<SimEvent>> {
    let mut out = vec![Vec::new()];
    for e in script {
        if e.op == Op::UserTurn {
            out.push(Vec::new());
        } else if let Some(last) = out.last_mut() {
            last.push(e.clone());
        }
    }
    out
}

pub fn read_script(path: &str) -> Result<Vec<SimEvent>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    text.lines()
        .filter(|l| !l.trim().is_empty())
        .enumerate()
        .map(|(i, l)| serde_json::from_str(l).map_err(|e| format!("{path}:{}: {e}", i + 1)))
        .collect()
}

pub fn parse_rate(s: &str) -> Result<f64, String> {
    let v: f64 =
        s.trim_end_matches(['x', 'X']).parse().map_err(|_| format!("rate: bad value {s:?}"))?;
    if v > 0.0 { Ok(v) } else { Err(format!("rate: {s:?} must be above 0")) }
}

struct Out(Mutex<std::io::BufWriter<std::io::Stdout>>);

impl Out {
    fn send(&self, v: &Value) {
        if let Ok(mut w) = self.0.lock() {
            let _ = serde_json::to_writer(&mut *w, v);
            let _ = w.write_all(b"\n");
            let _ = w.flush();
        }
    }

    /// Many lines under one lock and one flush.
    fn send_all(&self, lines: &[Value]) {
        if let Ok(mut w) = self.0.lock() {
            for v in lines {
                let _ = serde_json::to_writer(&mut *w, v);
                let _ = w.write_all(b"\n");
            }
            let _ = w.flush();
        }
    }
}

struct Agent {
    coord: u32,
    rate: f64,
    segments: Vec<Vec<SimEvent>>,
    next_segment: AtomicU64,
    out: Out,
    emit: Option<Mutex<std::io::BufWriter<std::fs::File>>>,
    cancelled: Mutex<std::collections::HashSet<String>>,
    /// stdin closed: every turn stops.
    closed: AtomicBool,
    sessions: AtomicU64,
    /// One turn streams at a time; a second run prompt waits for it.
    turn: Mutex<()>,
}

pub fn run(args: &[String]) -> Result<(), String> {
    let script = flag(args, "--script").ok_or("--script FILE is required")?;
    let rate = parse_rate(flag(args, "--rate").unwrap_or("1"))?;
    let coord: u32 = flag_or(args, "--coord", 0)?;
    let events = read_script(script)?;
    let emit = match flag(args, "--emit-log") {
        Some(dir) => {
            std::fs::create_dir_all(dir).map_err(|e| format!("{dir}: {e}"))?;
            let path = format!("{dir}/emit-{coord}-{}.ndjson", std::process::id());
            let f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|e| format!("{path}: {e}"))?;
            Some(Mutex::new(std::io::BufWriter::with_capacity(1 << 16, f)))
        }
        None => None,
    };
    let agent = Agent {
        coord,
        rate,
        segments: segments(&events),
        next_segment: AtomicU64::new(0),
        out: Out(Mutex::new(std::io::BufWriter::with_capacity(1 << 20, std::io::stdout()))),
        emit,
        cancelled: Mutex::new(Default::default()),
        closed: AtomicBool::new(false),
        sessions: AtomicU64::new(0),
        turn: Mutex::new(()),
    };
    // stdin is read here; each prompt streams on a thread of this scope, which joins them once
    // stdin closes (the host or daemon went away), and they stop at once then (`closed`).
    std::thread::scope(|s| {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if line.trim().is_empty() {
                continue;
            }
            let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
            agent.handle(s, msg);
        }
        agent.closed.store(true, Ordering::Relaxed);
    });
    agent.flush_emit();
    if let Ok(mut w) = agent.out.0.lock() {
        let _ = w.flush();
    }
    Ok(())
}

impl Agent {
    fn handle<'s, 'e: 's>(&'e self, s: &'s std::thread::Scope<'s, 'e>, msg: Value) {
        let Some(method) = msg.get("method").and_then(Value::as_str) else { return };
        let id = msg.get("id").cloned();
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        let reply = |result: Value| {
            if let Some(id) = &id {
                self.out.send(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
            }
        };
        match method {
            "initialize" => reply(json!({
                "protocolVersion": 1,
                "agentInfo": {"name": "coord-sim", "version": env!("CARGO_PKG_VERSION")},
                "agentCapabilities": {"loadSession": true, "sessionCapabilities": {"fork": {}}},
                "authMethods": [],
            })),
            "session/new" | "session/fork" => {
                let n = self.sessions.fetch_add(1, Ordering::Relaxed) + 1;
                reply(
                    json!({"sessionId": format!("coord-sim-{}-{}-{n}", self.coord, std::process::id()),
                    "modes": {"currentModeId": "normal", "availableModes": [{"id": "normal", "name": "Normal"}]}}),
                )
            }
            "session/load" => reply(Value::Null),
            "session/cancel" => {
                if let (Some(sid), Ok(mut c)) =
                    (params.get("sessionId").and_then(Value::as_str), self.cancelled.lock())
                {
                    c.insert(sid.to_owned());
                }
            }
            "session/prompt" => {
                s.spawn(move || self.prompt(id, params));
            }
            m if m.starts_with("session/set_") => reply(json!({})),
            _ => {
                if let Some(id) = id {
                    self.out.send(&json!({"jsonrpc": "2.0", "id": id,
                        "error": {"code": -32601, "message": "no such method"}}));
                }
            }
        }
    }

    fn prompt(&self, id: Option<Value>, params: Value) {
        let sid = params.get("sessionId").and_then(Value::as_str).unwrap_or_default().to_owned();
        let text: String = params
            .get("prompt")
            .and_then(Value::as_array)
            .map(|blocks| {
                blocks.iter().filter_map(|b| b.get("text").and_then(Value::as_str)).collect()
            })
            .unwrap_or_default();
        let stop = match text.find(RUN_PREFIX) {
            Some(at) => {
                let t0 = text[at..]
                    .split_whitespace()
                    .find_map(|w| w.strip_prefix("t0="))
                    .and_then(|v| v.parse().ok())
                    .unwrap_or_else(now_us);
                let _turn = self.turn.lock();
                if let Ok(mut c) = self.cancelled.lock() {
                    c.remove(&sid);
                }
                let n = self.next_segment.fetch_add(1, Ordering::Relaxed) as usize;
                match self.segments.get(n) {
                    Some(seg) => self.stream(&sid, seg, t0),
                    None => "end_turn",
                }
            }
            None => {
                // Another coordinator's message: one short acknowledgement.
                let upd = json!({"sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "coord-sim: message received"}});
                self.out.send(&json!({"jsonrpc": "2.0", "method": "session/update",
                    "params": {"sessionId": sid, "update": upd}}));
                "end_turn"
            }
        };
        self.flush_emit();
        if let Some(id) = id {
            self.out.send(&json!({"jsonrpc": "2.0", "id": id, "result": {"stopReason": stop}}));
        }
    }

    /// Streams one segment on its schedule; "cancelled" when a session/cancel came.
    fn stream(&self, sid: &str, seg: &[SimEvent], t0: u64) -> &'static str {
        let mut tool_id = String::from("cs-tool-0");
        let mut batch: Vec<Value> = Vec::with_capacity(256);
        let mut emits: Vec<EmitRecord> = Vec::with_capacity(256);
        let mut i = 0;
        while let Some(first) = seg.get(i) {
            if self.closed.load(Ordering::Relaxed)
                || self.cancelled.lock().map(|c| c.contains(sid)).unwrap_or(false)
            {
                return "cancelled";
            }
            let due = t0 + (first.at_ms as f64 * 1000.0 / self.rate) as u64;
            let now = now_us();
            if due > now {
                std::thread::sleep(Duration::from_micros((due - now).min(50_000)));
                continue;
            }
            // Everything due by now goes in one write.
            while let Some(e) = seg.get(i) {
                if batch.len() >= 512 {
                    break;
                }
                let due = t0 + (e.at_ms as f64 * 1000.0 / self.rate) as u64;
                if due > now_us() {
                    break;
                }
                self.emit_event(sid, e, due, &mut tool_id, &mut batch, &mut emits);
                i += 1;
            }
            self.out.send_all(&batch);
            batch.clear();
            self.log(&mut emits);
        }
        "end_turn"
    }

    fn emit_event(
        &self,
        sid: &str,
        e: &SimEvent,
        due: u64,
        tool_id: &mut String,
        batch: &mut Vec<Value>,
        emits: &mut Vec<EmitRecord>,
    ) {
        let seed = (self.coord as u64) << 40 ^ e.seq;
        let (update, count, subagent) = match &e.op {
            Op::Event { kind } => match update_for(kind) {
                Some(u) => (u, 1, false),
                None => return,
            },
            Op::Subagent { events } => {
                ("agent_message_chunk", (*events).clamp(1, SUBAGENT_CAP), true)
            }
            Op::Compaction | Op::Attachment => ("agent_message_chunk", 1, false),
            Op::UserTurn | Op::SendTo { .. } => return,
        };
        let kind = match &e.op {
            Op::Event { kind } => kind.clone(),
            Op::Subagent { .. } => "subagent".into(),
            Op::Compaction => "compaction".into(),
            Op::Attachment => "attachment".into(),
            _ => String::new(),
        };
        let bytes = if subagent { (e.bytes / count as u64).max(200) } else { e.bytes };
        for k in 0..count {
            let emit_us = now_us();
            let tagged = tag(self.coord, e.seq, k, emit_us);
            if update == "tool_call" {
                *tool_id = format!("cs-tool-{}-{}", self.coord, e.seq);
            }
            let upd = update_json(update, &tagged, bytes, seed ^ k as u64, tool_id);
            let mut params = json!({"sessionId": sid, "update": upd});
            if subagent {
                params["_meta"] = json!({"acpmux": {"subagent": format!("cs-sub-{}", e.seq)}});
            }
            batch.push(json!({"jsonrpc": "2.0", "method": "session/update", "params": params}));
            emits.push(EmitRecord {
                c: self.coord,
                seq: e.seq,
                k,
                kind: kind.clone(),
                update: update.into(),
                bytes,
                due_us: due,
                emit_us,
            });
        }
    }

    fn log(&self, emits: &mut Vec<EmitRecord>) {
        if let Some(w) = &self.emit
            && let Ok(mut w) = w.lock()
        {
            for r in emits.iter() {
                let _ = serde_json::to_writer(&mut *w, r);
                let _ = w.write_all(b"\n");
            }
        }
        emits.clear();
    }

    fn flush_emit(&self) {
        if let Some(w) = &self.emit
            && let Ok(mut w) = w.lock()
        {
            let _ = w.flush();
        }
    }
}

#[cfg(test)]
#[path = "agent_tests.rs"]
mod tests;
