//! `cmux automation … --target cloud` through the real binary against a fake
//! cmux app: every verb is one `cloud.automation` call, a create makes a
//! `chief` body for the default Cloud Chief's main conversation, a mutation
//! carries an idempotency key, and a plan refusal prints its checkout link and
//! exits 4 (docs/automations-platonic-ideal.md, Cloud slice).
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn temp_dir(label: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = Path::new("/tmp").join(format!("cmux-{label}-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

static CREATES: AtomicUsize = AtomicUsize::new(0);

/// A fake app: one Cloud Chief; the first `automation.create` succeeds, the
/// second answers the free plan's refusal with a checkout link.
fn answer(request: &Value) -> Value {
    if request["method"] != "cloud.automation" {
        return json!({"id": request["id"], "ok": true, "result": {"pong": true}});
    }
    let p = &request["params"];
    let value = match p["op"].as_str().unwrap_or("") {
        "chief.list" => json!({"ok": true, "value": {"chiefs": [
            {"id": "agent_01J0000000000000000000000A", "is_default": true, "archived_at": null, "main_conversation": "conv_main"}
        ], "tombstones": []}}),
        "automation.create" => {
            if CREATES.fetch_add(1, Ordering::SeqCst) == 0 {
                json!({"ok": true, "value": {"id": "auto_aaaaaaaaaaaaaaaaaaaa", "name": p["params"]["name"], "enabled": true,
                       "triggers": [{"spec": p["params"]["triggers"][0]}], "next_run_at": 1_793_350_800_000_i64}})
            } else {
                json!({"ok": false, "error": {"code": "automation.plan.required", "message": "the free plan has 1 Cloud job",
                       "details": {"plan": "pro", "checkout": "https://api.test/v1/billing/plan/abc.def"}}})
            }
        }
        "automation.list" => json!({"ok": true, "value": {"automations": [
            {"id": "auto_aaaaaaaaaaaaaaaaaaaa", "name": "Morning brief", "enabled": true, "triggers": [], "next_run_at": null}
        ]}}),
        "automation.run" => {
            json!({"ok": true, "value": {"id": "run_bbbbbbbbbbbbbbbbbbbb", "state": "queued"}})
        }
        other => {
            json!({"ok": false, "error": {"code": "automation.op_not_allowed", "message": other}})
        }
    };
    json!({"id": request["id"], "ok": true, "result": value})
}

fn fake_app(socket: &Path, done: Arc<AtomicBool>) -> std::thread::JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let received = Arc::new(Mutex::new(Vec::<Value>::new()));
    std::thread::spawn(move || {
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut writer = stream;
                    let mut line = String::new();
                    while reader.read_line(&mut line).unwrap_or(0) > 0 {
                        let request: Value = serde_json::from_str(&line).unwrap();
                        line.clear();
                        let response = answer(&request);
                        received.lock().unwrap().push(request);
                        if writeln!(writer, "{response}").is_err() {
                            break;
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    if done.load(Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) => panic!("accept: {e}"),
            }
        }
        received.lock().unwrap().clone()
    })
}

fn cmux(dir: &Path, app: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--app-socket")
        .arg(app)
        .args(args)
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .env("HOME", dir)
        .env("TZ", "America/Los_Angeles")
        .env("CMUX_AUTOMATIONS_DIR", dir.join("store"))
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap()
}

fn text(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[test]
fn cloud_create_list_run_and_the_plan_refusal() {
    let dir = temp_dir("autocloud");
    let socket = dir.join("app.sock");
    let done = Arc::new(AtomicBool::new(false));
    let app = fake_app(&socket, done.clone());

    let made = cmux(
        &dir,
        &socket,
        &[
            "--json",
            "automation",
            "create",
            "Morning brief",
            "--target",
            "cloud",
            "--prompt",
            "Summarize merged PRs",
            "--weekdays",
            "09:00",
        ],
    );
    assert!(made.status.success(), "{}{}", text(&made.stdout), text(&made.stderr));
    let made: Value = serde_json::from_slice(&made.stdout).unwrap();
    assert_eq!(made["id"], "auto_aaaaaaaaaaaaaaaaaaaa");

    let second = cmux(
        &dir,
        &socket,
        &["automation", "create", "Second", "--target=cloud", "--prompt", "x", "--daily", "8:00"],
    );
    assert_eq!(second.status.code(), Some(4), "{}", text(&second.stderr));
    assert!(
        text(&second.stderr).contains("https://api.test/v1/billing/plan/abc.def"),
        "{}",
        text(&second.stderr)
    );

    let list = cmux(&dir, &socket, &["automation", "list", "--target", "cloud"]);
    assert!(list.status.success(), "{}", text(&list.stderr));
    assert!(text(&list.stdout).contains("Morning brief"));

    let run = cmux(&dir, &socket, &["automation", "run", "morning brief", "--target", "cloud"]);
    assert!(run.status.success(), "{}", text(&run.stderr));
    assert!(text(&run.stdout).contains("run_bbbbbbbbbbbbbbbbbbbb"));

    // Local-only schedules and shell commands are refused before any call.
    for args in [
        &["automation", "create", "X", "--target", "cloud", "--prompt", "x", "--every", "30m"][..],
        &["automation", "create", "X", "--target", "cloud", "--command", "true", "--daily", "9:00"],
        &["automation", "logs", "X", "--target", "cloud"],
    ] {
        assert_eq!(cmux(&dir, &socket, args).status.code(), Some(2), "{args:?}");
    }

    done.store(true, Ordering::Relaxed);
    let requests = app.join().unwrap();
    let ops: Vec<&Value> = requests
        .iter()
        .filter(|r| r["method"] == "cloud.automation")
        .map(|r| &r["params"])
        .collect();
    let create = ops.iter().find(|p| p["op"] == "automation.create").unwrap();
    assert_eq!(
        create["params"]["body"],
        json!({"type": "chief", "chief": "agent_01J0000000000000000000000A",
        "conversation": "conv_main", "prompt": "Summarize merged PRs"})
    );
    assert_eq!(
        create["params"]["triggers"][0],
        json!({"type": "cron", "expr": "0 9 * * 1-5", "tz": "America/Los_Angeles"})
    );
    assert!(create["idempotency_key"].as_str().is_some_and(|k| !k.is_empty()));
    let run = ops.iter().find(|p| p["op"] == "automation.run").unwrap();
    assert_eq!(run["params"]["automation"], "auto_aaaaaaaaaaaaaaaaaaaa");
    assert!(run["idempotency_key"].as_str().is_some());
    assert!(
        ops.iter()
            .filter(|p| p["op"] == "chief.list" || p["op"] == "automation.list")
            .all(|p| p.get("idempotency_key").is_none())
    );
    let _ = std::fs::remove_dir_all(&dir);
}
