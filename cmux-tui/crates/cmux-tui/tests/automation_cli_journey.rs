//! `cmux automation` end to end through the real binary: create, list, run
//! now (a real `_exec` child), history, logs, pause, resume, edit, a runner
//! tick, delete (docs/automations-platonic-ideal.md, slice 1).
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct Env {
    dir: PathBuf,
}

impl Env {
    fn new(label: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-automation-cli-{label}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("bin")).unwrap();
        symlink(env!("CARGO_BIN_EXE_cmux-tui"), dir.join("bin/cmux")).unwrap();
        Self { dir }
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(self.dir.join("bin/cmux"))
            .args(args)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("HOME", &self.dir)
            .env("CMUX_AUTOMATIONS_DIR", self.dir.join("store"))
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .output()
            .unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        let out = self.run(&all);
        assert!(
            out.status.success(),
            "cmux {args:?}: {}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap_or_else(|e| {
            panic!("cmux {args:?} printed no JSON ({e}): {}", String::from_utf8_lossy(&out.stdout))
        })
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn automation_journey_create_run_history_logs_pause_edit_delete() {
    let env = Env::new("journey");

    let created = env.json(&[
        "automation",
        "create",
        "Echo check",
        "--command",
        "echo automation-ran-$CMUX_AUTOMATION_RUN_ID",
        "--daily",
        "09:00",
    ]);
    let id = created["id"].as_str().unwrap().to_string();
    assert!(id.starts_with("auto_"));
    assert_eq!(created["trigger"]["expr"], "0 9 * * *");
    assert!(created["next_run_at"].as_i64().is_some());
    assert_eq!(created["runner_running"], false);

    let list = env.json(&["automation", "list"]);
    assert_eq!(list["automations"].as_array().unwrap().len(), 1);

    // Run now by name, waiting for the real `_exec` child.
    let run = env.json(&["automation", "run", "echo check", "--wait", "--key", "k1"]);
    let run_id = run["id"].as_str().unwrap().to_string();
    assert_eq!(run["state"], "succeeded", "{run}");
    assert_eq!(run["trigger"], "manual");

    // The same key is the same run: nothing starts twice.
    let again = env.json(&["automation", "run", &id, "--wait", "--key", "k1"]);
    assert_eq!(again["id"], run_id.as_str());

    let history = env.json(&["automation", "history", &id]);
    assert_eq!(history["runs"].as_array().unwrap().len(), 1);

    let logs = env.run(&["automation", "logs", &run_id]);
    let text = String::from_utf8_lossy(&logs.stdout);
    assert!(text.contains(&format!("automation-ran-{run_id}")), "{text}");

    // A failing command fails the run and the exit code says so.
    env.json(&["automation", "edit", &id, "--command", "exit 7"]);
    let failed = env.run(&["--json", "automation", "run", &id, "--wait", "--key", "k2"]);
    assert_eq!(failed.status.code(), Some(1));
    let failed: Value = serde_json::from_slice(&failed.stdout).unwrap();
    assert_eq!(failed["reason"], "exit_7");
    let only_failed = env.json(&["automation", "history", "--state", "failed"]);
    assert_eq!(only_failed["runs"].as_array().unwrap().len(), 1);

    let paused = env.json(&["automation", "pause", &id]);
    assert_eq!(paused["enabled"], false);
    assert!(paused["next_run_at"].is_null());
    let resumed = env.json(&["automation", "resume", &id]);
    assert_eq!(resumed["enabled"], true);
    assert_eq!(resumed["version"], 2, "pause and resume do not change the definition");

    // One runner tick: nothing is due yet, and it exits.
    let tick = env.run(&["--json", "automation", "runner", "--once"]);
    assert!(tick.status.success(), "{}", String::from_utf8_lossy(&tick.stderr));

    env.json(&["automation", "delete", &id]);
    let list = env.json(&["automation", "list"]);
    assert!(list["automations"].as_array().unwrap().is_empty());
}

#[test]
fn automation_usage_errors_exit_2_with_a_reason() {
    let env = Env::new("usage");
    for args in [
        &["automation", "create", "No schedule", "--command", "true"][..],
        &["automation", "create", "Two", "--command", "true", "--daily", "9:00", "--hourly"],
        &["automation", "create", "Bad time", "--command", "true", "--daily", "25:00"],
        &[
            "automation",
            "create",
            "Named zone",
            "--prompt",
            "hi",
            "--daily",
            "9:00",
            "--tz",
            "Europe/Paris",
        ],
        &["automation", "frobnicate"],
    ] {
        let out = env.run(args);
        assert_eq!(
            out.status.code(),
            Some(2),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(!out.stderr.is_empty() || !out.stdout.is_empty(), "{args:?} printed no reason");
    }
    let missing = env.run(&["automation", "show", "nothing-like-this"]);
    assert_eq!(missing.status.code(), Some(1));
}
