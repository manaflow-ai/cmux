//! What lanes ran as `acpmux --json … | python3 -c …` or a loop of sends, as one command against
//! a real daemon: `ls PATTERN`, `ls --fields a.b`, `session info --fields` and `send --tag`.
//! Leo, 2026-10-30: "various not as ergonomic/one-command-y as i'd liike set of commands for
//! interacting with stuff".
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
    let dir = std::env::temp_dir().join(format!("amx-1c-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
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

fn ok(dir: &Path, args: &[&str]) -> String {
    let out = cli(dir, args);
    assert!(out.status.success(), "{args:?}: {}", text(&out));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

#[test]
fn one_command_selection_and_send_to_a_tag() {
    let dir = scratch("s");
    let _shutdown = Shutdown(&dir);
    ok(&dir, &["run", "-n", "review-27899", "--tag", "area=acpmux", "warm up"]);
    ok(&dir, &["run", "-n", "review-27800", "--tag", "area=acpmux", "warm up"]);
    ok(&dir, &["run", "-n", "cloud-lane", "--tag", "area=cloud", "warm up"]);

    // `ls PATTERN`: a name glob, in place of `ls | grep` or `--json | python3` by name.
    let names = ok(&dir, &["ls", "review-27*", "--fields", "name"]);
    let mut got: Vec<&str> = names.lines().skip(1).collect();
    got.sort_unstable();
    assert_eq!(got, ["review-27800", "review-27899"], "{names}");
    let one = ok(&dir, &["--json", "ls", "review-2789?", "--fields", "name,turnCount"]);
    let one: Value = serde_json::from_str(&one).unwrap();
    assert_eq!(one["sessions"], json!([{"name": "review-27899", "turnCount": 1}]), "{one}");
    let by_flag =
        ok(&dir, &["ls", "--name", "cloud-*", "--name", "review-27899", "--fields", "name"]);
    assert_eq!(by_flag.lines().count(), 3, "--name is the same as a PATTERN: {by_flag}");
    // A dotted field in text mode, as in JSON.
    let nested = ok(&dir, &["ls", "cloud-lane", "--fields", "name,tags.area"]);
    assert_eq!(nested, "name\ttags.area\ncloud-lane\tcloud\n");
    let none = ok(&dir, &["--json", "ls", "nothing-*"]);
    assert_eq!(serde_json::from_str::<Value>(&none).unwrap()["sessions"], json!([]));

    // `session info --fields`: one bare value, `field<TAB>value` lines, or a JSON object.
    let id = ok(&dir, &["session", "info", "cloud-lane", "--fields", "sessionId"]);
    let id = id.trim();
    assert!(id.len() >= 32 && !id.contains('\t'), "a bare id: {id:?}");
    let pair = ok(&dir, &["session", "info", "cloud-lane", "--fields", "name,tags.area"]);
    assert_eq!(pair, "name\tcloud-lane\ntags.area\tcloud\n");
    let obj = ok(&dir, &["--json", "session", "info", "cloud-lane", "--fields", "name,status"]);
    let obj: Value = serde_json::from_str(&obj).unwrap();
    assert_eq!(obj.as_object().map(|o| o.len()), Some(2), "{obj}");
    assert_eq!(obj["name"], "cloud-lane");

    // `send --tag --dry-run` lists the targets and sends nothing.
    let dry = ok(&dir, &["send", "--tag", "area=acpmux", "--dry-run", "ping"]);
    assert_eq!(dry.lines().count(), 2, "{dry}");
    assert!(dry.lines().all(|l| l.ends_with("\twould send")), "{dry}");

    // `send --tag`: one message to each live session with the tag, none to the others.
    let sent = ok(&dir, &["--json", "send", "--tag", "area=acpmux", "base is green again"]);
    let sent: Value = serde_json::from_str(&sent).unwrap();
    let rows = sent["sent"].as_array().unwrap();
    assert_eq!(rows.len(), 2, "{sent}");
    assert!(rows.iter().all(|r| r["status"] == "queued" && r["deliveryId"].is_string()), "{sent}");
    for name in ["review-27899", "review-27800"] {
        let waited = cli(
            &dir,
            &["wait", name, "--until", "ready", "--match", "base is green", "--timeout", "20"],
        );
        assert!(waited.status.success(), "{name}: {}", text(&waited));
        assert!(ok(&dir, &["last", name]).contains("echo: base is green again"), "{name}");
    }
    assert!(!ok(&dir, &["last", "cloud-lane"]).contains("base is green"), "another tag got it");
    let turns = ok(&dir, &["session", "info", "cloud-lane", "--fields", "turnCount"]);
    assert_eq!(turns.trim(), "1", "cloud-lane got a turn");

    // Nothing carries the tag: an error, not a silent no-op.
    let missing = cli(&dir, &["send", "--tag", "area=nobody", "hello"]);
    assert_eq!(missing.status.code(), Some(4), "no such session: {}", text(&missing));
}
