//! A send between two machines that have no peer link to each other, by `HOST/NAME`, through the
//! send relay (`src/cli/send_relay.rs`), against two real daemons: machine A's `acpmux ls` lists
//! machine B's sessions (the relay's `lsArgv`), A's send to `hostb/NAME` is delivered to B's
//! session, and the cross-host audit log (`src/xhost_audit.rs`) has the send on A and its
//! receipt on B, never the text.
//!
//! The relay here plays the broker two lane machines share: it hands the message to B's daemon
//! with the sender named `hosta/LANE`, as the broker names a lane VM's sender. Leo, 2026-11-05, on
//! sends between lane machines: "ACPMux should definitely just do that, should just allow that.
//! ... Just do what's expected. Just do the magic."
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::time::Duration;

fn home(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-xh-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    dir
}

fn config(dir: &Path, extra: Value) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
                            "permissionPolicy": "approve-all"});
    if let (Some(config), Some(extra)) = (config.as_object_mut(), extra.as_object()) {
        config.extend(extra.clone());
    }
    fs::write(dir.join("config.json"), config.to_string()).unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
}

fn script(path: &Path, body: &str) {
    fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    let mut cmd = daemon_env::command(dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(args)
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("ACPMUX_FROM")
        .env_remove("ACPMUX_SESSION_ID")
        .current_dir(dir.join("p"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
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

fn audit(dir: &Path) -> Vec<Value> {
    fs::read_to_string(dir.join("cross-host-audit.jsonl"))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
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
fn a_send_by_host_and_name_reaches_another_machines_session_listed_and_audited_on_both() {
    let _ = &HERMETIC;
    let (a, b) = (home("a"), home("b"));
    let (_down_a, _down_b) = (Shutdown(&a), Shutdown(&b));
    config(&b, json!({}));
    let made = cli(&b, &["run", "-n", "lane-x", "warm up"]);
    assert!(made.status.success(), "machine B's session: {}", text(&made));

    // Machine A's relay: the send goes to B's daemon as the broker would deliver it, and the
    // listing is B's live sessions, each with its machine.
    let exe = env!("CARGO_BIN_EXE_acpmux");
    let (relay, ls) = (a.join("relay"), a.join("relay-ls"));
    script(
        &relay,
        &format!(
            "name=\"${{2#hostb/}}\"\nexec env ACPMUX_HOME={b} {exe} --json send --no-wait --from \"hosta/${{ACPMUX_FROM:-unnamed}}\" \"$name\" -",
            b = b.display()
        ),
    );
    script(
        &ls,
        &format!(
            "env ACPMUX_HOME={b} {exe} --json ls --live | python3 -c 'import json,sys; d=json.load(sys.stdin); [r.__setitem__(\"peer\", \"hostb\") for r in d[\"sessions\"]]; print(json.dumps(d))'",
            b = b.display()
        ),
    );
    config(
        &a,
        json!({"sendRelay": {"argv": [relay.display().to_string(), "send"],
                             "lsArgv": [ls.display().to_string()]}}),
    );
    let mine = cli(&a, &["run", "-n", "lane-a", "warm up"]);
    assert!(mine.status.success(), "machine A's session: {}", text(&mine));

    // Discovery: A lists B's session as hostb/lane-x beside its own.
    let listed = cli(&a, &["--json", "ls"]);
    assert!(listed.status.success(), "{}", text(&listed));
    let rows: Value = serde_json::from_slice(&listed.stdout).unwrap();
    let names: Vec<String> = rows["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| match r["peer"].as_str() {
            Some(peer) => format!("{peer}/{}", r["name"].as_str().unwrap_or_default()),
            None => r["name"].as_str().unwrap_or_default().to_owned(),
        })
        .collect();
    assert!(names.contains(&"hostb/lane-x".to_owned()), "{names:?}");
    let lane_x = rows["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["peer"] == "hostb" && r["name"] == "lane-x")
        .and_then(|r| r["sessionId"].as_str())
        .expect("lane-x's id")
        .to_owned();
    assert!(names.contains(&"lane-a".to_owned()), "{names:?}");
    let table = cli(&a, &["ls"]);
    assert!(String::from_utf8_lossy(&table.stdout).contains("lane-x"), "{}", text(&table));
    // `--machine` this one lists no other machine's.
    let local = cli(&a, &["--json", "ls", "--machine", "local"]);
    assert!(!String::from_utf8_lossy(&local.stdout).contains("lane-x"), "{}", text(&local));

    // The send, by HOST/NAME, from a named sender.
    let sent = cli(
        &a,
        &["--json", "send", "--no-wait", "--from", "lane-a", "hostb/lane-x", "hello across"],
    );
    assert!(sent.status.success(), "{}", text(&sent));
    let out: Value = serde_json::from_slice(&sent.stdout).unwrap();
    assert_eq!(out["status"], "relayed", "{out}");
    let answer: Value = serde_json::from_str(out["output"].as_str().unwrap()).unwrap();
    let delivery = answer["deliveryId"].as_str().expect("B's delivery id").to_owned();

    // Delivered on B.
    let delivered = (0..100).any(|_| {
        let status = cli(&b, &["--json", "send", "--status", &delivery]);
        let v: Value = serde_json::from_slice(&status.stdout).unwrap_or(Value::Null);
        let done = v["status"] == "delivered";
        if !done {
            std::thread::sleep(Duration::from_millis(100));
        }
        done
    });
    assert!(delivered, "B never delivered {delivery}");

    // Audited on both machines, the text in neither.
    let sender = audit(&a);
    let line = sender.iter().find(|l| l["dir"] == "sent").unwrap_or_else(|| panic!("{sender:?}"));
    assert_eq!(
        (&line["via"], &line["to"], &line["from"]),
        (&json!("sendRelay"), &json!("hostb/lane-x"), &json!("lane-a"))
    );
    assert_eq!(line["exit"], 0);
    assert_eq!(line["bytes"], 12);
    // Of the relay's output, only B's delivery id.
    assert_eq!(line["delivery"], json!(delivery));
    // B names the session it delivered to by its id.
    let receiver = audit(&b);
    let line =
        receiver.iter().find(|l| l["dir"] == "received").unwrap_or_else(|| panic!("{receiver:?}"));
    assert_eq!(
        (&line["from"], &line["fromHost"], &line["to"]),
        (&json!("hosta/lane-a"), &json!("hosta"), &json!(lane_x))
    );
    for dir in [&a, &b] {
        let raw = fs::read_to_string(dir.join("cross-host-audit.jsonl")).unwrap();
        assert!(!raw.contains("hello across"), "{raw}");
    }

    // An unknown name fails fast with the relay's refusal, and nothing is delivered.
    let refuse = a.join("refuse");
    script(&refuse, "echo 'refused: no session \"nobody\" on hostb' >&2\nexit 1");
    config(&a, json!({"sendRelay": {"argv": [refuse.display().to_string(), "send"]}}));
    let unknown = cli(&a, &["send", "--no-wait", "hostb/nobody", "x"]);
    assert_eq!(unknown.status.code(), Some(1), "{}", text(&unknown));
    assert!(
        String::from_utf8_lossy(&unknown.stderr).contains("no session \"nobody\" on hostb"),
        "{}",
        text(&unknown)
    );
    // Audited as refused, not sent: nothing crossed machines.
    let refused = audit(&a);
    let line = refused.last().unwrap_or_else(|| panic!("{refused:?}"));
    assert_eq!(
        (&line["dir"], &line["to"], &line["exit"]),
        (&json!("refused"), &json!("hostb/nobody"), &json!(1))
    );
}
