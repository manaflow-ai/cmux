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
    Attested {
        role: Role::Owner,
        sub: "u_owner".into(),
        team: Some("t_1".into()),
        chats: vec![],
        name: None,
    }
}

fn teammate() -> Attested {
    Attested {
        role: Role::Team,
        sub: "u_mate".into(),
        team: Some("t_1".into()),
        chats: vec!["chat-a".into(), "c".into(), "chat".into()],
        name: None,
    }
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
    assert_eq!(
        ok(r#"{"vmk":"team","sub":"u_mate","team":"t_1","chats":["chat-a","c","chat"]}"#),
        Ok(teammate())
    );
    // An owner's `chats` is ignored, whatever it holds: the owner reaches every chat.
    assert_eq!(ok(r#"{"vmk":"owner","sub":"u_owner","team":"t_1","chats":["x"]}"#), Ok(owner()));
    assert_eq!(ok(r#"{"vmk":"owner","sub":"u_owner","team":"t_1","chats":7}"#), Ok(owner()));
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
        (&[r#"{"vmk":"team","sub":"a","team":null,"chats":["c"]}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":"","chats":["c"]}"#], "carrier.header_malformed"),
        // A teammate's grant names its chats: none, an empty list or a bad id is refused.
        (&[r#"{"vmk":"team","sub":"a","team":"t"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":"t","chats":[]}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":"t","chats":null}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":"t","chats":"c"}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":"t","chats":[""]}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":"t","chats":["a b"]}"#], "carrier.header_malformed"),
        (&[r#"{"vmk":"team","sub":"a","team":"t","chats":[7]}"#], "carrier.header_malformed"),
        // A name is 1 to 256 bytes, not blank, with no control character.
        (
            &[r#"{"vmk":"team","sub":"a","team":"t","chats":["c"],"name":""}"#],
            "carrier.header_malformed",
        ),
        (
            &[r#"{"vmk":"team","sub":"a","team":"t","chats":["c"],"name":"  "}"#],
            "carrier.header_malformed",
        ),
        (
            &[r#"{"vmk":"team","sub":"a","team":"t","chats":["c"],"name":"a\nb"}"#],
            "carrier.header_malformed",
        ),
        (
            &[r#"{"vmk":"team","sub":"a","team":"t","chats":["c"],"name":"a\u0007b"}"#],
            "carrier.header_malformed",
        ),
        (
            &[r#"{"vmk":"team","sub":"a","team":"t","chats":["c"],"name":7}"#],
            "carrier.header_malformed",
        ),
        (&[r#"{"vmk":"owner","sub":"a","team":"t","name":["x"]}"#], "carrier.header_malformed"),
        // A field the grant does not have is never taken as more.
        (
            &[r#"{"vmk":"team","sub":"a","team":"t","chats":["c"],"role":"owner"}"#],
            "carrier.header_malformed",
        ),
    ];
    for (values, reason) in refused {
        assert_eq!(Attested::parse(values), Err(*reason), "{values:?}");
    }
    let long = format!(r#"{{"vmk":"owner","sub":"{}","team":"t"}}"#, "a".repeat(257));
    assert_eq!(ok(&long), Err("carrier.header_malformed"));
    // `name` is optional for either role; null is no name.
    let named = r#"{"vmk":"team","sub":"u_mate","team":"t_1","chats":["chat-a","c","chat"],"name":"Ada Lovelace"}"#;
    assert_eq!(ok(named), Ok(Attested { name: Some("Ada Lovelace".into()), ..teammate() }));
    let named = r#"{"vmk":"owner","sub":"u_owner","team":"t_1","name":"Owen"}"#;
    assert_eq!(ok(named), Ok(Attested { name: Some("Owen".into()), ..owner() }));
    assert_eq!(ok(r#"{"vmk":"owner","sub":"u_owner","team":"t_1","name":null}"#), Ok(owner()));
    // The caps the bridge sizes its grant to: a name or an id of 256 bytes, 64 chats, a value
    // of 8 KiB.
    let longest = format!(
        r#"{{"vmk":"team","sub":"a","team":"t","chats":["c"],"name":"{}"}}"#,
        "é".repeat(128)
    );
    assert_eq!(ok(&longest).map(|a| a.name.map(|n| n.len())), Ok(Some(256)));
    let longer = longest.replace("\"}", "é\"}");
    assert_eq!(ok(&longer), Err("carrier.header_malformed"));
    let chats = |n: usize| (0..n).map(|i| format!("ses_{i}")).collect::<Vec<_>>();
    let team = |chats: Vec<String>| {
        json!({"vmk": "team", "sub": "a", "team": "t", "chats": chats, "name": "x"}).to_string()
    };
    assert_eq!(ok(&team(chats(64))).map(|a| a.chats.len()), Ok(64));
    assert_eq!(ok(&team(chats(65))), Err("carrier.header_malformed"));
    let id = |n: usize| json!({"vmk": "owner", "sub": "a".repeat(n), "team": "t"}).to_string();
    assert!(ok(&id(256)).is_ok());
    assert_eq!(ok(&id(257)), Err("carrier.header_malformed"));
    // 64 ids of 120 bytes fit in 8 KiB; the same header padded past it with spaces is refused.
    let wide: Vec<String> = (0..64).map(|i| format!("{i:0>120}")).collect();
    let fits = team(wide);
    assert!(fits.len() <= 8 * 1024 && ok(&fits).is_ok(), "{}", fits.len());
    let over = format!("{fits}{}", " ".repeat(8 * 1024 + 1 - fits.len()));
    assert_eq!(over.len(), 8 * 1024 + 1);
    assert_eq!(ok(&over), Err("carrier.header_malformed"));
}

/// The header exactly as the session host's bridge builds it (cmux-remote `acpmux_bridge.rs`
/// `header`): `json!({vmk, sub, team, chats, name})` with `chats` and `name` null when the grant
/// has none, written as ASCII with every other character a `\u` escape (`ascii_json`).
fn bridge_header(
    vmk: &str,
    team: Option<&str>,
    chats: Option<&[&str]>,
    name: Option<&str>,
) -> String {
    use std::fmt::Write as _;
    let value = json!({
        "vmk": vmk,
        "sub": "user_2xQ9",
        "team": team,
        "chats": chats,
        "name": name,
    });
    let mut out = String::new();
    for c in value.to_string().chars() {
        if c.is_ascii() {
            out.push(c);
        } else {
            let mut units = [0_u16; 2];
            for unit in c.encode_utf16(&mut units) {
                let _ = write!(out, "\\u{unit:04x}");
            }
        }
    }
    out
}

#[test]
fn a_header_built_as_the_bridge_builds_it_parses() {
    let chats = ["ses_a", "0f8e2c1a-7b0d-4c55-9a43-2b1d7d7f5e10"];
    let team = bridge_header("team", Some("team_7"), Some(&chats), Some("Ana Lí 🧑\u{200d}💻"));
    assert!(team.is_ascii(), "{team}");
    assert!(team.parse::<tokio_tungstenite::tungstenite::http::HeaderValue>().is_ok());
    let who = Attested::parse(&[&team]).unwrap();
    assert_eq!(who.role, Role::Team);
    assert_eq!(who.sub, "user_2xQ9");
    assert_eq!(who.team.as_deref(), Some("team_7"));
    assert_eq!(who.chats, chats);
    assert_eq!(who.name.as_deref(), Some("Ana Lí 🧑\u{200d}💻"));
    // The stamp keeps the name on one line: the zero-width joiner goes, the rest stays.
    assert_eq!(who.author(), json!({"id": "user_2xQ9", "name": "Ana Lí 🧑💻"}));
    // An owner's grant sends `chats: null`, and a grant without a name `name: null`.
    let mine = Attested::parse(&[&bridge_header("owner", Some("team_7"), None, None)]).unwrap();
    assert_eq!((mine.role, mine.chats.len(), mine.name), (Role::Owner, 0, None));
    let personal = Attested::parse(&[&bridge_header("owner", None, None, Some("Ana"))]).unwrap();
    assert_eq!((personal.team, personal.name.as_deref()), (None, Some("Ana")));
    let unnamed =
        Attested::parse(&[&bridge_header("team", Some("t"), Some(&["c"]), None)]).unwrap();
    assert_eq!(unnamed.author()["name"], "user_2xQ9");
    // The bridge's largest grant (16 chats of 128 bytes, a 64-character name of 4-byte
    // characters, each written as two escapes) fits the 8 KiB cap.
    let ids: Vec<String> = (0..16).map(|i| format!("{i:0>128}")).collect();
    let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
    let name = "🧑".repeat(64);
    let largest = bridge_header("team", Some(&"t".repeat(128)), Some(&ids), Some(&name));
    assert!(largest.len() <= 8 * 1024, "{}", largest.len());
    let parsed = Attested::parse(&[&largest]);
    assert_eq!(parsed.as_ref().map(|a| a.chats.len()), Ok(16));
    // Its name is over the stamp's 64 characters only when it is: 64 here, kept whole.
    assert_eq!(parsed.unwrap().author()["name"], name);
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
        let admitted = admit(&teammate(), m, json!({"sessionId": "chat-a"}));
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
    // The header's `name`, when it has one, is the name the transcript and the stamp show.
    let named = Attested { name: Some("Ada Lovelace".into()), ..teammate() };
    let prompt = admit(&named, method::SESSION_PROMPT, json!({"sessionId": "c"})).unwrap();
    assert_eq!(
        prompt.pointer("/_meta/acpmux/author"),
        Some(&json!({"id": "user_u_mate", "name": "Ada Lovelace"}))
    );
    assert_eq!(crate::author::of_prompt(&prompt).unwrap().unwrap().name, "Ada Lovelace");
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
    // A granted id that no session here has (stale) is refused before any dispatcher.
    let attach = ask(&send, &mut recv, 99, "_acpmux/attach", json!({"sessionId": "chat"})).await;
    assert_eq!(attach["error"]["data"]["reason"], "carrier.team_refused", "{attach}");
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
    let team = r#"{"vmk":"team","sub":"u_mate","team":"t_1","chats":["chat-a"]}"#;
    let hello = upgrade(Some(team)).await.unwrap();
    assert_eq!(hello["result"]["_meta"]["acpmux"]["auth"], "carrierTeam", "{hello}");
    let hello = upgrade(Some(r#"{"vmk":"owner","sub":"u_owner","team":null}"#)).await.unwrap();
    assert_eq!(hello["result"]["_meta"]["acpmux"]["auth"], "carrierOwner", "{hello}");
    assert_eq!(upgrade(None).await, Err(403));
    // A teammate's header that names no chat.
    assert_eq!(upgrade(Some(r#"{"vmk":"team","sub":"u","team":"t"}"#)).await, Err(403));
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

#[test]
fn a_teammate_reaches_only_the_chats_its_grant_names_by_exact_id() {
    let who = teammate();
    for m in [
        method::MUX_ATTACH,
        method::MUX_INFO,
        method::MUX_EVENTS,
        method::MUX_ATTACHMENT,
        method::SESSION_PROMPT,
        method::SESSION_CANCEL,
        method::MUX_DETACH,
    ] {
        assert!(admit(&who, m, json!({"sessionId": "chat-a"})).is_ok(), "{m}");
        let refused = [
            json!({"sessionId": "chat-b"}),
            // A prefix or a longer id of a given chat is another chat.
            json!({"sessionId": "chat-"}),
            json!({"sessionId": "chat-a2"}),
            json!({"sessionId": "CHAT-A"}),
            json!({"sessionId": "this-mac/chat-a"}),
            // No chat named: `_acpmux/info` with none would describe the machine's chats.
            json!({}),
            Value::Null,
            json!({"sessionId": 7}),
            // A name or another machine stands in for nothing, given chat or not.
            json!({"session": "chat-a"}),
            json!({"name": "chat-a"}),
            json!({"sessionId": "chat-a", "session": "chat-b"}),
            json!({"sessionId": "chat-a", "name": "chat-b"}),
            json!({"sessionId": "chat-a", "host": "other"}),
        ];
        for params in refused {
            let e = admit(&who, m, params.clone()).unwrap_err();
            assert_eq!(e.data.unwrap()["reason"], "carrier.team_refused", "{m} {params}");
        }
    }
}

/// A memory hub with chats `chat-a`, `chat-b` (named `alias`), `chat-xyz` and `chat-n` (named
/// `chat-named`): none spawned.
fn hub_with_chats() -> Arc<Hub> {
    let dir = std::env::temp_dir();
    let cfg: Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["claude"]}},
        "defaultHarness": "claude", "store": {"mode": "memory"}
    }))
    .unwrap();
    let store = crate::store::open(&cfg.store, &dir).unwrap();
    for (id, name) in [
        ("chat-a", "chat-a"),
        ("chat-b", "alias"),
        ("chat-xyz", "chat-xyz"),
        ("chat-n", "chat-named"),
    ] {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": name,
            "harness": "claude", "cwd": dir, "status": "idle",
            "createdAt": 1, "updatedAt": 1, "agentSessionId": format!("s-{id}")
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    Hub::new(cfg, store)
}

#[tokio::test]
async fn a_teammate_attaches_its_chat_and_hears_nothing_of_another() {
    let hub = hub_with_chats();
    // The grant names `chat-a`, and two ids no session has: `chat-x` (a prefix of `chat-xyz`)
    // and `chat-named` (`chat-n`'s name). Neither may reach those sessions.
    let who = Attested {
        chats: vec!["chat-a".into(), "chat-x".into(), "chat-named".into()],
        ..teammate()
    };
    let (send, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut recv) = tokio::sync::mpsc::channel(256);
    let server = tokio::spawn(serve_attested(hub.clone(), inbound, out, who));
    ask(&send, &mut recv, 0, "initialize", json!({"protocolVersion": 1})).await;
    let attach = ask(&send, &mut recv, 1, "_acpmux/attach", json!({"sessionId": "chat-a"})).await;
    assert!(attach.get("result").is_some(), "{attach}");
    let info = ask(&send, &mut recv, 2, "_acpmux/info", json!({"sessionId": "chat-a"})).await;
    assert!(info.get("result").is_some(), "{info}");
    let refused = [
        ("_acpmux/attach", json!({"sessionId": "chat-b"})),
        ("_acpmux/attach", json!({"sessionId": "alias"})),
        ("_acpmux/attach", json!({"sessionId": "chat-x"})),
        ("_acpmux/attach", json!({"sessionId": "chat-named"})),
        ("_acpmux/events", json!({"sessionId": "chat-b"})),
        ("_acpmux/events", json!({"sessionId": "chat-x"})),
        (
            "session/prompt",
            json!({"sessionId": "chat-b", "prompt": [{"type": "text", "text": "hi"}]}),
        ),
        (
            "session/prompt",
            json!({"sessionId": "chat-named", "prompt": [{"type": "text", "text": "hi"}]}),
        ),
        ("session/cancel", json!({"sessionId": "chat-b"})),
        ("_acpmux/info", json!({})),
        ("_acpmux/info", json!({"sessionId": "chat-b"})),
        ("session/list", json!({})),
        ("_acpmux/sessions", json!({})),
    ];
    for (id, (m, params)) in refused.into_iter().enumerate() {
        let reply = ask(&send, &mut recv, id as i64 + 10, m, params.clone()).await;
        assert_eq!(
            reply["error"]["data"]["reason"], "carrier.team_refused",
            "{m} {params}: {reply}"
        );
    }
    // A record in another chat reaches no teammate attached to its own; one in its chat does.
    let other = hub.resolve("chat-b").unwrap();
    hub.append(&other, "mux", "agent_hold", json!({"held": true}));
    let own = hub.resolve("chat-a").unwrap();
    hub.append(&own, "mux", "agent_hold", json!({"held": true}));
    loop {
        let line = tokio::time::timeout(WAIT, recv.recv()).await.unwrap().unwrap();
        assert!(!line.contains("chat-b"), "a teammate of chat-a heard chat-b: {line}");
        if line.contains("agent_hold") && line.contains("chat-a") {
            break;
        }
    }
    drop(send);
    tokio::time::timeout(WAIT, server).await.unwrap().unwrap();
}

#[tokio::test]
async fn a_teammates_cancel_notification_goes_on_only_for_a_chat_it_was_given() {
    let hub = hub_with_chats();
    let who = teammate();
    let cancel = |params: Value| {
        notification_admitted(&hub, Some(&who), method::SESSION_CANCEL, Some(&params))
    };
    assert!(cancel(json!({"sessionId": "chat-a"})));
    // `c` is granted, but no session here has that id.
    assert!(!cancel(json!({"sessionId": "c"})));
    for params in [
        json!({"sessionId": "chat-b"}),
        json!({"sessionId": "chat-"}),
        json!({"sessionId": "CHAT-A"}),
        json!({}),
        Value::Null,
        json!({"session": "chat-a"}),
        json!({"sessionId": "chat-a", "host": "other"}),
    ] {
        assert!(!cancel(params.clone()), "{params}");
    }
    assert!(!notification_admitted(&hub, Some(&who), method::SESSION_CANCEL, None));
    // No other notification of a teammate's goes on, for its chat or another.
    for m in
        ["_acpmux/typing", "_acpmux/view", "$/cancel_request", "session/update", "_acpmux/attach"]
    {
        assert!(
            !notification_admitted(&hub, Some(&who), m, Some(&json!({"sessionId": "chat-a"}))),
            "{m}"
        );
    }
    // An owner's, and a connection's with no carrier, go on as before.
    let any = json!({"sessionId": "chat-b"});
    assert!(notification_admitted(&hub, Some(&owner()), "_acpmux/typing", Some(&any)));
    assert!(notification_admitted(&hub, None, "_acpmux/typing", Some(&any)));
}

/// A memory hub whose owner relaxed the Web's modes: `webAskingModes` adds Claude's `review`
/// (a mode no reviewed source names as not asking), and `codex` runs the Codex bridge, which
/// the Web may drive in any mode. Chats: `strict` (Claude, `default`), `planned` (`plan`),
/// `relaxed` (Claude, `review`), `unnamed` (Claude, no mode), `bridge-ask` and `bridge-full`
/// (the bridge in `ask` and `agent-full-access`).
fn hub_with_relaxed_modes() -> Arc<Hub> {
    let dir = std::env::temp_dir();
    let cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "claude": {"kind": "claude-stdio", "argv": ["claude"]},
            "codex": {"argv": ["codex", "app-server"]}
        },
        "defaultHarness": "claude", "store": {"mode": "memory"},
        "webAskingModes": {"claude": ["review"]}
    }))
    .unwrap();
    let store = crate::store::open(&cfg.store, &dir).unwrap();
    for (id, harness, mode) in [
        ("strict", "claude", Some("default")),
        ("planned", "claude", Some("plan")),
        ("relaxed", "claude", Some("review")),
        ("unnamed", "claude", None),
        ("bridge-ask", "codex", Some("ask")),
        ("bridge-full", "codex", Some("agent-full-access")),
    ] {
        let argv: Vec<&str> =
            if harness == "codex" { vec!["codex", "app-server"] } else { vec!["claude"] };
        let mut meta = json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": harness, "family": harness, "harnessArgv": argv, "cwd": dir,
            "status": "idle", "createdAt": 1, "updatedAt": 1, "agentSessionId": format!("s-{id}"),
            "permissionPolicy": "ask"
        });
        if let Some(mode) = mode {
            meta["modes"] = json!({"currentModeId": mode});
        }
        let meta: crate::store::SessionMeta = serde_json::from_value(meta).unwrap();
        store.save(&meta).unwrap();
    }
    Hub::new(cfg, store)
}

/// The owner's `webAskingModes` and the bridge's any-mode exception open more modes to the
/// Web; a teammate's prompt still runs only in the strictest asking modes, and under the Web's
/// floor (`Control::Web`: nothing approves itself in its turn, `hub/remote_floor.rs`).
#[tokio::test]
async fn a_teammate_prompts_only_in_the_strictest_asking_modes_whatever_the_owner_relaxed() {
    let hub = hub_with_relaxed_modes();
    let chats = ["strict", "planned", "relaxed", "unnamed", "bridge-ask", "bridge-full"];
    let who = Attested { chats: chats.iter().map(|c| c.to_string()).collect(), ..teammate() };
    // The owner's relaxations are real: the Web's own mode rules let the relaxed chats ask.
    let relaxed = hub.resolve("relaxed").unwrap().meta();
    assert!(hub.web_modes().session_asks(&relaxed));
    assert!(hub.any_mode_for_web(&hub.resolve("bridge-full").unwrap().meta()));
    let mut n = 0;
    let (send, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut recv) = tokio::sync::mpsc::channel(256);
    let server = tokio::spawn(serve_attested(hub.clone(), inbound, out, who.clone()));
    ask(&send, &mut recv, 0, "initialize", json!({"protocolVersion": 1})).await;
    for (id, asks) in [
        ("strict", true),
        ("planned", true),
        ("bridge-ask", true),
        ("relaxed", false),
        ("unnamed", false),
        ("bridge-full", false),
    ] {
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}],
            "_meta": {"acpmux": {"via": "web"}}});
        // The params the request runs with: the Cloud mobile floor, held to it again at dispatch,
        // as a Web turn.
        let admitted = admit(&who, method::SESSION_PROMPT, prompt.clone()).unwrap();
        assert_eq!(admitted.pointer("/_meta/acpmux/via"), Some(&json!(TEAM_PROMPT_VIA)), "{id}");
        assert!(remote_guard::cloud_mobile(&admitted), "{id}");
        assert_eq!(
            remote_guard::control_of(Origin::Web, ConnAuth::CarrierTeam, &admitted),
            Control::Web,
            "{id}"
        );
        let checked = strictest_modes(&hub, &who, method::SESSION_PROMPT, &admitted);
        assert_eq!(checked.is_ok(), asks, "{id}: {checked:?}");
        // The owner through the carrier keeps the owner's relaxations.
        assert!(strictest_modes(&hub, &owner(), method::SESSION_PROMPT, &prompt).is_ok());
        if asks {
            continue;
        }
        // A refused prompt is refused over the connection before it reaches the chat.
        n += 1;
        let reply = ask(&send, &mut recv, n, "session/prompt", prompt).await;
        assert_eq!(reply["error"]["data"]["reason"], TEAM_MODE_NOT_ASKING, "{id}: {reply}");
    }
    drop(send);
    tokio::time::timeout(WAIT, server).await.unwrap().unwrap();
}

/// A chat the machine started for itself runs with its own Claude permissions: a teammate's
/// prompt to it is refused like any Web client's, even when the grant names it (intended,
/// `docs/carrier-roles.md`).
#[tokio::test]
async fn a_teammates_prompt_to_a_local_claude_chat_it_was_given_is_refused() {
    // `strict`: a local-origin Claude chat in `default`, which passes the carrier's mode gate.
    let hub = hub_with_relaxed_modes();
    let meta = hub.resolve("strict").unwrap().meta();
    assert!(!meta.remote_origin, "strict is a local-origin chat");
    let who = Attested { chats: vec!["strict".into()], ..teammate() };
    let prompt = json!({"sessionId": "strict", "prompt": [{"type": "text", "text": "hi"}]});
    assert!(strictest_modes(&hub, &who, method::SESSION_PROMPT, &prompt).is_ok());
    let (send, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut recv) = tokio::sync::mpsc::channel(256);
    let server = tokio::spawn(serve_attested(hub.clone(), inbound, out, who));
    ask(&send, &mut recv, 0, "initialize", json!({"protocolVersion": 1})).await;
    let reply = ask(&send, &mut recv, 1, "session/prompt", prompt).await;
    assert_eq!(reply["error"]["data"]["reason"], "remote.local_claude_session", "{reply}");
    drop(send);
    tokio::time::timeout(WAIT, server).await.unwrap().unwrap();
}

/// A memory hub with two chats this machine started (not `remote_origin`), neither spawned:
/// `local-gemini` (a harness that is not Claude) and `local-claude`, and `other` (not granted).
fn hub_with_local_chats() -> Arc<Hub> {
    let dir = std::env::temp_dir();
    let cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "claude": {"kind": "claude-stdio", "argv": ["claude"]},
            "gemini": {"argv": ["gemini", "--experimental-acp"]}
        },
        "defaultHarness": "gemini", "store": {"mode": "memory"}
    }))
    .unwrap();
    let store = crate::store::open(&cfg.store, &dir).unwrap();
    for (id, harness) in
        [("local-gemini", "gemini"), ("local-claude", "claude"), ("other", "gemini")]
    {
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": harness,
            "cwd": dir, "status": "idle", "createdAt": 1, "updatedAt": 1,
            "agentSessionId": format!("s-{id}")
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    Hub::new(cfg, store)
}

/// A teammate stops a chat its grant names that this machine started (the teammate verb
/// `agent-session-cancel`; the remote guard's Stop rule refused it before), and no other chat.
/// A Claude chat the machine started stays refused, as its prompt is
/// (`remote.local_claude_session`, intended: `docs/carrier-roles.md`).
#[tokio::test]
async fn a_teammate_cancels_a_local_chat_it_was_given_and_no_other() {
    let hub = hub_with_local_chats();
    assert!(!hub.resolve("local-gemini").unwrap().meta().remote_origin);
    // `local-g` is in the grant but is only a unique prefix of `local-gemini`'s id.
    let chats = vec!["local-gemini".into(), "local-claude".into(), "local-g".into()];
    let who = Attested { chats, ..teammate() };
    let (send, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut recv) = tokio::sync::mpsc::channel(256);
    let server = tokio::spawn(serve_attested(hub.clone(), inbound, out, who.clone()));
    ask(&send, &mut recv, 0, "initialize", json!({"protocolVersion": 1})).await;
    let mine =
        ask(&send, &mut recv, 1, "session/cancel", json!({"sessionId": "local-gemini"})).await;
    assert!(mine.get("error").is_none(), "{mine}");
    let claude =
        ask(&send, &mut recv, 2, "session/cancel", json!({"sessionId": "local-claude"})).await;
    assert_eq!(claude["error"]["data"]["reason"], "remote.local_claude_session", "{claude}");
    for (id, chat) in [(3, "other"), (4, "local-g")] {
        let reply = ask(&send, &mut recv, id, "session/cancel", json!({"sessionId": chat})).await;
        assert_eq!(reply["error"]["data"]["reason"], "carrier.team_refused", "{chat}: {reply}");
    }
    drop(send);
    tokio::time::timeout(WAIT, server).await.unwrap().unwrap();
    // The notification form: the same rule, the exact id included.
    let cancel = |chat: &str| {
        let params = json!({"sessionId": chat});
        notification_admitted(&hub, Some(&who), method::SESSION_CANCEL, Some(&params))
    };
    assert!(cancel("local-gemini"));
    assert!(!cancel("other"));
    assert!(!cancel("local-g"), "a prefix in the grant never stops another chat");
}

/// A granted id is reached only as exactly one session of this daemon with that very id: a
/// `HOST/NAME`, an id of a chat that no longer lives here, an ambiguous or a unique prefix are
/// refused by the carrier before any dispatcher, so nothing goes on to a peer, for every
/// session-addressed verb, request and notification alike.
#[tokio::test]
async fn a_teammates_granted_id_reaches_only_that_one_local_chat_and_never_a_peer() {
    let hub = hub_with_chats();
    // `peer-mac/chat-a`: another machine's chat by `HOST/NAME`; `gone`: a chat no session here
    // has (ended, or another machine's id); `chat-`: a prefix of three chats; `chat-xy`: a
    // unique prefix of `chat-xyz`.
    let refused = ["peer-mac/chat-a", "gone", "chat-", "chat-xy"];
    let chats = ["chat-a"].iter().chain(refused.iter()).map(|c| c.to_string()).collect();
    let who = Attested { chats, ..teammate() };
    let (send, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut recv) = tokio::sync::mpsc::channel(256);
    let server = tokio::spawn(serve_attested(hub.clone(), inbound, out, who.clone()));
    ask(&send, &mut recv, 0, "initialize", json!({"protocolVersion": 1})).await;
    let verbs = [
        method::MUX_ATTACH,
        method::MUX_INFO,
        method::MUX_EVENTS,
        method::MUX_ATTACHMENT,
        method::SESSION_PROMPT,
        method::SESSION_CANCEL,
        method::MUX_DETACH,
    ];
    let mut n = 0;
    for m in verbs {
        for chat in refused {
            n += 1;
            let params = json!({"sessionId": chat, "prompt": [{"type": "text", "text": "hi"}]});
            let reply = ask(&send, &mut recv, n, m, params.clone()).await;
            assert_eq!(
                reply["error"]["data"]["reason"], "carrier.team_refused",
                "{m} {chat}: {reply}"
            );
            assert!(scoped(&hub, &who, m, params.clone()).is_err(), "{m} {chat}");
            assert!(!notification_admitted(&hub, Some(&who), m, Some(&params)), "{m} {chat}");
        }
    }
    // The exact local id still works.
    let attach =
        ask(&send, &mut recv, 900, method::MUX_ATTACH, json!({"sessionId": "chat-a"})).await;
    assert!(attach.get("result").is_some(), "{attach}");
    let cancel = json!({"sessionId": "chat-a"});
    assert!(notification_admitted(&hub, Some(&who), method::SESSION_CANCEL, Some(&cancel)));
    drop(send);
    tokio::time::timeout(WAIT, server).await.unwrap().unwrap();
}
