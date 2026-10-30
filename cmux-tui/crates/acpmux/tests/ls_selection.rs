//! Bounded, selective session listings stay small enough for agent scripts.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Output, Stdio};
use std::time::{Duration, Instant};

fn scratch() -> PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-ls-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("sessions")).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(root.join("sessions"), fs::Permissions::from_mode(0o700)).unwrap();
    root
}

fn write_sessions(home: &Path, count: usize) {
    let now =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    for i in 0..count {
        let id = format!("01a16c00-0000-7000-8000-{i:012x}");
        let dir = home.join("sessions").join(&id);
        fs::create_dir_all(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let at = if i + 1 == count { now } else { now.saturating_sub(2 * 86_400_000) + i as u64 };
        // Every tenth session is closed, the rest live (`ls`'s compact view and `--live`).
        let status = if i % 10 == 0 { "closed" } else { "idle" };
        let row = json!({
            "schema": "acpmux.session.v1", "id": id, "name": format!("lane-{i}"),
            "harness": "claude", "model": "sonnet", "cwd": "/tmp", "status": status,
            "createdAt": at, "updatedAt": at, "turnCount": 1, "lastSeq": 0,
            "eventCount": 0,
            "tools": {"rows": [{"id": "mcp:example", "name": "example", "kind": "mcp",
                "source": "claude", "enabled": true, "canToggle": true}], "mutable": true},
            "tags": {"area": {"value": "cli"}, "pad": {"value": "x".repeat(3650)}}
        });
        fs::write(dir.join("session.json"), row.to_string()).unwrap();
        fs::set_permissions(dir.join("session.json"), fs::Permissions::from_mode(0o600)).unwrap();
    }
}

struct Daemon {
    child: Child,
    root: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: this is the daemon child started by this test.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn start(root: &Path) -> Daemon {
    let socket = root.join("acpmux.sock");
    let mut child = daemon_env::acpmux(root)
        .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", root)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let ready = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map_while(Result::ok)
        .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
    assert!(ready, "daemon did not become ready");
    Daemon { child, root: root.to_owned() }
}

fn run(root: &Path, args: &[&str]) -> (Output, Duration) {
    let started = Instant::now();
    let output = daemon_env::command(root, daemon_env::Agents::Deny, &[])
        .args(args)
        .env("ACPMUX_HOME", root)
        .env("ACPMUX_SOCKET", root.join("acpmux.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(root)
        .output()
        .unwrap();
    (output, started.elapsed())
}

#[test]
fn selected_listing_is_bounded_and_newest_first_for_a_large_store() {
    let root = scratch();
    write_sessions(&root, 3_000);
    let _daemon = start(&root);

    let (full, full_elapsed) = run(&root, &["--json", "ls"]);
    assert!(full.status.success(), "full listing failed: {full:?}");
    let full_value: Value = serde_json::from_slice(&full.stdout).unwrap();
    assert_eq!(full_value["sessions"].as_array().map(Vec::len), Some(3_000));
    assert!(full_value["sessions"].as_array().unwrap().iter().all(|s| s.get("tools").is_none()));
    let (with_tools, _) = run(&root, &["--json", "ls", "--with-tools", "--limit", "1"]);
    assert!(with_tools.status.success(), "inventory listing failed: {with_tools:?}");
    let with_tools: Value = serde_json::from_slice(&with_tools.stdout).unwrap();
    assert_eq!(with_tools["sessions"].as_array().unwrap().len(), 1);
    assert_eq!(with_tools["sessions"][0]["tools"][0]["id"], "mcp:example");
    assert_eq!(with_tools["sessions"][0]["toolsMutable"], true);
    eprintln!("ls benchmark baseline: full={} bytes/{full_elapsed:?}", full.stdout.len());
    let (selected, selected_elapsed) =
        run(&root, &["--json", "ls", "--limit", "20", "--fields", "name,harness,model,status,cwd"]);
    assert!(selected.status.success(), "selected listing failed: {selected:?}");
    assert!(
        selected.stdout.len() < 20 * 1024,
        "selected output is {} bytes",
        selected.stdout.len()
    );
    assert!(
        selected_elapsed < Duration::from_millis(300),
        "selected listing took {selected_elapsed:?}"
    );
    assert!(selected.stdout.len() < full.stdout.len(), "selection did not reduce output");
    assert!(
        selected_elapsed <= full_elapsed,
        "selection slower than full listing: {selected_elapsed:?} > {full_elapsed:?}"
    );
    eprintln!(
        "ls benchmark head: full={} bytes/{full_elapsed:?}; selected={} bytes/{selected_elapsed:?}",
        full.stdout.len(),
        selected.stdout.len()
    );

    let value: Value = serde_json::from_slice(&selected.stdout).unwrap();
    let rows = value["sessions"].as_array().unwrap();
    assert_eq!(rows.len(), 20);
    let fields = rows[0].as_object().unwrap();
    assert_eq!(fields.len(), 5);
    for field in ["cwd", "harness", "model", "name", "status"] {
        assert!(fields.contains_key(field), "missing {field}: {fields:?}");
    }
    assert_eq!(rows[0]["name"], "lane-2999");
    assert_eq!(rows[19]["name"], "lane-2980");

    let (text, _) = run(&root, &["ls", "--limit", "2", "--fields", "name,status"]);
    assert!(text.status.success(), "text selection failed: {text:?}");
    let text = String::from_utf8_lossy(&text.stdout);
    assert_eq!(text.lines().next(), Some("name\tstatus"), "{text}");
    assert_eq!(text.lines().count(), 3, "{text}");

    let (filtered, _) = run(
        &root,
        &[
            "--json", "ls", "--status", "idle", "--tag", "area=cli", "--since", "100000d",
            "--limit", "3",
        ],
    );
    assert!(filtered.status.success(), "combined filters failed: {filtered:?}");
    let filtered: Value = serde_json::from_slice(&filtered.stdout).unwrap();
    assert_eq!(filtered["sessions"].as_array().map(Vec::len), Some(3));

    let (recent, _) = run(&root, &["--json", "ls", "--since", "1h"]);
    assert!(recent.status.success(), "since filter failed: {recent:?}");
    let recent: Value = serde_json::from_slice(&recent.stdout).unwrap();
    assert_eq!(recent["sessions"].as_array().map(Vec::len), Some(1));

    // Leo, 2026-10-29: "are the tools/commands/docs/etc clear and good enough for you guys? i
    // feel like they could be better". A busy host's `ls` is thousands of rows: `--live`,
    // `--name` and `--host` narrow it, the same in text and JSON.
    let (live, _) = run(&root, &["--json", "ls", "--live", "--fields", "name,status"]);
    assert!(live.status.success(), "--live failed: {live:?}");
    let live: Value = serde_json::from_slice(&live.stdout).unwrap();
    let live = live["sessions"].as_array().unwrap();
    assert_eq!(live.len(), 2_700);
    assert!(live.iter().all(|s| s["status"] != "closed"));
    let (named, _) = run(&root, &["--json", "ls", "--name", "^lane-29[0-9][0-9]$", "--live"]);
    let named: Value = serde_json::from_slice(&named.stdout).unwrap();
    assert_eq!(named["sessions"].as_array().map(Vec::len), Some(90));
    let (here, _) = run(&root, &["--json", "ls", "--host", "local", "--limit", "5"]);
    let here: Value = serde_json::from_slice(&here.stdout).unwrap();
    assert_eq!(here["sessions"].as_array().map(Vec::len), Some(5));
    let (elsewhere, _) = run(&root, &["--json", "ls", "--host", "no-such-peer"]);
    let elsewhere: Value = serde_json::from_slice(&elsewhere.stdout).unwrap();
    assert_eq!(elsewhere["sessions"].as_array().map(Vec::len), Some(0));
    let (bad, _) = run(&root, &["ls", "--name", "("]);
    assert_eq!(bad.status.code(), Some(2), "a bad pattern is a usage error: {bad:?}");
    let (text, _) = run(&root, &["ls", "--name", "^lane-299[0-9]$"]);
    let text = String::from_utf8_lossy(&text.stdout);
    assert_eq!(text.lines().count(), 11, "a header and every match, closed too: {text}");

    // With no filter, the text view is the live sessions, capped, and says what it left out.
    let (compact, _) = run(&root, &["ls"]);
    assert!(compact.status.success(), "compact ls failed: {compact:?}");
    let compact = String::from_utf8_lossy(&compact.stdout);
    let lines: Vec<&str> = compact.lines().collect();
    assert_eq!(lines.len(), 42, "a header, 40 rows and the note: {compact}");
    assert!(lines[1].starts_with("lane-2999 "), "{compact}");
    assert!(!compact.contains("closed  "), "{compact}");
    assert_eq!(
        lines[41],
        "2660 more live and 300 closed not shown: --all lists every session; --live, --name \
REGEX, --host HOST, --status S or --limit N narrow it"
    );
    let (all, _) = run(&root, &["ls", "--all"]);
    assert_eq!(String::from_utf8_lossy(&all.stdout).lines().count(), 3_001);
}
