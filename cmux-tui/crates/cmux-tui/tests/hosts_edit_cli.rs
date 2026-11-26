//! `cmux hosts add|rename|set-endpoints|remove` through the CLI entry on a
//! scratch cmux-next.json: each verb changes one host, the file keeps its
//! comments and other keys, a refused edit writes nothing, and an agent
//! caller is refused.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir()
            .join(format!("cmux-hosts-edit-cli-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(dir.join("home")).unwrap();
        Scratch(dir)
    }

    fn config(&self) -> PathBuf {
        self.0.join("cmux-next.json")
    }

    fn run(&self, args: &[&str], agent: bool) -> Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(args)
            .env_clear()
            .env("HOME", self.0.join("home"))
            .env("PATH", "/usr/bin:/bin")
            .env("CMUX_NEXT_CONFIG_FILE", self.config());
        if agent {
            command.env("ACPMUX_SESSION_ID", "s-test");
        }
        command.output().expect("run cmux")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn ok(out: &Output) -> String {
    assert!(out.status.success(), "stderr: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn hosts(path: &Path) -> Value {
    let text = std::fs::read_to_string(path).unwrap();
    let start = text.find('{').unwrap();
    // The file is JSONC; the test's own comments sit on lines of their own.
    let strict: String =
        text[start..].lines().filter(|line| !line.trim_start().starts_with("//")).collect();
    serde_json::from_str::<Value>(&strict).unwrap()["machines"]["hosts"].clone()
}

#[test]
fn each_verb_changes_one_host_and_keeps_the_file() {
    let scratch = Scratch::new("verbs");
    std::fs::write(
        scratch.config(),
        "{\n  // my terminal\n  \"terminal\": { \"fontSize\": 13 }\n}\n",
    )
    .unwrap();
    ok(&scratch
        .run(&["hosts", "add", "studio", "studio.local", "--icon", "desktopcomputer"], false));
    ok(&scratch.run(&["hosts", "add", "box", "ssh://leo@10.0.0.2:2222"], false));
    ok(&scratch.run(&["hosts", "rename", "studio", "studio mini"], false));
    ok(&scratch.run(&["hosts", "set-endpoints", "box", "b1", "ssh://b2:22"], false));
    let list = hosts(&scratch.config());
    assert_eq!(list[0]["label"], "studio mini");
    assert_eq!(list[0]["icon"], "desktopcomputer");
    assert_eq!(list[1]["endpoints"], serde_json::json!(["b1", "ssh://b2:22"]));
    let reply: Value = serde_json::from_str(&ok(
        &scratch.run(&["--json", "hosts", "remove", "studio mini"], false)
    ))
    .unwrap();
    assert_eq!(reply["hosts"].as_array().map(Vec::len), Some(1));
    let text = std::fs::read_to_string(scratch.config()).unwrap();
    assert!(text.contains("// my terminal"), "{text}");
    assert!(text.contains("\"fontSize\": 13"), "{text}");
    let listed: Value =
        serde_json::from_str(&ok(&scratch.run(&["--json", "hosts", "list"], false))).unwrap();
    assert_eq!(listed["hosts"][0]["label"], "box");
}

#[test]
fn refused_edits_write_nothing_and_agents_are_refused() {
    let scratch = Scratch::new("refused");
    ok(&scratch.run(&["hosts", "add", "a", "a.local"], false));
    let before = std::fs::read_to_string(scratch.config()).unwrap();
    for args in [
        &["hosts", "add", "A", "b"][..],
        &["hosts", "add", "c", "http://c"],
        &["hosts", "rename", "nope", "x"],
        &["hosts", "remove", "nope"],
    ] {
        let out = scratch.run(args, false);
        assert!(!out.status.success(), "{args:?} succeeded");
    }
    let out = scratch.run(&["hosts", "remove", "a"], true);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("an agent cannot change machines.hosts"));
    assert_eq!(std::fs::read_to_string(scratch.config()).unwrap(), before);
}

#[test]
fn every_verb_has_help() {
    let scratch = Scratch::new("help");
    for verb in ["add", "rename", "set-endpoints", "remove", "check", "list"] {
        let text = ok(&scratch.run(&["hosts", verb, "--help"], false));
        assert!(text.contains("cmux hosts rename OLD NEW"), "{verb}: {text}");
    }
}
