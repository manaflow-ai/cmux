//! `_acpmux/peer_lease` (`hub/peer_lease.rs`): a peer that lasts only as long
//! as the unix socket connection that leased it. Two hubs: B serves
//! WebSocket with a peer token, A leases B over a local connection.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection_with, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

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
    cfg.permission_policy = PermissionPolicy::Ask;
    cfg
}

fn hub(cfg: Config) -> Arc<Hub> {
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A scratch folder, removed when the test ends (also when it fails).
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn scratch(tag: &str) -> Scratch {
    let d = std::env::temp_dir().join(format!("apl-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    Scratch(d)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    fn new(h: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(h.clone(), in_rx, out_tx, origin));
        C { tx: in_tx, rx: out_rx, next: 0 }
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(40), self.rx.recv())
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

    /// Close the connection and wait until the daemon finished with it: its
    /// end (every lease it held ended) comes before its last reply sender
    /// drops.
    async fn close(self) {
        let C { tx, mut rx, .. } = self;
        drop(tx);
        tokio::time::timeout(Duration::from_secs(20), async { while rx.recv().await.is_some() {} })
            .await
            .expect("the daemon never finished with the closed connection");
    }
}

/// B: a hub with one session, serving WebSocket with dashboard token `tok`
/// and a peer token. Returns B, its port and its peer token.
async fn serving_b(tag: &str) -> (Arc<Hub>, u16, String) {
    let b = hub(config());
    let home = scratch(&format!("{tag}-b"));
    let auth = PeerAuth::create(&home.0).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home.0)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), auth));
    let mut cb = C::new(&b, Origin::Local);
    cb.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
        "_meta": {"acpmux": {"name": "vm-one"}}});
    cb.call(method::SESSION_NEW, new).await.unwrap();
    (b, port, peer_token)
}

fn lease(port: u16, peer_token: &str) -> Value {
    json!({"name": "cloud-vm", "url": format!("ws://127.0.0.1:{port}"), "token": "tok",
        "peerToken": peer_token, "wait": true})
}

#[tokio::test]
async fn a_peer_lease_lists_the_peers_sessions_served_as_a_peer() {
    let (_b, port, peer_token) = serving_b("list").await;
    let a = hub(config());
    let mut ca = C::new(&a, Origin::Local);
    ca.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    let r = ca.call("_acpmux/peer_lease", lease(port, &peer_token)).await.unwrap();
    assert_eq!(r["lease"], "cloud-vm");
    let peer = &r["peers"][0];
    assert_eq!(peer["name"], "cloud-vm", "{r}");
    assert_eq!(peer["servedAs"], "peer", "{r}");
    assert_eq!(peer["leased"], true, "{r}");
    let v = ca.call(method::MUX_SESSIONS, json!({})).await.unwrap();
    assert!(
        v["sessions"].as_array().unwrap().iter().any(|s| s["name"] == "cloud-vm/vm-one"),
        "the leased peer's session is not listed: {v}"
    );
}

#[tokio::test]
async fn a_peer_lease_never_changes_config_json_and_ends_with_its_connection() {
    let (_b, port, peer_token) = serving_b("close").await;
    let scratch_a = scratch("close-a");
    let dir = &scratch_a.0;
    let mut cfg = config();
    cfg.path = Some(dir.join("config.json"));
    cfg.save().unwrap();
    let a = hub(cfg);

    let mut ca = C::new(&a, Origin::Local);
    ca.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    let before = std::fs::read(dir.join("config.json")).unwrap();
    ca.call("_acpmux/peer_lease", lease(port, &peer_token)).await.unwrap();
    assert_eq!(a.peers().len(), 1);
    assert_eq!(std::fs::read(dir.join("config.json")).unwrap(), before, "a lease saved config");
    assert!(
        a.all_session_summaries().iter().any(|s| s["name"] == "cloud-vm/vm-one"),
        "{:?}",
        a.all_session_summaries()
    );

    // Another connection's close does not end the lease.
    let mut other = C::new(&a, Origin::Local);
    other.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    other.close().await;
    assert_eq!(a.peers().len(), 1, "{:?}", a.peers());

    // The leasing connection closes: the peer and its rows go with it.
    ca.close().await;
    assert!(a.peers().is_empty(), "{:?}", a.peers());
    assert!(!a.is_leased("cloud-vm"));
    assert!(
        !a.all_session_summaries().iter().any(|s| s["peer"] == "cloud-vm"),
        "{:?}",
        a.all_session_summaries()
    );
    assert_eq!(std::fs::read(dir.join("config.json")).unwrap(), before, "ending saved config");
}

#[tokio::test]
async fn a_renewed_peer_lease_survives_the_first_connection() {
    let (_b, port, peer_token) = serving_b("renew").await;
    let a = hub(config());
    let mut first = C::new(&a, Origin::Local);
    first.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    first.call("_acpmux/peer_lease", lease(port, &peer_token)).await.unwrap();
    let mut second = C::new(&a, Origin::Local);
    second.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    second.call("_acpmux/peer_lease", lease(port, &peer_token)).await.unwrap();
    // The first connection's lease was superseded: its close leaves the
    // second's peer running.
    first.close().await;
    assert_eq!(a.peers().len(), 1, "{:?}", a.peers());
    assert_eq!(a.peers()[0]["connected"], true, "{:?}", a.peers());
    assert!(a.is_leased("cloud-vm"));
    second.close().await;
    assert!(a.peers().is_empty(), "{:?}", a.peers());
}

#[tokio::test]
async fn a_peer_lease_never_takes_a_saved_peers_name() {
    let mut cfg = config();
    cfg.peers.insert(
        "cloud-vm".into(),
        acpmux::config::PeerConfig {
            wireguard: None,
            url: "ws://127.0.0.1:1".into(),
            token: None,
            peer_token: None,
            vm_boundary: false,
            github_broker: false,
        },
    );
    let a = hub(cfg);
    let mut ca = C::new(&a, Origin::Local);
    ca.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    let e = ca.call("_acpmux/peer_lease", lease(1, &"0".repeat(64))).await.unwrap_err();
    assert!(e.contains("saved peer"), "{e}");
    assert!(!a.is_leased("cloud-vm"));
}

#[tokio::test]
async fn a_peer_lease_is_refused_to_web_local_app_and_peer_callers() {
    let (_b, port, peer_token) = serving_b("guard").await;
    let a = hub(config());
    for origin in [Origin::Web, Origin::LocalApp, Origin::Peer] {
        let mut c = C::new(&a, origin);
        let e = c.call("_acpmux/peer_lease", lease(port, &peer_token)).await.unwrap_err();
        assert!(e.contains("only over the local unix socket"), "{origin:?}: {e}");
    }
    assert!(a.peers().is_empty(), "{:?}", a.peers());
}

/// A closing connection ends its leases before it kills its ephemeral
/// sessions: that kill awaits each agent, and a leased peer must not keep
/// pointing at a forward port its bridge already closed meanwhile.
#[tokio::test]
async fn a_closing_connection_ends_its_peer_lease_before_killing_its_ephemeral_sessions() {
    let (_b, port, peer_token) = serving_b("order").await;
    let a = hub(config());
    let mut ca = C::new(&a, Origin::Local);
    ca.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    ca.call("_acpmux/peer_lease", lease(port, &peer_token)).await.unwrap();
    assert!(
        a.all_session_summaries().iter().any(|s| s["name"] == "cloud-vm/vm-one"),
        "{:?}",
        a.all_session_summaries()
    );
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
        "_meta": {"acpmux": {"name": "scratch", "ephemeral": true}}});
    let r = ca.call(method::SESSION_NEW, new).await.unwrap();
    let id = r["sessionId"].as_str().expect("sessionId").to_owned();

    let mut events = a.subscribe();
    ca.close().await;
    // The leased peer's rows purged, and the ephemeral session purged (the
    // end of its kill). Only purges: the agent may still be sending events.
    let (mut lease_ended, mut killed) = (None, None);
    let mut at = 0;
    while let Ok(e) = events.try_recv() {
        match &e.remote {
            Some(r) if r.peer == "cloud-vm" && e.record.kind == "purged" => {
                lease_ended.get_or_insert(at);
            }
            None if e.session_id == id && e.record.kind == "purged" => {
                killed.get_or_insert(at);
            }
            _ => {}
        }
        at += 1;
    }
    let (lease_ended, killed) = (
        lease_ended.expect("the lease's rows were never purged"),
        killed.expect("the ephemeral session was never killed"),
    );
    assert!(lease_ended < killed, "the lease ended after the kill ({lease_ended} >= {killed})");
    assert!(a.peers().is_empty(), "{:?}", a.peers());
    assert!(a.resolve(&id).is_err(), "the ephemeral session was not purged");
}

/// A saved peer's `vmBoundary` (`hub/vm_boundary.rs`) follows config.json at a
/// reload: the caller taking it back applies to the running peer at once, with
/// no reconnect.
#[tokio::test]
async fn a_reload_takes_a_saved_peers_vm_boundary_back() {
    let scratch_a = scratch("reload-vmb");
    let path = scratch_a.0.join("config.json");
    let write = |on: bool| {
        let mut cfg = config();
        cfg.path = Some(path.clone());
        cfg.peers.insert(
            "vm".into(),
            acpmux::config::PeerConfig {
                wireguard: None,
                url: "ws://127.0.0.1:1".into(),
                token: None,
                peer_token: None,
                vm_boundary: on,
                github_broker: false,
            },
        );
        cfg.save().unwrap();
        cfg
    };
    let a = hub(write(true));
    a.reconnect_peer("vm", false).await.unwrap();
    assert!(a.peer_by_name("vm").unwrap().vm_boundary());
    write(false);
    a.reload_catalog().await.unwrap();
    assert!(!a.peer_by_name("vm").unwrap().vm_boundary(), "the reload left the boundary on");
    write(true);
    a.reload_catalog().await.unwrap();
    assert!(a.peer_by_name("vm").unwrap().vm_boundary());
}

/// The caller's side of the VM boundary (`hub/vm_boundary.rs`): a lease with
/// `vmBoundary` makes each `session/new` the person's own clients forward to the
/// peer carry `_meta.acpmux.vmBoundary: true`; a field the client sent itself is
/// dropped first. A Web client's never carries it, nor a paired machine's (which
/// goes as `via: device`), nor anything through a plain lease.
#[tokio::test]
async fn a_vm_boundary_lease_forwards_the_boundary_for_the_persons_own_clients_only() {
    use acpmux::server::{ConnAuth, serve_connection_authed};
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;

    for vm_boundary in [true, false] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (received_tx, mut received_rx) = mpsc::channel(8);
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            while let Some(Ok(Ws::Text(text))) = ws.next().await {
                let Ok(Message::Request { id, method: m, params }) = Message::parse(&text) else {
                    continue;
                };
                let reply = if m == method::SESSION_NEW {
                    received_tx.send(params.unwrap_or_default()).await.unwrap();
                    Message::err(id, acpmux::rpc::RpcError::invalid_params("recorded"))
                } else if m == method::INITIALIZE {
                    Message::ok(
                        id,
                        json!({"protocolVersion": 1, "_meta": {"acpmux": {
                        "version": "0", "build": "test", "origin": "peer",
                        "features": ["trustGate"]}}}),
                    )
                } else {
                    Message::ok(id, json!({}))
                };
                ws.send(Ws::Text(reply.to_line().into())).await.unwrap();
            }
        });
        let a = hub(config());
        let mut ca = C::new(&a, Origin::Local);
        let mut lease = json!({"name": "cloud-vm", "url": format!("ws://127.0.0.1:{port}"),
            "token": "tok", "wait": true});
        if vm_boundary {
            lease["vmBoundary"] = json!(true);
        }
        ca.call("_acpmux/peer_lease", lease).await.unwrap();
        let new = |name: &str| {
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {
                "peer": "cloud-vm", "name": name, "vmBoundary": true}}})
        };
        let mut received = BTreeMap::new();
        let mut replies = BTreeMap::new();
        let mut clients = vec![
            ("own", C::new(&a, Origin::Local)),
            ("app", C::new(&a, Origin::LocalApp)),
            ("web", C::new(&a, Origin::Web)),
        ];
        // A paired machine's `client` credential: served as a peer (`pairing::origin_of`).
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            a.clone(),
            in_rx,
            out_tx,
            Origin::Peer,
            ConnAuth::Device,
        ));
        clients.push(("device", C { tx: in_tx, rx: out_rx, next: 0 }));
        for (name, c) in &mut clients {
            let reply = c.call(method::SESSION_NEW, new(name)).await;
            replies.insert(name.to_string(), format!("{reply:?}"));
            if let Ok(Some(p)) =
                tokio::time::timeout(Duration::from_millis(500), received_rx.recv()).await
            {
                received.insert(name.to_string(), p["_meta"]["acpmux"].clone());
            }
        }
        server.abort();
        for name in ["own", "app"] {
            let meta =
                received.get(name).unwrap_or_else(|| panic!("{name} never reached the peer"));
            assert_eq!(
                meta.get("vmBoundary"),
                vm_boundary.then_some(&json!(true)),
                "{name}: {meta}"
            );
        }
        // A Web client and a paired machine: if the guard here lets the start through
        // at all, it goes as theirs, never at the boundary.
        for (name, via) in [("web", "web"), ("device", "device")] {
            if let Some(meta) = received.get(name) {
                assert_eq!(meta["via"], via, "{name}: {meta}");
                assert!(meta.get("vmBoundary").is_none(), "{name}: {meta}");
            }
        }
    }
}
