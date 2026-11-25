//! Tail-first move bench: a chat of over 50 MB moved between two real headless
//! cmux-tui daemons, each with its own real acpmux, by the real `cmux link agent
//! move`, whole (today) and with `--history-later` (its last turns first, its
//! packed history after).
//!
//! Leo: "say you move an existing chat over there. How do we make that as fast
//! as possible ... with as little jank as possible", and "compressed session
//! history ... load it on demand ... just-in-time".
//!
//! Four moves, each of a fresh chat of `TAIL_FIRST_BENCH_MB` (default 55) MB of
//! log on the "Mac" daemon to the daemon shaped like a personal Cloud VM
//! (`journey_support`, as `offload_roundtrip_bench.rs`):
//!
//! - `whole` and `tail_first`: the chat settled, the machine idle.
//! - `whole_duress` and `tail_first_duress`: the chat mid-turn (a turn running
//!   until a cancel and a prompt queued behind it, moved with `--interrupt`)
//!   while every core runs a busy loop this bench started.
//!
//! "Live" is when the chat runs on the VM: the move's own `live_ms` (start to
//! commit) with `--history-later`, the command's wall time without it (the
//! chat is live only when the whole move ends). After each tail-first move the
//! VM's log holds every turn the Mac's did.
//!
//! Prints one line `TAIL_FIRST_BENCH {json}`; `TAIL_FIRST_BENCH_OUT` also writes
//! it there.
//!
//! Run: `cargo test --release -p cmux-tui --test it --
//! tail_first_move_bench:: --ignored --nocapture`.
//!
//! Linux only, like the journeys it reuses: a Cloud host is a Linux machine.
#![cfg(target_os = "linux")]

use crate::journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

/// The largest single prompt the bench sends to grow the chat log.
const FILLER_PROMPT_BYTES: usize = 256 * 1024;

/// Every record of `session` on `acpmux`, read in pages.
fn whole_log(acpmux: &mut Acpmux, session: &str) -> Vec<Value> {
    let mut all: Vec<Value> = Vec::new();
    loop {
        let after = all.last().and_then(|e| e["seq"].as_u64()).unwrap_or(0);
        let page = acpmux.call(
            "_acpmux/events",
            json!({"sessionId": session, "afterSeq": after, "limit": 5000}),
        );
        let events = page["events"].as_array().cloned().unwrap_or_default();
        if events.is_empty() {
            return all;
        }
        all.extend(events);
    }
}

/// What the person said in the chat, in order.
fn said(log: &[Value]) -> Vec<String> {
    log.iter()
        .filter(|e| e["kind"] == "user_message")
        .filter_map(|e| e["msg"]["text"].as_str().map(str::to_owned))
        .collect()
}

/// A chat on the Mac with `mb` MiB of finished turns; `mid_turn`: then a turn
/// running until a cancel and a prompt queued behind it.
fn chat(acpmux: &mut Acpmux, cwd: &Path, tag: &str, mb: usize, mid_turn: bool) -> String {
    let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    // The agent echoes each prompt: half the log is prompts, half echoes.
    let mut left = (mb << 20) / 2;
    let mut n = 0;
    while left > 0 {
        let size = left.min(FILLER_PROMPT_BYTES);
        let text = format!("{n:08} {}", "x".repeat(size.saturating_sub(9)));
        acpmux.call("session/prompt", prompt(&session, &text, &format!("{tag}-fill-{n}")));
        left -= size;
        n += 1;
    }
    acpmux.call("session/prompt", prompt(&session, "the last turn", &format!("{tag}-last")));
    if mid_turn {
        acpmux.send("session/prompt", prompt(&session, "until-cancel", &format!("{tag}-running")));
        wait_until(20, "the running turn", || {
            acpmux.summary(&session).filter(|s| s["turn"].is_object()).map(|_| ())
        });
        acpmux.send("session/prompt", prompt(&session, "queued", &format!("{tag}-queued")));
        wait_until(20, "the queued prompt", || {
            acpmux.summary(&session).filter(|s| s["queued"].as_u64() == Some(1)).map(|_| ())
        });
    }
    session
}

/// A busy loop on every core, ended when dropped.
struct Load(Vec<Child>);

impl Load {
    fn start() -> Self {
        let cores = std::thread::available_parallelism().map(usize::from).unwrap_or(4);
        let spin = || {
            Command::new("sh")
                .args(["-c", "while :; do :; done"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap()
        };
        Self((0..cores).map(|_| spin()).collect())
    }
}

impl Drop for Load {
    fn drop(&mut self) {
        for child in &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

struct Bench {
    root: PathBuf,
    mac: Machine,
    vm: Machine,
    mb: usize,
}

impl Bench {
    /// One move of a fresh chat: its row.
    fn run(&self, label: &str, tail_first: bool, duress: bool) -> Value {
        let mut mac_acpmux = self.mac.acpmux();
        let mut vm_acpmux = self.vm.acpmux();
        let name = format!("app-{label}");
        let repo = self.mac.home().join(&name);
        fs::create_dir_all(&repo).unwrap();
        let synced = self.vm.home().join("work").join(&name);
        let session = chat(&mut mac_acpmux, &repo, label, self.mb, duress);
        let source = whole_log(&mut mac_acpmux, &session);
        let log_bytes: usize = source.iter().map(|e| e.to_string().len() + 1).sum();
        let surface = bound_agent_tab(&self.mac, &session);
        let mac_state = self.mac.dir.join("state");
        // The chat's folder on the VM: the move takes the chat alone (no `--sync`).
        fs::create_dir_all(&synced).unwrap();

        let mut command = Command::new(bin());
        command
            .env("CMUX_TUI_STATE_DIR", &mac_state)
            .env_remove("ACPMUX_MOVE_HISTORY_LATER")
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&self.mac.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&self.vm.socket)
            .arg("--cwd")
            .arg(&synced)
            .args(["--vm-kind", "owner", "--state-dir"])
            .arg(self.root.join(format!("pump-{label}")));
        if duress {
            command.arg("--interrupt");
        }
        if tail_first {
            command.args(["--history-later", "4"]);
        }
        let load = duress.then(Load::start);
        let started = Instant::now();
        let (ok, answer) = run_json(&mut command);
        let wall_ms = started.elapsed().as_millis();
        drop(load);
        assert!(ok && answer["ok"] == json!(true), "{label}: {answer}");
        assert!(answer.get("history_error").is_none(), "{label}: {answer}");
        let live_ms = if tail_first {
            answer["live_ms"].as_u64().unwrap_or_else(|| panic!("{label}: no live_ms: {answer}"))
                as u128
        } else {
            wall_ms
        };

        // The VM holds every turn the Mac's log held, in order.
        let moved = whole_log(&mut vm_acpmux, &session);
        let (before, after) = (said(&source), said(&moved));
        assert!(after.len() >= before.len(), "{label}: {} of {} turns", after.len(), before.len());
        assert_eq!(after[..before.len()], before[..], "{label}");
        let row = json!({
            "label": label,
            "tail_first": tail_first,
            "duress": duress,
            "log_bytes": log_bytes,
            "records": source.len(),
            "live_ms": live_ms,
            "wall_ms": wall_ms,
            "frozen_ms": answer["frozen_ms"],
            "bytes": answer["bytes"],
            "history_ms": answer["history_ms"],
            "history_bytes": answer["history_bytes"],
            "history_records": answer["history_records"],
            "phases": answer["phases"],
        });
        eprintln!("tail-first bench {row}");
        row
    }
}

#[test]
#[ignore = "bench: run with --release --ignored --nocapture (TAIL_FIRST_BENCH_MB)"]
fn tail_first_bench_moves_a_55_mb_chat_between_two_real_daemons() {
    let mb =
        std::env::var("TAIL_FIRST_BENCH_MB").ok().and_then(|v| v.parse().ok()).unwrap_or(55usize);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("tfb-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());
    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-tail-first-bench".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let bench = Bench { root: root.clone(), mac, vm, mb };
    let rows = vec![
        bench.run("whole", false, false),
        bench.run("tail_first", true, false),
        bench.run("whole_duress", false, true),
        bench.run("tail_first_duress", true, true),
    ];
    let report = json!({
        "profile": if cfg!(debug_assertions) { "dev" } else { "release" },
        "cores": std::thread::available_parallelism().map(usize::from).unwrap_or(0),
        "mb": mb,
        "rows": rows,
    });
    println!("TAIL_FIRST_BENCH {report}");
    if let Ok(path) = std::env::var("TAIL_FIRST_BENCH_OUT")
        && !path.is_empty()
    {
        fs::write(&path, format!("{report}\n")).unwrap();
    }
}
