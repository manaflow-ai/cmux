//! One private Codex auth holder process (`acpmux codex-auth-broker`, acpmux
//! `cli/codex_auth_broker.rs`): JSON lines on private pipes, one reply per request id. The
//! holder serializes provider work itself; this side only correlates replies, bounds a reply
//! line, and stops the child (SIGTERM, then SIGKILL after 2 s) and waits for its exit, so a
//! replacement never races the credential lock it releases on exit.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Map, Value};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::process::ChildStdin;
use tokio::sync::{oneshot, watch};

use crate::cx::Cx;

/// One reply line's bound (a whole one, or the part still waiting for its newline).
const LINE_LIMIT: usize = 64 * 1024;
const STOP_GRACE: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionError {
    InvalidReply,
    AccountChanged,
    NotAuthenticated,
    TimedOut,
    Cancelled,
    Io,
}

type Waiter = oneshot::Sender<Result<Value, SessionError>>;

#[derive(Default)]
struct Pending {
    waiting: Mutex<HashMap<u64, Waiter>>,
}

impl Pending {
    fn insert(&self, id: u64, waiter: Waiter) {
        self.lock().insert(id, waiter);
    }

    fn take(&self, id: u64) -> Option<Waiter> {
        self.lock().remove(&id)
    }

    fn fail_all(&self, error: SessionError) {
        let waiting: Vec<Waiter> = self.lock().drain().map(|(_, waiter)| waiter).collect();
        for waiter in waiting {
            let _ = waiter.send(Err(error));
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Waiter>> {
        self.waiting.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Removes a request's waiter when its wait ends any way (a cancel, a timeout, a drop).
struct Forget<'a>(&'a Pending, u64);

impl Drop for Forget<'_> {
    fn drop(&mut self) {
        self.0.take(self.1);
    }
}

pub struct Session {
    input: tokio::sync::Mutex<Option<ChildStdin>>,
    pending: Arc<Pending>,
    next_id: AtomicU64,
    stopped: AtomicBool,
    terminating: AtomicBool,
    pid: Option<i32>,
    exited: watch::Receiver<bool>,
}

impl Session {
    /// Starts `executable prefix… codex-auth-broker --home HOME --codex CODEX` with only PATH,
    /// HOME, USER, TMPDIR and the TLS variables of `environment`.
    pub fn spawn(
        executable: &Path,
        prefix: &[String],
        codex: &Path,
        home: &Path,
        environment: &HashMap<String, String>,
        fallback_home: &Path,
    ) -> std::io::Result<Arc<Self>> {
        std::fs::create_dir_all(home)?;
        let mut command = tokio::process::Command::new(executable);
        command
            .args(prefix)
            .arg("codex-auth-broker")
            .arg("--home")
            .arg(home)
            .arg("--codex")
            .arg(codex)
            .env_clear()
            .env("PATH", environment.get("PATH").map_or("/usr/bin:/bin", String::as_str))
            .env(
                "HOME",
                environment.get("HOME").map_or_else(|| fallback_home.to_path_buf(), PathBuf::from),
            );
        for key in ["USER", "TMPDIR", "SSL_CERT_FILE", "SSL_CERT_DIR"] {
            if let Some(value) = environment.get(key) {
                command.env(key, value);
            }
        }
        let mut child =
            command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
        let input = child.stdin.take();
        let output = child.stdout.take();
        let pid = child.id().and_then(|pid| i32::try_from(pid).ok());
        let pending = Arc::new(Pending::default());
        let (exit_sender, exited) = watch::channel(false);
        tokio::spawn(async move {
            let _ = child.wait().await;
            let _ = exit_sender.send(true);
        });
        let session = Arc::new(Self {
            input: tokio::sync::Mutex::new(input),
            pending: pending.clone(),
            next_id: AtomicU64::new(0),
            stopped: AtomicBool::new(false),
            terminating: AtomicBool::new(false),
            pid,
            exited,
        });
        if let Some(output) = output {
            let weak = Arc::downgrade(&session);
            tokio::spawn(read_replies(output, pending, weak));
        }
        Ok(session)
    }

    fn has_exited(&self) -> bool {
        *self.exited.borrow()
    }

    /// One request. `force` and `previous_account` go only when given.
    pub async fn request(
        &self,
        cx: &Cx,
        method: &str,
        force: Option<bool>,
        previous_account: Option<&str>,
    ) -> Result<Value, SessionError> {
        if cx.is_cancelled() {
            return Err(SessionError::Cancelled);
        }
        if self.stopped.load(Ordering::SeqCst) || self.has_exited() {
            return Err(SessionError::InvalidReply);
        }
        let id = self.next_id.fetch_add(1, Ordering::SeqCst).saturating_add(1);
        let mut object = Map::new();
        if let Some(force) = force {
            object.insert("force".into(), Value::Bool(force));
        }
        object.insert("id".into(), Value::from(id));
        object.insert("method".into(), Value::from(method));
        if let Some(previous) = previous_account {
            object.insert("previousAccountId".into(), Value::from(previous));
        }
        let mut line = Value::Object(object).to_string().into_bytes();
        line.push(b'\n');
        let (sender, receiver) = oneshot::channel();
        self.pending.insert(id, sender);
        let _forget = Forget(&self.pending, id);
        {
            let mut input = self.input.lock().await;
            let Some(stdin) = input.as_mut() else { return Err(SessionError::Io) };
            if stdin.write_all(&line).await.is_err() || stdin.flush().await.is_err() {
                return Err(SessionError::Io);
            }
        }
        tokio::select! {
            biased;
            () = cx.cancelled() => Err(SessionError::Cancelled),
            reply = receiver => reply.unwrap_or(Err(SessionError::InvalidReply)),
        }
    }

    /// Ends every waiting request, stops the child and waits for its exit.
    pub async fn shutdown(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        self.pending.fail_all(SessionError::Cancelled);
        if self.has_exited() {
            return;
        }
        if !self.terminating.swap(true, Ordering::SeqCst) {
            self.signal(libc::SIGTERM);
            let mut exited = self.exited.clone();
            let pid = self.pid;
            tokio::spawn(async move {
                let timed_out =
                    tokio::time::timeout(STOP_GRACE, exited.wait_for(|e| *e)).await.is_err();
                // Only the child this session launched, and only while it has not exited.
                if timed_out
                    && !*exited.borrow()
                    && let Some(pid) = pid
                {
                    // SAFETY: kill has no memory preconditions; `pid` is this session's unreaped child.
                    unsafe {
                        libc::kill(pid, libc::SIGKILL);
                    }
                }
            });
        }
        let mut exited = self.exited.clone();
        let _ = exited.wait_for(|e| *e).await;
    }

    fn signal(&self, signal: i32) {
        if self.has_exited() {
            return;
        }
        if let Some(pid) = self.pid {
            // SAFETY: kill has no memory preconditions; `pid` is this session's unreaped child.
            unsafe {
                libc::kill(pid, signal);
            }
        }
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.signal(libc::SIGTERM);
    }
}

/// Reads reply lines until end of file, then fails what still waits. A line past the bound
/// stops the child.
async fn read_replies(
    mut output: tokio::process::ChildStdout,
    pending: Arc<Pending>,
    session: std::sync::Weak<Session>,
) {
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; 16 * 1024];
    loop {
        let read = match output.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        buffer.extend_from_slice(chunk.get(..read).unwrap_or_default());
        while let Some(newline) = buffer.iter().position(|b| *b == b'\n') {
            if newline > LINE_LIMIT {
                overflow(&pending, &session, &mut buffer);
                break;
            }
            let line: Vec<u8> = buffer.drain(..=newline).collect();
            deliver(&pending, line.get(..newline).unwrap_or_default());
        }
        if buffer.len() > LINE_LIMIT {
            overflow(&pending, &session, &mut buffer);
        }
    }
    pending.fail_all(SessionError::InvalidReply);
}

fn overflow(pending: &Pending, session: &std::sync::Weak<Session>, buffer: &mut Vec<u8>) {
    pending.fail_all(SessionError::InvalidReply);
    if let Some(session) = session.upgrade() {
        session.signal(libc::SIGTERM);
    }
    *buffer = Vec::new();
}

fn deliver(pending: &Pending, line: &[u8]) {
    let Ok(reply) = serde_json::from_slice::<Value>(line) else { return };
    let Some(id) = reply.get("id").and_then(Value::as_u64) else { return };
    let Some(waiter) = pending.take(id) else { return };
    let answer = match (reply.get("error"), reply.get("result")) {
        (Some(Value::String(error)), _) => Err(match error.as_str() {
            "codex_auth_account_changed" => SessionError::AccountChanged,
            "codex_auth_timeout" => SessionError::TimedOut,
            "codex_auth_unavailable" => SessionError::NotAuthenticated,
            _ => SessionError::InvalidReply,
        }),
        (Some(error), _) if !error.is_null() => Err(SessionError::InvalidReply),
        (_, Some(result)) if result.is_object() => Ok(result.clone()),
        _ => Err(SessionError::InvalidReply),
    };
    let _ = waiter.send(answer);
}

#[cfg(test)]
#[path = "session_tests.rs"]
mod tests;
