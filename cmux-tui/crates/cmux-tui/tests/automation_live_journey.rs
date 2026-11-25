//! The live proof of docs/automations-desktop-parity.md, with the real binary,
//! a real runner process and the real clock (about four minutes, so it runs
//! only with `CMUX_AUTOMATION_LIVE=1`, or in a fleet step whose key ends in
//! `automation-live`: `cmux-ci run … --key NAME-automation-live --script
//! scripts/ci/cmux-tui-rust-check.sh --arg test --arg automation_live --arg cmux-tui`):
//!
//! 1. A schedule fires: an automation every minute runs at its minute.
//! 2. A sleep is caught up: the runner stops for two and a half minutes (the
//!    Mac asleep) and the runner health says stopped; started again, it runs
//!    the newest missed time once, late, and records the older one as skipped
//!    with its reason.
//! 3. A failure shows: a command that exits 3 is a failed run with its reason,
//!    its log (stderr too) and an unread failure on the automation.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-automation-live-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("bin")).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("bin/cmux")).unwrap();
        Self { dir }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(self.dir.join("bin/cmux"));
        command
            .args(args)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("HOME", &self.dir)
            .env("CMUX_AUTOMATIONS_DIR", self.dir.join("store"))
            .env("CMUX_AUTOMATION_NOTIFY", "off")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG");
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        let out = self.run(&all);
        serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
            panic!(
                "cmux {args:?} printed no JSON ({e}): {}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            )
        })
    }

    /// The runner, as the login item runs it.
    fn runner(&self) -> Runner {
        let child = self
            .command(&["automation", "runner"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        Runner(child)
    }

    fn runs(&self, name: &str) -> Vec<Value> {
        self.json(&["automation", "history", name])["runs"].as_array().cloned().unwrap_or_default()
    }

    fn health(&self) -> String {
        self.json(&["automation", "runner", "status"])["health"].as_str().unwrap_or("").to_string()
    }

    /// Waits up to `limit` for `done`, checking every second.
    fn until(&self, limit: Duration, what: &str, mut done: impl FnMut() -> bool) {
        let end = Instant::now() + limit;
        while !done() {
            assert!(Instant::now() < end, "{what}: not within {limit:?}");
            std::thread::sleep(Duration::from_secs(1));
        }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// A runner process this test started; stopped when dropped.
struct Runner(Child);

impl Drop for Runner {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn state(run: &Value) -> &str {
    run["state"].as_str().unwrap_or("")
}

#[test]
fn automation_live_a_schedule_fires_a_sleep_is_caught_up_and_a_failure_shows() {
    let asked = std::env::var("CMUX_AUTOMATION_LIVE").as_deref() == Ok("1")
        || std::env::var("CMUX_CI_STEP_KEY").is_ok_and(|k| k.ends_with("automation-live"));
    if !asked {
        eprintln!("skipped: set CMUX_AUTOMATION_LIVE=1 (about four minutes of real time)");
        return;
    }
    let env = Env::new();
    let every = env.json(&[
        "automation",
        "create",
        "Every minute",
        "--command",
        "echo checked disk",
        "--every",
        "1m",
    ]);
    assert!(every["id"].as_str().is_some(), "{every}");
    let failing = env.json(&[
        "automation",
        "create",
        "Nightly build",
        "--command",
        "echo building; echo 'error: 2 tests failed' >&2; exit 3",
        "--manual",
    ]);
    assert!(failing["id"].as_str().is_some(), "{failing}");

    // 1. The schedule fires at its minute.
    assert_eq!(env.health(), "stopped");
    let runner = env.runner();
    env.until(Duration::from_secs(20), "runner health running", || env.health() == "running");
    env.until(Duration::from_secs(100), "a scheduled run that succeeded", || {
        env.runs("Every minute")
            .iter()
            .any(|r| r["trigger"] == "schedule" && state(r) == "succeeded")
    });
    let first = env.runs("Every minute");
    eprintln!("scheduled: {}", serde_json::to_string(&first).unwrap());

    // 2. The Mac sleeps: no runner for 150 s, two minutes pass unrun.
    drop(runner);
    env.until(Duration::from_secs(10), "runner health stopped", || env.health() == "stopped");
    let asleep_at = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64;
    std::thread::sleep(Duration::from_secs(150));
    let woke_at = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64;
    let _runner = env.runner();
    // The times missed while asleep: after the stop, at or before the wake.
    let missed = |runs: &[Value]| -> Vec<Value> {
        runs.iter()
            .filter(|r| {
                let at = r["scheduled_at"].as_i64().unwrap_or(0);
                at > asleep_at && at <= woke_at
            })
            .cloned()
            .collect()
    };
    env.until(Duration::from_secs(30), "the catch-up run after the sleep", || {
        missed(&env.runs("Every minute")).iter().any(|r| state(r) == "succeeded")
    });
    let after = missed(&env.runs("Every minute"));
    eprintln!("missed while asleep: {}", serde_json::to_string(&after).unwrap());
    assert!(after.len() >= 2, "150 s asleep miss at least two minutes: {after:?}");
    let ran: Vec<&Value> = after.iter().filter(|r| state(r) == "succeeded").collect();
    assert_eq!(ran.len(), 1, "the missed times run once, not once each: {after:?}");
    assert!(
        ran[0]["late_seconds"].as_i64().unwrap_or(0) > 0,
        "the catch-up says it is late: {:?}",
        ran[0]
    );
    let newest = after.iter().filter_map(|r| r["scheduled_at"].as_i64()).max();
    assert_eq!(ran[0]["scheduled_at"].as_i64(), newest, "it is the newest missed time that runs");
    let skipped: Vec<&Value> = after.iter().filter(|r| state(r) == "skipped").collect();
    assert_eq!(skipped.len(), after.len() - 1, "{after:?}");
    assert!(
        skipped.iter().all(|r| r["reason"] == "superseded"),
        "each older miss stays, with its reason: {skipped:?}"
    );

    // 3. A failure shows: its reason, its log, an unread failure.
    let ran = env.run(&["automation", "run", "Nightly build", "--wait"]);
    assert!(!ran.status.success(), "a failed run exits non-zero");
    let failed = env.runs("Nightly build");
    let run = failed.iter().find(|r| state(r) == "failed").unwrap_or_else(|| panic!("{failed:?}"));
    assert_eq!(run["reason"], "exit_3");
    let id = run["id"].as_str().unwrap();
    let log = env.run(&["automation", "logs", id]);
    let log = String::from_utf8_lossy(&log.stdout);
    assert!(log.contains("building") && log.contains("error: 2 tests failed"), "{log}");
    let list = env.json(&["automation", "list"]);
    let nightly = list["automations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["name"] == "Nightly build")
        .unwrap()
        .clone();
    assert_eq!(nightly["unread_failures"], 1, "{nightly}");
    eprintln!("failed: {}\nlog:\n{log}", serde_json::to_string(run).unwrap());
}
