//! `cmux-tui remote update-need` (cx-3r9mt, hq-6d 2026-10-15): the app's one
//! question before it replaces a machine's cmux-tui. Each case feeds this
//! binary its own `remote-probe --json`, changed the way an older, a newer or
//! an unrelated build would differ.

use std::io::Write;
use std::process::{Command, Stdio};

use serde_json::{Value, json};

use super::bin;

fn own_probe() -> Value {
    let output =
        Command::new(bin()).args(["remote-probe", "--json", "--build-facts"]).output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let probe: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(probe["build_time"].as_u64().is_some_and(|time| time > 0), "{probe}");
    assert!(probe["daemon_capabilities"].as_array().is_some_and(|list| list.len() > 10), "{probe}");
    probe
}

fn ask(probe: &Value) -> Value {
    let mut child = Command::new(bin())
        .args(["remote", "update-need", "--probe-json", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(probe.to_string().as_bytes()).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "exit 0 for every answer: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn answer(reply: &Value) -> (&str, &str) {
    (reply["need"].as_str().unwrap(), reply["reason"].as_str().unwrap())
}

/// Another commit with the same capability set, at `time`.
fn other_commit(probe: &Value, time: u64) -> Value {
    let mut other = probe.clone();
    other["build_identity"] = json!("0123456789abcdef0123456789abcdef01234567");
    other["build_time"] = json!(time);
    other
}

#[test]
fn the_same_commit_needs_nothing() {
    let probe = own_probe();
    assert_eq!(answer(&ask(&probe)), ("none", "same_commit"));
}

#[test]
fn equal_capabilities_order_by_build_time() {
    let probe = own_probe();
    let time = probe["build_time"].as_u64().unwrap();
    assert_eq!(answer(&ask(&other_commit(&probe, time - 60))), ("older", "build_time"));
    assert_eq!(answer(&ask(&other_commit(&probe, time + 60))), ("newer", "build_time"));
    // The same time with another commit: no order, so nothing flips back and forth.
    assert_eq!(answer(&ask(&other_commit(&probe, time))), ("none", "build_time"));
    // An unknown remote time counts as older.
    assert_eq!(answer(&ask(&other_commit(&probe, 0))), ("older", "build_time"));
}

#[test]
fn capabilities_order_before_build_time() {
    let probe = own_probe();
    let time = probe["build_time"].as_u64().unwrap();
    // A remote without one of this build's capabilities is older even with a later commit.
    let mut subset = other_commit(&probe, time + 3600);
    subset["daemon_capabilities"].as_array_mut().unwrap().pop();
    assert_eq!(answer(&ask(&subset)), ("older", "capabilities"));
    // A remote with a capability this build lacks is newer even with an earlier commit.
    let mut superset = other_commit(&probe, time - 3600);
    superset["daemon_capabilities"].as_array_mut().unwrap().push(json!("from-the-future-v1"));
    assert_eq!(answer(&ask(&superset)), ("newer", "capabilities"));
    // Each lacks one of the other's: no order, with a warning.
    let mut apart = other_commit(&probe, time - 3600);
    let list = apart["daemon_capabilities"].as_array_mut().unwrap();
    list.pop();
    list.push(json!("from-the-future-v1"));
    let reply = ask(&apart);
    assert_eq!(answer(&reply), ("none", "incomparable"));
    assert!(reply["warning"].is_string(), "{reply}");
}

#[test]
fn a_build_before_the_facts_is_older_and_bad_input_fails() {
    let probe = own_probe();
    let mut old = other_commit(&probe, 0);
    old.as_object_mut().unwrap().remove("daemon_capabilities");
    old.as_object_mut().unwrap().remove("build_time");
    assert_eq!(answer(&ask(&old)), ("older", "unknown"));
    let bad = Command::new(bin())
        .args(["remote", "update-need", "--probe-json", "/nonexistent/probe.json"])
        .output()
        .unwrap();
    assert!(!bad.status.success());
}

/// The plain probe stays inside what every client's SSH bootstrap reads (4096
/// bytes): the capability list comes only with `--build-facts`.
#[test]
fn the_plain_probe_fits_the_bootstrap_limit() {
    let output = Command::new(bin()).args(["remote-probe", "--json"]).output().unwrap();
    assert!(output.status.success());
    assert!(output.stdout.len() < 2048, "{} bytes", output.stdout.len());
    let probe: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert!(probe.get("daemon_capabilities").is_none(), "{probe}");
    assert!(probe["build_time"].is_u64(), "{probe}");
}
