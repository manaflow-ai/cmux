//! An agent asks to connect an MCP server (plans/cmux-next/mcp-connect-DESIGN.md).
//!
//! The agent's `mcp_connect` tool calls `_acpmux/mcp_connect_request {sessionId, server, scope,
//! reason}`, which waits. The daemon resolves and checks the server first (`cmux-mcp-connect`: the
//! registry, the URL rules, the command rules); a refused or unknown input answers at once with
//! no card. Otherwise the chat shows a card from the `mcp_connect_request` record: the exact URL or
//! command, the publisher, Verified or not, the sign-in and its scopes, the proposed scope. The
//! person answers with `_acpmux/mcp_connect_answer`, accepted only from the person's connection
//! (`hub/person.rs`), so an agent, and so a prompt-injected "connect to X", can never approve its
//! own card (threat model T1, T2).
//!
//! - The scope is the person's choice; the agent's is only the proposal (T7).
//! - A chat has at most one open connect card: a new ask replaces it and the old asker gets
//!   `cancelled` (T18). A chat a remote device started asks for none (T17).
//! - A card nobody answers is cancelled after [`ASK_TTL`], and with the turn
//!   (`cancel_pending_mcp_connects`).
//! - No record holds a secret: sign-in and keys are later steps on the person's connection.

use super::{Hub, Session, SessionStatus};
use crate::rpc::RpcError;
use cmux_mcp_connect::registry::{AuthKind, Registry};
use cmux_mcp_connect::resolve::{Resolved, resolve};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::Ordering;
use std::time::Duration;
use tokio::sync::oneshot;

pub(super) const ASK_TTL: Duration = Duration::from_secs(15 * 60);
const MAX_REASON_CHARS: usize = 300;
const MAX_INPUT_CHARS: usize = 2048;
/// The scopes a card offers, narrowest first (design section 2b).
pub const SCOPES: [&str; 5] = ["chat", "chief", "allChiefs", "agents", "everywhere"];

#[derive(Default)]
pub(crate) struct McpConnects {
    pending: StdMutex<HashMap<String, Pending>>,
}

struct Pending {
    session: String,
    reply: oneshot::Sender<Answer>,
}

/// The person's answer.
struct Answer {
    approve: bool,
    scope: String,
}

fn auth_word(kind: AuthKind) -> &'static str {
    match kind {
        AuthKind::None => "none",
        AuthKind::Oauth => "oauth",
        AuthKind::Device => "device",
        AuthKind::Key => "key",
    }
}

/// The card's facts for a resolved server (never a secret).
fn card_of(resolved: &Resolved) -> Option<Value> {
    Some(match resolved {
        Resolved::Known { entry, target } => json!({
            "name": entry.name, "title": entry.title, "publisher": entry.publisher,
            "verified": resolved.verified(), "idn": target.idn,
            "transport": "remote", "url": target.url,
            "auth": auth_word(entry.auth), "scopes": entry.scopes,
            "keyName": entry.key_header, "keyOptional": entry.key_optional,
        }),
        Resolved::Remote { target } => json!({
            "name": target.host, "title": target.host, "publisher": target.publisher,
            "verified": false, "idn": target.idn, "loopback": target.loopback,
            "transport": "remote", "url": target.url,
            // A custom server's sign-in is learned from its metadata after the person approves,
            // so nothing is fetched from an unapproved host (T4).
            "auth": "discover", "scopes": [],
        }),
        Resolved::Local { command } => json!({
            "name": command.argv.first().map(|p| p.rsplit('/').next().unwrap_or(p)).unwrap_or_default(),
            "title": command.argv.first().cloned().unwrap_or_default(),
            "publisher": "this Mac", "verified": false, "idn": false,
            "transport": "local", "argv": command.argv, "fetchesCode": command.fetches_code,
            "auth": "none", "scopes": [],
        }),
        Resolved::Unknown { .. } => return None,
    })
}

impl Hub {
    /// The agent's ask: resolves `input`, shows the card, waits for the person. Returns
    /// `{status: approved, name, scope}`, `{status: declined|cancelled, name}`, or
    /// `{status: unknown, near}` with no card.
    pub async fn request_mcp_connect(
        &self,
        session: &Session,
        input: &str,
        proposed_scope: &str,
        reason: &str,
    ) -> Result<Value, RpcError> {
        if session.meta().remote_origin {
            return Err(RpcError::invalid_params(
                "a chat a remote device started connects no MCP servers",
            ));
        }
        if input.chars().count() > MAX_INPUT_CHARS {
            return Err(RpcError::invalid_params("the server input is too long"));
        }
        let resolved = resolve(input, &Registry::builtin())
            .map_err(|refusal| RpcError::invalid_params(refusal.0))?;
        let Some(mut card) = card_of(&resolved) else {
            let near = match resolved {
                Resolved::Unknown { near } => near,
                _ => Vec::new(),
            };
            return Ok(json!({"status": "unknown", "near": near}));
        };
        let name = card["name"].as_str().unwrap_or_default().to_owned();
        let proposed = if SCOPES.contains(&proposed_scope) { proposed_scope } else { "chat" };
        let reason: String = reason.chars().take(MAX_REASON_CHARS).collect();
        let request_id = super::person::new_nonce();
        card["requestId"] = json!(request_id);
        card["reason"] = json!(reason);
        card["proposedScope"] = json!(proposed);
        card["scopesOffered"] = json!(SCOPES);
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner());
            // Dropping the old card's reply answers its asker `cancelled`.
            pending.retain(|_, p| p.session != session.id);
            pending.insert(request_id.clone(), Pending { session: session.id.clone(), reply: tx });
        }
        if session.closing.load(Ordering::SeqCst) || session.status() == SessionStatus::Closed {
            self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&request_id);
            return Ok(json!({"status": "cancelled", "name": name}));
        }
        self.append(session, "mux", "mcp_connect_request", card);
        let prev = session.status();
        self.set_status(session, SessionStatus::Waiting);
        let answer = tokio::time::timeout(ASK_TTL, rx).await.ok().and_then(Result::ok);
        self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&request_id);
        let (status, scope) = match &answer {
            Some(Answer { approve: true, scope }) => ("approved", Some(scope.clone())),
            Some(Answer { approve: false, .. }) => ("declined", None),
            None => ("cancelled", None),
        };
        self.append(
            session,
            "mux",
            "mcp_connect_decision",
            json!({"requestId": request_id, "name": name, "outcome": status, "scope": scope}),
        );
        if session.status() == SessionStatus::Waiting
            && session.permissions.lock().unwrap_or_else(|e| e.into_inner()).pending.is_empty()
            && !self.secrets.waiting_in(&session.id)
            && !self.mcp_connects.waiting_in(&session.id)
        {
            self.set_status(session, super::permissions::status_after_ask(session, prev));
        }
        Ok(match scope {
            Some(scope) => json!({"status": status, "name": name, "scope": scope}),
            None => json!({"status": status, "name": name}),
        })
    }

    /// The person's answer to a connect card. `scope` is theirs (the card's menu); it must be one
    /// of [`SCOPES`].
    pub fn answer_mcp_connect(
        &self,
        session: &Session,
        request_id: &str,
        approve: bool,
        scope: Option<&str>,
    ) -> Result<(), RpcError> {
        let scope = match (approve, scope) {
            (true, Some(s)) if SCOPES.contains(&s) => s.to_owned(),
            (true, _) => {
                return Err(RpcError::invalid_params(format!(
                    "an approval names its scope: one of {}",
                    SCOPES.join(", ")
                )));
            }
            (false, _) => String::new(),
        };
        let pending = {
            let mut map = self.mcp_connects.pending.lock().unwrap_or_else(|e| e.into_inner());
            match map.get(request_id) {
                Some(p) if p.session == session.id => map.remove(request_id),
                _ => None,
            }
        };
        let pending = pending.ok_or_else(|| {
            RpcError::invalid_params("no MCP connect card with that id in this chat")
        })?;
        pending
            .reply
            .send(Answer { approve, scope })
            .map_err(|_| RpcError::invalid_params("the agent stopped waiting for this card"))
    }

    /// Closes the session's open connect card with its turn: the asker gets `cancelled`.
    pub(super) fn cancel_pending_mcp_connects(&self, session: &Session) {
        self.mcp_connects
            .pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|_, p| p.session != session.id);
    }
}

impl McpConnects {
    /// Whether `session` has an open connect card (the Waiting status stays for it).
    pub(super) fn waiting_in(&self, session: &str) -> bool {
        self.pending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .any(|p| p.session == session)
    }
}
