//! The daemon raises its soft open-file limit at start. launchd starts it
//! with a soft RLIMIT_NOFILE of 256; on cmux16 (2026-10-22) a daemon with a few
//! hundred sessions used all 256 and every agent start failed with "Too many
//! open files (os error 24)". The agents it starts inherit the raised limit.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const LAUNCHD_SOFT: u64 = 256;

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

/// The daemon, stopped and reaped however the test ends.
struct Daemon(std::process::Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the pid is this test's own child.
        unsafe { libc::kill(self.0.id() as i32, libc::SIGTERM) };
        let _ = self.0.wait();
    }
}

fn hard_limit() -> u64 {
    let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) }, 0);
    lim.rlim_max
}

#[tokio::test]
async fn daemon_started_with_launchds_256_raises_it_for_itself_and_its_agents() {
    if hard_limit() <= LAUNCHD_SOFT {
        eprintln!("skip: this host's hard open-file limit is {}", hard_limit());
        return;
    }
    let dir = scratch("nofile");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    // The stand-in agent writes the open-file limit it started with, then runs
    // as the fake agent.
    let seen = dir.join("agent-nofile");
    let script = format!("ulimit -n > '{}'; exec python3 '{fake}'", seen.display());
    std::fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["/bin/sh", "-c", script]}},
               "defaultHarness": "fake", "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    let socket = dir.join("s.sock");
    let mut cmd = daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]);
    cmd.args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "warn"])
        .env("ACPMUX_HOME", &dir)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    // Start it the way launchd does: soft 256, hard as it was.
    unsafe {
        cmd.pre_exec(|| {
            let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
            if libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            lim.rlim_cur = LAUNCHD_SOFT as libc::rlim_t;
            if libc::setrlimit(libc::RLIMIT_NOFILE, &lim) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = Daemon(cmd.spawn().unwrap());
    let stdout = child.0.stdout.take().unwrap();
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
    tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();

    let mut rpc = Rpc::connect(&socket).await;
    let s = rpc
        .call(
            "session/new",
            json!({"cwd": dir, "mcpServers": [], "_meta": {"acpmux": {"name": "nofile"}}}),
        )
        .await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    rpc.call(
        "session/prompt",
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}]}),
    )
    .await;
    // The agent wrote the file before it answered the prompt.
    let text = std::fs::read_to_string(&seen).expect("the agent recorded its limit");
    drop(child);
    let _ = std::fs::remove_dir_all(&dir);

    let limit = text.trim();
    let raised = limit == "unlimited" || limit.parse::<u64>().is_ok_and(|n| n > LAUNCHD_SOFT);
    assert!(
        raised,
        "the agent started with an open-file limit of {limit}, launchd's {LAUNCHD_SOFT}"
    );
}
