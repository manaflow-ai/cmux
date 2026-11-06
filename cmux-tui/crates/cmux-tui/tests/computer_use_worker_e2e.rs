//! The real `cmux-tui __computer-use-worker` process, driven the way the
//! daemon and acpmux's bridge drive it: configure over its stdin, then an
//! agent over the Unix socket. The worker uses the in-memory desktop
//! (`CMUX_CU_FAKE_DESKTOP=1`, honored by debug builds only).
#![cfg(target_os = "linux")]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

fn line(reader: &mut impl BufRead) -> Value {
    let mut text = String::new();
    reader.read_line(&mut text).unwrap();
    serde_json::from_str(&text).unwrap_or(Value::Null)
}

#[test]
fn computer_use_worker_serves_agents_and_exits_when_stdin_closes() {
    let dir = std::env::temp_dir().join(format!("cu-e2e-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let socket = dir.join("run").join("cu.sock");
    let secret = "5a".repeat(32);
    let mut worker = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("__computer-use-worker")
        .env("CMUX_CU_FAKE_DESKTOP", "1")
        .env_remove("DISPLAY")
        .env_remove("WAYLAND_DISPLAY")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let mut control = worker.stdin.take().unwrap();
    let mut events = BufReader::new(worker.stdout.take().unwrap());
    writeln!(
        control,
        "{}",
        json!({"type": "configure", "config": {"mode": "approvedApps"}, "socket": socket,
               "secret": secret, "state_dir": dir.join("state"), "machine": "e2e"})
    )
    .unwrap();
    let ready = line(&mut events);
    assert_eq!(ready["type"], "ready", "{ready}");
    assert_eq!(ready["pid"], worker.id());

    // A peer without the secret is refused.
    let mut bad = UnixStream::connect(&socket).unwrap();
    bad.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    writeln!(bad, "{}", json!({"secret": "00".repeat(32)})).unwrap();
    assert_eq!(line(&mut BufReader::new(bad))["reason"], "bad secret");

    let agent = UnixStream::connect(&socket).unwrap();
    agent.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut answers = BufReader::new(agent.try_clone().unwrap());
    let mut agent = agent;
    writeln!(agent, "{}", json!({"secret": secret})).unwrap();
    assert_eq!(line(&mut answers)["ok"], true);
    writeln!(agent, "{}", json!({"id": 1, "method": "status"})).unwrap();
    let status = line(&mut answers);
    assert_eq!(status["result"]["body"]["machine"], "e2e", "{status}");
    assert_eq!(status["result"]["body"]["platform"]["os"], "fake");

    // Approved apps: the first use asks the host; "always" is saved.
    writeln!(
        agent,
        "{}",
        json!({"id": 2, "method": "tools/call", "name": "click", "session": "s",
        "label": "Claude", "call_id": "c-1", "arguments": {"window_id": "1", "element_id": "e1"}})
    )
    .unwrap();
    let ask = line(&mut events);
    assert_eq!(ask["type"], "ask", "{ask}");
    assert_eq!(ask["question"]["remember"], true);
    writeln!(control, "{}", json!({"type": "answer", "id": ask["id"], "answer": "always"}))
        .unwrap();
    let clicked = line(&mut answers);
    assert_eq!(clicked["id"], 2);
    assert_eq!(clicked["result"]["is_error"], false, "{clicked}");
    // The retry of the same call_id does not ask or click again.
    writeln!(
        agent,
        "{}",
        json!({"id": 3, "method": "tools/call", "name": "click", "session": "s",
        "call_id": "c-1", "arguments": {"window_id": "1", "element_id": "e1"}})
    )
    .unwrap();
    assert_eq!(line(&mut answers)["result"], clicked["result"]);
    let saved: Value =
        serde_json::from_slice(&std::fs::read(dir.join("state").join("approvals.json")).unwrap())
            .unwrap();
    assert_eq!(saved["always"], json!(["com.apple.Safari"]));

    // stdin closes: the worker stops serving and exits 0.
    drop(control);
    let status = worker.wait().unwrap();
    assert!(status.success(), "{status}");
    assert!(!socket.exists());
    let _ = std::fs::remove_dir_all(&dir);
}
