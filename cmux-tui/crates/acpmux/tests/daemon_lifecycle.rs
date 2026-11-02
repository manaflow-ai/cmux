//! The real daemon binary: it binds and answers before the login shell
//! environment is imported, reports readiness on a descriptor, serves a
//! `127.0.0.1:0` listen address, applies the imported environment to
//! agents, and stops promptly on SIGTERM.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

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
    // A login shell that takes 2 s (under the 3 s limit) and exports one variable.
    let shell = dir.join("slowsh");
    write_executable(
        &shell,
        "#!/bin/sh\nsleep 2\nprintf 'SSL_CERT_DIR=/amx-test-imported\\0'\nexec env -0\n",
    );
    let socket = dir.join("s.sock");
    let started = Instant::now();
    let mut child = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "1")
        .env("SHELL", &shell)
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
    // Bound and ready before the 2 s login shell finishes.
    assert!(started.elapsed() < Duration::from_secs(2), "ready after {:?}", started.elapsed());
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
    assert!(started.elapsed() < Duration::from_secs(2), "status after {:?}", started.elapsed());
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
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "env: SSL_CERT_DIR"}]}),
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
    assert_eq!(texts, ["SSL_CERT_DIR=/amx-test-imported"]);
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
    let mut cmd = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "3"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
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

/// A home, socket and TMPDIR so deep that the configured socket path is past
/// the Unix socket limit (a CI worker's long TMPDIR): the daemon still binds,
/// at a short alias, and a client given the same long path reaches it.
#[tokio::test]
async fn a_socket_path_past_the_unix_limit_still_serves() {
    let dir = scratch("long").join("d".repeat(110));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    assert!(socket.as_os_str().len() > 104, "the path must be past the limit");
    let mut child = daemon_env::acpmux(&dir)
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("TMPDIR", &dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let ready = tokio::task::spawn_blocking(move || {
        BufReader::new(stdout).lines().map_while(Result::ok).find_map(|line| {
            serde_json::from_str::<Value>(&line).ok().filter(|v| v["ready"] == true)
        })
    });
    let ready = tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();
    let Some(ready) = ready else {
        let _ = child.kill();
        panic!("the daemon exited without a readiness line: {:?}", child.wait());
    };
    let bound = PathBuf::from(ready["socket"].as_str().unwrap());
    assert!(bound.as_os_str().len() <= 103, "bound past the limit: {}", bound.display());
    // A client knows only the long path.
    let out = daemon_env::acpmux(&dir)
        .args(["daemon", "shutdown"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("TMPDIR", &dir)
        .output()
        .unwrap();
    let exited = (0..200).find_map(|_| {
        let status = child.try_wait().unwrap();
        if status.is_none() {
            std::thread::sleep(Duration::from_millis(50));
        }
        status
    });
    if exited.is_none() {
        let _ = child.kill();
        let _ = child.wait();
    }
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(exited.is_some(), "the client's shutdown did not reach the daemon");
    assert!(!bound.exists(), "the short socket stayed after shutdown");
}

/// A state write that fails while the daemon loads (huge-blue, 2026-10-25:
/// `write .../daemon.tmp-N-0: No space left on device`) must not stop it. The
/// pid file's path is a folder here, so every write of it fails; the daemon
/// still reports ready, answers, leaves no temporary file behind (a full
/// disk keeps none of them), and stops cleanly on SIGTERM.
#[tokio::test]
async fn a_failed_state_write_while_loading_leaves_the_daemon_serving() {
    let dir = scratch("nospc");
    std::fs::create_dir_all(dir.join("daemon.pid")).unwrap();
    let socket = dir.join("s.sock");
    let mut child = daemon_env::acpmux(&dir)
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let pid = child.id() as i32;
    let stdout = child.stdout.take().unwrap();
    let ready = tokio::task::spawn_blocking(move || {
        BufReader::new(stdout).lines().map_while(Result::ok).find_map(|line| {
            serde_json::from_str::<Value>(&line).ok().filter(|v| v["ready"] == true)
        })
    });
    let ready = tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();
    let Some(ready) = ready else {
        let _ = child.kill();
        panic!("the daemon exited on a failed pid file write: {:?}", child.wait());
    };
    assert_eq!(ready["pid"], pid);
    let mut rpc = Rpc::connect(&socket).await;
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert_eq!(status["pid"], pid, "{status}");
    // Past the first retries (1 s, then 2 s): still up, still answering.
    tokio::time::sleep(Duration::from_millis(3_500)).await;
    assert!(child.try_wait().unwrap().is_none(), "the daemon exited while retrying");
    let status = rpc.call("_acpmux/status", json!({})).await;
    assert_eq!(status["pid"], pid, "{status}");
    unsafe {
        libc::kill(pid, libc::SIGTERM);
    }
    let term = Instant::now();
    let code = loop {
        if let Some(code) = child.try_wait().unwrap() {
            break code;
        }
        if term.elapsed() > Duration::from_secs(8) {
            let _ = child.kill();
            panic!("daemon still running 8 s after SIGTERM");
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    assert!(code.success(), "{code:?}");
    // The shutdown ended the retries before it exited: nothing writes now.
    let left: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.starts_with("daemon.tmp-"))
        .collect();
    assert!(left.is_empty(), "failed writes left temporary files: {left:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Starts a daemon on its own home `dir` whose owning app is `owner` (`ACPMUX_OWNER_APP_PID`, as
/// the app's launcher sets it) and waits for its ready line. `harness`: a stand-in agent config.
async fn owned_daemon(dir: &Path, owner: u32, harness: bool) -> std::process::Child {
    let socket = dir.join("s.sock");
    let mut cmd = if harness {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        std::fs::write(
            dir.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
        )
        .unwrap();
        daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
    } else {
        daemon_env::acpmux(dir)
    };
    let mut child = cmd
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("TMPDIR", dir)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("ACPMUX_OWNER_APP_PID", owner.to_string())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let ready = tokio::task::spawn_blocking(move || {
        BufReader::new(stdout).lines().map_while(Result::ok).find_map(|line| {
            serde_json::from_str::<Value>(&line).ok().filter(|v| v["ready"] == true)
        })
    });
    let ready = tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();
    if ready.is_none() {
        let _ = child.kill();
        panic!("the daemon exited without a readiness line: {:?}", child.wait());
    }
    child
}

/// Waits up to `limit` for `child` to exit; kills it (and returns None) when it does not.
async fn exits_within(
    child: &mut std::process::Child,
    limit: Duration,
) -> Option<std::process::ExitStatus> {
    let start = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        if start.elapsed() > limit {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn end(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Quit leaves no helper processes (P0 journey quit-leaves-no-helpers: 5 s after a quit the app's
/// acpmux still ran). The app starts its daemon detached so durable agents outlive it, and names
/// itself in `ACPMUX_OWNER_APP_PID`. With a fake app (a `sleep` child): the daemon stays while the
/// app runs and while a client is connected, and stops soon after the app is gone and the last
/// client left, with no agent, turn or task to keep it.
#[tokio::test]
async fn quit_helpers_a_daemon_stops_soon_after_its_app_is_gone_and_its_last_client_left() {
    let dir = scratch("own");
    let mut owner = std::process::Command::new("sleep").arg("600").spawn().expect("a fake app");
    let mut child = owned_daemon(&dir, owner.id(), false).await;
    // The app runs, no client: the daemon stays.
    tokio::time::sleep(Duration::from_secs(4)).await;
    if child.try_wait().unwrap().is_some() {
        end(&mut owner);
        panic!("the daemon exited while its app runs");
    }
    // A client connects; then the app quits. The client keeps the daemon.
    let mut client = Rpc::connect(&dir.join("s.sock")).await;
    client.call("_acpmux/status", json!({})).await;
    end(&mut owner);
    tokio::time::sleep(Duration::from_secs(4)).await;
    if child.try_wait().unwrap().is_some() {
        panic!("the daemon exited while a client was connected");
    }
    // The last client leaves: nothing keeps the daemon.
    drop(client);
    let exited = exits_within(&mut child, Duration::from_secs(15)).await;
    let _ = std::fs::remove_dir_all(&dir);
    let status =
        exited.expect("the daemon still ran 15 s after its app was gone and its last client left");
    assert!(status.success(), "the daemon did not stop normally: {status:?}");
}

/// Keep Sessions Running (#29984): an agent still in its turn when the app quits keeps the daemon,
/// with no client connected, until the turn is over.
#[tokio::test]
async fn quit_helpers_a_running_turn_keeps_the_daemon_after_its_app_is_gone() {
    let dir = scratch("ownw");
    let mut owner = std::process::Command::new("sleep").arg("600").spawn().expect("a fake app");
    let mut child = owned_daemon(&dir, owner.id(), true).await;
    let socket = dir.join("s.sock");
    let mut rpc = Rpc::connect(&socket).await;
    let s = rpc
        .call(
            "session/new",
            json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "busy"}}}),
        )
        .await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // A turn that never ends: a busy agent.
    let line = json!({"jsonrpc": "2.0", "id": 99, "method": "session/prompt", "params": {"sessionId": id, "prompt": [{"type": "text", "text": "hang"}]}});
    rpc.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    let mut watcher = Rpc::connect(&socket).await;
    let start = Instant::now();
    while watcher.call("_acpmux/info", json!({"sessionId": id})).await["status"] != "running" {
        assert!(start.elapsed() < Duration::from_secs(20), "the turn never started");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    drop(watcher);
    drop(rpc);
    end(&mut owner);
    // No client and no app, but a turn runs: the daemon stays.
    tokio::time::sleep(Duration::from_secs(8)).await;
    let alive = child.try_wait().unwrap().is_none();
    end(&mut child);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(alive, "the daemon stopped under a running turn after its app quit");
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

/// An agent chat's agent runs the app's `cmux` and reaches the app (cx-c6xdh):
/// the app hands its daemon the bundled CLI (`CMUX_BUNDLED_CLI_PATH`) and its
/// control socket, and every agent finds that CLI first on its `PATH`, ahead
/// of the login shell's entries (where an older `cmux` may live), with the
/// socket that names the app.
#[tokio::test]
async fn an_agent_runs_the_apps_bundled_cmux_and_reaches_the_app() {
    let dir = scratch("cli");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    std::fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    let bundled = dir.join("cmux.app/Contents/Resources/bin");
    std::fs::create_dir_all(&bundled).unwrap();
    write_executable(bundled.join("cmux"), "#!/bin/sh\necho bundled\n");
    // The app's URL opener (scripts/cmux-next/url-open/cmux-open-url): an
    // agent's `BROWSER`, as in the app's terminals, so a sign-in page a tool
    // opens (`gh auth login`, `aws sso login`, Python's webbrowser) lands in a
    // cmux tab, and prezto's `.zprofile` (`BROWSER=open` when unset) in the
    // agent's `zsh -lc` keeps it.
    write_executable(bundled.join("cmux-open-url"), "#!/bin/sh\nexit 0\n");
    // The app's agent zsh layer (Resources/cmux-cli-path/zsh-agent): the
    // agent's own `zsh -lc` runs the user's .zprofile, which may put the old
    // `cmux` first again; the layer moves the bundled one back after it.
    let agent_zsh = dir.join("cmux.app/Contents/Resources/cmux-cli-path/zsh-agent");
    std::fs::create_dir_all(&agent_zsh).unwrap();
    std::fs::write(agent_zsh.join(".zshenv"), "# layer\n").unwrap();
    let user_zdotdir = dir.join("user-zdotdir");
    let login = dir.join("login-bin");
    std::fs::create_dir_all(&login).unwrap();
    write_executable(login.join("cmux"), "#!/bin/sh\necho stale\n");
    // The login shell lists its own `cmux` first.
    let shell = dir.join("loginsh");
    write_executable(
        &shell,
        format!("#!/bin/sh\nPATH='{}':\"$PATH\" exec env -0\n", login.display()),
    );
    let socket = dir.join("s.sock");
    let app_socket = dir.join("app.sock");
    let mut child = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "1")
        .env("SHELL", &shell)
        .env("CMUX_BUNDLED_CLI_PATH", bundled.join("cmux"))
        .env("CMUX_SOCKET_PATH", &app_socket)
        .env("CMUX_BUNDLE_ID", "com.cmuxterm.app.next.debug.cli")
        .env("ZDOTDIR", &user_zdotdir)
        .env_remove("BROWSER")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    tokio::task::spawn_blocking(move || {
        for line in BufReader::new(stdout).lines() {
            if serde_json::from_str::<Value>(&line.unwrap()).is_ok_and(|v| v["ready"] == true) {
                return;
            }
        }
        panic!("daemon exited without a readiness line");
    })
    .await
    .unwrap();

    let mut rpc = Rpc::connect(&socket).await;
    let s = rpc
        .call(
            "session/new",
            json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "cli"}}}),
        )
        .await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let mut answers = Vec::new();
    for name in [
        "PATH",
        "CMUX_SOCKET_PATH",
        "CMUX_BUNDLE_ID",
        "ZDOTDIR",
        "CMUX_CLI_AGENT_ZDOTDIR",
        "BROWSER",
    ] {
        rpc.call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("env: {name}")}]}),
        )
        .await;
        let events = rpc
            .call("_acpmux/events", json!({"sessionId": id, "kinds": ["agent_message_chunk"]}))
            .await;
        let seen: Vec<String> = events["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
            .map(str::to_owned)
            .collect();
        answers.push(seen.last().cloned().unwrap_or_default());
    }
    let seen = answers;
    let _ = child.kill();
    let _ = child.wait();
    let path = seen[0].strip_prefix("PATH=").unwrap_or_else(|| panic!("{seen:?}"));
    let first_cmux = path
        .split(':')
        .map(|entry| Path::new(entry).join("cmux"))
        .find(|candidate| candidate.is_file())
        .unwrap_or_else(|| panic!("no cmux on the agent's PATH: {path}"));
    assert_eq!(first_cmux, bundled.join("cmux"), "the agent's PATH: {path}");
    assert_eq!(seen[1], format!("CMUX_SOCKET_PATH={}", app_socket.display()));
    assert_eq!(seen[2], "CMUX_BUNDLE_ID=com.cmuxterm.app.next.debug.cli");
    assert_eq!(seen[3], format!("ZDOTDIR={}", agent_zsh.display()), "{seen:?}");
    assert_eq!(seen[4], format!("CMUX_CLI_AGENT_ZDOTDIR={}", user_zdotdir.display()), "{seen:?}");
    assert_eq!(seen[5], "BROWSER=cmux-open-url", "{seen:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Every path under `dir` (itself included) whose mode lets the group or
/// others write it, with that mode.
fn writable_by_others(dir: &Path) -> Vec<String> {
    use std::os::unix::fs::PermissionsExt;
    let mut found = Vec::new();
    let mut todo = vec![dir.to_path_buf()];
    while let Some(path) = todo.pop() {
        let Ok(meta) = std::fs::symlink_metadata(&path) else { continue };
        if meta.file_type().is_symlink() {
            continue;
        }
        let mode = meta.permissions().mode() & 0o777;
        if mode & 0o022 != 0 {
            found.push(format!("{mode:o} {}", path.display()));
        }
        if meta.is_dir() {
            todo.extend(std::fs::read_dir(&path).unwrap().map(|e| e.unwrap().path()));
        }
    }
    found.sort();
    found
}

/// `acpmux ARGS` for home `home` under umask 002.
fn umask_002_cli(dir: &Path, home: &Path, args: &[&str]) -> std::process::Output {
    use std::os::unix::process::CommandExt;
    let mut cmd = daemon_env::acpmux(dir);
    cmd.args(args)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null());
    // SAFETY: umask is async-signal-safe and changes only the child.
    unsafe {
        cmd.pre_exec(|| {
            libc::umask(0o002);
            Ok(())
        });
    }
    cmd.output().unwrap()
}

/// Shuts down the daemon of `home`, also when an assert failed.
struct ShutDown(PathBuf, PathBuf);

impl Drop for ShutDown {
    fn drop(&mut self) {
        let _ = umask_002_cli(&self.0, &self.1, &["daemon", "shutdown"]);
    }
}

/// A host whose umask is 002 (a Linux account in a shared group): the home and
/// the log a daemon start makes are owner-only all the same, nothing the daemon
/// makes in its home is writable by the group, and the next start finds
/// nothing to refuse (ergo-walk2, 2026-10-25: "daemon run/start on a host with
/// umask 002 -> refuses group-writable ~/.acpmux and daemon.log").
#[test]
fn a_daemon_started_under_umask_002_keeps_its_home_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch("umask");
    // Missing: `daemon start` makes it.
    let home = dir.join("h");
    let cli = |args: &[&str]| umask_002_cli(&dir, &home, args);
    let _stop = ShutDown(dir.clone(), home.clone());
    let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    for start in ["first", "second"] {
        let out = cli(&["daemon", "start"]);
        assert!(
            out.status.success(),
            "{start} start: {}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(mode(&home), 0o700, "{start} start: the home");
        assert_eq!(mode(&home.join("daemon.log")), 0o600, "{start} start: the log");
        let status = cli(&["daemon", "status"]);
        assert!(status.status.success(), "{}", String::from_utf8_lossy(&status.stderr));
        let shutdown = cli(&["daemon", "shutdown"]);
        assert!(shutdown.status.success(), "{}", String::from_utf8_lossy(&shutdown.stderr));
        let loose = writable_by_others(&home);
        assert!(loose.is_empty(), "{start} start left paths the group may write: {loose:?}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// `daemon run` for home `home` and socket `socket`, once it reported ready: its store on disk
/// and one stand-in agent harness configured.
async fn ready_daemon(dir: &Path, home: &Path, socket: &Path) -> std::process::Child {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    std::fs::write(
        home.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake", "permissionPolicy": "approve-all"}).to_string(),
    )
    .unwrap();
    let mut output_log = std::fs::File::create(dir.join("daemon.stdout.log")).unwrap();
    let error_log = std::fs::File::create(dir.join("daemon.stderr.log")).unwrap();
    let mut child = daemon_env::command(dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::from(error_log))
        .spawn()
        .unwrap();
    // Keep draining the daemon's readiness pipe after the first line. The daemon logs to the
    // inherited stream too; closing it after readiness produced BrokenPipe errors during shutdown.
    // Keep both output streams for a failure diagnostic, outside the home these tests remove.
    let stdout = child.stdout.take().unwrap();
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    tokio::task::spawn_blocking(move || {
        let mut ready_tx = Some(ready_tx);
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = writeln!(output_log, "{line}");
            if let Ok(value) = serde_json::from_str::<Value>(&line)
                && value["ready"] == true
                && let Some(tx) = ready_tx.take()
            {
                let _ = tx.send(());
            }
        }
    });
    let ready = tokio::time::timeout(Duration::from_secs(20), ready_rx).await;
    match ready {
        Ok(Ok(())) => {}
        Ok(Err(_)) => {
            let _ = child.kill();
            panic!("the daemon exited without a readiness line: {:?}", child.wait());
        }
        Err(_) => {
            let _ = child.kill();
            panic!("the daemon did not report readiness in time: {:?}", child.wait());
        }
    }
    child
}

/// The daemon's exit status within `budget`; it is killed when it is still running then.
async fn exit_within(
    child: &mut std::process::Child,
    budget: Duration,
) -> Option<std::process::ExitStatus> {
    let start = Instant::now();
    while start.elapsed() < budget {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let _ = child.kill();
    let _ = child.wait();
    None
}

/// A test harness that removes its temporary home also ends the daemon it started there
/// (cosmic-gray, 2026-10-29: two nightly daemons ran 8 days under a removed Python `mkdtemp`
/// home). The daemon stops normally, with a live chat, and its shutdown's last saves never make
/// the removed home again.
#[tokio::test]
async fn a_daemon_whose_home_is_removed_stops() {
    let dir = scratch("gone");
    let home = dir.join("h");
    std::fs::create_dir(&home).unwrap();
    let socket = home.join("s.sock");
    let mut child = ready_daemon(&dir, &home, &socket).await;
    let mut rpc = Rpc::connect(&socket).await;
    rpc.call(
        "session/new",
        json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "gone"}}}),
    )
    .await;
    std::fs::remove_dir_all(&home).unwrap();
    let status = exit_within(&mut child, acpmux::daemon::EXIT_BUDGET).await;
    let status = status.expect("the daemon still ran after its home was removed");
    assert!(status.success(), "{status:?}");
    assert!(!home.exists(), "the stopping daemon made its removed home again: {:?}", tree(&home));
    let _ = std::fs::remove_dir_all(&dir);
}

/// A home moved away and made again at the same path is another home: the daemon of the old
/// one stops, and never serves or locks the new one.
#[tokio::test]
async fn a_daemon_whose_home_is_replaced_stops() {
    let dir = scratch("swap");
    let home = dir.join("h");
    std::fs::create_dir(&home).unwrap();
    let socket = home.join("s.sock");
    let mut child = ready_daemon(&dir, &home, &socket).await;
    // The startup's own writes (the chat index, the model probes' folder) end first, so the
    // home is replaced under a daemon that only serves and stops. A write in that window is
    // `tests/lost_home_writes.rs`'s.
    let mut rpc = Rpc::connect(&socket).await;
    let started = Instant::now();
    while rpc.call("_acpmux/status", json!({})).await["loading"]["startupDone"] != true {
        assert!(started.elapsed() < Duration::from_secs(20), "the startup never ended");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    drop(rpc);
    std::fs::rename(&home, dir.join("h.old")).unwrap();
    std::fs::create_dir(&home).unwrap();
    let status = exit_within(&mut child, acpmux::daemon::EXIT_BUDGET).await;
    let status = status.expect("the daemon still ran after its home was replaced");
    assert!(status.success(), "{status:?}");
    assert!(!socket.exists(), "the old home's daemon bound the new home's socket");
    let left: Vec<_> = std::fs::read_dir(&home).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert!(left.is_empty(), "the old home's daemon wrote into the new home: {left:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Moving a parent changes no entry inside the home itself. It must still stop an idle daemon.
#[tokio::test]
async fn a_daemon_whose_home_ancestor_is_renamed_stops() {
    let dir = scratch("ancestor");
    let parent = dir.join("parent");
    let home = parent.join("h");
    std::fs::create_dir_all(&home).unwrap();
    let mut child = ready_daemon(&dir, &home, &home.join("s.sock")).await;
    std::fs::rename(&parent, dir.join("moved")).unwrap();
    let status = exit_within(&mut child, acpmux::daemon::EXIT_BUDGET).await;
    let status = status.expect("ancestor rename left the daemon running");
    assert!(
        status.success(),
        "ancestor rename exit {status:?}\nstdout:\n{}\nstderr:\n{}",
        std::fs::read_to_string(dir.join("daemon.stdout.log")).unwrap_or_default(),
        std::fs::read_to_string(dir.join("daemon.stderr.log")).unwrap_or_default(),
    );
    assert!(!parent.exists(), "shutdown recreated the renamed ancestor");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Replacing a symlink outside the original socket directory produces no event inside it.
#[tokio::test]
async fn a_daemon_whose_socket_ancestor_is_retargeted_stops() {
    let dir = scratch("retarget");
    let home = dir.join("h");
    let first = dir.join("first");
    let second = dir.join("second");
    for path in [&home, &first, &second] {
        std::fs::create_dir(path).unwrap();
    }
    let link = dir.join("link");
    std::os::unix::fs::symlink(&first, &link).unwrap();
    let mut child = ready_daemon(&dir, &home, &link.join("s.sock")).await;
    let replacement = dir.join("replacement");
    std::os::unix::fs::symlink(&second, &replacement).unwrap();
    std::fs::rename(replacement, &link).unwrap();
    let status = exit_within(&mut child, acpmux::daemon::EXIT_BUDGET).await;
    assert!(status.expect("retargeting a socket ancestor left the daemon running").success());
    assert_eq!(std::fs::read_dir(second).unwrap().count(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A socket removed on its own (a cleanup of the folder that holds it) under a daemon that still
/// holds its home and lock: the daemon binds it again and serves on, so commands reach it within
/// seconds. Before, a Mac daemon whose watch missed the removal ran on with the lock and no socket,
/// and every command waited out "holds daemon.lock but does not answer" (cosmic-gray, 2026-11-02);
/// one whose watch saw it stopped. Both layouts: the socket in the home (the default), and in a
/// folder of its own (on a Mac the socket is seen through its folder, cx-n1nrjk). A second removal
/// is bound again too.
#[tokio::test]
async fn a_daemon_whose_socket_is_removed_binds_it_again() {
    for (tag, own_folder) in [("sockgone", false), ("sockrun", true)] {
        let dir = scratch(tag);
        let home = dir.join("h");
        let run = dir.join("run");
        for path in [&home, &run] {
            std::fs::create_dir(path).unwrap();
        }
        let socket = if own_folder { run.join("s.sock") } else { home.join("s.sock") };
        let mut child = ready_daemon(&dir, &home, &socket).await;
        let pid =
            Rpc::connect(&socket).await.call("_acpmux/status", json!({})).await["pid"].clone();
        for round in 1..=2 {
            std::fs::remove_file(&socket).unwrap();
            let started = Instant::now();
            let status = loop {
                if let Ok(Ok(stream)) = tokio::time::timeout(
                    Duration::from_millis(500),
                    tokio::net::UnixStream::connect(&socket),
                )
                .await
                {
                    drop(stream);
                    break Rpc::connect(&socket).await.call("_acpmux/status", json!({})).await;
                }
                if let Some(exit) = child.try_wait().unwrap() {
                    panic!(
                        "{tag}: the daemon exited ({exit:?}) after its socket was removed (round {round})\nstderr:\n{}",
                        std::fs::read_to_string(dir.join("daemon.stderr.log")).unwrap_or_default()
                    );
                }
                assert!(
                    started.elapsed() < Duration::from_secs(5),
                    "{tag}: no daemon answered at the socket 5 s after it was removed (round {round})"
                );
                tokio::time::sleep(Duration::from_millis(50)).await;
            };
            assert_eq!(status["pid"], pid, "{tag}: another daemon answered (round {round})");
        }
        assert!(child.try_wait().unwrap().is_none(), "{tag}: the daemon stopped");
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// The acquired identity is a startup boundary: replacement must not receive config/store writes.
// The deterministic lock-held marker exists only in debug daemon builds.
#[cfg(debug_assertions)]
#[tokio::test]
async fn a_home_replaced_after_lock_acquisition_receives_no_startup_writes() {
    let dir = scratch("startup-swap");
    let home = dir.join("h");
    std::fs::create_dir(&home).unwrap();
    let mut child = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("ACPMUX_TEST_HOLD_AFTER_LOCK", "1")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let replacement_home = home.clone();
    let old_home = dir.join("old");
    let replaced = tokio::task::spawn_blocking(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if line == "acpmux-test-lock-held" {
                std::fs::rename(&replacement_home, old_home).unwrap();
                std::fs::create_dir(&replacement_home).unwrap();
                return true;
            }
        }
        false
    });
    let status = exit_within(&mut child, acpmux::daemon::EXIT_BUDGET).await;
    assert!(replaced.await.unwrap(), "startup seam was not reached");
    assert!(!status.expect("startup did not stop").success());
    assert_eq!(std::fs::read_dir(&home).unwrap().count(), 0, "startup wrote into the replacement");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A command whose `ACPMUX_SOCKET` is not the socket its home's running daemon serves fails at
/// once, naming the one it serves, instead of starting a daemon that waits out the handover
/// budget on the lock that daemon holds. A listing, which never starts one, fails as fast instead of waiting out
/// the budget for a socket that daemon will never serve.
#[tokio::test]
async fn a_socket_the_homes_daemon_does_not_serve_fails_fast() {
    let dir = scratch("other");
    let home = dir.join("h");
    std::fs::create_dir(&home).unwrap();
    let socket = home.join("acpmux.sock");
    let mut child = ready_daemon(&dir, &home, &socket).await;
    let wrong = home.join("other.sock");
    let started = Instant::now();
    let out = daemon_env::acpmux(&dir)
        .args(["ls"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &wrong)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let took = started.elapsed();
    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
    let stopped = exit_within(&mut child, acpmux::daemon::EXIT_BUDGET).await;
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "{stderr}");
    assert!(stderr.contains(&format!("serves {}", socket.display())), "{stderr}");
    assert!(took < acpmux::daemon::HANDOVER_BUDGET, "failed after {took:?}");
    assert!(stopped.is_some(), "the daemon did not stop on SIGTERM");

    // The home's daemon serves a socket of its own choosing, and the command asks for the
    // home's default one: the socket the lock records names it.
    let custom = home.join("custom.sock");
    let mut child = ready_daemon(&dir, &home, &custom).await;
    let started = Instant::now();
    let out = daemon_env::acpmux(&dir)
        .args(["ls"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let took = started.elapsed();
    unsafe {
        libc::kill(child.id() as i32, libc::SIGTERM);
    }
    let stopped = exit_within(&mut child, acpmux::daemon::EXIT_BUDGET).await;
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "{stderr}");
    assert!(stderr.contains(&format!("serves {}", custom.display())), "{stderr}");
    assert!(took < acpmux::daemon::HANDOVER_BUDGET, "failed after {took:?}");
    assert!(stopped.is_some(), "the daemon did not stop on SIGTERM");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A command whose `ACPMUX_HOME` is missing (a test's removed temporary home) starts no daemon
/// and does not make the folder again: a daemon there would run beside the one still on the
/// removed files.
/// (`chats list` starts a daemon when none runs; a listing, `ls`, never does.)
#[test]
fn a_command_in_a_missing_home_starts_no_daemon() {
    let dir = scratch("nohome");
    let home = dir.join("tmp7uxt3tq_/.acpmux");
    let out = daemon_env::acpmux(&dir)
        .args(["chats", "list"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", home.join("acpmux.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "{stderr}");
    assert!(stderr.contains("does not exist"), "{stderr}");
    assert!(!dir.join("tmp7uxt3tq_").exists(), "the command made the removed home again");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The same with a systemd unit installed (a Linux machine running `acpmux.service`): the
/// command refuses before it asks systemd anything, since starting the unit for that home would
/// make it again (review of #27796).
#[cfg(target_os = "linux")]
#[test]
fn a_command_in_a_missing_home_starts_no_systemd_unit() {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch("nounit");
    let home = dir.join("tmp7uxt3tq_/.acpmux");
    let bin = dir.join("bin");
    std::fs::create_dir(&bin).unwrap();
    let asked = dir.join("systemctl-asked");
    let systemctl = bin.join("systemctl");
    std::fs::write(
        &systemctl,
        format!("#!/bin/sh\necho \"$@\" >> '{}'\necho loaded\nexit 0\n", asked.display()),
    )
    .unwrap();
    std::fs::set_permissions(&systemctl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
    let out = daemon_env::acpmux(&dir)
        .args(["chats", "list"])
        .env("PATH", path)
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", home.join("acpmux.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "{stderr}");
    assert!(stderr.contains("does not exist"), "{stderr}");
    assert!(!asked.exists(), "systemctl was asked: {:?}", std::fs::read_to_string(&asked));
    assert!(!dir.join("tmp7uxt3tq_").exists(), "the command made the removed home again");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `ACPMUX_SOCKET` alone names another home's daemon (the Chief's): with that daemon down, a
/// command fails at once, naming the socket and its own home's, instead of starting a daemon
/// under this home's lock for that socket and waiting out the handover budget on it.
#[test]
fn a_socket_without_its_home_starts_no_daemon() {
    let dir = scratch("lone");
    let elsewhere = dir.join("chief");
    std::fs::create_dir(&elsewhere).unwrap();
    let socket = elsewhere.join("acpmux.sock");
    let out = daemon_env::acpmux(&dir)
        .args(["chats", "list"])
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "{stderr}");
    assert!(stderr.contains("share one home"), "{stderr}");
    assert!(stderr.contains(&socket.display().to_string()), "{stderr}");
    let default_home = daemon_env::home(&dir).join(".acpmux");
    assert!(
        !default_home.join("daemon.lock").exists(),
        "a daemon was started in {}",
        default_home.display()
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// Every path under `dir`, for a failure message.
fn tree(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut todo = vec![dir.to_path_buf()];
    while let Some(path) = todo.pop() {
        if let Ok(entries) = std::fs::read_dir(&path) {
            todo.extend(entries.map_while(Result::ok).map(|e| e.path()));
        }
        found.push(path);
    }
    found.sort();
    found
}
