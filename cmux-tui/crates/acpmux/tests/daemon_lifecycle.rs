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
    write_executable(
        &shell,
        "#!/bin/sh\nsleep 4\nprintf 'AMX_TEST_IMPORTED=yes\\0'\nexec env -0\n",
    );
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
    tcp.write_all(b"GET /health HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n").unwrap();
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

/// Launched the way an app launcher can leave it: SIGTERM blocked in the
/// inherited signal mask and set to "ignore", in a new session, with the
/// readiness line on fd 3. Two agents are live (one mid-turn, one that
/// ignores SIGTERM), a client is attached and another watches. SIGTERM
/// must still stop the daemon and every agent within 5 s.
#[tokio::test]
async fn sigterm_is_bounded_with_busy_agents_and_attached_clients() {
    use std::os::fd::FromRawFd;
    use std::os::unix::process::CommandExt;
    let dir = scratch("term");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    std::fs::write(
        dir.join("config.json"),
        json!({"harnesses": {
            "fake": {"argv": ["python3", fake]},
            "stubborn": {"argv": ["python3", fake], "env": {"FAKE_IGNORE_TERM": "1"}}
        }, "defaultHarness": "fake", "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    let socket = dir.join("s.sock");
    let mut fds = [0i32; 2];
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    let (rfd, wfd) = (fds[0], fds[1]);
    let mut cmd = std::process::Command::new(env!("CARGO_BIN_EXE_acpmux"));
    cmd.args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "3"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env_remove("XPC_SERVICE_NAME")
        .env_remove("CLAUDECODE")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    unsafe {
        cmd.pre_exec(move || {
            libc::setsid();
            if libc::dup2(wfd, 3) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            libc::signal(libc::SIGTERM, libc::SIG_IGN);
            let mut set: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut set);
            libc::sigaddset(&mut set, libc::SIGTERM);
            libc::pthread_sigmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
            Ok(())
        });
    }
    let mut child = cmd.spawn().unwrap();
    unsafe { libc::close(wfd) };
    let pid = child.id() as i32;
    let ready = tokio::task::spawn_blocking(move || {
        let mut line = String::new();
        let f = unsafe { std::fs::File::from_raw_fd(rfd) };
        BufReader::new(f).read_line(&mut line).unwrap();
        line
    });
    let ready = tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();
    let ready: Value = serde_json::from_str(&ready).unwrap();
    assert_eq!(ready["pid"], pid);

    let mut rpc = Rpc::connect(&socket).await;
    let mut watcher = Rpc::connect(&socket).await;
    watcher.call("_acpmux/watch", json!({"enabled": true})).await;
    let mut agents = Vec::new();
    for (name, harness) in [("busy", "fake"), ("stubborn", "stubborn")] {
        let s = rpc
            .call(
                "session/new",
                json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": name, "harness": harness}}}),
            )
            .await;
        let id = s["sessionId"].as_str().unwrap().to_owned();
        let info = rpc.call("_acpmux/info", json!({"sessionId": id})).await;
        assert_eq!(info["status"], "ready", "{info}");
        agents.push(id);
    }
    // Agent pids: the daemon's children.
    let kids = std::fs::read_to_string(format!("/proc/{pid}/task/{pid}/children"))
        .ok()
        .map(|s| s.split_whitespace().filter_map(|p| p.parse::<i32>().ok()).collect::<Vec<_>>());
    // One agent is mid-turn; the prompt never returns.
    let line = json!({"jsonrpc": "2.0", "id": 99, "method": "session/prompt", "params": {"sessionId": agents[0], "prompt": [{"type": "text", "text": "hang"}]}});
    rpc.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    loop {
        let st = watcher.call("_acpmux/info", json!({"sessionId": agents[0]})).await;
        if st["status"] == "running" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    let term = Instant::now();
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }
    let code = loop {
        if let Some(code) = child.try_wait().unwrap() {
            break code;
        }
        if term.elapsed() > Duration::from_secs(12) {
            unsafe {
                libc::kill(pid, libc::SIGKILL);
            }
            let _ = child.wait();
            panic!("daemon still running 12 s after SIGTERM");
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let took = term.elapsed();
    assert!(code.success(), "{code:?}");
    assert!(took < Duration::from_secs(5), "stopped after {took:?}");
    // No agent survives the daemon.
    for k in kids.unwrap_or_default() {
        let alive = unsafe { libc::kill(k, 0) } == 0
            && std::fs::read_to_string(format!("/proc/{k}/stat"))
                .map(|s| !s.contains(") Z "))
                .unwrap_or(false);
        assert!(!alive, "agent {k} outlived the daemon");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// Creates an executable (0755) script without this process ever holding a
/// write descriptor for it.
///
/// Tests run on many threads. A sibling test that forks while this process
/// holds such a descriptor hands a copy to its child until that child execs,
/// and executing the script in that window fails with ETXTBSY ("Text file
/// busy"). `O_CLOEXEC` does not close that window, and a temp file plus a
/// rename does not either (the child holds the same inode). A short-lived
/// `sh` opens, writes, and closes the file in its own process, so no fork of
/// this process can inherit it. (The same helper as cmux-tui's `test_exec`.)
fn write_executable(path: impl AsRef<std::path::Path>, contents: impl AsRef<[u8]>) {
    use std::io::Write as _;
    use std::process::{Command, Stdio};
    let path = path.as_ref();
    let mut child = Command::new("/bin/sh")
        .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(contents.as_ref()).unwrap();
    assert!(child.wait().unwrap().success(), "could not write {}", path.display());
}
