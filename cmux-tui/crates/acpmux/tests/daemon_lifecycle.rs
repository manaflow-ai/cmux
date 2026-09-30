//! The real daemon binary: it binds and answers before the login shell
//! environment is imported, reports readiness on a descriptor, serves a
//! `127.0.0.1:0` listen address, applies the imported environment to
//! agents, and stops promptly on SIGTERM.
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
        }
    }
}

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[tokio::test]
async fn daemon_binds_before_login_env_reports_ready_and_stops_on_sigterm() {
    let dir = scratch("life");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    std::fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    // A login shell that takes 4 s and exports one variable.
    let shell = dir.join("slowsh");
    std::fs::write(&shell, "#!/bin/sh\nsleep 4\nprintf 'AMX_TEST_IMPORTED=yes\\0'\nexec env -0\n")
        .unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let socket = dir.join("s.sock");
    let started = Instant::now();
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "1")
        .env("SHELL", &shell)
        .env_remove("XPC_SERVICE_NAME")
        .env_remove("CLAUDECODE")
        .env_remove("AMX_TEST_IMPORTED")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let pid = child.id() as i32;
    let stdout = child.stdout.take().unwrap();
    let ready = tokio::task::spawn_blocking(move || {
        for line in BufReader::new(stdout).lines() {
            let line = line.unwrap();
            if let Ok(v) = serde_json::from_str::<Value>(&line)
                && v["ready"] == true
            {
                return v;
            }
        }
        panic!("daemon exited without a readiness line");
    });
    let ready = tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();
    // Bound and ready well before the 4 s login shell finishes.
    assert!(started.elapsed() < Duration::from_secs(3), "ready after {:?}", started.elapsed());
    assert_eq!(ready["pid"], pid);
    assert_eq!(ready["socket"], socket.to_string_lossy().as_ref());
    let listen = ready["listen"].as_str().unwrap().to_owned();
    assert!(listen.starts_with("127.0.0.1:") && !listen.ends_with(":0"), "{listen}");
    let mut tcp = std::net::TcpStream::connect(&listen).unwrap();
    tcp.write_all(b"GET /health HTTP/1.1\r\nhost: x\r\n\r\n").unwrap();
    let mut body = String::new();
    tcp.read_to_string(&mut body).unwrap();
    assert!(body.starts_with("HTTP/1.1 200") && body.ends_with("ok"), "{body}");

    let mut rpc = Rpc::connect(&socket).await;
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert!(started.elapsed() < Duration::from_secs(4), "status after {:?}", started.elapsed());
    assert_eq!(status["ready"], false);
    assert_eq!(status["loginEnv"], "pending");
    assert_eq!(status["listen"], listen);

    // Session creation waits for the import; the agent sees its variable.
    let s = rpc
        .call(
            "session/new",
            json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "env"}}}),
        )
        .await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    rpc.call(
        "session/prompt",
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "env: AMX_TEST_IMPORTED"}]}),
    )
    .await;
    let events = rpc
        .call("_acpmux/events", json!({"sessionId": id, "kinds": ["agent_message_chunk"]}))
        .await;
    let texts: Vec<&str> = events["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
        .collect();
    assert_eq!(texts, ["AMX_TEST_IMPORTED=yes"]);
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert_eq!(status["ready"], true);
    assert_eq!(status["loginEnv"], "imported");
    assert_eq!(status["liveAgents"], 1);

    // SIGTERM with a live agent: an orderly exit within the budget.
    let term = Instant::now();
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }
    let code = loop {
        if let Some(code) = child.try_wait().unwrap() {
            break code;
        }
        assert!(term.elapsed() < Duration::from_secs(8), "daemon still running after SIGTERM");
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert!(code.success(), "{code:?}");
    assert!(term.elapsed() < Duration::from_secs(4), "stopped after {:?}", term.elapsed());
    assert!(!socket.exists(), "socket removed on shutdown");
    let _ = std::fs::remove_dir_all(&dir);
}
