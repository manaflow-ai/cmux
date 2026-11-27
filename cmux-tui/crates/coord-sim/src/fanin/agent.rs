//! `coord-sim fanin agent`: the stand-in ACP agent the host daemons start for each session (until
//! the agent helper's `coord-sim agent` replays real-shaped scripts; this one only needs to be
//! light, since 2,000 of them run on one machine, and to stamp its times).
//!
//! - Its session's index comes from its cwd (`.../cwd/s00042` -> 42): the driver makes one folder
//!   per session.
//! - Churn: once `FANIN_DIR/ctl` holds a period in ms, every session emits one
//!   `agent_message_chunk` per period, text `fanin s=<idx> k=<seq> t=<emit unix us>`, and appends
//!   `<seq> <emit us>` to `FANIN_DIR/tx/s<idx>.tx` (what was sent, for lost-event counts). `ctl`
//!   empty or `0` pauses; `exit` (or the folder gone) ends the agent. The first tick of each
//!   session is offset by its index so N sessions do not tick together.
//! - A prompt is answered at once: a chunk `fanin-rx s=<idx> r=<round> t=<receipt us>` (the
//!   fan-out sample: the driver sent `fanout r=<round>`), then `end_turn`.
//! - stdin closed: the agent exits.

use serde_json::{Value, json};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::rpc::now_us;

type Out = Arc<Mutex<std::io::Stdout>>;

fn send(out: &Out, v: &Value) -> bool {
    let mut line = v.to_string();
    line.push('\n');
    let mut o = out.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    o.write_all(line.as_bytes()).is_ok() && o.flush().is_ok()
}

fn chunk(sid: &str, text: String) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
}

/// The session index a cwd names (`s00042` -> 42).
fn index_of(cwd: Option<&str>) -> u64 {
    cwd.and_then(|c| c.rsplit('/').find(|p| !p.is_empty()))
        .and_then(|p| p.strip_prefix('s'))
        .and_then(|n| n.parse().ok())
        .unwrap_or(0)
}

/// What `ctl` says: `Some(period_ms)` (0 paused), `None` to exit.
fn control(dir: &std::path::Path) -> Option<u64> {
    match std::fs::read_to_string(dir.join("ctl")) {
        Ok(t) if t.trim() == "exit" => None,
        Ok(t) => Some(t.trim().parse().unwrap_or(0)),
        Err(_) if !dir.exists() => None,
        Err(_) => Some(0),
    }
}

/// Sleeps `ms` in short steps; false once `stop` is set (stdin closed).
fn nap(ms: u64, stop: &AtomicBool) -> bool {
    let until = std::time::Instant::now() + Duration::from_millis(ms);
    while std::time::Instant::now() < until {
        if stop.load(Ordering::Relaxed) {
            return false;
        }
        std::thread::sleep(Duration::from_millis(ms.min(100)));
    }
    !stop.load(Ordering::Relaxed)
}

fn churn(out: Out, dir: PathBuf, sid: String, idx: u64, stop: &AtomicBool) {
    let tx_path = dir.join("tx").join(format!("s{idx:05}.tx"));
    let mut tx = std::fs::OpenOptions::new().create(true).append(true).open(&tx_path).ok();
    // The seq goes on from what an earlier run of this session logged (a load after a restart).
    let mut seq = std::fs::read_to_string(&tx_path).map(|t| t.lines().count() as u64).unwrap_or(0);
    // Spread the first tick over the period by the golden ratio of the index.
    let mut first = true;
    loop {
        let Some(period) = control(&dir) else { return };
        if period == 0 {
            if !nap(200, stop) {
                return;
            }
            first = true;
            continue;
        }
        if first {
            let frac = (idx as f64 * 0.618_033_988_75).fract();
            if !nap((period as f64 * frac) as u64, stop) {
                return;
            }
            first = false;
        }
        seq += 1;
        let t = now_us();
        if !send(&out, &chunk(&sid, format!("fanin s={idx} k={seq} t={t}"))) {
            return;
        }
        if let Some(f) = tx.as_mut() {
            let _ = writeln!(f, "{seq} {t}");
        }
        if !nap(period, stop) {
            return;
        }
    }
}

pub fn run() -> Result<(), String> {
    let dir = PathBuf::from(std::env::var("FANIN_DIR").map_err(|_| "FANIN_DIR is not set")?);
    let out: Out = Arc::new(Mutex::new(std::io::stdout()));
    let stop = AtomicBool::new(false);
    // Each session's churn is a thread of this scope; stdin closing stops them all.
    std::thread::scope(|s| {
        serve(s, &dir, &out, &stop);
        stop.store(true, Ordering::Relaxed);
    });
    Ok(())
}

fn serve<'s>(s: &'s std::thread::Scope<'s, '_>, dir: &'s Path, out: &Out, stop: &'s AtomicBool) {
    let mut sessions: Vec<(String, u64)> = Vec::new();
    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(method) = msg.get("method").and_then(Value::as_str) else { continue };
        let id = msg.get("id").cloned();
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        let reply = |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result});
        let answer = match method {
            "initialize" => reply(json!({
                "protocolVersion": 1,
                "agentInfo": {"name": "coord-sim-fanin", "version": "0"},
                "agentCapabilities": {"loadSession": true,
                    "_meta": {"acpmux": {"asksBeforeTools": true}}},
                "authMethods": [],
            })),
            "session/new" | "session/load" => {
                let idx = index_of(params.get("cwd").and_then(Value::as_str));
                let sid = match params.get("sessionId").and_then(Value::as_str) {
                    Some(s) => s.to_owned(),
                    None => format!("fanin-s{idx:05}-{}", std::process::id()),
                };
                if !sessions.iter().any(|(s, _)| *s == sid) {
                    sessions.push((sid.clone(), idx));
                    let (o, d, sid2) = (out.clone(), dir.to_path_buf(), sid.clone());
                    s.spawn(move || churn(o, d, sid2, idx, stop));
                }
                if method == "session/new" {
                    reply(json!({"sessionId": sid}))
                } else {
                    reply(Value::Null)
                }
            }
            "session/prompt" => {
                let t = now_us();
                let sid = params.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
                let idx = sessions.iter().find(|(s, _)| *s == sid).map_or(0, |(_, i)| *i);
                let text = params.get("prompt").map(Value::to_string).unwrap_or_default();
                let round = text
                    .split("fanout r=")
                    .nth(1)
                    .and_then(|r| r.split(|c: char| !c.is_ascii_digit()).next())
                    .and_then(|r| r.parse::<u64>().ok())
                    .unwrap_or(0);
                send(out, &chunk(&sid, format!("fanin-rx s={idx} r={round} t={t}")));
                reply(json!({"stopReason": "end_turn"}))
            }
            "session/set_mode" | "session/set_model" | "session/set_config_option" => {
                reply(json!({}))
            }
            _ if id.is_some() => json!({"jsonrpc": "2.0", "id": id,
                "error": {"code": -32601, "message": "no such method"}}),
            _ => continue,
        };
        if !send(out, &answer) {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn index_from_cwd() {
        assert_eq!(index_of(Some("/run/cwd/s00042")), 42);
        assert_eq!(index_of(Some("/run/cwd/s00042/")), 42);
        assert_eq!(index_of(Some("/elsewhere")), 0);
        assert_eq!(index_of(None), 0);
    }
}
