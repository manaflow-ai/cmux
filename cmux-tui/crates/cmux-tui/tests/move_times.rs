//! RFD 0135 gate 3's times: a chat moved to a VM and back, `MOVE_TIMES_RUNS` times, by the real
//! `cmux link agent move` between two real headless cmux-tui daemons (the "Mac" and one shaped
//! like a personal Cloud VM, `journey_support`).
//!
//! Leo: "Ok well we can't be letting important rfds like that take breaks unless I put in fleet
//! wide pauses, esp when this is stuff that materially improves the app". The gate
//! (`scripts/cmux-next/rfd0135_gates.py move`) asks for a p95 under 10 s each way and read its
//! times from a `MOVE_TIMES` file nothing wrote; this test writes it.
//!
//! Each round is a fresh chat on the Mac with a finished turn and a turn running when the move
//! starts (`--interrupt`, as the app's Move does), moved to the VM, then the same chat moved back.
//! A time is the move command's wall time, start to answer. Each move is checked: the session
//! is the same, the finished turn is on the far side, and the near side closed it.
//! `MOVE_TIMES_LOAD=1` runs a busy loop on every core for the whole run (the duress number).
//!
//! Prints `MOVE_TIMES {"to_cloud_ms":[...],"back_ms":[...],...}`; `MOVE_TIMES_OUT` also writes
//! that JSON there, the file the gate reads as `MOVE_TIMES`.
//!
//! ```text
//! MOVE_TIMES_RUNS=20 MOVE_TIMES_OUT=/tmp/move-times.json \
//!   cargo test -p cmux-tui --test it -- --ignored --nocapture move_times::
//! ```
//!
//! What it does not time: the network between a Mac and a real VM (both daemons are on one
//! host) and `--sync` of the folder (the folder is already on the VM, as after Move to Cloud).
#![cfg(target_os = "linux")]

use crate::journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

const HISTORY: &str = "the turn before the move";

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

/// A chat in `cwd` with a finished turn and a turn running until a cancel.
fn running_chat(acpmux: &mut Acpmux, cwd: &Path, tag: &str) -> String {
    let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, HISTORY, &format!("{tag}-history")));
    acpmux.send("session/prompt", prompt(&session, "until-cancel", &format!("{tag}-running")));
    wait_until(20, "the running turn", || {
        acpmux.summary(&session).filter(|s| s["turn"].is_object()).map(|_| ())
    });
    session
}

/// One timed `cmux link agent move` of tab `surface` of `from` to `to`, in `cwd`.
fn timed_move(from: &Machine, to: &Machine, surface: u64, cwd: &Path, pump: &Path) -> (u64, Value) {
    let mut command = Command::new(bin());
    command
        .env("CMUX_TUI_STATE_DIR", from.dir.join("state"))
        .env_remove("ACPMUX_MOVE_HISTORY_LATER")
        .args(["link", "agent", "move", "--from-socket"])
        .arg(&from.socket)
        .args(["--surface", &surface.to_string(), "--to-socket"])
        .arg(&to.socket)
        .arg("--cwd")
        .arg(cwd)
        .args(["--vm-kind", "owner", "--interrupt", "--state-dir"])
        .arg(pump);
    let started = Instant::now();
    let (ok, answer) = run_json(&mut command);
    let ms = started.elapsed().as_millis() as u64;
    assert!(ok && answer["ok"] == json!(true), "move: {answer}");
    (ms, answer)
}

/// The chat is on `here` with its finished turn, and closed on `there`.
fn landed(here: &mut Acpmux, there: &mut Acpmux, session: &str, answer: &Value) {
    assert_eq!(answer["session_id"], json!(session), "{answer}");
    let events = wait_until(30, "the moved chat's history", || {
        let events = here.events(session);
        events
            .iter()
            .any(|e| e["kind"] == "user_message" && e["msg"]["text"] == HISTORY)
            .then_some(events)
    });
    assert!(!events.is_empty());
    let left = there.summary(session);
    assert!(left.as_ref().is_none_or(|s| s["status"] == "closed"), "still open: {left:?}");
}

fn p95(times: &[u64]) -> Option<u64> {
    let mut sorted = times.to_vec();
    sorted.sort_unstable();
    let rank = (sorted.len() * 95).div_ceil(100);
    rank.checked_sub(1).and_then(|i| sorted.get(i).copied())
}

#[test]
#[ignore = "gate: run with --ignored --nocapture (MOVE_TIMES_RUNS, MOVE_TIMES_LOAD, MOVE_TIMES_OUT)"]
fn move_times_round_trips_a_running_chat_to_a_vm_and_back() {
    let runs: usize =
        std::env::var("MOVE_TIMES_RUNS").ok().and_then(|v| v.parse().ok()).unwrap_or(5);
    let loaded = std::env::var("MOVE_TIMES_LOAD").is_ok_and(|v| v == "1");
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("mvt-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());
    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-move-times".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let mut mac_acpmux = mac.acpmux();
    let mut vm_acpmux = vm.acpmux();
    let load = loaded.then(Load::start);

    let (mut to_cloud, mut back) = (Vec::new(), Vec::new());
    for n in 0..runs {
        let tag = format!("mvt-{n}");
        let repo = mac.home().join(&tag);
        fs::create_dir_all(&repo).unwrap();
        // The Mac's guard takes a chat back only into a folder the person trusts.
        mac_acpmux.call("acp.trust.set", json!({"cwd": repo, "level": "trusted"}));
        let synced = vm.home().join("work").join(&tag);
        fs::create_dir_all(&synced).unwrap();

        let session = running_chat(&mut mac_acpmux, &repo, &tag);
        let surface = bound_agent_tab(&mac, &session);
        let (ms, answer) =
            timed_move(&mac, &vm, surface, &synced, &root.join(format!("{tag}-out")));
        landed(&mut vm_acpmux, &mut mac_acpmux, &session, &answer);
        to_cloud.push(ms);

        let surface = bound_agent_tab(&vm, &session);
        let (ms, answer) = timed_move(&vm, &mac, surface, &repo, &root.join(format!("{tag}-back")));
        landed(&mut mac_acpmux, &mut vm_acpmux, &session, &answer);
        back.push(ms);
        eprintln!("move-times round {n}: to cloud {} ms, back {ms} ms", to_cloud[n]);
    }
    drop(load);

    let report = json!({
        "to_cloud_ms": to_cloud,
        "back_ms": back,
        "p95_to_cloud_ms": p95(&to_cloud),
        "p95_back_ms": p95(&back),
        "runs": runs,
        "load": loaded,
        "profile": if cfg!(debug_assertions) { "dev" } else { "release" },
        "cores": std::thread::available_parallelism().map(usize::from).unwrap_or(0),
    });
    println!("MOVE_TIMES {report}");
    if let Ok(path) = std::env::var("MOVE_TIMES_OUT")
        && !path.is_empty()
    {
        fs::write(&path, format!("{report}\n")).unwrap();
    }
}
