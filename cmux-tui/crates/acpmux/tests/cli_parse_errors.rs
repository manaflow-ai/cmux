//! Parse errors from a real binary leave an agent a way out: `acpmux stop NAME` is
//! `session stop NAME` (clap offered `shutdown`, which stops the daemon), a root word a command
//! group takes names that command, every parse error under `--json` is the error envelope, and
//! a lone `-` among `new`'s prompt words is refused for `--prompt-file -`, not sent as "-".
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
    let dir = std::env::temp_dir().join(format!("amx-cpe-{tag}-{}", std::process::id()));
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

fn envelope(o: &Output) -> Value {
    let line = String::from_utf8_lossy(&o.stderr);
    serde_json::from_str(line.trim()).unwrap_or_else(|e| panic!("not JSON ({e}): {}", text(o)))
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

#[test]
fn stop_is_session_stop_and_never_suggests_shutdown() {
    let dir = scratch("s");
    let _shutdown = Shutdown(&dir);
    let help = cli(&dir, &["stop", "--help"]);
    assert_eq!(help.status.code(), Some(0), "{}", text(&help));
    let out = String::from_utf8_lossy(&help.stdout);
    assert!(out.contains("Stop the agent process"), "not session stop's help: {}", text(&help));
    assert!(!String::from_utf8_lossy(&help.stderr).contains("shutdown"), "{}", text(&help));
}

#[test]
fn a_root_word_a_group_takes_names_that_command() {
    let dir = scratch("g");
    let _shutdown = Shutdown(&dir);
    let out = cli(&dir, &["restart", "lane"]);
    assert_eq!(out.status.code(), Some(2), "{}", text(&out));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("Try: acpmux session restart lane"), "{}", text(&out));
    assert!(!err.contains("shutdown"), "{}", text(&out));

    let json = cli(&dir, &["--json", "restart", "lane"]);
    assert_eq!(json.status.code(), Some(2), "{}", text(&json));
    let v = envelope(&json);
    assert_eq!(v["error"]["code"], "usage", "{v}");
    assert_eq!(v["error"]["data"]["reason"], "usage.unknown_command", "{v}");
    assert_eq!(v["error"]["data"]["try"], "acpmux session restart lane", "{v}");
}

#[test]
fn every_parse_error_under_json_is_the_envelope() {
    let dir = scratch("j");
    let _shutdown = Shutdown(&dir);
    for (args, reason) in [
        (&["--json", "frobnicate"][..], "usage.unknown_command"),
        (&["--json", "ls", "--no-such-flag"][..], "usage.unknown_argument"),
        (&["--json", "session", "stop"][..], "usage.missing_argument"),
    ] {
        let out = cli(&dir, args);
        assert_eq!(out.status.code(), Some(2), "{args:?}: {}", text(&out));
        let v = envelope(&out);
        assert_eq!(v["error"]["code"], "usage", "{args:?}: {v}");
        assert_eq!(v["error"]["exit"], 2, "{args:?}: {v}");
        assert_eq!(v["error"]["data"]["reason"], reason, "{args:?}: {v}");
    }
}

#[test]
fn a_lone_dash_prompt_word_is_refused_for_prompt_file() {
    let dir = scratch("d");
    let _shutdown = Shutdown(&dir);
    let listing = || {
        let mut names: Vec<_> =
            fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name()).collect();
        names.sort();
        names
    };
    let before = listing();
    let out = cli(&dir, &["new", "-d", "lane", "-"]);
    assert_eq!(out.status.code(), Some(2), "{}", text(&out));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("Try: acpmux new --prompt-file - -d lane"), "{}", text(&out));

    let json = cli(&dir, &["--json", "new", "-d", "-"]);
    assert_eq!(json.status.code(), Some(2), "{}", text(&json));
    let v = envelope(&json);
    assert_eq!(v["error"]["data"]["reason"], "usage.prompt_stdin", "{v}");
    assert_eq!(before, listing(), "a daemon was started");
}
