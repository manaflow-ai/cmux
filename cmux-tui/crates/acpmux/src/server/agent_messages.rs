//! Controls over the agent messages this daemon delivered or held, on this daemon only (never
//! forwarded to a peer, `peer_forward.rs`):
//!
//! - `_acpmux/prompt_withdraw`: an agent message's sender takes it back (`hub/withdraw.rs`); the
//!   unix socket only.
//! - `_acpmux/agent_pair_resume {sessionId, peerSessionId?}`: the person resumes the pairs the
//!   runaway guard paused that `sessionId` is in (`hub/agent_pairs.rs`); `peerSessionId` only
//!   picks one of them. Only a connection that proved the person key (`hub/person.rs`) on this
//!   machine (the unix socket or the app, `remote_guard.rs` refusing Web and Peer first).
//! - The person's own prompt into a chat resumes that chat's pairs too ([`person_prompt`]).
//!
//! And `_acpmux/retry {sessionId, subagentId?}` ([`retry`]): the chat's failed last turn, retried
//! now (`hub/auto_resume/retry_turn.rs`), or with `subagentId` that failed subagent, resumed now
//! (`hub/subagent_retry_manual.rs`). It may reach a peer's chat (`peer_forward.rs`).
//!
//! And `_acpmux/inbox_digest {sessionId, dryRun?}` ([`inbox_digest`]): the agent messages waiting
//! in the chat's queue go in as one digest (`hub/inbox_digest.rs`). The unix socket only, from
//! the person or the chat's own agent (its proven caller token); never from another session's
//! agent.

use super::{Conn, Origin, session_key, str_param};
use crate::hub::{Hub, Session};
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The connection is the person, on this machine.
fn local_person(conn: &Conn) -> bool {
    conn.is_person() && !conn.origin.web_class()
}

/// `_acpmux/prompt_withdraw`, `_acpmux/agent_pair_resume`, `_acpmux/retry` or
/// `_acpmux/inbox_digest`.
pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if m == method::MUX_RETRY {
        return retry(hub, conn, params).await;
    }
    if m == method::MUX_INBOX_DIGEST {
        return inbox_digest(hub, conn, params).await;
    }
    if m == method::MUX_PROMPT_WITHDRAW {
        // The unix socket only; `remote_guard.rs` refuses every other origin first.
        if conn.origin != Origin::Local {
            return Err(crate::prompt_provenance::withdraw_origin_refused());
        }
        let s = hub.resolve(session_key(params)?)?;
        return hub.prompt_withdraw(&s, params).await;
    }
    // An agent may not resume its own pair.
    if !local_person(conn) {
        return Err(Hub::agent_pair_resume_refused());
    }
    let s = hub.resolve(session_key(params)?)?;
    // The pairs come back with the logs (`restore_queue`): resume what they restored.
    hub.wait_logs().await;
    Ok(hub.agent_pair_resume(&s.id, str_param(params, "peerSessionId")))
}

/// `_acpmux/inbox_digest`: the unix socket only (`remote_guard.rs` refuses every other origin
/// first), and never for another session's agent. A connection that says it runs in a session
/// proves it with that session's caller token (one this run issued) and drains only that
/// session's inbox; one that names no session is trusted as the socket trusts it for every queue
/// change (`hub/inbox_digest.rs` module docs).
async fn inbox_digest(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    if conn.origin != Origin::Local {
        return Err(Hub::inbox_digest_origin_refused());
    }
    let s = hub.resolve(session_key(params)?)?;
    // A token this run did not issue proves no session, the one it names included.
    if conn.unproven_caller.get().is_some() && !conn.is_person() {
        return Err(Hub::inbox_digest_caller_not_proven());
    }
    if conn.caller().is_some_and(|id| id != s.id) {
        return Err(Hub::inbox_digest_other_agent());
    }
    let dry_run = params.get("dryRun").and_then(Value::as_bool).unwrap_or(false);
    hub.inbox_digest(&s, &conn.label(), dry_run).await
}

/// `_acpmux/retry`: under the caller's rules, as a prompt it sent (its control, the trust gate
/// and a paired machine's Full access). With `subagentId`, that failed subagent is resumed.
async fn retry(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    // A retry reads the failed turn's log, and its held prompts come back with its log.
    hub.session_log(&s).await;
    let by = crate::hub::auto_resume::retry_turn::RetryBy {
        control: super::remote_guard::control_of(conn.origin, conn.auth, params),
        trust_gate: super::trust_gate::gated(conn.origin, params),
        full_access_device: super::remote_guard::full_access_device(hub, conn, params),
        from: None,
    };
    hub.retry(&s, str_param(params, "subagentId"), by).await
}

/// Before the person's own `session/prompt` into `s` (no provenance: not an agent's message, from
/// a connection that proved the person key on this machine): every agent pair `s` is in starts
/// over, and a paused one is resumed.
pub(super) async fn person_prompt(
    hub: &Arc<Hub>,
    conn: &Conn,
    s: &Arc<Session>,
    agent_message: bool,
) {
    if !agent_message && local_person(conn) {
        // After its log and its peers' load, which restore the pairs this resumes.
        hub.pair_peer_logs(s).await;
        hub.agent_pair_person_prompt(s);
    }
}
