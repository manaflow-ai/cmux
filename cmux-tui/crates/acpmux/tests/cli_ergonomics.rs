//! `acpmux wait --print` after a failed turn, against a real daemon. The gui-push coordinator
//! driving remote lanes (2026-10-20), word for word: "(1) acpmux wait --print after a turn that
//! failed (capacity) prints the previous turn's reply, not the error, so a failed turn reads as
//! done".
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Output;

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-erg-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    // The daemon refuses a state folder others may write to.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    // One automatic retry, a minute out: it still waits when the test reads it.
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all", "autoResumeDelaysMs": [60000]})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    dir
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args).env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
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

/// After a turn a capacity error cut off, `wait --print` prints that turn's error and the
/// retry that waits, never the reply of the turn before, and exits 1; `--json` carries both.
#[test]
fn wait_print_after_a_failed_turn_prints_its_error_and_retry_not_the_reply_before() {
    let dir = scratch("w");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["run", "-n", "lane", "warm up"]);
    assert!(made.status.success(), "the session: {}", text(&made));
    let answered = cli(&dir, &["send", "-q", "lane", "the answer before"]);
    assert!(answered.status.success(), "{}", text(&answered));
    assert!(String::from_utf8_lossy(&answered.stdout).contains("echo: the answer before"));
    let failed = cli(&dir, &["send", "-q", "lane", "cap-fail-once: build it"]);
    assert!(!failed.status.success(), "the turn should fail: {}", text(&failed));

    let waited = cli(&dir, &["wait", "lane", "--print", "--timeout", "20"]);
    let out = String::from_utf8_lossy(&waited.stdout);
    assert_eq!(waited.status.code(), Some(1), "{}", text(&waited));
    assert!(!out.contains("echo: the answer before"), "the reply before: {}", text(&waited));
    assert!(out.contains("turn failed"), "{}", text(&waited));
    assert!(out.contains("no non-exhausted claude accounts"), "the error: {}", text(&waited));
    assert!(out.contains("retry 1 of 1"), "the waiting retry: {}", text(&waited));
    assert!(out.contains("capacity"), "what it waits on: {}", text(&waited));
    assert!(out.contains("acpmux retry lane"), "how to retry now: {}", text(&waited));

    let json = cli(&dir, &["--json", "wait", "lane", "--timeout", "20"]);
    assert_eq!(json.status.code(), Some(1), "{}", text(&json));
    let v: Value = serde_json::from_slice(&json.stdout)
        .unwrap_or_else(|e| panic!("not JSON ({e}): {}", text(&json)));
    let row = &v["sessions"][0];
    let error = row["error"].as_str().unwrap_or_default();
    assert!(error.contains("no non-exhausted claude accounts"), "{v}");
    assert_eq!(row["retry"]["reason"], "capacity", "{v}");
    assert_eq!(row["retry"]["attempt"], 1, "{v}");
    assert_eq!(row["retry"]["of"], 1, "{v}");
    assert!(row["retry"]["nextAt"].as_u64().is_some(), "{v}");
    assert_ne!(row["reply"], "echo: the answer before", "{v}");
}
