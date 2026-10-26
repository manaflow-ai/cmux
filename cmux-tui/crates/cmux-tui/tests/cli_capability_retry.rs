//! The public client's capability hello is before its resource command. A
//! dropped hello must heal the connection without declaring the unsent command
//! outcome unknown.
#![cfg(unix)]
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[test]
fn newtab_agent_identity_retries_a_dropped_capability_hello() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("cmux-hello-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let listener = transport::listen(&socket).unwrap();
    let worker = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for attempt in 0..2 {
            let mut stream = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut reader = BufReader::new(stream.try_clone_box().unwrap());
            let mut line = String::new();
            // A cleanup connection unblocks accept if the unfixed client exits.
            if reader.read_line(&mut line).unwrap() == 0 {
                return seen;
            }
            let hello: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(hello["cmd"], "set-client-info", "{hello}");
            seen.push(hello.clone());
            if attempt == 0 {
                continue;
            }
            writeln!(stream, "{}", json!({"id":hello["id"],"ok":true,"data":{}})).unwrap();
            stream.flush().unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            seen.push(request.clone());
            writeln!(
                stream,
                "{}",
                json!({"protocol":"cmux.protocol/2","type":"response",
                "id":request["id"],"ok":true,"result":[]})
            )
            .unwrap();
            stream.flush().unwrap();
        }
        seen
    });
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--json", "--socket"])
        .arg(&socket)
        .args(["tab", "list"])
        .env("CMUX_TEST_RETRY_BACKOFF_MS", "1")
        .env_remove("CMUX_CLI_NO_RETRY")
        .env_remove("CMUX_TUI_SOCKET")
        .output()
        .unwrap();
    drop(transport::connect(&socket));
    let seen = worker.join().unwrap();
    std::fs::remove_dir_all(dir).unwrap();
    assert!(
        output.status.success(),
        "dropped hello was not retried: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(seen.len(), 3, "two hellos and one resource command: {seen:?}");
    assert_eq!(seen[2]["operation"], "tab.list");
    assert_eq!(serde_json::from_slice::<Value>(&output.stdout).unwrap(), json!([]));
}
