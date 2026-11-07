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
    /// Held across [`Hub::close_stale_card`]'s read and append, so two late answers write one
    /// decision.
    closing: StdMutex<()>,
}

struct Pending {
    session: String,
    /// The card's `decisionNonce`, for a card a phone may answer with a signature
    /// ([`CardKind::signed`]); None for the others, which only the person's connection answers.
    nonce: Option<String>,
    /// [`CardKind::one_line`].
    one_line: Option<usize>,
    reply: oneshot::Sender<Option<Zeroizing<String>>>,
}

struct Held {
    project: String,
    value: Zeroizing<String>,
    at: Instant,
}

/// The records a private card writes, and the outcome words of its answer.
#[derive(Clone, Copy)]
pub(super) struct CardKind {
    pub request: &'static str,
    pub decision: &'static str,
    pub provided: &'static str,
    pub declined: &'static str,
    /// A phone's signed answer counts too (`Hub::card_answer_signed`): the request record carries a
    /// `decisionNonce` and this run's `personInstance`.
    pub signed: bool,
    /// The value must be one line of at most this many bytes (a password): `secret_submit`
    /// refuses another and the card stays open, so a decision is never recorded for a value the
    /// asker cannot use.
    pub one_line: Option<usize>,
}

/// The option a phone signs for a card's value (`approvers::message`, the card's id as the
/// permission). A decline is not signed.
pub const CARD_PROVIDE: &str = "card_provide";

const CARD_SECRET: CardKind = CardKind {
    request: "secret_request",
    decision: "secret_decision",
    provided: "provided",
    declined: "declined",
    signed: false,
    one_line: None,
};

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
pub(super) async fn read_capped(
    pipe: Option<impl AsyncRead + Unpin>,
    cap: usize,
) -> (Vec<u8>, bool) {
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
fn mask(read: (Vec<u8>, bool), value: &str) -> String {
    mask_within(read, value, MAX_OUTPUT_BYTES)
}

/// [`mask`], cut to `max` bytes.
pub(super) fn mask_within((bytes, cut): (Vec<u8>, bool), value: &str, max: usize) -> String {
    let end = if cut { bytes.len() - cut_value_len(&bytes, value.as_bytes()) } else { bytes.len() };
    let masked = String::from_utf8_lossy(&bytes[..end]).replace(value, MASK);
    let mut end = masked.len().min(max);
    while !masked.is_char_boundary(end) {
        end -= 1;
    }
    masked[..end].to_owned()
}

/// The variables a secret's command keeps from the daemon, besides the login
/// environment: never a token or an acpmux setting.
pub(super) const KEPT_ENV: &[&str] =
    &["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM"];

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
        let card = json!({"name": name, "reason": reason});
        let (outcome, value) = self.ask_person(session, CARD_SECRET, card, ASK_TTL).await;
        let Some(value) = value else {
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

    /// Shows the chat a private card of `kind` (`{kind}_request` with `secretId` and `card`'s
    /// fields) and waits at most `ttl` for the person's answer through `secret_submit`, then
    /// records `{kind}_decision` with the outcome: `provided` with the value, `declined`, or
    /// `cancelled` (a newer card, the turn's end, the wait running out). One open card per chat,
    /// whatever its kind. The value is never in a record.
    pub(super) async fn ask_person(
        &self,
        session: &Session,
        kind: CardKind,
        card: Value,
        ttl: Duration,
    ) -> (&'static str, Option<Zeroizing<String>>) {
        let secret_id = super::person::new_nonce();
        let nonce = kind.signed.then(super::person::new_nonce);
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner());
            // Dropping the old card's reply answers its asker `cancelled`.
            pending.retain(|_, p| p.session != session.id);
            let card = Pending {
                session: session.id.clone(),
                nonce: nonce.clone(),
                one_line: kind.one_line,
                reply: tx,
            };
            pending.insert(secret_id.clone(), card);
        }
        // Stopped (`Hub::kill` marks it closing before it cancels the cards): a card that came
        // after the cancel is cancelled here.
        if session.closing.load(Ordering::SeqCst) || session.status() == SessionStatus::Closed {
            self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&secret_id);
            return ("cancelled", None);
        }
        let mut record = card.clone();
        cmux_json::JsonSet::set(&mut record, "secretId", json!(secret_id));
        if let Some(nonce) = &nonce {
            cmux_json::JsonSet::set(&mut record, super::person::DECISION_NONCE_FIELD, json!(nonce));
            cmux_json::JsonSet::set(&mut record, "personInstance", json!(self.person.instance()));
        }
        self.append(session, "mux", kind.request, record);
        let prev = session.status();
        self.set_status(session, SessionStatus::Waiting);
        let answer = tokio::time::timeout(ttl, rx).await.ok().and_then(Result::ok);
        // A cancelled or expired card is gone from the pane as well.
        self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&secret_id);
        let outcome = match answer {
            Some(Some(_)) => kind.provided,
            Some(None) => kind.declined,
            None => "cancelled",
        };
        let mut decision = card;
        cmux_json::JsonSet::set(&mut decision, "secretId", json!(secret_id));
        cmux_json::JsonSet::set(&mut decision, "outcome", json!(outcome));
        self.append(session, "mux", kind.decision, decision);
        if session.status() == SessionStatus::Waiting
            && session.permissions.lock().unwrap_or_else(|e| e.into_inner()).pending.is_empty()
            && !self.secrets.waiting_in(&session.id)
        {
            self.set_status(session, super::permissions::status_after_ask(session, prev));
        }
        (outcome, answer.flatten())
    }

    /// An answer to a card this daemon no longer holds (it restarted while the card was open) whose
    /// request record has no decision: every client still shows that card and would keep
    /// answering it. Its `cancelled` decision closes it everywhere. A card this run asked is left
    /// alone: its own ask writes its decision, and may be about to. Reads this one chat's card
    /// records, only on this error path.
    fn close_stale_card(&self, session: &Session, secret_id: &str) {
        const KINDS: [CardKind; 2] = [CARD_SECRET, super::elevation::CARD];
        let names = KINDS.map(|k| [k.request, k.decision]).concat();
        let _one = self.secrets.closing.lock().unwrap_or_else(|e| e.into_inner());
        let mut open: Option<(CardKind, Value)> = None;
        let _ = self.store.scan_kinds(&session.id, &names, &mut |event| {
            if event.msg.get("secretId").and_then(Value::as_str) == Some(secret_id) {
                open = KINDS
                    .into_iter()
                    .find(|k| k.request == event.kind && event.at < self.started_at)
                    .map(|k| (k, event.msg));
            }
            true
        });
        let Some((kind, mut decision)) = open else { return };
        if let Some(fields) = decision.as_object_mut() {
            fields.remove(super::person::DECISION_NONCE_FIELD);
            fields.remove("personInstance");
            fields.insert("outcome".into(), json!("cancelled"));
        }
        self.append(session, "mux", kind.decision, decision);
    }

    /// Whether a `secret_submit` from a connection that is not the person counts for this card.
    /// Only a card whose kind is [`CardKind::signed`] has a nonce; a secret card stays the
    /// person's own. On such a card a decline counts from anyone (it narrows, as a deny of a
    /// permission does), and a value only with an enrolled phone's signature over the card's
    /// answer (`approvers.rs`): the card's id as the permission, [`CARD_PROVIDE`] as the option,
    /// the card's own nonce, no answers. The nonce is spent when it counts, so a signature
    /// answers once.
    pub fn card_answer_signed(
        &self,
        session: &Session,
        secret_id: &str,
        provides: bool,
        params: &Value,
    ) -> bool {
        let nonce = {
            let pending = self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner());
            match pending.get(secret_id) {
                Some(p) if p.session == session.id => p.nonce.clone(),
                _ => None,
            }
        };
        let Some(nonce) = nonce else { return false };
        if !provides {
            return true;
        }
        let meta = params.pointer("/_meta/acpmux");
        let field = |f: &str| meta.and_then(|m| m.get(f));
        let (Some(sent_nonce), Some(signed)) = (
            field(super::person::DECISION_NONCE_FIELD).and_then(Value::as_str),
            field(super::approvers::DECISION_FIELD).filter(|v| v.is_object()),
        ) else {
            return false;
        };
        if !cmux_local_auth::tokens_match(sent_nonce, &nonce) {
            return false;
        }
        self.person.approvers.verifies_then(
            self.person.instance(),
            &session.id,
            secret_id,
            CARD_PROVIDE,
            &nonce,
            None,
            signed,
            super::approvers::unix_now(),
            || self.person.spend_decision(&nonce),
        )
    }

    /// The person's answer to a card: `value` None declines it.
    /// Whether `value` fits the open card `secret_id`: 1 byte to 64 KiB, and one line of at most
    /// the card's bound for a sudo card. Checked before an approver signature is spent, so a value
    /// the card refuses leaves both the card and the phone's retry open.
    pub fn check_card_value(
        &self,
        session: &Session,
        secret_id: &str,
        value: Option<&str>,
    ) -> Result<(), RpcError> {
        let Some(v) = value else { return Ok(()) };
        if v.is_empty() || v.len() > MAX_VALUE_BYTES {
            return Err(RpcError::invalid_params("the secret must be 1 byte to 64 KiB"));
        }
        let map = self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(Pending { session: owner, one_line: Some(max), .. }) = map.get(secret_id)
            && *owner == session.id
            && (v.len() > *max || v.contains(['\n', '\r', '\0']))
        {
            return Err(RpcError::invalid_params(format!(
                "the password must be one line of at most {max} bytes"
            )));
        }
        Ok(())
    }

    /// Whether `secret_id` is an open card of this chat.
    pub fn card_open(&self, session: &Session, secret_id: &str) -> bool {
        let map = self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner());
        map.get(secret_id).is_some_and(|p| p.session == session.id)
    }

    pub fn submit_secret(
        &self,
        session: &Session,
        secret_id: &str,
        value: Option<Zeroizing<String>>,
    ) -> Result<(), RpcError> {
        // A value the card cannot use leaves it open for another try.
        self.check_card_value(session, secret_id, value.as_deref().map(String::as_str))?;
        let pending = {
            let mut map = self.secrets.pending.lock().unwrap_or_else(|e| e.into_inner());
            match map.get(secret_id) {
                Some(p) if p.session == session.id => map.remove(secret_id),
                _ => None,
            }
        };
        let Some(pending) = pending else {
            self.close_stale_card(session, secret_id);
            return Err(RpcError::invalid_params("no secret request with that id in this chat"));
        };
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
