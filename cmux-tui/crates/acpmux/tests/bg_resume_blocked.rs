//! The start's pass over background-task records (`hub/bg_notify.rs`, `bg_notify_resume`)
//! never holds the session list. On the owner's Mac (2026-11-11) it read 6,043 records in 182
//! chat folders before the store was marked ready: 92-115 ms warm, 8.9 s cold on a fleet Mac's
//! disk, and every request that needs the whole list (`acpmux ls`, names) and the adoption of
//! running agents waited on it. Here one record never finishes reading (a named pipe).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

async fn sessions(socket: &std::path::Path) -> Value {
    let s = tokio::net::UnixStream::connect(socket).await.expect("connect to daemon socket");
    let (rd, mut wr) = s.into_split();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/sessions", "params": {}});
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
async fn a_background_record_that_reads_slowly_does_not_hold_the_session_list() {
    let _ = &HERMETIC;
    let dir = std::env::temp_dir().join(format!("amx-bgr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let home = dir.join("home");
    let folder = home.join("bg").join("01a1c916-0000-7000-8000-000000000001");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join(".generation"), "g1").unwrap();
    let fifo =
        std::ffi::CString::new(folder.join("bg-0001.json").into_os_string().into_encoded_bytes())
            .unwrap();
    // SAFETY: a valid NUL-terminated path; mkfifo only reads it.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0, "mkfifo");
    let socket = dir.join("s.sock");
    let mut child = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--ready-fd", "1"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let ready = tokio::task::spawn_blocking(move || {
        let mut line = String::new();
        loop {
            line.clear();
            if stdout.read_line(&mut line).unwrap_or(0) == 0 {
                return false;
            }
            if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true) {
                // Drained after the ready line, so no log write ever waits on this pipe.
                std::thread::spawn(move || while stdout.read_line(&mut line).unwrap_or(0) > 0 {});
                return true;
            }
        }
    });
    let ready = tokio::time::timeout(Duration::from_secs(30), ready).await.unwrap().unwrap();
    assert!(ready, "the daemon became ready");
    let reply = tokio::time::timeout(Duration::from_secs(10), sessions(&socket)).await;
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);
    let reply = reply.expect("the session list answered in 10 s while a background record read");
    assert!(reply["result"]["sessions"].is_array(), "{reply}");
}
