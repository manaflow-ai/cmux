//! Real two-daemon transport measurement for RFD 0140 machine presence.
//!
//! This is intentionally ignored in ordinary test runs: it waits for the production 30 s
//! heartbeat TTL. The fleet command runs it with `--ignored --nocapture` and records the p95
//! visibility and expiry numbers.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::peer::Peer;
use acpmux::protocol::here::{HereActivity, HereBeatParams, HereDeviceKind};
use acpmux::rpc::method;
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const SAMPLES: usize = 50;
const VISIBILITY_P95: Duration = Duration::from_millis(250);
const TTL: Duration = Duration::from_secs(30);

fn config() -> Config {
    let mut c = Config::default();
    c.store.mode = StoreMode::Memory;
    c.permission_policy = PermissionPolicy::ApproveAll;
    c.harnesses = BTreeMap::new();
    c
}

fn store(c: &Config) -> Box<dyn acpmux::store::Store> {
    acpmux::store::open(&c.store, std::path::Path::new("/nonexistent")).unwrap()
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    async fn connect(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
        Self { tx: in_tx, rx: out_rx, next: 0 }
    }

    async fn request_with_timeout(
        &mut self,
        method_name: &str,
        params: Value,
        timeout: Duration,
    ) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx
            .send(acpmux::rpc::Message::request(id, method_name, params).to_line())
            .await
            .unwrap();
        loop {
            let line = tokio::time::timeout(timeout, self.rx.recv())
                .await
                .expect("response timeout")
                .expect("connection closed");
            if let acpmux::rpc::Message::Response { id: got, result, error } =
                acpmux::rpc::Message::parse(&line).unwrap()
                && got == id
            {
                assert!(error.is_none(), "RPC {method_name} failed: {error:?}");
                return result.unwrap_or(Value::Null);
            }
        }
    }

    async fn request(&mut self, method_name: &str, params: Value) -> Value {
        self.request_with_timeout(method_name, params, Duration::from_secs(5)).await
    }
}

async fn pair() -> (Arc<Hub>, Arc<Hub>, Arc<Peer>, Client) {
    let a = Arc::new(Hub::new(config(), store(&config())));
    let b = Arc::new(Hub::new(config(), store(&config())));
    let home = tempfile::tempdir().unwrap();
    let auth = PeerAuth::create(home.path()).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(home.path())).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(
        b.clone(),
        listener,
        "transport-presence".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    a.add_peer(
        "b",
        &format!("ws://127.0.0.1:{port}"),
        Some("transport-presence".into()),
        Some(peer_token.trim().into()),
        false,
    )
    .await
    .unwrap();
    let peer = a.peer_by_name("b").unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while a.peers()[0]["state"] != "connected" {
        assert!(Instant::now() < deadline, "peer did not connect: {:?}", a.peers());
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let client = Client::connect(&b).await;
    (a, b, peer, client)
}

fn beat(seq: u64, scope: &str) -> Value {
    serde_json::to_value(HereBeatParams {
        device: "transport-a".into(),
        device_kind: HereDeviceKind::Vm,
        seq,
        activity: HereActivity::Working,
        idle_ms: 0,
        scopes: vec![scope.into()],
        leave: false,
        meta: Some(acpmux::protocol::presence::AuthorMeta {
            acpmux: Some(acpmux::protocol::presence::AuthorMetaFields {
                author: Some(acpmux::protocol::presence::Author {
                    id: "tailnet:transport-a".into(),
                    name: "transport-a".into(),
                    login: Some("transport-a".into()),
                    node: Some("vm".into()),
                    approval: None,
                }),
            }),
        }),
    })
    .unwrap()
}

fn has_presence(v: &Value) -> bool {
    v["here"]
        .as_array()
        .is_some_and(|rows| rows.iter().any(|row| row["id"] == "tailnet:transport-a"))
}

async fn wait_for_scope(
    client: &mut Client,
    scope: &str,
    deadline: Instant,
    expected: bool,
) -> Duration {
    let started = Instant::now();
    loop {
        assert!(
            Instant::now() < deadline,
            "scope {scope:?} did not reach expected={expected} before deadline"
        );
        let now = client
            .request_with_timeout(
                method::MUX_HERE,
                json!({"scope": scope}),
                Duration::from_millis(500),
            )
            .await;
        if has_presence(&now) == expected {
            return started.elapsed();
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "fleet measurement: waits for the production 30 s presence TTL"]
async fn two_daemons_presence_visibility_p95_and_ttl() {
    let (_a, b, peer, mut client) = pair().await;
    let mut visibility = Vec::with_capacity(SAMPLES);
    for seq in 1..=SAMPLES as u64 {
        let scope = format!("rfd0140-seq-{seq}");
        let changed = peer.request(method::MUX_HERE_BEAT, beat(seq, &scope)).await.unwrap();
        assert_eq!(changed["changed"], true, "heartbeat {seq} was not accepted: {changed}");
        visibility.push(
            wait_for_scope(&mut client, &scope, Instant::now() + Duration::from_secs(5), true)
                .await,
        );
    }
    let mut sorted = visibility.clone();
    sorted.sort();
    let p95 = sorted[((SAMPLES - 1) * 95 / 100)];
    assert!(
        p95 < VISIBILITY_P95,
        "presence visibility p95 {:?} exceeded {:?}; samples={:?}",
        p95,
        VISIBILITY_P95,
        sorted
    );

    let final_scope = format!("rfd0140-final-{SAMPLES}");
    let changed = peer
        .request(method::MUX_HERE_BEAT, beat((SAMPLES + 1) as u64, &final_scope))
        .await
        .unwrap();
    assert_eq!(changed["changed"], true, "final heartbeat was not accepted: {changed}");
    let accepted_at = Instant::now();
    let expiry = wait_for_scope(
        &mut client,
        &final_scope,
        accepted_at + TTL + Duration::from_secs(2),
        false,
    )
    .await;
    assert!(expiry >= TTL, "presence expired early at {:?}", expiry);
    assert!(expiry < TTL + Duration::from_secs(2), "presence outlived TTL by {:?}", expiry - TTL);
    eprintln!(
        "PRESENCE-TRANSPORT samples={SAMPLES} visibility_p95_ms={} ttl_expiry_ms={} ttl_ms={}",
        p95.as_millis(),
        expiry.as_millis(),
        TTL.as_millis()
    );
}
