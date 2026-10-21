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

use super::{Conn, Origin, session_key, str_param};
use crate::hub::{Hub, PromptOptions, Session};
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The connection is the person, on this machine.
fn local_person(conn: &Conn) -> bool {
    conn.is_person() && !conn.origin.web_class()
}

/// `_acpmux/prompt_withdraw` or `_acpmux/agent_pair_resume`.
pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
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
    Ok(hub.agent_pair_resume(&s.id, str_param(params, "peerSessionId")))
}

/// Before the person's own `session/prompt` into `s` (no provenance: not an agent's message, from
/// a connection that proved the person key on this machine): every agent pair `s` is in starts
/// over, and a paused one is resumed.
pub(super) fn person_prompt(hub: &Arc<Hub>, conn: &Conn, s: &Session, opts: &PromptOptions) {
    if opts.provenance.is_none() && local_person(conn) {
        hub.agent_pair_person_prompt(s);
    }
}
