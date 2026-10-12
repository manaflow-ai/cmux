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
//!   comes back with the value masked. A refused run spends nothing.
//! - An unspent ref expires after [`HELD_TTL`]; at most [`HELD_LIMIT`] are
//!   held. A card nobody fills is cancelled after [`ASK_TTL`].
//!
//! The masking covers the value as given. A command that prints it encoded
//! (base64, reversed) shows it to the agent: the ref limits where and how
//! often the value is used, not what a command it runs may do with it.

use super::{Hub, Session, SessionStatus};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex as StdMutex;
use std::time::{Duration, Instant};
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

fn mask(bytes: &[u8], value: &str) -> String {
    let cut = &bytes[..bytes.len().min(MAX_OUTPUT_BYTES)];
    String::from_utf8_lossy(cut).replace(value, MASK)
}

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
        let reason: String = reason.chars().take(MAX_REASON_CHARS).collect();
        let project = project_of(session)?;
        let secret_id = super::person::new_nonce();
        let (tx, rx) = oneshot::channel();
        self.secrets
            .pending
            .lock()
            .unwrap()
            .insert(secret_id.clone(), Pending { session: session.id.clone(), reply: tx });
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
            let next = if session.turn().is_some() { SessionStatus::Running } else { prev };
            self.set_status(session, next);
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
                Some(true) => held.remove(secret_ref).map(|h| h.value),
            }
        };
        let Some(value) = value else {
            return Err(RpcError::invalid_params("unknown, spent or expired secretRef"));
        };
        let child = tokio::process::Command::new(program)
            .args(args)
            .current_dir(&project)
            .env(env, value.as_str())
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| RpcError::invalid_params(format!("could not run {program}: {e}")))?;
        let result = match tokio::time::timeout(RUN_TIMEOUT, child.wait_with_output()).await {
            Err(_) => {
                json!({"exitCode": Value::Null, "timedOut": true, "stdout": "", "stderr": ""})
            }
            Ok(Err(e)) => return Err(RpcError::internal(format!("running {program}: {e}"))),
            Ok(Ok(out)) => json!({
                "exitCode": out.status.code(),
                "stdout": mask(&out.stdout, &value),
                "stderr": mask(&out.stderr, &value),
            }),
        };
        self.append(
            session,
            "mux",
            "secret_run",
            json!({"env": env, "program": program, "exitCode": result["exitCode"]}),
        );
        Ok(result)
    }
}

impl Secrets {
    fn waiting_in(&self, session: &str) -> bool {
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .any(|p| p.session == session)
    }
}
