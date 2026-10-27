//! Pairing over the WebSocket listener (`src/pairing`, `src/server/pairing.rs`):
//! B mints a ticket, A redeems it once over B's listener and pairs in the
//! ticket's role. B enforces the role: a read-only machine reads and is
//! refused everything else, and a revoked machine is cut off at once.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::pairing::{Role, TICKET_HEADER};
use acpmux::rpc::{Message, method};
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

const DASHBOARD: &str = "dashboard-token-0123";
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

fn hub() -> Arc<Hub> {
    let cfg = config();
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A hub's WebSocket listener (dashboard token only, no peer token): its URL.
async fn listen(h: Arc<Hub>) -> String {
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(h, l, DASHBOARD.into(), WsAuth::default()));
    format!("ws://127.0.0.1:{port}")
}

/// A local (unix socket) client of a hub.
struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    /// A client that stands for the person at this machine's app
    /// (`hub/person.rs`), as in `peer_integration.rs`.
    async fn new(h: Arc<Hub>) -> Self {
        let _ = h.person.install_spawn_key(PERSON_KEY);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(h, in_rx, out_tx));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
        let init = c.call(method::INITIALIZE, hello).await.unwrap();
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        c.call("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
        c
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn dial(url: &str, headers: &[(&str, &str)]) -> Result<Ws, String> {
    let mut req = url.into_client_request().unwrap();
    for (k, v) in headers {
        let name = tokio_tungstenite::tungstenite::http::HeaderName::from_bytes(k.as_bytes());
        req.headers_mut().append(name.unwrap(), v.parse().unwrap());
    }
    tokio_tungstenite::connect_async(req).await.map(|(ws, _)| ws).map_err(|e| e.to_string())
}

/// One request on a raw WebSocket: the reply's result or error object.
async fn rpc(ws: &mut Ws, id: u64, m: &str, p: Value) -> Result<Value, Value> {
    let r = json!({"jsonrpc": "2.0", "id": id, "method": m, "params": p});
    ws.send(Frame::Text(r.to_string().into())).await.unwrap();
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .expect("a reply")
            .expect("open")
            .unwrap();
        let Frame::Text(t) = frame else { continue };
        let v: Value = serde_json::from_str(&t).unwrap();
        if v["id"] == id {
            return match v.get("error") {
                Some(e) => Err(e.clone()),
                None => Ok(v["result"].clone()),
            };
        }
    }
}

/// Redeem `secret` at `url` the way `acpmux host join` does.
async fn redeem(url: &str, secret: &str, params: Value) -> Result<Value, Value> {
    let mut ws = dial(url, &[(TICKET_HEADER, secret)]).await.map_err(|e| json!(e))?;
    rpc(&mut ws, 1, method::MUX_PAIR_REDEEM, params).await
}

fn mint(h: &Hub, role: Role, url: &str) -> String {
    h.pairing.mint(role, 900, None, url.to_owned(), "b".into()).unwrap().0.secret
}

async fn remote_session(b: &Arc<Hub>) -> String {
    let mut cb = C::new(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "remote-one"}}}),
        )
        .await
        .unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn pairing_a_client_ticket_pairs_once_and_the_joiner_drives_the_minter() {
    let b = hub();
    let url = listen(b.clone()).await;
    remote_session(&b).await;
    let secret = mint(&b, Role::Client, &url);

    let reply = redeem(&url, &secret, json!({"name": "a"})).await.unwrap();
    assert_eq!(reply["role"], "client");
    assert_eq!(reply["minter"].as_str().map(str::is_empty), Some(false));
    let token = reply["token"].as_str().unwrap().to_owned();
    // Single use: the same ticket is refused at the upgrade.
    assert!(redeem(&url, &secret, json!({"name": "a2"})).await.is_err());

    // A adds B as a peer with the credential; B serves it as a peer daemon.
    let a = hub();
    a.add_peer("b", &url, Some(token), None, true).await.unwrap();
    assert_eq!(a.peers()[0]["servedAs"], "peer", "{:?}", a.peers());
    let mut ca = C::new(a.clone()).await;
    let r = ca
        .call(
            method::SESSION_PROMPT,
            json!({"sessionId": "b/remote-one", "prompt": [{"type": "text", "text": "via a"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn");

    let list = b.pairing.list();
    assert_eq!(list["tickets"][0]["state"], "used");
    assert_eq!(list["devices"][0]["name"], "a");
    assert_eq!(list["devices"][0]["role"], "client");
    assert_eq!(list["devices"][0]["connections"], 1);
}

#[tokio::test]
async fn pairing_a_read_only_machine_reads_and_the_minter_refuses_everything_else() {
    let b = hub();
    let url = listen(b.clone()).await;
    let remote = remote_session(&b).await;
    let secret = mint(&b, Role::ReadOnly, &url);
    let reply = redeem(&url, &secret, json!({"name": "tablet"})).await.unwrap();
    assert_eq!(reply["role"], "read-only");
    let token = reply["token"].as_str().unwrap().to_owned();

    // Through a peer: A lists B's sessions, and B refuses A's prompt.
    let a = hub();
    a.add_peer("b", &url, Some(token.clone()), None, true).await.unwrap();
    assert_eq!(a.peers()[0]["servedAs"], "remote", "{:?}", a.peers());
    let mut ca = C::new(a.clone()).await;
    let v = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(v["sessions"].as_array().unwrap().iter().any(|s| s["name"] == "b/remote-one"), "{v}");
    let e = ca
        .call(
            method::SESSION_PROMPT,
            json!({"sessionId": "b/remote-one", "prompt": [{"type": "text", "text": "no"}]}),
        )
        .await
        .unwrap_err();
    assert!(e.contains("read-only"), "{e}");

    // Directly: the credential in place of the dashboard token.
    let bearer = format!("Bearer {token}");
    let mut ws = dial(&url, &[("authorization", &bearer)]).await.unwrap();
    let init = rpc(&mut ws, 1, method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    assert_eq!(init["_meta"]["acpmux"]["origin"], "remote");
    assert_eq!(init["_meta"]["acpmux"]["auth"], "readOnlyDevice");
    assert!(rpc(&mut ws, 2, method::MUX_SESSIONS, json!({})).await.is_ok());
    assert!(
        rpc(&mut ws, 3, method::MUX_ATTACH, json!({"session": remote, "limit": 0})).await.is_ok()
    );
    assert!(rpc(&mut ws, 4, method::MUX_HISTORY, json!({"session": remote})).await.is_ok());
    let refused = [
        (method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []})),
        (
            method::SESSION_PROMPT,
            json!({"sessionId": remote, "prompt": [{"type": "text", "text": "x"}]}),
        ),
        (method::MUX_KILL, json!({"sessionId": remote})),
        (method::MUX_RENAME, json!({"sessionId": remote, "name": "x"})),
        (method::MUX_SET_POLICY, json!({"sessionId": remote, "policy": "ask"})),
        (method::MUX_PAIR_LIST, json!({})),
        ("_acpmux/peer_add", json!({"name": "x", "url": "ws://127.0.0.1:1"})),
    ];
    for (i, (m, p)) in refused.into_iter().enumerate() {
        let e = rpc(&mut ws, 10 + i as u64, m, p).await.unwrap_err();
        assert_eq!(e["data"]["reason"], "read_only", "{m}: {e}");
    }
    // Nothing it sent changed the session.
    let mut cb = C::new(b.clone()).await;
    let v = cb.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    let sessions = v["sessions"].as_array().unwrap();
    assert!(sessions.iter().any(|s| s["name"] == "remote-one"), "{v}");
    assert_eq!(sessions.len(), 1, "{v}");
}

/// A read-only machine resolves a name or link to a session (`_acpmux/resolve`), and reads no
/// more than its session list shows: every field of the card is the listed summary's, and
/// neither this machine's name nor its peers' (a peer with no sessions, its state) appear.
#[tokio::test]
async fn pairing_a_read_only_machine_resolves_no_more_than_its_session_list_shows() {
    let b = hub();
    let url = listen(b.clone()).await;
    remote_session(&b).await;
    // A peer of B with no sessions, never connected: a session list does not name it.
    b.add_peer("quiet-peer", "ws://127.0.0.1:1", None, None, false).await.unwrap();
    let secret = mint(&b, Role::ReadOnly, &url);
    let reply = redeem(&url, &secret, json!({"name": "tablet"})).await.unwrap();
    let bearer = format!("Bearer {}", reply["token"].as_str().unwrap());
    let mut ws = dial(&url, &[("authorization", &bearer)]).await.unwrap();
    rpc(&mut ws, 1, method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();

    let listed = rpc(&mut ws, 2, method::MUX_SESSIONS, json!({})).await.unwrap();
    let summary = listed["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["name"] == "remote-one")
        .cloned()
        .unwrap_or_else(|| panic!("{listed}"));
    let found = rpc(&mut ws, 3, method::MUX_RESOLVE, json!({"query": "remote-one"}))
        .await
        .unwrap_or_else(|e| panic!("resolve refused: {e}"));
    let card = found["session"].as_object().unwrap_or_else(|| panic!("{found}"));
    let machine = acpmux::pairing::machine_name();
    for (key, value) in card {
        match key.as_str() {
            // Derived from the summary's tags.
            "beads" => assert_eq!(value, &json!([]), "{found}"),
            // This machine's session: no host name, so no link that names one.
            "host" | "link" => assert!(value.is_null(), "{key}: {found}"),
            _ => assert_eq!(value, &summary[key], "{key}: {found}"),
        }
    }
    assert!(!found.to_string().contains(&format!("host={machine}")), "{found}");

    let e =
        rpc(&mut ws, 4, method::MUX_RESOLVE, json!({"query": "nobody-here"})).await.unwrap_err();
    let text = e.to_string();
    assert!(text.contains("nobody-here"), "{text}");
    assert!(!text.contains("quiet-peer"), "{text}");
    assert!(!text.contains(&machine), "{text}");
}

#[tokio::test]
async fn pairing_revoking_a_machine_closes_its_connection_and_refuses_it_again() {
    let b = hub();
    let url = listen(b.clone()).await;
    let secret = mint(&b, Role::Client, &url);
    let reply = redeem(&url, &secret, json!({"name": "laptop"})).await.unwrap();
    let bearer = format!("Bearer {}", reply["token"].as_str().unwrap());
    let mut ws = dial(&url, &[("authorization", &bearer)]).await.unwrap();
    let init = rpc(&mut ws, 1, method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    assert_eq!(init["_meta"]["acpmux"]["auth"], "device");
    assert_eq!(init["_meta"]["acpmux"]["origin"], "peer");

    let v = b.pairing.revoke("laptop").unwrap();
    assert_eq!(v["closed_connections"], 1);
    let closed = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match ws.next().await {
                None | Some(Err(_)) | Some(Ok(Frame::Close(_))) => return,
                Some(Ok(_)) => continue,
            }
        }
    })
    .await;
    assert!(closed.is_ok(), "the revoked machine's connection stayed open");
    assert!(dial(&url, &[("authorization", &bearer)]).await.is_err());
    // The dashboard token still works.
    let dashboard = format!("Bearer {DASHBOARD}");
    assert!(dial(&url, &[("authorization", &dashboard)]).await.is_ok());
}

#[tokio::test]
async fn pairing_wrong_and_revoked_tickets_and_credentials_are_refused_at_the_upgrade() {
    let b = hub();
    let url = listen(b.clone()).await;
    // An unknown ticket, and a revoked one.
    assert!(dial(&url, &[(TICKET_HEADER, &"0".repeat(64))]).await.is_err());
    let (ticket, record) =
        b.pairing.mint(Role::Client, 900, None, url.clone(), "b".into()).unwrap();
    b.pairing.revoke(&record.id).unwrap();
    assert!(dial(&url, &[(TICKET_HEADER, &ticket.secret)]).await.is_err());
    // Two ticket headers.
    let open = mint(&b, Role::Client, &url);
    assert!(dial(&url, &[(TICKET_HEADER, &open), (TICKET_HEADER, &open)]).await.is_err());
    // A daemon ticket redeemed without an advertised address is refused
    // and stays open.
    let secret = mint(&b, Role::Daemon, &url);
    let e = redeem(&url, &secret, json!({"name": "nodaemon"})).await.unwrap_err();
    assert_eq!(e["data"]["reason"], "advertise_required", "{e}");
    assert!(b.pairing.ticket_open(&secret), "a refused redeem keeps the ticket");
    // A wrong credential in place of the dashboard token.
    let wrong = format!("Bearer {}", "ab".repeat(32));
    assert!(dial(&url, &[("authorization", &wrong)]).await.is_err());
    // A daemon-role record names a machine this one drives; it proves nothing here.
    let (_, daemon) = b.pairing.issue("driven", Role::Daemon).unwrap();
    let daemon = format!("Bearer {daemon}");
    assert!(dial(&url, &[("authorization", &daemon)]).await.is_err());
    // The minter's methods are the unix socket's only.
    let dashboard = format!("Bearer {DASHBOARD}");
    let mut ws = dial(&url, &[("authorization", &dashboard)]).await.unwrap();
    rpc(&mut ws, 1, method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    for (i, m) in [
        method::MUX_PAIR_TICKET_NEW,
        method::MUX_PAIR_LIST,
        method::MUX_PAIR_REVOKE,
        method::MUX_PAIR_ISSUE,
        method::MUX_PAIR_REDEEM,
    ]
    .into_iter()
    .enumerate()
    {
        let e = rpc(&mut ws, 2 + i as u64, m, json!({"role": "client"})).await.unwrap_err();
        assert!(e["message"].as_str().unwrap().contains("local socket only"), "{m}: {e}");
    }
}

#[tokio::test]
async fn pairing_a_daemon_ticket_makes_the_minter_dial_the_joiner() {
    let b = hub();
    let b_url = listen(b.clone()).await;
    let a = hub();
    let a_url = listen(a.clone()).await;
    // A issues B a client credential for A's own listener, then redeems.
    let (_, for_b) = a.pairing.issue("b", Role::Client).unwrap();
    let secret = mint(&b, Role::Daemon, &b_url);
    let reply = redeem(
        &b_url,
        &secret,
        json!({"name": "a", "advertiseUrl": a_url, "advertiseToken": for_b}),
    )
    .await
    .unwrap();
    assert_eq!(reply["role"], "daemon");
    assert!(reply.get("token").is_none(), "a daemon-role joiner gets no credential: {reply}");
    assert_eq!(reply["peer"]["url"], a_url);
    b.reconnect_peer("a", true).await.unwrap();
    let peers = b.peers();
    let peer = peers.iter().find(|p| p["name"] == "a").expect("B saved A as a peer");
    assert_eq!(peer["servedAs"], "peer", "{peers:?}");
    // Revoking the machine on B removes the peer too.
    let mut cb = C::new(b.clone()).await;
    cb.call(method::MUX_PAIR_REVOKE, json!({"id": "a"})).await.unwrap();
    assert!(b.peers().iter().all(|p| p["name"] != "a"), "{:?}", b.peers());
}

#[tokio::test]
async fn pairing_the_minter_mints_lists_and_revokes_over_its_socket() {
    let b = hub();
    let mut cb = C::new(b.clone()).await;
    // No listener: the minter must be told where it is reached.
    let e = cb.call(method::MUX_PAIR_TICKET_NEW, json!({"role": "client"})).await.unwrap_err();
    assert!(e.contains("listener"), "{e}");
    let e = cb
        .call(method::MUX_PAIR_TICKET_NEW, json!({"role": "client", "url": "ws://10.1.2.3:1"}))
        .await
        .unwrap_err();
    assert!(e.contains("wss://"), "{e}");
    let e = cb.call(method::MUX_PAIR_TICKET_NEW, json!({"role": "owner"})).await.unwrap_err();
    assert!(e.contains("read-only"), "{e}");
    let v = cb
        .call(
            method::MUX_PAIR_TICKET_NEW,
            json!({"role": "read-only", "url": "wss://b.example/acp", "ttlSeconds": 60, "label": "tab"}),
        )
        .await
        .unwrap();
    let ticket = acpmux::pairing::Ticket::decode(v["ticket"].as_str().unwrap()).unwrap();
    assert_eq!(ticket.role, Role::ReadOnly);
    assert_eq!(ticket.url, "wss://b.example/acp");
    assert_eq!(v["role"], "read-only");
    assert!(v["expires_at"].as_str().unwrap().ends_with('Z'));
    let list = cb.call(method::MUX_PAIR_LIST, json!({})).await.unwrap();
    assert_eq!(list["tickets"][0]["state"], "open");
    assert_eq!(list["tickets"][0]["label"], "tab");
    assert!(!list.to_string().contains(&ticket.secret), "the list shows no secret");
    let id = v["id"].as_str().unwrap();
    let r = cb.call(method::MUX_PAIR_REVOKE, json!({"id": id})).await.unwrap();
    assert_eq!(r["revoked"]["kind"], "ticket");
    let list = cb.call(method::MUX_PAIR_LIST, json!({})).await.unwrap();
    assert_eq!(list["tickets"][0]["state"], "revoked");
}
