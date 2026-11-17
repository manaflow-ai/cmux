//! The real [`crate::io`] implementations: std files, the `git` CLI, app processes, the wall
//! clock, a loopback HTTP probe, and this machine's agent socket for the platform and listeners.

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead as _, Read as _, Write as _};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_process::{Child, Command, Stdio};

use serde_json::{Value, json};

use crate::infer::Inferred;
use crate::io::{
    Answered, AppsTransport, Clock, Fs, Git, Launch, Listeners, Probe, Procs, Unanswered,
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
        let _ = fs::remove_file(&tar);
        result.map(|_| ())
    }
}

/// The unprivileged account app processes run as when the publisher is root.
pub const APP_USER: &str = "cmux-app";

/// The app processes started here. Each is detached (a version outlives the command that
/// published it), and kept so its exit is reaped and seen by [`Procs::alive`].
pub struct RealProcs {
    children: Mutex<HashMap<u32, Child>>,
    user: Option<(u32, u32)>,
}

impl RealProcs {
    pub fn new() -> RealProcs {
        RealProcs { children: Mutex::new(HashMap::new()), user: app_user() }
    }

    fn command(&self, launch: &Launch<'_>) -> Result<Command, String> {
        if let Some(parent) = launch.log.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("cannot make {}: {e}", parent.display()))?;
        }
        let log = OpenOptions::new()
            .create(true)
            .append(true)
            .open(launch.log)
            .map_err(|e| format!("cannot open {}: {e}", launch.log.display()))?;
        let err = log.try_clone().map_err(|e| e.to_string())?;
        let mut command = match self.user {
            // The version's directory (HOME) becomes the app user's so it can write there, and
            // setpriv drops to that user before the shell starts.
            Some((uid, gid)) => {
                if let Some((_, home)) = launch.env.iter().find(|(k, _)| k == "HOME") {
                    let owner = format!("{uid}:{gid}");
                    run_output(Command::new("chown").args(["-R", &owner, home]), "chown")?;
                }
                let mut command = Command::new("setpriv");
                command.args([
                    format!("--reuid={uid}"),
                    format!("--regid={gid}"),
                    "--clear-groups".to_owned(),
                    "--".to_owned(),
                    "/bin/sh".to_owned(),
                ]);
                command
            }
            None => Command::new("/bin/sh"),
        };
        command
            .arg("-c")
            .arg(launch.command)
            .current_dir(launch.dir)
            .env_clear()
            .envs(launch.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::null())
            .stdout(log)
            .stderr(err)
            .new_session();
        Ok(command)
    }
}

impl Default for RealProcs {
    fn default() -> Self {
        RealProcs::new()
    }
}

/// `cmux-app`'s uid and gid when this process is root and the account exists.
fn app_user() -> Option<(u32, u32)> {
    // SAFETY: geteuid has no preconditions; getpwnam's entry is read before any other call.
    unsafe {
        if libc::geteuid() != 0 {
            return None;
        }
        let name = std::ffi::CString::new(APP_USER).ok()?;
        let entry = libc::getpwnam(name.as_ptr());
        if entry.is_null() || (*entry).pw_uid == 0 {
            return None;
        }
        Some(((*entry).pw_uid, (*entry).pw_gid))
    }
}

impl Procs for RealProcs {
    fn spawn_detached(&self, launch: &Launch<'_>) -> Result<u32, String> {
        let mut child = self.command(launch)?.spawn().map_err(|e| e.to_string())?;
        child.detach("a published app version outlives the cmux app command that started it");
        let pid = child.id();
        self.children.lock().unwrap_or_else(|e| e.into_inner()).insert(pid, child);
        Ok(pid)
    }

    fn run(&self, launch: &Launch<'_>, limit: Duration) -> Result<(), String> {
        // Not detached: a setup that runs past its limit is ended with its group on drop.
        let mut child = self.command(launch)?.spawn().map_err(|e| e.to_string())?;
        match child.wait_timeout(limit).map_err(|e| e.to_string())? {
            Some(status) if status.success() => Ok(()),
            Some(status) => Err(format!("exited with {status}")),
            None => Err(format!("did not finish within {} s", limit.as_secs())),
        }
    }

    fn alive(&self, pid: u32) -> bool {
        let mut children = self.children.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(child) = children.get_mut(&pid) {
            return matches!(child.try_wait(), Ok(None));
        }
        // SAFETY: signal 0 only checks that the process exists.
        unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
    }

    fn stop(&self, pid: u32) {
        // SAFETY: the version's process leads its own session and group, so this ends only it.
        unsafe {
            libc::kill(-(pid as libc::pid_t), libc::SIGTERM);
        }
        if let Some(mut child) =
            self.children.lock().unwrap_or_else(|e| e.into_inner()).remove(&pid)
        {
            let _ = child.try_wait();
        }
    }

    fn free_port(&self) -> Result<u16, String> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|e| e.to_string())?;
        listener.local_addr().map(|a| a.port()).map_err(|e| e.to_string())
    }

    fn port_free(&self, port: u16) -> bool {
        TcpListener::bind((Ipv4Addr::LOCALHOST, port)).is_ok()
    }

    fn run_as(&self) -> Option<String> {
        self.user.map(|_| APP_USER.to_owned())
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
            match stream.read(&mut head[read..]) {
                Ok(0) => break,
                Ok(n) => read += n,
                Err(e) if read == 0 => return Err(e.to_string()),
                Err(_) => break,
            }
            if head[..read].contains(&b'\n') {
                break;
            }
        }
        let line = String::from_utf8_lossy(&head[..read]);
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
    fn ask(&self, line: &Value, bound: Duration) -> Result<Value, Unanswered> {
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
            pid: reply.get("pid").and_then(Value::as_u64).unwrap_or_default() as u32,
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
