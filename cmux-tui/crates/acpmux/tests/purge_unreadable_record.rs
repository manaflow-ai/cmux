//! Bench round 5 (row 11b): `acpmux session kill --purge r5-NAME` on the shared daemon refused
//! with "chat 01a0a94c-...'s metadata does not read, and it may be a fork of <id>" and purged
//! none of 7 sessions. One chat record that does not read must not block the purge of a chat it
//! cannot name: a fork names its chat's id in its record (`historyFrom`), so a record whose text
//! does not hold that id is no fork of it. It is skipped and stays as it is. A record that does
//! name the chat still refuses its purge, so a fork never loses its history.
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
    let dir = std::env::temp_dir().join(format!("amx-pur-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    // The daemon refuses a state folder others may write to.
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all"})
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

/// Every session `ls --all` lists: name to id.
fn ids(dir: &Path) -> std::collections::BTreeMap<String, String> {
    let out = cli(dir, &["--json", "ls", "--all"]);
    assert!(out.status.success(), "ls: {}", text(&out));
    let v: Value = serde_json::from_slice(&out.stdout)
        .unwrap_or_else(|e| panic!("ls printed no JSON ({e}): {}", text(&out)));
    let rows = v["sessions"].as_array().cloned().unwrap_or_default();
    rows.iter()
        .map(|s| {
            let id = s["sessionId"].as_str().or_else(|| s["id"].as_str()).unwrap_or("");
            (s["name"].as_str().unwrap_or("").to_owned(), id.to_owned())
        })
        .collect()
}

/// A chat record in the store that does not read as one (`name` is not text), with `extra`.
fn unreadable_record(dir: &Path, id: &str, extra: Value) {
    let folder = dir.join("sessions").join(id);
    fs::create_dir_all(&folder).unwrap();
    fs::set_permissions(&folder, fs::Permissions::from_mode(0o700)).unwrap();
    let mut record = json!({"schema": "acpmux.session.v1", "id": id, "name": 7, "status": "idle"});
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        record[k] = v;
    }
    let file = folder.join("session.json");
    fs::write(&file, record.to_string()).unwrap();
    fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
}

#[test]
fn w5s_an_unreadable_record_that_names_no_chat_does_not_block_its_purge() {
    let dir = scratch("p");
    let _shutdown = Shutdown(&dir);
    for name in ["victim", "guarded"] {
        let made = cli(&dir, &["run", "-n", name, "warm up"]);
        assert!(made.status.success(), "the session {name}: {}", text(&made));
    }
    let before = ids(&dir);
    let guarded = before.get("guarded").cloned().unwrap_or_default();
    assert!(!guarded.is_empty(), "{before:?}");
    // Records the store lists at its next start and cannot read.
    let down = cli(&dir, &["daemon", "shutdown", "--end-agents"]);
    assert!(down.status.success(), "{}", text(&down));
    let other = "01a0a94c-0a6b-71da-9739-4a14a7456d24";
    unreadable_record(&dir, other, json!({}));
    let fork = "01a0a94c-0a6b-71da-9739-4a14a7456d25";
    unreadable_record(&dir, fork, json!({"historyFrom": {"session": guarded, "throughSeq": 1}}));

    let purged = cli(&dir, &["session", "kill", "--purge", "victim"]);
    assert!(purged.status.success(), "an unrelated record blocked the purge: {}", text(&purged));
    let after = ids(&dir);
    assert!(!after.contains_key("victim"), "victim was not purged: {after:?}");
    // The record that did not read is skipped, never removed.
    assert!(dir.join("sessions").join(other).join("session.json").exists());

    // A record that names the chat may be its fork: that purge is still refused.
    let refused = cli(&dir, &["session", "kill", "--purge", "guarded"]);
    assert!(!refused.status.success(), "a possible fork lost its history: {}", text(&refused));
    assert!(String::from_utf8_lossy(&refused.stderr).contains(fork), "{}", text(&refused));
    assert!(ids(&dir).contains_key("guarded"), "guarded was purged");
}
