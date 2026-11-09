//! Who may Stop a chat from a connection that is not the unix socket (Web, Peer). A chat started
//! on this machine (the unix socket, the app: not `remote_origin`) belongs to the person here
//! (#21134, D13): a Web client (the shared dashboard token), a paired device's link, or a peer
//! forwarding for either (`via: web`, `via: device`) never stops it. The person's own daemon on
//! another machine does: a link that presented this launch's peer token, asking for itself or for
//! its own person's app or unix socket (`hub/vm_boundary.rs` `owner`). That is the same proof that
//! already lets it start a chat here under any policy, end one (`_acpmux/kill`), or close one;
//! anyone holding the peer token reads it from this user's own `ACPMUX_HOME` and could stop the
//! chat over the unix socket as well. Leo pressed Stop on a lane running on a peer and nothing
//! happened (2026-10-29: "i literally can't stop you i clicked the stop button and it didnt do
//! anything"): every peer link was refused here, and the notification form only logged it.
//!
//! A teammate through the Cloud carrier (`ConnAuth::CarrierTeam`, `carrier.rs`) stops a chat its
//! grant names, a chat started here included: the teammate verb `agent-session-cancel`
//! (`docs/carrier-roles.md`). The carrier gate (`carrier::gate`, and `takes_notification` for the
//! notification form) admitted the request only for a chat of the grant by the exact id of a
//! session here, before this check; any other chat never reaches it.
//!
//! A forwarded `personStop` (the person's Stop, `requests/person_stop.rs`) rides on the same
//! link, so it passes for the owner and is refused with the rest for anyone else.

use crate::rpc::RpcError;
use serde_json::Value;

/// `data.reason` of the refusal.
pub(in crate::server) const REASON: &str = "remote.session_cancel_ownership";

/// A Stop from `origin` (Web or Peer) of the chat `params` names: a chat a remote caller started,
/// a peer's chat (that peer judges it), or one started here when the link is the owner's.
pub(in crate::server) fn check(
    hub: &std::sync::Arc<crate::hub::Hub>,
    origin: crate::server::Origin,
    auth: crate::server::ConnAuth,
    params: &Value,
) -> Result<(), RpcError> {
    let key = crate::server::session_key(params)?;
    match hub.resolve(key) {
        Ok(session) if session.meta().remote_origin => Ok(()),
        Ok(_) if owner(origin, auth, params) => Ok(()),
        Ok(_) if auth == crate::server::ConnAuth::CarrierTeam => Ok(()),
        Ok(_) => Err(refused()),
        Err(_) if hub.resolve_remote(key).is_some() => Ok(()),
        Err(e) => Err(RpcError::invalid_params(format!(
            "session/cancel from a remote WebSocket connection is refused: the session cannot be resolved ({})",
            e.message
        ))),
    }
}

/// The person's own daemon on another machine, by the proof its link presented: the peer token,
/// not forwarding for its Web client (`Control::Peer`) nor for a paired machine (`via: device`).
/// A paired device's own credential (`ConnAuth::Device`) is never the owner here.
fn owner(origin: crate::server::Origin, auth: crate::server::ConnAuth, params: &Value) -> bool {
    origin == crate::server::Origin::Peer
        && auth.peer_daemon()
        && crate::hub::vm_boundary::owner(auth, super::control_of(origin, auth, params), params)
}

/// No host name: a guest who can name a chat here learns nothing more about this machine.
fn refused() -> RpcError {
    RpcError::invalid_params(
        "This chat runs on the machine that started it, and only its owner can stop it",
    )
    .with_data(serde_json::json!({"reason": REASON}))
}

#[cfg(test)]
mod tests {
    use super::owner;
    use crate::server::{ConnAuth, Origin};
    use serde_json::json;

    #[test]
    fn only_the_peer_tokens_own_link_is_the_owner() {
        let plain = json!({"sessionId": "s"});
        let via = |v: &str| json!({"sessionId": "s", "_meta": {"acpmux": {"via": v}}});
        assert!(owner(Origin::Peer, ConnAuth::PeerToken, &plain));
        assert!(owner(Origin::Peer, ConnAuth::PeerToken, &via("app")));
        assert!(!owner(Origin::Peer, ConnAuth::PeerToken, &via("web")));
        assert!(!owner(Origin::Peer, ConnAuth::PeerToken, &via("device")));
        for auth in
            [ConnAuth::Device, ConnAuth::ReadOnlyDevice, ConnAuth::ListenerToken, ConnAuth::None]
        {
            assert!(!owner(Origin::Peer, auth, &plain), "{auth:?}");
            assert!(!owner(Origin::Peer, auth, &via("app")), "{auth:?}");
        }
        for auth in [ConnAuth::ListenerToken, ConnAuth::PeerToken] {
            assert!(!owner(Origin::Web, auth, &plain), "{auth:?}");
        }
    }

    /// A local chat: a teammate through the carrier (its grant checked before, by the carrier
    /// gate) stops it; every other Web or paired-device proof is refused as before.
    #[tokio::test]
    async fn a_teammate_through_the_carrier_stops_a_local_chat_and_no_other_web_client_does() {
        let dir = std::env::temp_dir();
        let cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["claude"]}},
            "defaultHarness": "claude", "store": {"mode": "memory"}
        }))
        .unwrap();
        let store = crate::store::open(&cfg.store, &dir).unwrap();
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "local-1", "name": "local-1",
            "harness": "claude", "cwd": dir, "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
        let hub = crate::hub::Hub::new(cfg, store);
        let params = json!({"sessionId": "local-1"});
        assert!(!hub.resolve("local-1").unwrap().meta().remote_origin);
        assert!(super::check(&hub, Origin::Web, ConnAuth::CarrierTeam, &params).is_ok());
        for auth in [ConnAuth::ListenerToken, ConnAuth::Device, ConnAuth::ReadOnlyDevice] {
            let e = super::check(&hub, Origin::Web, auth, &params).unwrap_err();
            assert_eq!(e.data.unwrap()["reason"], super::REASON, "{auth:?}");
        }
        let via_web = json!({"sessionId": "local-1", "_meta": {"acpmux": {"via": "web"}}});
        for auth in [ConnAuth::PeerToken, ConnAuth::CarrierOwner] {
            let e = super::check(&hub, Origin::Peer, auth, &via_web).unwrap_err();
            assert_eq!(e.data.unwrap()["reason"], super::REASON, "{auth:?}");
        }
    }
}
