//! `sendRelay` against a real daemon (`src/cli/send_relay.rs`): a send whose target names no
//! session here and no peer lists it goes to the relay command, with or without `--no-wait`, and
//! its status is the send's; a session here is never relayed, nor `@` outside a session, and a
//! relayed send with `--attach` is refused. A host may have no peer that reaches the target (an
//! agent VM that cannot dial back to the machine that drives it); the relay still delivers there.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::json;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};

/// A state folder whose config names a relay that records each call in `relayed` (its argv,
/// `ACPMUX_FROM` and stdin, one line per call), prints a delivery id and exits 7 for the
/// session `refuse`.
fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-rly-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let relay = dir.join("relay");
    fs::write(
        &relay,
        format!(
            "#!/bin/sh\n{{ printf '%s|' \"$*\" \"${{ACPMUX_FROM-unset}}\"; tr '\\n' ' '; echo; }} >> {}\n[ \"$2\" = refuse ] && {{ echo 'refused: not allowed' >&2; exit 7; }}\necho delivery-42\n",
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
               "sendRelay": {"argv": [relay.display().to_string(), "send"]}})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    dir
}

fn cli_with(dir: &Path, args: &[&str], stdin: Option<&str>) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("ACPMUX_FROM")
        .env_remove("ACPMUX_SESSION_ID")
        .current_dir(dir.join("p"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    if let Some(text) = stdin {
        input.write_all(text.as_bytes()).unwrap();
    }
    drop(input);
    child.wait_with_output().unwrap()
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    cli_with(dir, args, None)
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
fn a_target_nobody_here_resolves_goes_to_the_relay_and_a_session_here_never_does() {
    let dir = scratch("r");
    let _shutdown = Shutdown(&dir);
    let made = cli(&dir, &["run", "-n", "lane", "warm up"]);
    assert!(made.status.success(), "the session: {}", text(&made));

    // A session here: delivered as always, no relay.
    let here = cli(&dir, &["send", "--no-wait", "lane", "hello lane"]);
    assert!(here.status.success(), "{}", text(&here));
    assert_eq!(relayed(&dir), Vec::<String>::new());

    // --no-wait, text on stdin, the sender named.
    let sent = cli_with(
        &dir,
        &["send", "--no-wait", "--from", "vm/lane", "far/coordinator", "-"],
        Some("status: done\nsee the PR\n"),
    );
    assert!(sent.status.success(), "{}", text(&sent));
    assert_eq!(String::from_utf8_lossy(&sent.stdout).trim(), "delivery-42", "{}", text(&sent));
    assert_eq!(relayed(&dir), vec!["send far/coordinator -|vm/lane|status: done see the PR"]);

    // A send that waits relays too; with no sender named, ACPMUX_FROM is unset.
    let waited = cli(&dir, &["send", "-q", "far/coordinator", "hi"]);
    assert!(waited.status.success(), "{}", text(&waited));
    assert_eq!(relayed(&dir)[1], "send far/coordinator -|unset|hi");

    // The relay's refusal is the send's failure, with its status.
    let refused = cli(&dir, &["send", "--no-wait", "refuse", "x"]);
    assert_eq!(refused.status.code(), Some(7), "{}", text(&refused));
    assert!(String::from_utf8_lossy(&refused.stderr).contains("refused: not allowed"));

    // --json says what the relay did.
    let json = cli(&dir, &["--json", "send", "--no-wait", "far/coordinator", "j"]);
    assert!(json.status.success(), "{}", text(&json));
    let out: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(out["status"], "relayed", "{out}");
    assert_eq!(out["output"], "delivery-42", "{out}");
    let count = relayed(&dir).len();

    // Text only: --attach to such a target is refused, and nothing is relayed.
    fs::write(dir.join("p/notes.md"), b"# notes\n").unwrap();
    let attach = cli(&dir, &["send", "--no-wait", "far/coordinator", "x", "--attach", "notes.md"]);
    assert_eq!(attach.status.code(), Some(2), "{}", text(&attach));
    assert!(String::from_utf8_lossy(&attach.stderr).contains("text only"), "{}", text(&attach));

    // `@` outside a session is no target at all.
    let current = cli(&dir, &["send", "--no-wait", "@", "x"]);
    assert_eq!(current.status.code(), Some(4), "{}", text(&current));
    assert_eq!(relayed(&dir).len(), count, "{:?}", relayed(&dir));
}
