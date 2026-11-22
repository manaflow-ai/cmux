//! The real [`crate::io`] implementations: std files, the `git` CLI, app processes, the wall
//! clock, a loopback HTTP probe, and this machine's agent socket for the platform and listeners.

use std::fs;
use std::io::{self, BufRead as _, Read as _, Write as _};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_process::{Command, Stdio};

use serde_json::{Value, json};

use crate::infer::Inferred;
use crate::io::{
    Answered, AppsTransport, Clock, Fs, Git, Listeners, Probe, Procs, Start, Started, Unanswered,
};

pub struct RealFs;

impl Fs for RealFs {
    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        fs::read(path)
    }

    fn read_link(&self, path: &Path) -> io::Result<PathBuf> {
        fs::read_link(path)
    }

    fn list(&self, dir: &Path) -> io::Result<Vec<String>> {
        fs::read_dir(dir)?
            .map(|entry| entry.map(|e| e.file_name().to_string_lossy().into_owned()))
            .collect()
    }

    fn write(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
        fs::write(&tmp, bytes)?;
        fs::rename(&tmp, path)
    }
}

/// One command to its end: its trimmed stdout, or its trimmed stderr as the error.
fn run_output(command: &mut Command, what: &str) -> Result<String, String> {
    let out =
        command.stdin(Stdio::null()).output().map_err(|e| format!("cannot run {what}: {e}"))?;
    if !out.status.success() {
        return Err(format!("{what}: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

pub struct GitCli;

fn git(repo: &Path, args: &[&str], env: &[(&str, &str)]) -> Result<String, String> {
    let mut command = Command::new("git");
    command.arg("-C").arg(repo).args(args).envs(env.iter().copied());
    run_output(&mut command, &format!("git {}", args.first().copied().unwrap_or_default()))
}

impl Git for GitCli {
    fn toplevel(&self, dir: &Path) -> Result<PathBuf, String> {
        git(dir, &["rev-parse", "--show-toplevel"], &[]).map(PathBuf::from)
    }

    fn resolve(&self, repo: &Path, rev: &str) -> Result<String, String> {
        git(repo, &["rev-parse", "--verify", "--end-of-options", &format!("{rev}^{{commit}}")], &[])
    }

    fn dirty(&self, repo: &Path) -> Result<bool, String> {
        git(repo, &["status", "--porcelain"], &[]).map(|out| !out.is_empty())
    }

    fn snapshot(&self, repo: &Path, refname: &str, message: &str) -> Result<String, String> {
        // A scratch index, so the person's index and HEAD stay as they are.
        let index = git(repo, &["rev-parse", "--git-path", "cmux-app-index"], &[])?;
        let index = repo.join(index).display().to_string();
        let _ = fs::remove_file(&index);
        let env = [("GIT_INDEX_FILE", index.as_str())];
        let result = (|| {
            git(repo, &["read-tree", "HEAD"], &env)?;
            git(repo, &["add", "-A"], &env)?;
            let tree = git(repo, &["write-tree"], &env)?;
            let mut who = vec![];
            if git(repo, &["config", "user.email"], &[]).unwrap_or_default().is_empty() {
                who = vec![
                    ("GIT_AUTHOR_NAME", "cmux"),
                    ("GIT_AUTHOR_EMAIL", "cmux@localhost"),
                    ("GIT_COMMITTER_NAME", "cmux"),
                    ("GIT_COMMITTER_EMAIL", "cmux@localhost"),
                ];
            }
            let commit = git(repo, &["commit-tree", &tree, "-p", "HEAD", "-m", message], &who)?;
            git(repo, &["update-ref", refname, &commit], &[])?;
            Ok(commit)
        })();
        let _ = fs::remove_file(&index);
        result
    }

    fn archive(&self, repo: &Path, commit: &str, dest: &Path) -> Result<(), String> {
        fs::create_dir_all(dest).map_err(|e| format!("cannot make {}: {e}", dest.display()))?;
        let tar = dest.with_extension("tar");
        let tar_arg = tar.display().to_string();
        let result =
            git(repo, &["archive", "--format=tar", "-o", &tar_arg, commit], &[]).and_then(|_| {
                run_output(
                    Command::new("tar").arg("-x").arg("-f").arg(&tar).arg("-C").arg(dest),
                    "tar",
                )
            });
        // `src.tar` stays: it is what this machine's agent copies the version from.
        result.map(|_| ())
    }
}

/// App processes through this machine's agent (`apps.spawn`, `apps.status`, `apps.stop`):
/// the agent starts them as its unprivileged app user, so this process never does, and
/// ports on loopback.
pub struct RealProcs {
    pub agent: AgentSocket,
}

impl RealProcs {
    pub fn new() -> RealProcs {
        RealProcs { agent: AgentSocket::default() }
    }
}

impl Default for RealProcs {
    fn default() -> Self {
        RealProcs::new()
    }
}

impl Procs for RealProcs {
    fn start(&self, start: &Start<'_>) -> Result<Started, String> {
        let env: serde_json::Map<String, Value> =
            start.env.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
        let line = json!({"apps.spawn": {
            "slug": start.slug,
            "version": start.version,
            "versionDir": start.version_dir.display().to_string(),
            "subdir": start.subdir,
            "cmd": start.command,
            "setup": start.setup,
            "port": start.port,
            "env": env,
            "restart": start.restart,
        }});
        let reply = self.agent.ask(&line, SPAWN_BOUND).map_err(|e| e.message)?;
        let text =
            |key: &str| reply.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
        let pid = reply
            .get("pid")
            .and_then(Value::as_u64)
            .and_then(|p| u32::try_from(p).ok())
            .ok_or_else(|| "the agent's answer has no pid".to_owned())?;
        Ok(Started {
            pid,
            start_time: reply.get("startTime").and_then(Value::as_u64).unwrap_or_default(),
            run_dir: PathBuf::from(text("runDir")),
            log: PathBuf::from(text("log")),
            user: text("user"),
        })
    }

    fn alive(&self, slug: &str, version: u32) -> bool {
        let line = json!({"apps.status": {"slug": slug, "version": version}});
        self.agent
            .ask(&line, LISTENER_BOUND)
            .is_ok_and(|reply| reply.get("alive").and_then(Value::as_bool) == Some(true))
    }

    fn stop(&self, slug: &str, version: u32) {
        let line = json!({"apps.stop": {"slug": slug, "version": version}});
        let _ = self.agent.ask(&line, LISTENER_BOUND);
    }

    fn free_port(&self) -> Result<u16, String> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|e| e.to_string())?;
        listener.local_addr().map(|a| a.port()).map_err(|e| e.to_string())
    }

    fn port_free(&self, port: u16) -> bool {
        TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_ok()
    }
}

pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
    }

    fn sleep(&self, duration: Duration) {
        // The bounded wait between two probes of a version that is starting.
        std::thread::sleep(duration);
    }
}

/// HTTP/1.0 `GET` on loopback with 2 s bounds: the status line's code.
pub struct LoopbackProbe;

impl Probe for LoopbackProbe {
    fn get(&self, port: u16, path: &str) -> Result<u16, String> {
        let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
        let bound = Duration::from_secs(2);
        let mut stream = TcpStream::connect_timeout(&address, bound).map_err(|e| e.to_string())?;
        stream.set_read_timeout(Some(bound)).map_err(|e| e.to_string())?;
        stream.set_write_timeout(Some(bound)).map_err(|e| e.to_string())?;
        let request =
            format!("GET {path} HTTP/1.0\r\nHost: localhost:{port}\r\nConnection: close\r\n\r\n");
        stream.write_all(request.as_bytes()).map_err(|e| e.to_string())?;
        let mut head = [0u8; 64];
        let mut read = 0;
        while read < head.len() {
            let Some(rest) = head.get_mut(read..) else { break };
            match stream.read(rest) {
                Ok(0) => break,
                Ok(n) => read = read.saturating_add(n),
                Err(e) if read == 0 => return Err(e.to_string()),
                Err(_) => break,
            }
            if head.get(..read).is_some_and(|h| h.contains(&b'\n')) {
                break;
            }
        }
        let line = String::from_utf8_lossy(head.get(..read).unwrap_or_default());
        line.split_whitespace()
            .nth(1)
            .and_then(|code| code.parse().ok())
            .filter(|_| line.starts_with("HTTP/"))
            .ok_or_else(|| "not an HTTP answer".to_owned())
    }
}

/// This machine's agent socket (cmux-host `cloud::wire::AGENT_SOCKET`): it holds the VM
/// install's credential and answers `apps.call` and `apps.listener`.
pub const AGENT_SOCKET: &str = "/run/cmux-vm-agent/agent.sock";
/// An `apps.call`'s whole bound: the agent mints a token and the platform rechecks a promote.
const CALL_BOUND: Duration = Duration::from_secs(90);
const LISTENER_BOUND: Duration = Duration::from_secs(10);
/// An `apps.spawn`: the agent unpacks the version's source before it starts it.
const SPAWN_BOUND: Duration = Duration::from_secs(180);

/// The agent on its socket: one JSON line out, one line back, per connection.
pub struct AgentSocket {
    pub path: PathBuf,
}

impl Default for AgentSocket {
    fn default() -> AgentSocket {
        AgentSocket { path: PathBuf::from(AGENT_SOCKET) }
    }
}

fn unanswered(code: &str, message: impl Into<String>) -> Unanswered {
    Unanswered { code: code.to_owned(), message: message.into() }
}

impl AgentSocket {
    /// `Err` with `app.unreachable` when the line was sent and no answer came (it may have
    /// reached the platform), `app.agent` when the agent could not be reached at all.
    pub fn ask(&self, line: &Value, bound: Duration) -> Result<Value, Unanswered> {
        let mut stream = UnixStream::connect(&self.path).map_err(|e| {
            unanswered(
                "app.agent",
                format!(
                    "cannot reach this machine's agent at {} ({e}): run this on a cmux Cloud machine",
                    self.path.display()
                ),
            )
        })?;
        let lost = |e: io::Error| {
            unanswered("app.unreachable", format!("the agent's answer was lost: {e}"))
        };
        stream.set_read_timeout(Some(bound)).map_err(lost)?;
        stream.set_write_timeout(Some(bound)).map_err(lost)?;
        let mut text = line.to_string();
        text.push('\n');
        stream.write_all(text.as_bytes()).map_err(lost)?;
        let mut reply = String::new();
        io::BufReader::new(stream).read_line(&mut reply).map_err(lost)?;
        let reply: Value = serde_json::from_str(reply.trim()).map_err(|e| {
            unanswered("app.unreachable", format!("the agent answered no JSON: {e}"))
        })?;
        if reply.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(reply);
        }
        let error = reply.get("error").unwrap_or(&reply);
        let text = |key: &str| error.get(key).and_then(Value::as_str).map(str::to_owned);
        Err(unanswered(
            &text("code").unwrap_or_else(|| "app.agent".to_owned()),
            text("message").unwrap_or_else(|| format!("the agent refused: {reply}")),
        ))
    }
}

impl AppsTransport for AgentSocket {
    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        idempotency_key: Option<&str>,
    ) -> Result<Answered, Unanswered> {
        let line = json!({"apps.call": {
            "method": method,
            "path": path,
            "body": body,
            "idempotencyKey": idempotency_key,
        }});
        let reply = self.ask(&line, CALL_BOUND)?;
        let status =
            reply.get("status").and_then(Value::as_u64).and_then(|s| u16::try_from(s).ok());
        let Some(status) = status else {
            return Err(unanswered("app.unreachable", "the agent's answer has no status"));
        };
        Ok(Answered {
            status,
            body: reply.get("body").cloned().unwrap_or(Value::Null),
            machine: reply.get("machine").and_then(Value::as_str).unwrap_or_default().to_owned(),
        })
    }
}

impl Listeners for AgentSocket {
    fn holder(&self, port: u16) -> Result<Inferred, String> {
        let reply = self
            .ask(&json!({"apps.listener": {"port": port}}), LISTENER_BOUND)
            .map_err(|e| e.message)?;
        let text =
            |key: &str| reply.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
        Ok(Inferred {
            pid: reply
                .get("pid")
                .and_then(Value::as_u64)
                .and_then(|p| u32::try_from(p).ok())
                .unwrap_or_default(),
            dir: PathBuf::from(text("dir")),
            argv: reply
                .get("argv")
                .and_then(Value::as_array)
                .map(|argv| argv.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default(),
            command: text("command"),
        })
    }
}
