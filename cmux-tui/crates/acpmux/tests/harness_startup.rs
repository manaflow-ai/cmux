//! A harness found only on the login shell's PATH (an app-launched daemon
//! starts with `/usr/bin:/bin`) reaches every client: `_acpmux/harnesses`
//! asked while the daemon is still starting answers with it, and a login
//! shell read in the background announces it as `_acpmux/harnesses_changed`.
//! Leo 2026-10-14: a New Tab opened as the daemon restarted said "No agent to
//! ask" with Claude and Codex installed, until the app relaunched.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

struct Client {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
    notes: Vec<Value>,
}

impl Client {
    async fn connect(path: &Path) -> Self {
        let s = tokio::net::UnixStream::connect(path).await.expect("connect to daemon socket");
        let (rd, wr) = s.into_split();
        Self { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0, notes: Vec::new() }
    }

    async fn line(&mut self, wait: Duration) -> Option<Value> {
        let line = tokio::time::timeout(wait, self.lines.next_line()).await.ok()?.ok()??;
        serde_json::from_str(&line).ok()
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        loop {
            let v = self.line(Duration::from_secs(30)).await.expect("daemon answered in time");
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{method} failed: {v}");
                return v["result"].clone();
            }
            self.notes.push(v);
        }
    }

    /// The first `_acpmux/harnesses_changed` that names `harness`, kept or new.
    async fn change_naming(&mut self, harness: &str, wait: Duration) -> Option<Value> {
        let names = |v: &Value| {
            v["method"] == "_acpmux/harnesses_changed"
                && v["params"]["harnesses"].to_string().contains(&format!("\"{harness}\""))
        };
        if let Some(v) = self.notes.iter().find(|v| names(v)) {
            return Some(v.clone());
        }
        let end = Instant::now() + wait;
        loop {
            let v = self.line(end.checked_duration_since(Instant::now())?).await?;
            if names(&v) {
                return Some(v);
            }
        }
    }
}

fn scratch(tag: &str) -> PathBuf {
    // Short: the socket path must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amx-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("bin")).unwrap();
    std::fs::canonicalize(&dir).unwrap()
}

/// The daemon this test started, stopped by its own PID when dropped, so a
/// failed assertion leaves no daemon behind.
struct Daemon(std::process::Child);

impl Drop for Daemon {
    fn drop(&mut self) {
        if !matches!(self.0.try_wait(), Ok(None)) {
            return;
        }
        unsafe {
            libc::kill(self.0.id() as i32, libc::SIGTERM);
        }
        let started = Instant::now();
        while matches!(self.0.try_wait(), Ok(None)) {
            if started.elapsed() > Duration::from_secs(8) {
                let _ = self.0.kill();
                let _ = self.0.wait();
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

/// The daemon as the app starts it: the bare GUI PATH, the login shell read
/// at startup. Returns once it reports ready.
async fn start(dir: &Path) -> Daemon {
    let mut child = daemon_env::acpmux(dir)
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .env("ACPMUX_HOME", dir)
        .env("ACPMUX_SOCKET", dir.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "1")
        .env("SHELL", dir.join("loginsh"))
        .env("PATH", "/usr/bin:/bin")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let child = Daemon(child);
    let ready = tokio::task::spawn_blocking(move || {
        for line in BufReader::new(stdout).lines() {
            if serde_json::from_str::<Value>(&line.unwrap()).is_ok_and(|v| v["ready"] == true) {
                return;
            }
        }
        panic!("daemon exited without a readiness line");
    });
    tokio::time::timeout(Duration::from_secs(20), ready).await.unwrap().unwrap();
    child
}

#[tokio::test]
async fn a_harness_on_the_login_path_reaches_clients_that_asked_during_startup() {
    let dir = scratch("hstart");
    std::fs::write(dir.join("config.json"), "{}").unwrap();
    // `grok` is on the login PATH only; the login shell takes 2 s (under the
    // 3 s limit), time for a client to connect and watch first.
    write_executable(dir.join("bin").join("grok"), "#!/bin/sh\nexit 0\n");
    write_executable(
        dir.join("loginsh"),
        format!(
            "#!/bin/sh\nsleep 2\nPATH={}:/usr/bin:/bin\nexport PATH\nexec /bin/sh -c \"$4\"\n",
            daemon_env::sh_quote(dir.join("bin").display())
        ),
    );

    // First start, no cache: asked at once, the catalog answers after the
    // login shell, with grok.
    let child = start(&dir).await;
    let mut client = Client::connect(&dir.join("s.sock")).await;
    let reply = client.call("_acpmux/harnesses", json!({})).await;
    drop(child);
    assert!(
        reply["harnesses"].get("grok").is_some(),
        "asked during startup, the catalog missed the login PATH's harness: {}",
        reply["harnesses"]
    );

    // A day-old cache from before grok was installed: the daemon starts on
    // it and reads the login shell in the background. A watching client
    // hears the catalog that shell's PATH finds.
    let cache_path = dir.join("login-env.json");
    let mut cache: Value = serde_json::from_slice(&std::fs::read(&cache_path).unwrap()).unwrap();
    cache["path"] = json!("/usr/bin:/bin");
    cache["savedAt"] = json!(0);
    std::fs::write(&cache_path, cache.to_string()).unwrap();
    let child = start(&dir).await;
    let mut client = Client::connect(&dir.join("s.sock")).await;
    client.call("_acpmux/watch", json!({"enabled": true})).await;
    client.call("_acpmux/harnesses", json!({})).await;
    let changed = client.change_naming("grok", Duration::from_secs(15)).await;
    drop(child);
    assert!(changed.is_some(), "the background login shell's catalog never reached the watcher");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Writes an executable without this process holding it open for writing
/// (a parallel test's fork could inherit that descriptor: ETXTBSY). (The
/// same helper as daemon_lifecycle.rs.)
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
