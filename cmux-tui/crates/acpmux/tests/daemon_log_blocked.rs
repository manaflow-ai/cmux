//! A daemon whose log output takes no bytes still answers (`log_sink.rs`). aws-m4pro-5,
//! 2026-11-10: a daemon whose stdout was a pipe nobody read answered no `acpmux ls` for
//! 2 h 41 min, its request waiting on a lock held by a thread that logged.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

/// More connections than a full pipe holds the debug lines of ("client connected" and
/// "client disconnected", about 150 bytes each, against 64 KiB).
const CONNECTIONS: usize = 2000;

async fn status(socket: &std::path::Path) -> Value {
    let s = tokio::net::UnixStream::connect(socket).await.expect("connect to daemon socket");
    let (rd, mut wr) = s.into_split();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}});
    wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    let mut lines = tokio::io::BufReader::new(rd).lines();
    loop {
        let line = lines.next_line().await.unwrap().expect("daemon closed the socket");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_daemon_whose_log_output_takes_no_bytes_answers() {
    let _ = &HERMETIC;
    let dir = std::env::temp_dir().join(format!("amx-lb-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    std::fs::create_dir_all(&home).unwrap();
    let socket = dir.join("s.sock");
    let mut child = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--ready-fd", "1", "--log", "debug"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    // Read up to the readiness line, then never again: the pipe fills and stays full.
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let ready = tokio::task::spawn_blocking(move || {
        let mut line = String::new();
        loop {
            line.clear();
            if stdout.read_line(&mut line).unwrap_or(0) == 0 {
                return (false, stdout);
            }
            if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true) {
                return (true, stdout);
            }
        }
    });
    let (ready, _unread) =
        tokio::time::timeout(Duration::from_secs(30), ready).await.unwrap().unwrap();
    assert!(ready, "the daemon became ready");
    let mut answered = 0;
    for n in 0..CONNECTIONS {
        let reply = tokio::time::timeout(Duration::from_secs(10), status(&socket)).await;
        match reply {
            Ok(v) => {
                assert!(v.get("error").is_none(), "status failed: {v}");
                answered += 1;
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                panic!("request {n} had no answer in 10 s while the log output took no bytes");
            }
        }
    }
    assert_eq!(answered, CONNECTIONS);
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
