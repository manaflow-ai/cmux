//! Real transport measurement for RFD 0140 machine presence.
//!
//! This is intentionally ignored in ordinary test runs: it waits for the production 30 s
//! heartbeat TTL. The harness uses two authenticated local clients against one in-process hub;
//! machine presence is deliberately local and the production peer link rejects presence beats.
//! The fleet command runs it with `TESTNAME -- --ignored --nocapture` and records the p95
//! visibility and expiry numbers.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::protocol::here::{HereActivity, HereBeatParams, HereDeviceKind};
use acpmux::rpc::method;
use acpmux::server::serve_connection;
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
        let deadline = tokio::time::Instant::now() + timeout;
        self.next += 1;
        let id = self.next;
        tokio::time::timeout_at(
            deadline,
            self.tx.send(acpmux::rpc::Message::request(id, method_name, params).to_line()),
        )
        .await
        .expect("request send timeout")
        .expect("request channel closed");
        loop {
            let line = tokio::time::timeout_at(deadline, self.rx.recv())
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
}

async fn pair() -> (Arc<Hub>, Client, Client) {
    let hub = Hub::new(config(), store(&config()));
    let source = Client::connect(&hub).await;
    let observer = Client::connect(&hub).await;
    (hub, source, observer)
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
    presence_age_ms(v).is_some()
}

fn presence_age_ms(v: &Value) -> Option<u64> {
    v["here"]
        .as_array()
        .and_then(|rows| rows.iter().find(|row| row["id"] == "tailnet:transport-a"))
        .and_then(|row| row["devices"].as_array())
        .and_then(|devices| devices.iter().find(|device| device["device"] == "transport-a"))
        .and_then(|device| device["ageMs"].as_u64())
}

async fn wait_for_scope(
    client: &mut Client,
    scope: &str,
    started: Instant,
    deadline: Instant,
    expected: bool,
) -> Duration {
    loop {
        let now = Instant::now();
        assert!(
            now < deadline,
            "scope {scope:?} did not reach expected={expected} before deadline"
        );
        let query_timeout = deadline.duration_since(now).min(Duration::from_millis(500));
        let now = client
            .request_with_timeout(method::MUX_HERE, json!({"scope": scope}), query_timeout)
            .await;
        if has_presence(&now) == expected {
            return started.elapsed();
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        tokio::time::sleep(Duration::from_millis(10).min(remaining)).await;
    }
}

struct ExpiryWindow {
    last_visible: (Instant, Instant, u64),
    first_absent: (Instant, Instant),
}

async fn wait_for_expiry(client: &mut Client, scope: &str, deadline: Instant) -> ExpiryWindow {
    let mut last_visible = None;
    loop {
        let query_started = Instant::now();
        assert!(query_started < deadline, "scope {scope:?} did not expire before deadline");
        let query_timeout = deadline.duration_since(query_started).min(Duration::from_millis(500));
        let now = client
            .request_with_timeout(method::MUX_HERE, json!({"scope": scope}), query_timeout)
            .await;
        let query_finished = Instant::now();
        if let Some(age_ms) = presence_age_ms(&now) {
            last_visible = Some((query_started, query_finished, age_ms));
        } else {
            let last_visible = last_visible.expect("presence was never visible before expiry");
            return ExpiryWindow { last_visible, first_absent: (query_started, query_finished) };
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        tokio::time::sleep(Duration::from_millis(10).min(remaining)).await;
    }
}

async fn client_request_until(
    client: &mut Client,
    method_name: &str,
    params: Value,
    deadline: Instant,
) -> Value {
    let timeout = deadline.saturating_duration_since(Instant::now());
    assert!(!timeout.is_zero(), "client request deadline elapsed");
    client.request_with_timeout(method_name, params, timeout).await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "fleet measurement: waits for the production 30 s presence TTL"]
async fn two_clients_presence_visibility_p95_and_ttl() {
    let (_hub, mut source, mut observer) = pair().await;
    let mut visibility = Vec::with_capacity(SAMPLES);
    for seq in 1..=SAMPLES as u64 {
        let scope = format!("rfd0140-seq-{seq}");
        let started = Instant::now();
        let deadline = started + Duration::from_secs(5);
        let changed =
            client_request_until(&mut source, method::MUX_HERE_BEAT, beat(seq, &scope), deadline)
                .await;
        assert_eq!(changed["changed"], true, "heartbeat {seq} was not accepted: {changed}");
        visibility.push(wait_for_scope(&mut observer, &scope, started, deadline, true).await);
    }
    let mut sorted = visibility.clone();
    sorted.sort();
    let p95 = sorted[(SAMPLES - 1) * 95 / 100];
    assert!(
        p95 < VISIBILITY_P95,
        "presence visibility p95 {:?} exceeded {:?}; samples={:?}",
        p95,
        VISIBILITY_P95,
        sorted
    );

    let final_scope = format!("rfd0140-final-{SAMPLES}");
    let sent_at = Instant::now();
    let ack_deadline = sent_at + Duration::from_secs(5);
    let changed = client_request_until(
        &mut source,
        method::MUX_HERE_BEAT,
        beat((SAMPLES + 1) as u64, &final_scope),
        ack_deadline,
    )
    .await;
    assert_eq!(changed["changed"], true, "final heartbeat was not accepted: {changed}");
    let acked_at = Instant::now();
    let expiry_deadline = sent_at + TTL + Duration::from_secs(2);
    let expiry = wait_for_expiry(&mut observer, &final_scope, expiry_deadline).await;
    let tolerance = Duration::from_millis(2);
    let expected = (sent_at + TTL, acked_at + TTL);
    let observed = (expiry.last_visible.0, expiry.first_absent.1);
    assert!(
        observed.0 <= expected.1 + tolerance && observed.1 + tolerance >= expected.0,
        "expiry interval {:?} did not overlap acceptance window + TTL {:?}; last_age_ms={}",
        observed,
        expected,
        expiry.last_visible.2
    );
    let elapsed = expiry.first_absent.1.duration_since(sent_at);
    assert!(elapsed < TTL + Duration::from_secs(2), "presence outlived TTL by {:?}", elapsed - TTL);
    eprintln!(
        "PRESENCE-TRANSPORT samples={SAMPLES} visibility_p95_ms={} ttl_expiry_ms={} ttl_last_visible_age_ms={} ttl_ms={}",
        p95.as_millis(),
        elapsed.as_millis(),
        expiry.last_visible.2,
        TTL.as_millis()
    );
}
