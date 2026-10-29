//! `_acpmux/session/auth {sessionId | target, refresh?}` (`hub/session_auth.rs`). A chat here,
//! or a `target` with no `host`, is answered here. A peer's chat, or a target on a peer
//! (`target.host`, a peer name), goes to that peer, as the peer answers it. A peer whose link is
//! down is answered here (`peerUnreachable`, from the link), and a peer on an acpmux without the
//! method `unknown`, saying so.

use super::Conn;
use crate::hub::Hub;
use crate::peer::Peer;
use crate::protocol::auth::{
    SessionAuthLoginKind, SessionAuthParams, SessionAuthResult, SessionAuthSource,
    SessionAuthState, SessionAuthTarget,
};
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let p: SessionAuthParams = serde_json::from_value(params.clone())
        .map_err(|e| RpcError::invalid_params(format!("{}: {e}", method::MUX_SESSION_AUTH)))?;
    // A probe or a check runs on this machine: never for a browser page on the listener.
    let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
    if p.refresh && control == crate::hub::Control::Web {
        return Err(RpcError::invalid_params(
            "a remote WebSocket connection reads sign-in evidence as last seen (no refresh)",
        ));
    }
    let reply = match (&p.session_id, &p.target) {
        (Some(key), None) => match hub.resolve(key) {
            Ok(s) => hub.session_auth(Some(&s), None, p.refresh).await?,
            Err(e) => {
                let Some((peer, id, row)) = hub.resolve_remote(key) else { return Err(e) };
                let harness = row.get("harness").and_then(Value::as_str).unwrap_or_default();
                let mut forwarded = json!({"sessionId": id, "refresh": p.refresh});
                super::remote_guard::mark_forwarded(
                    conn.origin,
                    conn.auth,
                    &params,
                    &mut forwarded,
                );
                ask_peer(&peer, forwarded, harness, None).await?
            }
        },
        (None, Some(target)) => match target.host.as_deref() {
            None => hub.session_auth(None, Some(target), p.refresh).await?,
            Some(host) => {
                let peer = hub
                    .peer_by_name(host)
                    .ok_or_else(|| RpcError::invalid_params(format!("no peer named {host:?}")))?;
                let there = SessionAuthTarget { host: None, ..target.clone() };
                let mut forwarded = json!({"target": there, "refresh": p.refresh});
                super::remote_guard::mark_forwarded(
                    conn.origin,
                    conn.auth,
                    &params,
                    &mut forwarded,
                );
                ask_peer(&peer, forwarded, &target.harness, target.route_id.as_deref()).await?
            }
        },
        _ => {
            return Err(RpcError::invalid_params(
                "exactly one of sessionId and target is required",
            ));
        }
    };
    serde_json::to_value(reply).map_err(|e| RpcError::internal(e.to_string()))
}

/// The peer's answer, as from that host; or this daemon's own when the peer cannot answer, naming
/// the route a target asked about (`route_id`; a chat's route is the peer's to know).
async fn ask_peer(
    peer: &Arc<Peer>,
    params: Value,
    harness: &str,
    route_id: Option<&str>,
) -> Result<SessionAuthResult, RpcError> {
    let here = |state, detail: String| {
        let link = (state == SessionAuthState::PeerUnreachable).then(|| peer.link());
        SessionAuthResult {
            state,
            source: if link.is_some() {
                SessionAuthSource::PeerLink
            } else {
                SessionAuthSource::None
            },
            evidence_at: link.map(|l| l.down_since.unwrap_or_else(crate::store::now_ms)),
            detail,
            harness: harness.to_owned(),
            host: Some(peer.name.clone()),
            route_id: route_id.map(str::to_owned),
            login: None,
            from_session_id: None,
        }
    };
    let down = || {
        let state = peer.state().as_str();
        here(SessionAuthState::PeerUnreachable, format!("the link to {} is {state}", peer.name))
    };
    if !peer.connected.load(Ordering::SeqCst) {
        return Ok(down());
    }
    if !peer.supports_session_auth() {
        let build = peer.remote_build().unwrap_or_else(|| "unknown".into());
        return Ok(here(
            SessionAuthState::Unknown,
            format!(
                "{} runs acpmux build {build}, which does not answer {}; `acpmux host update {}` updates it",
                peer.name,
                method::MUX_SESSION_AUTH,
                peer.name
            ),
        ));
    }
    let answer = match peer.request(method::MUX_SESSION_AUTH, params).await {
        Ok(answer) => answer,
        Err(e) => {
            // Not sent (`peer_unreachable`), or sent on a link that dropped (`peer_disconnected`).
            let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
            let unreachable = matches!(reason, Some("peer_unreachable" | "peer_disconnected"));
            return match link_failure(&peer.name, &e.message) {
                // The link went down under the request.
                _ if unreachable || !peer.connected.load(Ordering::SeqCst) => Ok(down()),
                Some(LinkFailure::Lost) => Ok(down()),
                // The link is up but the peer did not answer: nothing is known.
                Some(LinkFailure::TimedOut) => Ok(here(
                    SessionAuthState::Unknown,
                    format!("{} did not answer in time", peer.name),
                )),
                // The peer's own answer (a chat it does not have, bad params).
                None => Err(e),
            };
        }
    };
    let mut out: SessionAuthResult = serde_json::from_value(answer).map_err(|e| {
        RpcError::internal(format!("{} answered {}: {e}", peer.name, method::MUX_SESSION_AUTH))
    })?;
    out.host = Some(peer.name.clone());
    if let Some(login) = out.login.as_mut().filter(|l| l.kind == SessionAuthLoginKind::Terminal) {
        login.host = Some(peer.name.clone());
    }
    Ok(out)
}

/// How the link failed a request, as `Peer::request` words it (`peer.rs`), when it did: not an
/// answer of the peer's.
enum LinkFailure {
    /// The connection closed, or dropped the request with it.
    Lost,
    TimedOut,
}

fn link_failure(peer: &str, message: &str) -> Option<LinkFailure> {
    let rest = message.strip_prefix("peer ")?.strip_prefix(peer)?;
    match rest {
        " connection closed" | " dropped the request" => Some(LinkFailure::Lost),
        // `peer NAME timed out after Ns`.
        _ if rest == " timed out" || rest.starts_with(" timed out after ") => {
            Some(LinkFailure::TimedOut)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_link_failure_is_read_from_the_links_own_words() {
        let timed_out = |m| matches!(link_failure("hb", m), Some(LinkFailure::TimedOut));
        let lost = |m| matches!(link_failure("hb", m), Some(LinkFailure::Lost));
        assert!(timed_out("peer hb timed out after 30s"));
        assert!(timed_out("peer hb timed out"));
        assert!(lost("peer hb connection closed"));
        assert!(lost("peer hb dropped the request"));
        // The peer's own answer, or another peer's words, is not the link's.
        assert!(link_failure("hb", "session not found: abc").is_none());
        assert!(link_failure("hb", "peer hbx timed out after 3s").is_none());
        assert!(link_failure("hbx", "peer hb timed out after 3s").is_none());
    }
}
