use super::*;
use crate::config::{Config, StoreMode};
use crate::session_identity::SessionReceipt;

/// A hub with no chat of its own, and peer hb (listed, never run) listing a working chat:
/// `Hub::resolve_remote` needs the peer as well as its row (`hub/own_host.rs` `add_peer`).
fn hub_with_a_peer_chat() -> Arc<Hub> {
    let mut config: Config = serde_json::from_value(json!({})).unwrap();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let row = crate::hub::RemoteSession {
        peer: "hb".into(),
        summary: json!({"sessionId": "peer-chat-1", "name": "hb/chat", "status": "running"}).into(),
        receipt: SessionReceipt {
            host_id: "hb".into(),
            mux_session_id: "peer-chat-1".into(),
            agent_session_id: None,
            generation: 1,
        },
    };
    hub.remote_sessions.write().insert("hb/peer-chat-1".into(), row);
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new("hb", "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert("hb".to_owned(), peer);
    hub
}

/// The child's `name` survives the rebuilt `session/fork` (Try another approach labels its sibling).
#[test]
fn a_turn_fork_keeps_the_childs_name() {
    let top = carried_meta(
        &json!({"sessionId": "s", "throughSeq": 3, "name": "Try another approach · Repo"}),
    );
    assert_eq!(top.get("name"), Some(&json!("Try another approach · Repo")));
    // The `_meta` name wins, as `session/fork` reads it; a non-string top-level name is dropped.
    let meta =
        carried_meta(&json!({"name": "top", "_meta": {"acpmux": {"name": "meta", "via": "hb"}}}));
    assert_eq!(meta.get("name"), Some(&json!("meta")));
    assert_eq!(meta.get("via"), Some(&json!("hb")));
    assert!(carried_meta(&json!({"name": 7})).get("name").is_none());
    assert!(carried_meta(&json!({"sessionId": "s"})).is_empty());
}

/// Leo, 2026-11-11: "why are only some chats forkable". A fork of a peer's chat through a turn
/// or before a prompt stays `acp.session.fork` with its params as sent, so it is forwarded
/// whole and the peer that holds the chat forks it. A `live` one (a Cloud machine's too) is
/// that machine's `session/fork`, onto another harness when the pick names one (Leo
/// 2026-11-11: "across any and all conditions of workspaces/folders/models/provides/harnesses").
#[tokio::test]
async fn a_peer_chats_fork_is_left_for_the_peer() {
    let hub = hub_with_a_peer_chat();
    assert!(hub.resolve_remote("hb/peer-chat-1").is_some(), "the fixture lists the peer's chat");
    for sent in [
        json!({"sessionId": "hb/peer-chat-1", "throughSeq": 3}),
        json!({"sessionId": "hb/peer-chat-1", "beforePromptId": "p", "requestId": "r"}),
    ] {
        let mut params = sent.clone();
        let m = as_session_fork(&hub, method::ACP_SESSION_FORK, &mut params).await.unwrap();
        assert_eq!(m, method::ACP_SESSION_FORK, "{sent}");
        assert_eq!(params, sent);
    }
    let mut live =
        json!({"sessionId": "hb/peer-chat-1", "live": true, "harness": "codex", "model": "m"});
    let m = as_session_fork(&hub, method::ACP_SESSION_FORK, &mut live).await.unwrap();
    assert_eq!(m, method::SESSION_FORK);
    assert_eq!(live["sessionId"], "hb/peer-chat-1");
    assert_eq!(live["_meta"]["acpmux"]["harness"], "codex");
    assert_eq!(live["_meta"]["acpmux"]["model"], "m");
    assert_eq!(live["_meta"]["acpmux"]["startLater"], true);
    // A chat neither here nor on a peer is still this daemon's unknown session.
    let mut params = json!({"sessionId": "nowhere", "live": true});
    assert!(as_session_fork(&hub, method::ACP_SESSION_FORK, &mut params).await.is_err());
}

/// A switch onto another harness forks the chat as it is now: `harness` or `model` with a turn
/// or a prompt boundary, or without `live`, is refused rather than dropped (a fork that ignored
/// the picked harness would send the message to the old model).
#[tokio::test]
async fn a_switch_needs_live_and_no_boundary() {
    let hub = hub_with_a_peer_chat();
    for params in [
        json!({"sessionId": "hb/peer-chat-1", "harness": "codex"}),
        json!({"sessionId": "hb/peer-chat-1", "live": true, "throughSeq": 3, "harness": "codex"}),
        json!({"sessionId": "hb/peer-chat-1", "beforePromptId": "p", "requestId": "r", "model": "m"}),
    ] {
        let err = to_session_fork(&hub, &params).await.unwrap_err();
        assert!(err.message.contains("send them with live"), "{params}: {}", err.message);
    }
}

/// A Web switch of a peer's chat passes this daemon's guard to that peer (forwarded `via: web`,
/// where the peer's own guard applies the Web's rules); an unknown chat is still refused.
#[tokio::test]
async fn a_web_switch_of_a_peer_chat_goes_to_the_peer() {
    let hub = hub_with_a_peer_chat();
    let mut fork = to_session_fork(
        &hub,
        &json!({"sessionId": "hb/peer-chat-1", "live": true, "harness": "codex"}),
    )
    .await
    .unwrap();
    let web = crate::hub::Control::Web;
    super::super::remote_guard::web_starts_asking(
        &hub,
        web,
        false,
        method::SESSION_FORK,
        &mut fork,
    )
    .await
    .unwrap();
    let mut unknown = json!({"sessionId": "nope", "_meta": {"acpmux": {"harness": "codex"}}});
    let refused = super::super::remote_guard::web_starts_asking(
        &hub,
        web,
        false,
        method::SESSION_FORK,
        &mut unknown,
    )
    .await;
    assert!(refused.is_err());
}

/// A switch's model is one model id: a flag or shell text is refused before it reaches a
/// launch command's `${model}`.
#[test]
fn a_switch_model_is_one_model_id() {
    let with = |model: &str| json!({"_meta": {"acpmux": {"harness": "codex", "model": model}}});
    assert!(retarget(&with("claude-opus-5-5[1m]")).is_ok());
    assert!(retarget(&with("provider/model:tag")).is_ok());
    for bad in ["m;id", "--dangerously-skip-permissions", "a b", "$(x)", "m`x`"] {
        assert!(retarget(&with(bad)).is_err(), "{bad}");
    }
}
