//! `newRelay` against a real daemon (`src/cli/new_relay.rs`): `new --machine HOST`, refused
//! because HOST names no peer of this daemon, goes to the relay command with `--machine HOST` and
//! the caller's other `new` words, and the relay's status is the `new`'s. A relay's own `new`
//! (`ACPMUX_NEW_RELAYED` set) is never relayed again, and with `--json` the relay's stdout comes
//! back in one object.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::json;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};

/// A state folder whose config names a relay that records each call's argv and
/// `ACPMUX_NEW_RELAYED` in `relayed`, prints `started`, and exits 6 when `-n refuse` is given.
fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-nrl-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let relay = dir.join("placer");
    fs::write(
        &relay,
        format!(
            "#!/bin/sh\nprintf '%s|%s\\n' \"$*\" \"${{ACPMUX_NEW_RELAYED-unset}}\" >> {}\ncase \" $* \" in *' -n refuse '*) echo 'refused: no room' >&2; exit 6;; esac\necho started\n",
            dir.join("relayed").display()
        ),
    )
    .unwrap();
    fs::set_permissions(&relay, fs::Permissions::from_mode(0o755)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all",
               "newRelay": {"argv": [relay.display().to_string(), "new"]}})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    dir
}

fn cli_env(dir: &Path, args: &[&str], relayed: bool) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("ACPMUX_SESSION_ID")
        .env_remove("ACPMUX_NEW_RELAYED")
        .current_dir(dir.join("p"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if relayed {
        cmd.env("ACPMUX_NEW_RELAYED", "1");
    }
    cmd.output().unwrap()
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    cli_env(dir, args, false)
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

fn relayed(dir: &Path) -> Vec<String> {
    fs::read_to_string(dir.join("relayed"))
        .unwrap_or_default()
        .lines()
        .map(|l| l.trim_end().to_owned())
        .collect()
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

#[test]
fn a_machine_no_peer_names_goes_to_the_new_relay_with_the_callers_words() {
    let dir = scratch("r");
    let _shutdown = Shutdown(&dir);

    // The machine and the other words, in order; the relay's stdout and status are the new's.
    let made = cli(&dir, &["new", "-n", "x", "--machine", "far", "-d", "fix the bug"]);
    assert!(made.status.success(), "{}", text(&made));
    assert_eq!(String::from_utf8_lossy(&made.stdout).trim(), "started", "{}", text(&made));
    assert_eq!(relayed(&dir), vec!["new --machine far -n x -d fix the bug|1"]);

    // The relay's refusal is the new's failure, with its status.
    let refused = cli(&dir, &["new", "--host=far", "-n", "refuse", "-d", "x"]);
    assert_eq!(refused.status.code(), Some(6), "{}", text(&refused));
    assert!(String::from_utf8_lossy(&refused.stderr).contains("refused: no room"));
    assert_eq!(relayed(&dir)[1], "new --machine far -n refuse -d x|1");

    // --json says what the relay did, with its stdout.
    let json = cli(&dir, &["--json", "new", "--machine", "far", "-d", "j"]);
    assert!(json.status.success(), "{}", text(&json));
    let out: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(out["machine"], "far", "{out}");
    assert_eq!(out["status"], "relayed", "{out}");
    assert_eq!(out["exit"], 0, "{out}");
    assert_eq!(out["output"], "started", "{out}");
    assert_eq!(relayed(&dir).len(), 3);

    // A relay's own `new` is refused as before, never relayed again.
    let looped = cli_env(&dir, &["new", "--machine", "far", "-d", "x"], true);
    assert!(!looped.status.success(), "{}", text(&looped));
    assert!(String::from_utf8_lossy(&looped.stderr).contains("no peer"), "{}", text(&looped));
    assert_eq!(relayed(&dir).len(), 3, "{:?}", relayed(&dir));
}
