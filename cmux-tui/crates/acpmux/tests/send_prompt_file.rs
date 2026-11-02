//! `acpmux send --prompt-file`, from a real binary. The gui-push coordinator driving remote
//! lanes (2026-10-20), word for word: "(2) acpmux send --no-wait --prompt-file FILE gives a bare
//! usage line without saying --prompt-file isn't a send flag."
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
    let dir = std::env::temp_dir().join(format!("amx-spf-{tag}-{}", std::process::id()));
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

/// `send --prompt-file` names the flag send does not take, the command that takes it, and what
/// send does instead, in text and as `data.reason` and `data.try` under `--json`. It is refused
/// before a daemon is asked anything.
#[test]
fn send_prompt_file_says_send_reads_stdin_and_which_command_takes_the_flag() {
    let dir = scratch("f");
    let _shutdown = Shutdown(&dir);
    fs::write(dir.join("p/brief.md"), "do it\n").unwrap();
    let listing = || {
        let mut names: Vec<_> =
            fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name()).collect();
        names.sort();
        names
    };
    let before = listing();
    let sent = cli(&dir, &["send", "--no-wait", "--prompt-file", "brief.md", "lane"]);
    let err = String::from_utf8_lossy(&sent.stderr);
    assert_eq!(sent.status.code(), Some(2), "{}", text(&sent));
    assert!(err.contains("send takes no --prompt-file"), "{}", text(&sent));
    assert!(err.contains("`new`"), "the command that takes it: {}", text(&sent));
    assert!(err.contains("acpmux send --no-wait lane - < brief.md"), "{}", text(&sent));
    assert!(!err.contains("--prompt-id"), "a misleading suggestion: {}", text(&sent));

    let json = cli(&dir, &["--json", "send", "lane", "--prompt-file=brief.md"]);
    assert_eq!(json.status.code(), Some(2), "{}", text(&json));
    let line = String::from_utf8_lossy(&json.stderr);
    let v: Value = serde_json::from_str(line.trim())
        .unwrap_or_else(|e| panic!("not JSON ({e}): {}", text(&json)));
    let data = &v["error"]["data"];
    assert_eq!(v["error"]["code"], "usage", "{v}");
    assert_eq!(data["reason"], "usage.unknown_flag", "{v}");
    assert_eq!(data["flag"], "--prompt-file", "{v}");
    assert_eq!(data["command"], "send", "{v}");
    assert_eq!(data["takenBy"], json!(["new"]), "{v}");
    assert_eq!(data["try"], "acpmux send lane - < brief.md", "{v}");
    assert_eq!(before, listing(), "a daemon was started");
}
