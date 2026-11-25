//! The link: any child process whose stdin/stdout carry the agent daemon's newline JSON-RPC
//! (acpmux's ACP plus `_acpmux/*`). That one seam keeps this client backend-agnostic:
//!
//! - this machine: `acpmux stdio`;
//! - any box you can SSH to, on any cloud: `ssh HOST acpmux stdio`;
//! - an AutoCloud machine: `cmux carrier dial --machine ID --service acpmux` (the Cloud carrier,
//!   RFD 0127; relay over 443, resumes across address changes);
//! - anything else: `--via "CMD"`.
//!
//! The link carries no state of its own: when it drops, the client dials again, re-attaches and
//! replays by seq (see `transcript.rs`).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use anyhow::{Context, Result, anyhow, bail};
use cmux_process::{Child, Command, Stdio};
use cmux_scope::Scope;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

#[derive(Clone, Debug)]
pub enum Spec {
    /// The daemon on this machine.
    Local,
    /// `ssh HOST acpmux stdio`.
    Ssh(String),
    /// An AutoCloud machine over the Cloud carrier.
    Machine(String),
    /// A shell command whose stdio is the daemon's JSON-RPC.
    Via(String),
}

impl Spec {
    pub fn describe(&self) -> String {
        match self {
            Spec::Local => "this machine".to_owned(),
            Spec::Ssh(h) => format!("ssh {h}"),
            Spec::Machine(m) => format!("cloud {m}"),
            Spec::Via(c) => format!("via `{c}`"),
        }
    }

    /// Whether this link needs a cmux sign-in (only the Cloud carrier does).
    pub fn needs_sign_in(&self) -> bool {
        matches!(self, Spec::Machine(_))
    }

    fn command(&self, harness: Option<&str>) -> Command {
        let stdio_args = |c: &mut Command| {
            c.arg("stdio");
            if let Some(h) = harness {
                c.args(["-m", h]);
            }
        };
        match self {
            Spec::Local => {
                // Inside `cmux autocloud` the daemon is this same binary's `acp` scope, so a
                // cmux install needs no `acpmux` on PATH.
                let mut c = match host_cmux() {
                    Some(cmux) => {
                        let mut c = Command::new(cmux);
                        c.arg("acp");
                        c
                    }
                    None => Command::new("acpmux"),
                };
                stdio_args(&mut c);
                c
            }
            Spec::Ssh(host) => {
                let mut c = Command::new("ssh");
                // No tty, fail fast instead of prompting, and notice a dead link in ~15 s.
                c.args(["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=5"]);
                c.args(["-o", "ServerAliveCountMax=3", host, "acpmux"]);
                stdio_args(&mut c);
                c
            }
            Spec::Machine(id) => {
                let mut c = Command::new(host_cmux().unwrap_or_else(|| "cmux".into()));
                c.args(["carrier", "dial", "--machine", id, "--service", "acpmux"]);
                c
            }
            Spec::Via(cmd) => {
                let mut c = Command::new("sh");
                c.args(["-c", cmd]);
                c
            }
        }
    }
}

/// The `cmux` binary this code runs inside (`cmux autocloud`), so its links use that build's
/// `carrier dial` and `acp`, not whichever `cmux` or `acpmux` PATH finds. `None` in the
/// standalone `cmux-autocloud`.
fn host_cmux() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let name = exe.file_stem()?.to_str()?;
    matches!(name, "cmux" | "cmux-tui").then_some(exe)
}

/// What the reader hands the client.
#[derive(Debug)]
pub enum Inbound {
    /// The first line arrived: the link is up.
    Up,
    Notification {
        method: String,
        params: Value,
    },
    /// The link ended (the child exited or its stdout closed), with the last stderr line.
    Closed(String),
}

type Pending = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, Value>>>>>;

pub struct Link {
    /// Held so the link command ends with the link (a dropped `cmux_process::Child` is ended).
    _child: Child,
    _scope: Scope,
    out: mpsc::UnboundedSender<String>,
    pending: Pending,
    next_id: AtomicU64,
}

impl Link {
    /// Starts the link command. Lines it prints go to `inbound`, tagged with `generation` so a late
    /// line from a dead link is told apart from the live one.
    pub fn spawn(
        spec: &Spec,
        harness: Option<&str>,
        token: Option<&str>,
        generation: u64,
        inbound: mpsc::UnboundedSender<(u64, Inbound)>,
    ) -> Result<Self> {
        let mut cmd = spec.command(harness);
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        if let Some(t) = token {
            cmd.env("CMUX_CLOUD_ACCESS_TOKEN", t);
        }
        let mut child =
            cmd.spawn().with_context(|| format!("start the link ({})", spec.describe()))?;
        let stdout =
            tokio::process::ChildStdout::from_std(child.stdout.take().context("link stdout")?)?;
        let stderr =
            tokio::process::ChildStderr::from_std(child.stderr.take().context("link stderr")?)?;
        let mut stdin =
            tokio::process::ChildStdin::from_std(child.stdin.take().context("link stdin")?)?;
        // The link's tasks end with it: dropping the link cancels them and ends the child.
        let scope = Scope::new("cmux-autocloud link");

        let (out, mut out_rx) = mpsc::unbounded_channel::<String>();
        scope.spawn_until_cancelled("link writer", async move {
            while let Some(line) = out_rx.recv().await {
                if stdin.write_all(line.as_bytes()).await.is_err()
                    || stdin.write_all(b"\n").await.is_err()
                    || stdin.flush().await.is_err()
                {
                    break;
                }
            }
        });

        let last_err = Arc::new(Mutex::new(String::new()));
        let err_sink = last_err.clone();
        scope.spawn_until_cancelled("link stderr", async move {
            let mut lines = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if !line.trim().is_empty() {
                    *err_sink.lock().unwrap_or_else(PoisonError::into_inner) = line;
                }
            }
        });

        let pending: Pending = Arc::default();
        let routes = pending.clone();
        let replies = out.clone();
        scope.spawn_until_cancelled("link reader", async move {
            let mut lines = BufReader::new(stdout).lines();
            let mut first = true;
            loop {
                let line = match lines.next_line().await {
                    Ok(Some(l)) => l,
                    _ => break,
                };
                if first {
                    first = false;
                    let _ = inbound.send((generation, Inbound::Up));
                }
                let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
                route(msg, &routes, &replies, generation, &inbound);
            }
            // Fail every request still waiting, so no caller hangs on a dead link.
            for (_, tx) in routes.lock().unwrap_or_else(PoisonError::into_inner).drain() {
                let _ = tx.send(Err(json!({"message": "link closed"})));
            }
            let why = last_err.lock().unwrap_or_else(PoisonError::into_inner).clone();
            let _ = inbound.send((generation, Inbound::Closed(why)));
        });

        Ok(Self { _child: child, _scope: scope, out, pending, next_id: AtomicU64::new(1) })
    }

    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap_or_else(PoisonError::into_inner).insert(id, tx);
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if self.out.send(line.to_string()).is_err() {
            bail!("link closed");
        }
        match rx.await {
            Ok(Ok(v)) => Ok(v),
            Ok(Err(e)) => Err(anyhow!(
                "{method}: {}",
                e.get("message").and_then(Value::as_str).unwrap_or("error")
            )),
            Err(_) => bail!("link closed"),
        }
    }

    /// Sends a request whose answer arrives later as notifications (a prompt's turn): the caller
    /// does not wait on it.
    pub fn fire(&self, method: &str, params: Value) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let _ = self.out.send(line.to_string());
    }
}

fn route(
    msg: Value,
    pending: &Pending,
    replies: &mpsc::UnboundedSender<String>,
    generation: u64,
    inbound: &mpsc::UnboundedSender<(u64, Inbound)>,
) {
    let method = msg.get("method").and_then(Value::as_str).map(str::to_owned);
    match (msg.get("id"), method) {
        // A response to one of ours.
        (Some(id), None) => {
            let Some(id) = id.as_u64() else { return };
            if let Some(tx) = pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id) {
                let _ = tx.send(match msg.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(msg.get("result").cloned().unwrap_or(Value::Null)),
                });
            }
        }
        // A request from the daemon: this client offers no client-side methods yet (no fs, no
        // terminal), so it says so and the agent carries on under the daemon's policy.
        (Some(id), Some(method)) => {
            let reply = json!({"jsonrpc": "2.0", "id": id,
                "error": {"code": -32601, "message": format!("{method} is not offered by cmux-autocloud")}});
            let _ = replies.send(reply.to_string());
        }
        (None, Some(method)) => {
            let params = msg.get("params").cloned().unwrap_or(Value::Null);
            let _ = inbound.send((generation, Inbound::Notification { method, params }));
        }
        (None, None) => {}
    }
}
