//! An agent's `acpmux send`, and any with `--class`, is queued in this daemon's outbox and
//! returns at once, however loaded the machine and however busy the target; `--wait` waits.
//!
//! Leo, 2026-11-02: "sends shouldn't time out just bc of load". On a Mac at load ~380 on
//! 15 CPUs, `timeout 100 acpmux send HOST/SESSION --class blocker "…"` failed for all six lanes
//! it went to: a send that waits streams the reply of the turn it steers into, so a busy target
//! (or a peer link that flapped under the load) held it past the caller's timeout.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-sq-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(
        dir.join("config.json"),
        std::os::unix::fs::PermissionsExt::from_mode(0o600),
    )
    .unwrap();
    dir
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("ACPMUX_FROM")
        .env_remove("ACPMUX_SESSION_ID")
        .current_dir(dir.join("p"));
    cmd.output().unwrap()
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

/// Busy-loops on `n` threads at normal priority until dropped.
struct CpuBurn(Arc<AtomicBool>, Vec<std::thread::JoinHandle<()>>);

impl CpuBurn {
    fn start(n: usize) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let threads = (0..n)
            .map(|_| {
                let stop = stop.clone();
                std::thread::spawn(move || {
                    let mut x = 0u64;
                    while !stop.load(Ordering::Relaxed) {
                        x = std::hint::black_box(
                            x.wrapping_mul(6364136223846793005).wrapping_add(1),
                        );
                    }
                })
            })
            .collect();
        CpuBurn(stop, threads)
    }
}

impl Drop for CpuBurn {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
        for t in self.1.drain(..) {
            let _ = t.join();
        }
    }
}

fn median(mut v: Vec<Duration>) -> Duration {
    v.sort();
    v[v.len() / 2]
}

/// The before and after of one machine: every CPU oversubscribed four times over and the target
/// in a turn that does not end. An agent's `--class blocker` send that waits (`--wait`, what a
/// plain one did before) is still waiting when its timeout ends it; the same send without
/// `--wait` is queued and returns at once, and its message reaches the session once.
#[test]
fn an_agents_classed_send_under_cpu_starvation_returns_at_once_and_a_waiting_one_times_out() {
    let dir = scratch("starved");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["new", "-d", "-n", "lane", "-m", "fake"]);
    assert!(made.status.success(), "start: {}", text(&made));
    // The lane at work: a turn that runs until it is cancelled.
    let busy = cli(&dir, &["send", "--no-wait", "--no-steer", "lane", "until-cancel"]);
    assert!(busy.status.success(), "busy: {}", text(&busy));
    let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
    let burn = CpuBurn::start(cores * 4);

    // Before: the send waits for the reply of the turn it went into.
    let started = Instant::now();
    let waited = cli(
        &dir,
        &[
            "send",
            "--wait",
            "--from",
            "coord",
            "--class",
            "blocker",
            "--timeout",
            "3",
            "lane",
            "rebase now",
        ],
    );
    let before = started.elapsed();
    assert_eq!(waited.status.code(), Some(3), "a waiting send times out: {}", text(&waited));

    // After: queued and answered once the message is on disk in the outbox.
    let mut after = Vec::new();
    let mut deliveries = Vec::new();
    for n in 0..5 {
        let started = Instant::now();
        let out = cli(
            &dir,
            &[
                "--json",
                "send",
                "--from",
                "coord",
                "--class",
                "blocker",
                "lane",
                &format!("blocker {n}"),
            ],
        );
        after.push(started.elapsed());
        assert!(out.status.success(), "a queued send: {}", text(&out));
        let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("--json");
        deliveries.push(v["deliveryId"].as_str().expect("a delivery id").to_owned());
    }
    drop(burn);
    let (slowest, typical) = (*after.iter().max().unwrap(), median(after.clone()));
    eprintln!(
        "under {}x CPU oversubscription ({cores} cores): waiting send {before:?} (timed out), \
         queued send median {typical:?}, slowest {slowest:?}: {after:?}",
        4
    );
    assert!(before >= Duration::from_secs(3), "{before:?}");
    // The CLI's own exec and connect under the load are in this; the daemon's part is ms.
    assert!(slowest < Duration::from_secs(3), "a queued send took {slowest:?}: {after:?}");

    // Each is delivered, and listed with its state.
    for delivery in &deliveries {
        let status = cli(&dir, &["--json", "send", "--status", delivery]);
        let v: serde_json::Value = serde_json::from_slice(&status.stdout).expect("--json");
        assert_eq!(v["status"], "delivered", "{v}");
    }
    let listed = cli(&dir, &["--json", "send", "--status"]);
    let v: serde_json::Value = serde_json::from_slice(&listed.stdout).expect("--json");
    let listed: Vec<&str> = v["deliveries"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|d| d["deliveryId"].as_str())
        .collect();
    for delivery in &deliveries {
        assert!(listed.contains(&delivery.as_str()), "{delivery} not in {v}");
    }
    let plain = cli(&dir, &["send", "--status"]);
    assert!(String::from_utf8_lossy(&plain.stdout).contains("delivered"), "{}", text(&plain));
}
