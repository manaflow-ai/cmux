//! Secrets an agent asks the person for (cx-ncc.42).
//!
//! The agent's `request_secret` tool (`secret_mcp.rs`) calls
//! `_acpmux/secret_request {sessionId, name, reason}`, which waits. The pane
//! shows a private card from the `secret_request` record (name and reason
//! only), and the person types the value there: `_acpmux/secret_submit`,
//! accepted only from the person's connection (`hub/person.rs`). The agent
//! gets a `secretRef` back, never the value.
//!
//! - The value lives in this daemon's memory only (zeroed when dropped):
//!   never in a record, the store, a log, a notification or a reply. The
//!   records say what was asked and whether it was given.
//! - A ref is spent once, by `_acpmux/secret_run {secretRef, env, argv}` from
//!   a session in the same project (the session folder, canonical): the
//!   command runs in that folder with the value in `env`, and what it prints
//!   comes back with the value masked, at most [`MAX_OUTPUT_BYTES`] of each
//!   stream (the rest is read and dropped). A refused run, or one whose
//!   command cannot start, spends nothing.
//! - An unspent ref expires after [`HELD_TTL`]; at most [`HELD_LIMIT`] are
//!   held. A card nobody fills is cancelled after [`ASK_TTL`], and with the
//!   turn (a cancel, a kill, an ended agent): `cancel_pending_secrets`.
//! - A chat has at most one open card: a new ask replaces it (a harness whose
//!   tool call timed out asks again), and the old asker gets `cancelled`. A
//!   chat a remote device started asks for none.
//! - The command gets a clean environment: the login environment (PATH and
//!   friends, `login_env.rs`), HOME, USER, the locale, TMPDIR and the
//!   secret. Never the daemon's own, which holds helper tokens an agent must
//!   not see (`cua_socket::scrub_agent_env`).
//! - Any agent can reach the socket, so an ask names its chat but cannot
//!   prove which agent made it; the card shows the chat it waits in.
//!
//! The masking covers the value as given. A command that prints it encoded
//! (base64, reversed) shows it to the agent: the ref limits where and how
//! often the value is used, not what a command it runs may do with it.

use super::{Hub, Session, SessionStatus};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::sync::oneshot;
use zeroize::Zeroizing;

pub(super) const ASK_TTL: Duration = Duration::from_secs(15 * 60);
pub(super) const HELD_TTL: Duration = Duration::from_secs(60 * 60);
pub(super) const HELD_LIMIT: usize = 64;
const MAX_VALUE_BYTES: usize = 64 * 1024;
const MAX_REASON_CHARS: usize = 500;
const RUN_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_OUTPUT_BYTES: usize = 64 * 1024;
const MASK: &str = "••••••";

#[derive(Default)]
pub(crate) struct Secrets {
    pending: StdMutex<HashMap<String, Pending>>,
    held: StdMutex<HashMap<String, Held>>,
}

struct Pending {
    session: String,
    reply: oneshot::Sender<Option<Zeroizing<String>>>,
}

struct Held {
    project: String,
    value: Zeroizing<String>,
    at: Instant,
}

/// An environment variable name: what the card shows and `secret_run` sets.
fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_uppercase() || c == '_')
        && name.len() <= 64
        && chars.all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
}

fn project_of(session: &Session) -> Result<String, RpcError> {
    crate::trust::normalize_cwd(&session.meta().cwd.to_string_lossy())
        .map_err(|e| RpcError::invalid_params(format!("the chat's folder: {e}")))
}

/// Reads `pipe` to its end, keeping at most `cap` bytes: a command that
/// prints without end cannot fill the daemon's memory.
async fn read_capped(pipe: Option<impl AsyncRead + Unpin>, cap: usize) -> (Vec<u8>, bool) {
    let (mut kept, mut cut) = (Vec::new(), false);
    let Some(mut pipe) = pipe else { return (kept, cut) };
    let mut chunk = [0u8; 8192];
    while let Ok(n) = pipe.read(&mut chunk).await {
        if n == 0 {
            break;
        }
        let room = cap - kept.len();
        cut |= n > room;
        kept.extend_from_slice(&chunk[..n.min(room)]);
    }
    (kept, cut)
}

/// How many bytes at the end of `bytes` begin `value`: a value the cap cut
/// off, which masking would miss (KMP over the last `value.len()` bytes).
fn cut_value_len(bytes: &[u8], value: &[u8]) -> usize {
    if value.is_empty() {
        return 0;
    }
    let mut fail = vec![0usize; value.len()];
    let mut k = 0;
    for i in 1..value.len() {
        while k > 0 && value[i] != value[k] {
            k = fail[k - 1];
        }
        if value[i] == value[k] {
            k += 1;
        }
        fail[i] = k;
    }
    k = 0;
    for &b in &bytes[bytes.len().saturating_sub(value.len())..] {
        if k == value.len() {
            k = fail[k - 1];
        }
        while k > 0 && b != value[k] {
            k = fail[k - 1];
        }
        if b == value[k] {
            k += 1;
        }
    }
    k
}

/// What a command printed (read with room for one value past the cap), the
/// value masked before the cap cuts it: a value across the cut would
/// otherwise leave its first bytes.
fn mask((bytes, cut): (Vec<u8>, bool), value: &str) -> String {
    let end = if cut { bytes.len() - cut_value_len(&bytes, value.as_bytes()) } else { bytes.len() };
    let masked = String::from_utf8_lossy(&bytes[..end]).replace(value, MASK);
    let mut end = masked.len().min(MAX_OUTPUT_BYTES);
    while !masked.is_char_boundary(end) {
        end -= 1;
    }
    masked[..end].to_owned()
}

/// The variables a secret's command keeps from the daemon, besides the login
/// environment: never a token or an acpmux setting.
const KEPT_ENV: &[&str] = &["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM"];

impl Hub {
    /// The agent's ask: waits for the person's card and returns
    /// `{secretRef, name}`, or `{declined: true, name}`.
    pub async fn request_secret(
        &self,
        session: &Session,
        name: &str,
        reason: &str,
    ) -> Result<Value, RpcError> {
        if !valid_name(name) {
            return Err(RpcError::invalid_params(
                "name must be an environment variable name (A-Z, 0-9, _)",
            ));
        }
        if session.meta().remote_origin {
            return Err(RpcError::invalid_params(
                "a chat a remote device started asks for no secrets",
            ));
        }
        let reason: String = reason.chars().take(MAX_REASON_CHARS).collect();
        let project = project_of(session)?;
        let secret_id = super::person::new_nonce();
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner());
            // Dropping the old card's reply answers its asker `cancelled`.
            pending.retain(|_, p| p.session != session.id);
            pending.insert(secret_id.clone(), Pending { session: session.id.clone(), reply: tx });
        }
        // Stopped (`Hub::kill` marks it closing before it cancels the cards): a card that came
        // after the cancel is cancelled here.
        if session.closing.load(Ordering::SeqCst) || session.status() == SessionStatus::Closed {
            self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&secret_id);
            return Ok(json!({"declined": true, "name": name, "outcome": "cancelled"}));
        }
        self.append(
            session,
            "mux",
            "secret_request",
            json!({"secretId": secret_id, "name": name, "reason": reason}),
        );
        let prev = session.status();
        self.set_status(session, SessionStatus::Waiting);
        let answer = tokio::time::timeout(ASK_TTL, rx).await.ok().and_then(Result::ok);
        // A cancelled or expired card is gone from the pane as well.
        self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&secret_id);
        let outcome = match answer {
            Some(Some(_)) => "provided",
            Some(None) => "declined",
            None => "cancelled",
        };
        self.append(
            session,
            "mux",
            "secret_decision",
            json!({"secretId": secret_id, "name": name, "outcome": outcome}),
        );
        if session.status() == SessionStatus::Waiting
            && session.permissions.lock().unwrap_or_else(|e| e.into_inner()).pending.is_empty()
            && !self.secrets.waiting_in(&session.id)
        {
            self.set_status(session, super::permissions::status_after_ask(session, prev));
        }
        let Some(Some(value)) = answer else {
            return Ok(json!({"declined": true, "name": name, "outcome": outcome}));
        };
        let secret_ref = format!("secret_{}", &super::person::new_nonce()[..32]);
        let mut held = self.secrets.held.lock().unwrap_or_else(|e| e.into_inner());
        held.retain(|_, h| h.at.elapsed() < HELD_TTL);
        if held.len() >= HELD_LIMIT
            && let Some(oldest) = held.iter().min_by_key(|(_, h)| h.at).map(|(k, _)| k.clone())
        {
            held.remove(&oldest);
        }
        held.insert(secret_ref.clone(), Held { project, value, at: Instant::now() });
        Ok(json!({"secretRef": secret_ref, "name": name}))
    }

    /// The person's answer to a card: `value` None declines it.
    pub fn submit_secret(
        &self,
        session: &Session,
        secret_id: &str,
        value: Option<Zeroizing<String>>,
    ) -> Result<(), RpcError> {
        if let Some(v) = &value
            && (v.is_empty() || v.len() > MAX_VALUE_BYTES)
        {
            return Err(RpcError::invalid_params("the secret must be 1 byte to 64 KiB"));
        }
        let pending = {
            let mut map = self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner());
            match map.get(secret_id) {
                Some(p) if p.session == session.id => map.remove(secret_id),
                _ => None,
            }
        };
        let pending = pending.ok_or_else(|| {
            RpcError::invalid_params("no secret request with that id in this chat")
        })?;
        pending
            .reply
            .send(value)
            .map_err(|_| RpcError::invalid_params("the agent stopped waiting for this secret"))
    }

    /// Spends `secret_ref` once: runs `argv` in the chat's folder with the
    /// value in `env`, and returns what it printed, the value masked.
    pub async fn run_with_secret(
        &self,
        session: &Session,
        secret_ref: &str,
        env: &str,
        argv: &[String],
    ) -> Result<Value, RpcError> {
        if !valid_name(env) {
            return Err(RpcError::invalid_params(
                "env must be an environment variable name (A-Z, 0-9, _)",
            ));
        }
        let Some((program, args)) = argv.split_first() else {
            return Err(RpcError::invalid_params("argv must name a command"));
        };
        let project = project_of(session)?;
        let value = {
            let mut held = self.secrets.held.lock().unwrap_or_else(|e| e.into_inner());
            held.retain(|_, h| h.at.elapsed() < HELD_TTL);
            match held.get(secret_ref).map(|h| h.project == project) {
                None => {
                    return Err(RpcError::invalid_params(
                        "unknown, spent or expired secretRef: ask for the secret again",
                    ));
                }
                Some(false) => {
                    return Err(RpcError::invalid_params(
                        "this secretRef belongs to another project",
                    ));
                }
                Some(true) => held.remove(secret_ref),
            }
        };
        let Some(Held { project, value, at }) = value else {
            return Err(RpcError::invalid_params("unknown, spent or expired secretRef"));
        };
        let mut command = tokio::process::Command::new(program);
        command.env_clear();
        for key in KEPT_ENV.iter().copied().chain(["PATH"]) {
            if let Some(v) = std::env::var_os(key) {
                command.env(key, v);
            }
        }
        for (key, v) in std::env::vars_os() {
            if key.to_str().is_some_and(|k| k.starts_with("LC_")) {
                command.env(key, v);
            }
        }
        crate::login_env::apply_tokio(&mut command);
        crate::cua_socket::scrub_agent_env(&mut command);
        command
            .args(args)
            .current_dir(&project)
            .env(env, value.as_str())
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        // Its own process group, so a timeout ends what it started too.
        #[cfg(unix)]
        command.process_group(0);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(e) => {
                // Nothing ran: the ref stays for the next try.
                let held = Held { project, value, at };
                let mut map = self.secrets.held.lock().unwrap_or_else(|e| e.into_inner());
                map.insert(secret_ref.to_owned(), held);
                return Err(RpcError::invalid_params(format!("could not run {program}: {e}")));
            }
        };
        #[cfg(unix)]
        let group = child.id();
        let cap = MAX_OUTPUT_BYTES + value.len();
        let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
        let run = async {
            let (out, err, status) =
                tokio::join!(read_capped(stdout, cap), read_capped(stderr, cap), child.wait());
            status.map(|status| (out, err, status))
        };
        let result = match tokio::time::timeout(RUN_TIMEOUT, run).await {
            Err(_) => {
                #[cfg(unix)]
                if let Some(pid) = group.and_then(|p| i32::try_from(p).ok()) {
                    // SAFETY: killpg has no memory preconditions; the group is the child's own.
                    unsafe { libc::killpg(pid, libc::SIGKILL) };
                }
                json!({"exitCode": Value::Null, "timedOut": true, "stdout": "", "stderr": ""})
            }
            Ok(Err(e)) => return Err(RpcError::internal(format!("running {program}: {e}"))),
            Ok(Ok((out, err, status))) => json!({
                "exitCode": status.code(),
                "stdout": mask(out, &value),
                "stderr": mask(err, &value),
            }),
        };
        self.append(
            session,
            "mux",
            "secret_run",
            json!({"env": env, "argv": argv, "exitCode": result["exitCode"]}),
        );
        Ok(result)
    }
}

impl Hub {
    /// Closes the session's open card with its turn (a cancel, a kill, an
    /// ended agent): the asker gets `cancelled`, and a late answer finds no card.
    pub(super) fn cancel_pending_secrets(&self, session: &Session) {
        // Dropping the reply ends the ask's wait.
        self.secrets
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|_, p| p.session != session.id);
    }
}

impl Secrets {
    /// Whether `session` has an open card (the Waiting status stays for it).
    pub(super) fn waiting_in(&self, session: &str) -> bool {
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .any(|p| p.session == session)
    }
}
