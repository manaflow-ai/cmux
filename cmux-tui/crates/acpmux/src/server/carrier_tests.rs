//! The Cloud carrier's auth kind (`carrier.rs`, `docs/carrier-roles.md`): the header, the
//! owner/team matrix over every method, the owner held to the Peer origin's rules, a teammate's
//! refusals end to end, and the header refused anywhere but the carrier socket.

use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::Control;
use crate::server::remote_guard;
use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

const WAIT: Duration = Duration::from_secs(10);

fn owner() -> Attested {
    Attested { role: Role::Owner, sub: "u_owner".into(), team: Some("t_1".into()) }
}

fn teammate() -> Attested {
    Attested { role: Role::Team, sub: "u_mate".into(), team: Some("t_1".into()) }
}

fn test_hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

/// Every method name in `rpc::method`, read from its source so a method added later gets a row.
fn every_method() -> Vec<String> {
    let src = include_str!("../rpc.rs");
    let start = src.find("pub mod method").expect("rpc.rs has a method module");
    let end = start + src[start..].find("\n}\n").expect("the method module ends");
    let mut out = Vec::new();
    for line in src[start..end].lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("pub const ")
            && let Some((_, value)) = rest.split_once("= \"")
            && let Some(name) = value.strip_suffix("\";")
        {
            out.push(name.to_owned());
        }
    }
    assert!(out.len() > 200, "read {} methods from rpc.rs", out.len());
    out
}

/// What a teammate may call: the rows of `docs/carrier-roles.md`. Every other method is refused.
const TEAM_ALLOWED: &[&str] = &[
    "initialize",
    "_acpmux/attach",
    "_acpmux/info",
    "_acpmux/events",
    "_acpmux/attachment",
    "session/prompt",
    "session/cancel",
    "_acpmux/detach",
];

#[test]
fn the_header_is_one_object_naming_the_role_the_person_and_the_team() {
    let ok = |v: &str| Attested::parse(&[v]);
    assert_eq!(ok(r#"{"vmk":"owner","sub":"u_owner","team":"t_1"}"#), Ok(owner()));
    assert_eq!(ok(r#"{"vmk":"team","sub":"u_mate","team":"t_1"}"#), Ok(teammate()));
    // An owner's personal VM may name no team.
    assert_eq!(ok(r#"{"vmk":"owner","sub":"u_owner","team":null}"#).map(|a| a.team), Ok(None));
    let refused: &[(&[&str], &str)] = &[
        (&[], "carrier.header_missing"),
        (
            &[r#"{"vmk":"owner","sub":"a","team":"t"}"#, r#"{"vmk":"owner","sub":"a","team":"t"}"#],
            "carrier.header_repeated",
        ),
        (&["owner"], "carrier.header_malformed"),
        (&[""], "carrier.header_malformed"),
        (&["[]"], "carrier.header_malformed"),
        (&[r#"{"vmk":"admin","sub":"a","team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"Owner","sub":"a","team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"sub":"a","team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"owner","team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"owner","sub":"a"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"owner","sub":"","team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"owner","sub":"a b","team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"owner","sub":"a\nb","team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"owner","sub":7,"team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":null}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":""}"#], "carrier.header_malformed"),
        // A field the grant does not have is never taken as more.
        (&[r#"{"vmk":"team","sub":"a","team":"t","role":"owner"}"#], "carrier.header_malformed"),
    ];
    for (values, reason) in refused {
        assert_eq!(Attested::parse(values), Err(*reason), "{values:?}");
    }
    let long = format!(r#"{{"vmk":"owner","sub":"{}","team":"t"}}"#, "a".repeat(257));
    assert_eq!(ok(&long), Err("carrier.header_malformed"));
}

#[test]
fn the_owner_and_team_matrix_covers_every_method() {
    let methods = every_method();
    for m in &methods {
        assert!(allows(Role::Owner, m), "the owner passes the carrier gate with {m}");
        assert_eq!(
            allows(Role::Team, m),
            TEAM_ALLOWED.contains(&m.as_str()),
            "a teammate and {m}: the matrix in docs/carrier-roles.md"
        );
        let admitted = admit(&teammate(), m, json!({"sessionId": "chat"}));
        assert_eq!(admitted.is_ok(), TEAM_ALLOWED.contains(&m.as_str()), "{m}");
        if let Err(e) = admitted {
            assert_eq!(e.code, NOT_A_TEAMMATE_VERB, "{m}");
            assert_eq!(e.data.as_ref().unwrap()["reason"], "carrier.team_refused", "{m}");
        }
    }
    // Each allowed method is a real one.
    for m in TEAM_ALLOWED {
        assert!(methods.iter().any(|x| x == m), "{m} is in rpc::method");
    }
    // A method no build has heard of is refused too.
    assert!(!allows(Role::Team, "_acpmux/some_future_method"));
}

#[test]
fn every_teammate_verb_has_a_row_and_every_row_is_a_teammate_verb() {
    use cmux_agent_pane_policy::share_roles::{GUEST_VERBS, TEAMMATE_VERBS};
    for verb in TEAMMATE_VERBS {
        assert!(TEAMMATE_METHODS.iter().any(|(v, _)| *v == verb), "no acpmux row for {verb}");
    }
    for (verb, methods) in TEAMMATE_METHODS {
        assert!(TEAMMATE_VERBS.contains(verb), "{verb} is not a teammate verb");
        assert!(!methods.is_empty(), "{verb}");
    }
    // A guest's typing and view are not a teammate's.
    for verb in GUEST_VERBS.iter().filter(|v| !TEAMMATE_VERBS.contains(v)) {
        assert!(TEAMMATE_METHODS.iter().all(|(v, _)| v != verb), "{verb}");
    }
}

#[test]
fn a_teammates_attach_is_hidden_and_its_prompt_names_the_attested_author_only() {
    let attach =
        admit(&teammate(), method::MUX_ATTACH, json!({"sessionId": "c", "visible": true})).unwrap();
    assert_eq!(attach["visible"], false);
    let forged = json!({"sessionId": "c", "prompt": [],
        "_meta": {"acpmux": {"author": {"id": "user_owner", "name": "Owner"}}}});
    let prompt = admit(&teammate(), method::SESSION_PROMPT, forged).unwrap();
    assert_eq!(
        prompt.pointer("/_meta/acpmux/author"),
        Some(&json!({"id": "user_u_mate", "name": "u_mate"}))
    );
    // It reads as a person's prompt (`author.rs`), never the owner's.
    let author = crate::author::of_prompt(&prompt).unwrap().unwrap();
    assert_eq!(author.id, "user_u_mate");
    // An id already in the platform's shape is kept as it is.
    let sub = Attested { sub: "user_42".into(), ..teammate() };
    let prompt = admit(&sub, method::SESSION_PROMPT, json!({"sessionId": "c"})).unwrap();
    assert_eq!(prompt.pointer("/_meta/acpmux/author/id"), Some(&json!("user_42")));
    assert!(admit(&teammate(), method::SESSION_PROMPT, Value::Null).is_err());
    // The owner's request goes on as it came.
    let mine = json!({"sessionId": "c", "visible": true});
    assert_eq!(admit(&owner(), method::MUX_ATTACH, mine.clone()).unwrap(), mine);
}

#[test]
fn the_owner_has_the_peer_tokens_rules_and_a_teammate_the_webs() {
    assert_eq!(owner().served_as(), (Origin::Peer, ConnAuth::CarrierOwner));
    assert_eq!(teammate().served_as(), (Origin::Web, ConnAuth::CarrierTeam));
    assert!(ConnAuth::CarrierOwner.peer_daemon());
    assert!(!ConnAuth::CarrierTeam.peer_daemon());
    for params in [json!({}), json!({"_meta": {"acpmux": {"via": "web"}}})] {
        let peer = remote_guard::control_of(Origin::Peer, ConnAuth::PeerToken, &params);
        let carrier = remote_guard::control_of(Origin::Peer, ConnAuth::CarrierOwner, &params);
        assert_eq!(peer, carrier, "{params}");
        assert_eq!(
            crate::hub::vm_boundary::forwards(ConnAuth::PeerToken, peer),
            crate::hub::vm_boundary::forwards(ConnAuth::CarrierOwner, carrier)
        );
    }
    let team = remote_guard::control_of(Origin::Web, ConnAuth::CarrierTeam, &json!({}));
    assert_eq!(team, Control::Web);
    assert!(!crate::hub::vm_boundary::forwards(ConnAuth::CarrierTeam, team));
}

/// The remote guard answers the owner through the carrier as it answers a peer daemon, for
/// every method, with the params that ask for a spawn, a path or a policy.
#[tokio::test]
async fn the_remote_guard_answers_the_owner_as_a_peer_daemon_for_every_method() {
    let hub = test_hub();
    let shapes = [
        json!({}),
        json!({"sessionId": "c", "mcpServers": [{"name": "x", "command": "/bin/sh", "args": []}]}),
        json!({"cwd": "/etc"}),
        json!({"sessionId": "c", "policy": "approve-all"}),
        json!({"set": {"env": {"LD_PRELOAD": "/tmp/x.so"}}}),
        json!({"dest": "/tmp/out"}),
        json!({"path": "/etc/passwd"}),
    ];
    for m in every_method() {
        for shape in &shapes {
            let check = |auth| {
                let hub = hub.clone();
                let (m, mut params) = (m.clone(), shape.clone());
                async move {
                    remote_guard::check(&hub, Origin::Peer, auth, None, &m, &mut params, false)
                        .await
                        .map(|()| params)
                        .map_err(|e| (e.code, e.message))
                }
            };
            assert_eq!(
                check(ConnAuth::PeerToken).await,
                check(ConnAuth::CarrierOwner).await,
                "{m} {shape}"
            );
        }
    }
}

/// One request on `send`, its answer from `recv`.
async fn ask(
    send: &tokio::sync::mpsc::Sender<String>,
    recv: &mut tokio::sync::mpsc::Receiver<String>,
    id: i64,
    m: &str,
    params: Value,
) -> Value {
    send.send(crate::rpc::Message::request(id, m, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(WAIT, recv.recv()).await.unwrap().unwrap();
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply.get("id") == Some(&json!(id)) {
            return reply;
        }
    }
}

#[tokio::test]
async fn a_teammate_never_starts_a_session_spawns_or_changes_rules() {
    let hub = test_hub();
    let (send, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut recv) = tokio::sync::mpsc::channel(64);
    let server = tokio::spawn(serve_attested(hub, inbound, out, teammate()));
    let hello = ask(&send, &mut recv, 0, "initialize", json!({"protocolVersion": 1})).await;
    assert!(hello.get("result").is_some(), "{hello}");
    let tmp = std::env::temp_dir();
    let refused = [
        ("session/new", json!({})),
        ("session/new", json!({"cwd": tmp, "mcpServers": []})),
        (
            "session/new",
            json!({"cwd": tmp, "mcpServers": [{"name": "x", "command": "/bin/sh", "args": [], "env": []}]}),
        ),
        ("session/new", json!({"cwd": "/etc"})),
        ("session/new", json!({"cwd": tmp, "_meta": {"acpmux": {"policy": "approve-all"}}})),
        ("session/fork", json!({"sessionId": "c", "cwd": tmp})),
        ("session/load", json!({"sessionId": "c", "cwd": tmp})),
        ("session/list", json!({})),
        ("_acpmux/sessions", json!({})),
        ("_acpmux/watch", json!({"enabled": true})),
        ("_acpmux/set_policy", json!({"sessionId": "c", "policy": "approve-all"})),
        ("_acpmux/set_rules", json!({"sessionId": "c", "rules": []})),
        (
            "_acpmux/permission_respond",
            json!({"sessionId": "c", "permissionId": "p", "optionId": "allow"}),
        ),
        ("_acpmux/process/list", json!({})),
        ("_acpmux/export", json!({"sessionId": "c", "dest": "/tmp/x"})),
        ("_acpmux/import", json!({"path": "/etc/passwd"})),
        ("_acpmux/peer_add", json!({"name": "x", "url": "ssh://x"})),
        ("_acpmux/kill", json!({"sessionId": "c"})),
        ("session/set_mode", json!({"sessionId": "c", "modeId": "bypassPermissions"})),
    ];
    for (id, (m, params)) in refused.into_iter().enumerate() {
        let reply = ask(&send, &mut recv, id as i64 + 1, m, params.clone()).await;
        assert_eq!(
            reply["error"]["data"]["reason"], "carrier.team_refused",
            "{m} {params}: {reply}"
        );
    }
    // An allowed verb reaches the dispatcher (no such chat here), not the carrier's refusal.
    let attach = ask(&send, &mut recv, 99, "_acpmux/attach", json!({"sessionId": "nope"})).await;
    assert_ne!(attach["error"]["data"]["reason"], "carrier.team_refused", "{attach}");
    drop(send);
    tokio::time::timeout(WAIT, server).await.unwrap().unwrap();
}

#[tokio::test]
async fn the_owner_through_the_carrier_is_held_to_the_peer_rules() {
    let hub = test_hub();
    let (send, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut recv) = tokio::sync::mpsc::channel(64);
    let server = tokio::spawn(serve_attested(hub, inbound, out, owner()));
    let hello = ask(&send, &mut recv, 0, "initialize", json!({"protocolVersion": 1})).await;
    assert_eq!(hello["result"]["_meta"]["acpmux"]["auth"], "carrierOwner", "{hello}");
    let tmp = std::env::temp_dir();
    let refused = [
        (
            "session/new",
            json!({"cwd": tmp, "mcpServers": [{"name": "x", "command": "/bin/sh", "args": [], "env": []}]}),
        ),
        ("_acpmux/process/list", json!({})),
        ("_acpmux/peer_add", json!({"name": "x", "url": "ssh://x"})),
        ("_acpmux/export", json!({"sessionId": "c", "dest": "/tmp/x"})),
        ("_acpmux/import", json!({"path": "/etc/passwd"})),
        ("_acpmux/web_token_rotate", json!({})),
    ];
    for (id, (m, params)) in refused.into_iter().enumerate() {
        let reply = ask(&send, &mut recv, id as i64 + 1, m, params.clone()).await;
        assert!(reply.get("error").is_some(), "{m} {params}: {reply}");
        assert_ne!(reply["error"]["data"]["reason"], "carrier.team_refused", "{m}: {reply}");
    }
    drop(send);
    tokio::time::timeout(WAIT, server).await.unwrap().unwrap();
}

#[tokio::test]
async fn a_carrier_proof_without_the_carrier_socket_gets_nothing() {
    for auth in [ConnAuth::CarrierOwner, ConnAuth::CarrierTeam] {
        let (send, inbound) = tokio::sync::mpsc::channel(8);
        let (out, mut recv) = tokio::sync::mpsc::channel(64);
        let server = tokio::spawn(crate::server::serve_connection_authed(
            test_hub(),
            inbound,
            out,
            Origin::Peer,
            auth,
        ));
        let reply = ask(&send, &mut recv, 1, "initialize", json!({"protocolVersion": 1})).await;
        assert_eq!(reply["error"]["code"], crate::server::conn_auth::UNAUTHENTICATED, "{reply}");
        drop(send);
        let _ = tokio::time::timeout(WAIT, server).await;
    }
}

#[test]
fn a_teammate_stops_a_turn_and_sends_no_other_notification() {
    assert!(team_allows(method::SESSION_CANCEL));
    for m in ["_acpmux/typing", "_acpmux/view", "$/cancel_request", "session/update"] {
        assert!(!team_allows(m), "{m}");
    }
}

/// The carrier socket's handshake, over an in-memory stream: the header decides who it is.
async fn upgrade(header: Option<&str>) -> Result<Value, u16> {
    let (client, server) = tokio::io::duplex(1 << 16);
    tokio::spawn(serve_one(test_hub(), server));
    let mut req = "ws://carrier/".into_client_request().unwrap();
    if let Some(h) = header {
        req.headers_mut().insert(HEADER, h.parse().unwrap());
    }
    let (mut ws, _) = match tokio_tungstenite::client_async(req, client).await {
        Ok(ws) => ws,
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            return Err(resp.status().as_u16());
        }
        Err(e) => panic!("{e}"),
    };
    let hello = crate::rpc::Message::request(1, "initialize", json!({"protocolVersion": 1}));
    ws.send(Frame::Text(hello.to_line().trim_end().to_owned().into())).await.unwrap();
    loop {
        let frame = tokio::time::timeout(WAIT, ws.next()).await.unwrap().unwrap().unwrap();
        if let Frame::Text(t) = frame {
            let reply: Value = serde_json::from_str(&t).unwrap();
            if reply["id"] == 1 {
                return Ok(reply);
            }
        }
    }
}

#[tokio::test]
async fn the_carrier_socket_admits_only_a_well_formed_header() {
    let hello = upgrade(Some(r#"{"vmk":"team","sub":"u_mate","team":"t_1"}"#)).await.unwrap();
    assert_eq!(hello["result"]["_meta"]["acpmux"]["auth"], "carrierTeam", "{hello}");
    let hello = upgrade(Some(r#"{"vmk":"owner","sub":"u_owner","team":null}"#)).await.unwrap();
    assert_eq!(hello["result"]["_meta"]["acpmux"]["auth"], "carrierOwner", "{hello}");
    assert_eq!(upgrade(None).await, Err(403));
    assert_eq!(upgrade(Some("not json")).await, Err(403));
    assert_eq!(upgrade(Some(r#"{"vmk":"root","sub":"u","team":"t"}"#)).await, Err(403));
}

#[tokio::test]
async fn the_websocket_listener_refuses_the_carrier_header() {
    const TOKEN: &str = "0123456789abcdef";
    let listener = crate::server::bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(crate::server::serve_ws_with(
        test_hub(),
        listener,
        TOKEN.into(),
        crate::server::WsAuth::default(),
    ));
    let request = |carrier: bool| {
        let mut req = format!("ws://127.0.0.1:{port}").into_client_request().unwrap();
        req.headers_mut().insert("authorization", format!("Bearer {TOKEN}").parse().unwrap());
        if carrier {
            let h = r#"{"vmk":"owner","sub":"u_owner","team":"t_1"}"#;
            req.headers_mut().insert(HEADER, h.parse().unwrap());
        }
        req
    };
    // The listener itself is up and takes the token.
    assert!(tokio_tungstenite::connect_async(request(false)).await.is_ok());
    match tokio_tungstenite::connect_async(request(true)).await {
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            assert_eq!(resp.status().as_u16(), 403);
            let body = resp.body().as_deref().map(String::from_utf8_lossy).unwrap_or_default();
            assert!(body.contains(WRONG_SOCKET), "{body}");
        }
        other => panic!("the listener took the carrier header: {:?}", other.map(|_| ())),
    }
}
