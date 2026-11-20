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
            .env("CMUX_AUTOMATION_NOTIFY", "off")
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
    // A history row says whose it is and where its log is (the Automations page opens it).
    let row = &only_failed["runs"][0];
    assert_eq!(row["automation_name"], "Echo check");
    assert!(
        row["log_path"]
            .as_str()
            .unwrap()
            .ends_with(&format!("{}.log", row["id"].as_str().unwrap()))
    );
    assert!(row.get("session").is_none(), "a command run has no agent chat");

    // The failure is unread until the automation is seen.
    let listed = env.json(&["automation", "list"]);
    assert_eq!(listed["automations"][0]["unread_failures"], 1, "{listed}");
    assert_eq!(listed["runner"]["health"], "stopped");
    let seen = env.json(&["automation", "seen", &id]);
    assert_eq!(seen["unread_failures"], 0);
    assert!(seen["seen_at"].as_i64().unwrap() > 0);

    // No runner: status says so, in JSON with its health.
    let status = env.run(&["--json", "automation", "runner", "status"]);
    assert_eq!(status.status.code(), Some(1));
    let status: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(status["health"], "stopped");

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

/// A prompt run is an agent chat: history names it, and a launcher that cannot
/// start fails the run with a reason the runner retries (not a body failure).
#[test]
fn automation_prompt_run_names_its_chat_and_a_launcher_that_cannot_start_is_retryable() {
    let env = Env::new("prompt");
    let created = env.json(&["automation", "create", "Brief", "--prompt", "Say hi", "--manual"]);
    let id = created["id"].as_str().unwrap().to_string();
    let out = Command::new(env.dir.join("bin/cmux"))
        .args(["--json", "automation", "run", &id, "--wait", "--key", "p1"])
        .env("LC_ALL", "C")
        .env("HOME", &env.dir)
        .env("CMUX_AUTOMATIONS_DIR", env.dir.join("store"))
        .env("CMUX_AUTOMATION_ACPMUX", env.dir.join("no-such-launcher"))
        .env("CMUX_AUTOMATION_NOTIFY", "off")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_SOCKET_PATH")
        .output()
        .unwrap();
    let run: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(run["state"], "failed", "{run}");
    assert!(run["reason"].as_str().unwrap().starts_with("error:"), "{run}");
    let history = env.json(&["automation", "history", &id]);
    let row = &history["runs"][0];
    let session = row["session"].as_str().unwrap();
    assert!(
        session.starts_with("auto-") && session.len() == "auto-12345678-12345678".len(),
        "{session}"
    );
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
