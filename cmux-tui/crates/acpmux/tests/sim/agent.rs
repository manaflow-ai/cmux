//! The simulation's agent: an ACP harness that runs in process on the daemon's own runtime
//! (`acpmux::sim_agent`), so a daemon crash ends it as it ends a real child.
//!
//! Every turn replays `worked_turn.json`: the `session/update` stream of the worked turn the
//! mock acpmux daemon serves the web pane (`webviews/src/agent-session/acpmux/mockFixture.ts`
//! `workedTurn`, exported with the command in `worked_turn.json`'s `source`), at a speed the seed
//! picks, then one `reply: <text>` chunk and `end_turn`. A prompt that arrives while a turn runs
//! is a steer, as Claude Code takes it: answered `steered` at once. `session/cancel` ends the
//! running turn `cancelled`. It records every `session/prompt` it is given, which the invariants
//! read: what the agent was given is what was applied.

use crate::rng::Rng;
use acpmux::config::HarnessProfile;
use acpmux::sim_agent::Pipes;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

/// One `session/prompt` the agent was given.
#[derive(Clone, Debug)]
pub struct Given {
    /// The daemon incarnation that sent it.
    pub incarnation: u64,
    pub prompt_id: Option<String>,
    pub text: String,
    /// It came while a turn ran (a steer).
    pub steer: bool,
}

struct Step {
    at: Duration,
    update: Value,
}

/// What every agent of a run shares: the fixture, what they were given, and the session ids
/// they made (a harness keeps its sessions on disk across restarts).
pub struct Agents {
    steps: Vec<Step>,
    pub given: Mutex<Vec<Given>>,
    next_session: AtomicU64,
    rng: Mutex<Rng>,
}

impl Agents {
    pub fn new(rng: Rng) -> Arc<Self> {
        let fixture: Value = serde_json::from_str(include_str!("worked_turn.json")).unwrap();
        let steps = fixture["steps"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| Step {
                at: Duration::from_millis(s["atMs"].as_u64().unwrap()),
                update: s["update"].clone(),
            })
            .collect();
        Arc::new(Self {
            steps,
            given: Mutex::new(Vec::new()),
            next_session: AtomicU64::new(1),
            rng: Mutex::new(rng),
        })
    }

    /// The `acpmux::sim_agent` factory of daemon incarnation `incarnation`.
    pub fn factory(
        self: &Arc<Self>,
        incarnation: u64,
    ) -> impl Fn(&str, &HarnessProfile) -> Pipes + 'static {
        let agents = self.clone();
        move |_name: &str, _profile: &HarnessProfile| {
            let (daemon_in, agent_in) = tokio::io::duplex(1 << 16);
            let (agent_out, daemon_out) = tokio::io::duplex(1 << 16);
            let (_agent_err, daemon_err) = tokio::io::duplex(64);
            let alive = Arc::new(AtomicBool::new(true));
            let speed = {
                let mut rng = agents.rng.lock().unwrap();
                // 1 to 20 percent of the recorded turn's 86 s.
                rng.range(1, 20)
            };
            tokio::spawn(run(
                agents.clone(),
                incarnation,
                speed,
                agent_in,
                agent_out,
                alive.clone(),
            ));
            Pipes {
                stdin: Box::new(daemon_in),
                stdout: Box::new(daemon_out),
                stderr: Box::new(daemon_err),
                alive,
            }
        }
    }
}

fn text_of(params: &Value) -> String {
    params["prompt"]
        .as_array()
        .map(|b| {
            b.iter()
                .filter(|b| !acpmux::prompt_context::is_context(b))
                .filter_map(|b| b["text"].as_str())
                .collect()
        })
        .unwrap_or_default()
}

fn prompt_id_of(params: &Value) -> Option<String> {
    let meta = &params["_meta"];
    meta["promptId"].as_str().or(meta["acpmux"]["promptId"].as_str()).map(str::to_owned)
}

/// One agent process: reads its stdin until the daemon closes it or ends the agent.
async fn run(
    agents: Arc<Agents>,
    incarnation: u64,
    speed_percent: u64,
    stdin: tokio::io::DuplexStream,
    stdout: tokio::io::DuplexStream,
    alive: Arc<AtomicBool>,
) {
    let (out, mut lines_out) = mpsc::unbounded_channel::<Value>();
    let writer_alive = alive.clone();
    let writer = tokio::spawn(async move {
        let mut stdout = stdout;
        while let Some(v) = lines_out.recv().await {
            if !writer_alive.load(Ordering::SeqCst) {
                break;
            }
            let mut line = v.to_string();
            line.push('\n');
            if stdout.write_all(line.as_bytes()).await.is_err() {
                break;
            }
        }
    });
    // Sessions with a running turn, and the turns a cancel ended.
    let running: Arc<Mutex<HashMap<String, Value>>> = Default::default();
    let cancelled: Arc<Mutex<HashSet<String>>> = Default::default();
    let mut lines = BufReader::new(stdin).lines();
    let mut check = tokio::time::interval(Duration::from_millis(50));
    loop {
        let line = tokio::select! {
            line = lines.next_line() => match line { Ok(Some(l)) => l, _ => break },
            _ = check.tick() => {
                if alive.load(Ordering::SeqCst) { continue } else { break }
            }
        };
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        let (id, method, params) =
            (msg.get("id").cloned(), msg["method"].as_str(), msg["params"].clone());
        let Some(method) = method else { continue }; // an answer to a request it never sent
        let reply = |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result});
        match method {
            "initialize" => {
                let _ = out.send(reply(json!({
                    "protocolVersion": 1,
                    "_meta": {"steering": {"supported": true}},
                    "agentInfo": {"name": "sim", "version": "0"},
                    "agentCapabilities": {"loadSession": true, "sessionCapabilities": {}},
                    "authMethods": [],
                })));
            }
            "session/new" => {
                let sid = format!("sim-{}", agents.next_session.fetch_add(1, Ordering::SeqCst));
                let _ = out.send(reply(json!({"sessionId": sid})));
            }
            "session/load" => {
                let _ = out.send(reply(Value::Null));
            }
            "session/prompt" => {
                let sid = params["sessionId"].as_str().unwrap_or_default().to_owned();
                let text = text_of(&params);
                let steer = running.lock().unwrap().contains_key(&sid);
                agents.given.lock().unwrap().push(Given {
                    incarnation,
                    prompt_id: prompt_id_of(&params),
                    text: text.clone(),
                    steer,
                });
                if steer {
                    let _ = out.send(update(&sid, chunk(&format!("steer: {text}"))));
                    let _ = out.send(reply(json!({"stopReason": "steered"})));
                    continue;
                }
                running.lock().unwrap().insert(sid.clone(), id.clone().unwrap_or(Value::Null));
                cancelled.lock().unwrap().remove(&sid);
                let steps: Vec<(Duration, Value)> = agents
                    .steps
                    .iter()
                    .map(|s| (s.at * speed_percent as u32 / 100, tag_tools(&s.update, &text)))
                    .collect();
                let (out, running, cancelled) = (out.clone(), running.clone(), cancelled.clone());
                tokio::spawn(async move {
                    let mut at = Duration::ZERO;
                    let mut stop = "end_turn";
                    for (when, upd) in steps {
                        tokio::time::sleep(when.saturating_sub(at)).await;
                        at = when;
                        if cancelled.lock().unwrap().contains(&sid) {
                            stop = "cancelled";
                            break;
                        }
                        let _ = out.send(update(&sid, upd));
                    }
                    if stop == "end_turn" {
                        let _ = out.send(update(&sid, chunk(&format!("reply: {text}"))));
                    }
                    let rid = running.lock().unwrap().remove(&sid);
                    let _ = out
                        .send(json!({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": stop}}));
                });
            }
            "session/cancel" => {
                if let Some(sid) = params["sessionId"].as_str() {
                    cancelled.lock().unwrap().insert(sid.to_owned());
                }
            }
            _ if id.is_some() => {
                // Setters the daemon may send (mode, model): taken as they are.
                if method.starts_with("session/set") {
                    let _ = out.send(reply(json!({})));
                } else {
                    let _ = out.send(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "no such method"}}));
                }
            }
            _ => {}
        }
    }
    alive.store(false, Ordering::SeqCst);
    drop(out);
    let _ = writer.await;
}

fn chunk(text: &str) -> Value {
    json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
}

fn update(sid: &str, upd: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": upd}})
}

/// A recorded tool call's id, made the turn's own (the fixture has one turn's ids).
fn tag_tools(update: &Value, turn: &str) -> Value {
    let mut u = update.clone();
    if let Some(id) = u["toolCallId"].as_str() {
        u["toolCallId"] = json!(format!("{id}-{turn}"));
    }
    u
}
