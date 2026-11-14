//! The time from a daemon's start to `_acpmux/prompt_accepted` for a prompt to one chat, for a
//! god chat, a small chat and one of 525 (cmuxterm-hq `docs/design/acpmux-per-chat-startup.md`).
//!
//! Leo, 2026-11-12: "it took well over 90 seconds to start anything... everything waits on
//! everything" and "even if a chat is long, there should be no percievable difference".
//!
//! The home holds a god chat (`ACPMUX_BENCH_GOD_MB`, default 1024 MB of log), a small chat of
//! [`SMALL_TURNS`] turns and `ACPMUX_BENCH_CHATS` (default 525) more small chats. Every turn is a
//! real turn the daemon logged (a prompt of [`PROMPT_BYTES`], tool calls, the reply), recorded once
//! from the stand-in agent and written again under fresh ids, plus [`TOOL_OUTPUT_BYTES`] of tool
//! output and, every third turn, an agent's message to the chat's inbox. The god chat's agent
//! host outlives each stop, as a busy coordinator's does, so its start adopts it.
//!
//! Each round stops the daemon, starts it, and sends one prompt to one of the three chats; its
//! time is from the spawn to the acceptance. The god's p95 over the small's is the bar (1.2).
//! Run by hand, as `update_cost_bench`:
//! `cargo test -p acpmux --release --test startup_accept_bench -- --ignored --nocapture`.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;

const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_BENCH_GOD_MB",
    "ACPMUX_BENCH_CHATS",
    "ACPMUX_BENCH_ROUNDS",
]);

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const SMALL_TURNS: usize = 20;
const PROMPT_BYTES: usize = 2_000;
const TOOL_OUTPUT_BYTES: usize = 16 * 1024;
/// The store's segment size (`config/store_config.rs`).
const SEGMENT_BYTES: usize = 8 << 20;

fn env_usize(key: &str, default: usize) -> usize {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    socket: PathBuf,
}

impl Daemon {
    fn new(home: PathBuf) -> Self {
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        let fake = json!({"argv": ["python3", FAKE], "env": {"FAKE_TOOL_CALLS": "3"}});
        let config = json!({"harnesses": {"fake": fake}, "defaultHarness": "fake",
                            "permissionPolicy": "approve-all"});
        std::fs::write(home.join("config.json"), config.to_string()).unwrap();
        let socket = home.join("s.sock");
        Self { child: None, home, socket }
    }

    /// Starts the daemon; returns the instant it was spawned.
    fn start(&mut self) -> Instant {
        assert!(self.child.is_none());
        let mut command = std::process::Command::new(daemon_env::bin());
        daemon_env::apply(&mut command, &self.home, daemon_env::Agents::StandIn, &[]);
        command
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        let spawned = Instant::now();
        let mut child = command.spawn().expect("start daemon");
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut ready = String::new();
        while stdout.read_line(&mut ready).unwrap() > 0 && !ready.contains("\"ready\":true") {
            ready.clear();
        }
        assert!(ready.contains("\"ready\":true"), "daemon not ready");
        if let Some(bound) = serde_json::from_str::<Value>(&ready)
            .ok()
            .and_then(|v| v["socket"].as_str().map(PathBuf::from))
        {
            self.socket = bound;
        }
        self.child = Some(child);
        spawned
    }

    fn sigterm(&mut self) {
        let mut child = self.child.take().unwrap();
        // SAFETY: signalling this test's own child process.
        assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
        let status = child.wait().unwrap();
        assert!(status.success(), "daemon exited badly on SIGTERM: {status}");
    }

    async fn rpc(&self) -> Rpc {
        Rpc::connect(&self.socket).await
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // End every host this bench started.
        if let Ok(dir) = std::fs::read_dir(self.home.join("hosts")) {
            for path in dir.filter_map(|e| e.ok().map(|e| e.path())) {
                let Ok(r) =
                    serde_json::from_slice::<Value>(&std::fs::read(&path).unwrap_or_default())
                else {
                    continue;
                };
                for pid in [r["harness_pid"].as_i64(), r["host_pid"].as_i64()].into_iter().flatten()
                {
                    // SAFETY: process groups this bench's daemon created.
                    unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        self.next
    }

    async fn next_line(&mut self) -> Value {
        let line = tokio::time::timeout(Duration::from_secs(600), self.lines.next_line())
            .await
            .expect("daemon answered in time")
            .unwrap()
            .expect("daemon closed the socket");
        serde_json::from_str(&line).unwrap()
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        loop {
            let v = self.next_line().await;
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }

    /// Sends a prompt; returns when it is accepted, then waits for its turn to end.
    async fn prompt(&mut self, session: &str, text: &str) -> Instant {
        let params = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let id = self.send("session/prompt", params).await;
        let mut accepted = None;
        loop {
            let v = self.next_line().await;
            if v["method"] == "_acpmux/prompt_accepted" && v["params"]["sessionId"] == session {
                accepted.get_or_insert_with(Instant::now);
            }
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "session/prompt failed: {v}");
                return accepted.expect("the prompt's turn ended with no prompt_accepted");
            }
        }
    }
}

fn records(home: &Path, session: &str) -> Vec<Value> {
    let dir = home.join("sessions").join(session).join("events");
    let mut files: Vec<PathBuf> =
        std::fs::read_dir(&dir).unwrap().filter_map(|e| e.ok().map(|e| e.path())).collect();
    files.retain(|f| f.extension().and_then(|e| e.to_str()) == Some("ndjson"));
    files.sort();
    files
        .iter()
        .flat_map(|f| {
            std::fs::read_to_string(f).unwrap().lines().map(str::to_owned).collect::<Vec<_>>()
        })
        .filter_map(|l| serde_json::from_str(&l).ok())
        .collect()
}

/// One turn as the daemon logged it: the records after the first turn's `turn_result` through
/// the second's, as serialized lines, with the ids each turn must get fresh.
struct Turn {
    lines: Vec<String>,
    ids: Vec<String>,
}

impl Turn {
    fn from_log(log: &[Value]) -> Self {
        let ends: Vec<usize> = log
            .iter()
            .enumerate()
            .filter(|(_, e)| e["kind"] == "turn_result")
            .map(|(i, _)| i)
            .collect();
        assert!(ends.len() >= 2, "the template chat ran fewer than two turns: {log:#?}");
        let mut unit: Vec<Value> = log[ends[0] + 1..=ends[1]].to_vec();
        // A finished tool call's output, as a working agent's turn has.
        if let Some(call) = unit.iter().position(|e| e["kind"] == "tool_call") {
            let mut output = unit[call].clone();
            let update = &mut output["msg"]["params"]["update"];
            update["sessionUpdate"] = json!("tool_call_update");
            update["content"] = json!([{"type": "content", "content": {"type": "text",
                "text": "o".repeat(TOOL_OUTPUT_BYTES)}}]);
            output["kind"] = json!("tool_call_update");
            unit.insert(call + 1, output);
        }
        let mut ids = std::collections::BTreeSet::new();
        for e in &unit {
            collect_ids(&e["msg"], &mut ids);
        }
        let lines = unit.iter().map(Value::to_string).collect();
        Self { lines, ids: ids.into_iter().filter(|id| id.len() >= 4).collect() }
    }

    /// Turn `n`'s records, with fresh ids, from `seq` on, at `at`.
    fn write(&self, n: usize, seq: &mut u64, at: u64, out: &mut impl FnMut(String)) {
        for line in &self.lines {
            let mut line = line.clone();
            for id in &self.ids {
                line = line.replace(&format!("\"{id}\""), &format!("\"{id}~{n}\""));
            }
            let mut e: Value = serde_json::from_str(&line).unwrap();
            *seq += 1;
            e["seq"] = json!(*seq);
            e["at"] = json!(at);
            out(e.to_string());
        }
        if n.is_multiple_of(3) {
            *seq += 1;
            let text = format!("agent report {n}: {}", "r".repeat(600));
            let inbox = json!({"seq": *seq, "at": at, "dir": "mux", "kind": "inbox", "msg": {
                "promptId": format!("inbox-{n}"), "threadId": "thread-lane", "from": "lane",
                "class": "result", "kind": "result", "client": "acpmux", "text": text,
                "prompt": [{"type": "text", "text": text}],
                "sender": {"kind": "agent", "label": "lane"}}});
            out(inbox.to_string());
        }
    }
}

fn collect_ids(v: &Value, ids: &mut std::collections::BTreeSet<String>) {
    match v {
        Value::Object(map) => {
            for (k, v) in map {
                if matches!(k.as_str(), "promptId" | "turnId" | "messageId" | "toolCallId")
                    && let Some(id) = v.as_str()
                {
                    ids.insert(id.to_owned());
                }
                collect_ids(v, ids);
            }
        }
        Value::Array(items) => items.iter().for_each(|v| collect_ids(v, ids)),
        _ => {}
    }
}

/// Writes chat `id` as a copy of `template`'s folder with `turns` turns (or `bytes` of log).
fn write_chat(home: &Path, template: &str, id: &str, turn: &Turn, turns: usize, bytes: usize) {
    let from = home.join("sessions").join(template);
    let dir = home.join("sessions").join(id);
    let events = dir.join("events");
    std::fs::create_dir_all(&events).unwrap();
    let (mut seq, mut written, mut segment, mut seg_bytes) = (0u64, 0usize, 1usize, 0usize);
    let mut file = std::io::BufWriter::new(
        std::fs::File::create(events.join(format!("{segment:06}.ndjson"))).unwrap(),
    );
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    let mut n = 0;
    while n < turns || written < bytes {
        // A minute a turn, ending now: months of history for a god chat.
        let at = now.saturating_sub(60_000 * (turns.max(1) - n.min(turns.max(1))) as u64);
        turn.write(n, &mut seq, at, &mut |line| {
            if seg_bytes >= SEGMENT_BYTES {
                file.flush().unwrap();
                segment += 1;
                seg_bytes = 0;
                file = std::io::BufWriter::new(
                    std::fs::File::create(events.join(format!("{segment:06}.ndjson"))).unwrap(),
                );
            }
            seg_bytes += line.len() + 1;
            written += line.len() + 1;
            writeln!(file, "{line}").unwrap();
        });
        n += 1;
    }
    file.flush().unwrap();
    let mut meta: Value =
        serde_json::from_slice(&std::fs::read(from.join("session.json")).unwrap()).unwrap();
    meta["id"] = json!(id);
    meta["name"] = json!(id);
    meta["lastSeq"] = json!(seq);
    meta["eventCount"] = json!(seq);
    meta["updatedAt"] = json!(now);
    if let Some(m) = meta.as_object_mut() {
        // No agent session of its own: a prompt starts a fresh agent.
        m.remove("agentSessionId");
        m.remove("transcriptSeq");
    }
    std::fs::write(dir.join("session.json"), meta.to_string()).unwrap();
}

fn percentile(samples: &mut [f64], p: f64) -> f64 {
    samples.sort_by(f64::total_cmp);
    let rank = ((p / 100.0) * (samples.len() - 1) as f64).round() as usize;
    samples[rank]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a bench, run by hand: cargo test -p acpmux --release --test startup_accept_bench -- --ignored --nocapture"]
async fn a_prompt_is_accepted_as_soon_after_a_start_in_a_god_chat_as_in_a_small_one() {
    let god_mb = env_usize("ACPMUX_BENCH_GOD_MB", 1024);
    let chats = env_usize("ACPMUX_BENCH_CHATS", 525);
    let rounds = env_usize("ACPMUX_BENCH_ROUNDS", 7);
    let home = std::env::temp_dir().join(format!("asab-{}", std::process::id()));
    let mut daemon = Daemon::new(home.clone());

    // One real chat, three real turns: the template.
    daemon.start();
    let template = {
        let mut rpc = daemon.rpc().await;
        let created = rpc.call("session/new", json!({"cwd": home, "mcpServers": []})).await;
        let id = created["sessionId"].as_str().unwrap().to_owned();
        for k in 0..3 {
            rpc.prompt(&id, &format!("step {k}: {}", "p".repeat(PROMPT_BYTES))).await;
        }
        id
    };
    daemon.sigterm();
    let turn = Turn::from_log(&records(&home, &template));

    let built = Instant::now();
    write_chat(&home, &template, "god", &turn, 0, god_mb << 20);
    write_chat(&home, &template, "small", &turn, SMALL_TURNS, 0);
    for i in 0..chats {
        write_chat(&home, &template, &format!("chat-{i:04}"), &turn, SMALL_TURNS, 0);
    }
    eprintln!("fixture: {god_mb} MB god, {chats} chats, in {:?}", built.elapsed());

    // A first start reads every log once (the kind index is built), and the god chat gets an
    // agent host that outlives every later stop.
    daemon.start();
    {
        let mut rpc = daemon.rpc().await;
        rpc.prompt("god", "warm").await;
        rpc.prompt("small", "warm").await;
    }
    daemon.sigterm();

    // One of the many small chats, from the middle of the list.
    let middle = format!("chat-{:04}", chats / 2);
    let targets = ["god", "small", middle.as_str()];
    let mut times: Vec<Vec<f64>> = vec![Vec::new(); targets.len()];
    for round in 0..rounds {
        for (t, target) in targets.iter().enumerate() {
            let spawned = daemon.start();
            let mut rpc = daemon.rpc().await;
            let accepted = rpc.prompt(target, &format!("round {round}")).await;
            times[t].push(accepted.duration_since(spawned).as_secs_f64() * 1000.0);
            drop(rpc);
            daemon.sigterm();
        }
    }
    let mut p95 = Vec::new();
    for (t, target) in targets.iter().enumerate() {
        let (p50, p) = (percentile(&mut times[t], 50.0), percentile(&mut times[t], 95.0));
        eprintln!(
            "start to prompt_accepted, {target}: p50 {p50:.0} ms, p95 {p:.0} ms ({rounds} rounds)"
        );
        p95.push(p);
    }
    let ratio = p95[0] / p95[1];
    eprintln!(
        "god p95 / small p95: {ratio:.2} (bar 1.2); {chats} chats p95 {:.0} ms (bar 2000)",
        p95[2]
    );
    let _ = HERMETIC;
}
