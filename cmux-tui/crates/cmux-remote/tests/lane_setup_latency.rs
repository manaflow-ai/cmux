#![cfg(unix)]
//! What a first connect costs on a relay-shaped carrier, on a paused clock: the real
//! `RemoteDaemon` and `ClientConnection` over the carrier simulation's links (`carrier_sim/net.rs`)
//! behind a group that opens links as `RelayLinkGroup::open` does. Each link's allocation is one
//! request on the group's one control socket (so allocations queue), and its circuit join is a
//! WebSocket of its own (TCP, TLS, upgrade) that runs alongside the others.
//!
//! A carrier connect has three lane links. With the daemon key pinned (every carrier dial pins
//! it) the three open and authenticate at once, so the connect costs about one link's open and
//! handshake plus the two allocations queued ahead of the last link, not a second open and
//! handshake after the first (production `cloud-chat-replies-production` 2026-11-22..23: the
//! `handshake` share of an ok dial was 1,020 ms p50, of which ~0.5 s was lanes 2 and 3 opening
//! after lane 1).
//!
//! Run (from `cmux-tui/`): `cargo test -p cmux-remote --test lane_setup_latency -- --nocapture`

#[allow(dead_code)]
#[path = "carrier_sim/net.rs"]
mod net;
#[allow(dead_code)]
#[path = "carrier_sim/rng.rs"]
mod rng;

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{DEFAULT_RESUME_LEASE, DaemonSessionPolicy, RemoteDaemon};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::link::FrameLink;
use cmux_remote::observability::TransportSnapshot;
use cmux_remote::provider::{
    CarrierEvidence, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{LanePolicy, SessionId};
use tokio::time::Instant;

use crate::net::{Route, SimGroup};
use crate::rng::Rng;

/// One-way latency of every simulated frame.
const ONE_WAY: Duration = Duration::from_millis(50);
/// A relay allocation: Connect and Allocated on the control socket, one round trip.
const ALLOCATE: Duration = Duration::from_millis(100);
/// A circuit join on its own WebSocket: TCP, TLS and upgrade, three round trips. The simulated
/// link's own open adds one more round trip after it.
const JOIN: Duration = Duration::from_millis(300);

/// A carrier group shaped like `RelayLinkGroup`: allocations take turns on one control socket,
/// joins do not.
struct RelayShaped {
    inner: Arc<SimGroup>,
    control: tokio::sync::Mutex<()>,
    evidence: CarrierEvidence,
}

#[async_trait]
impl LinkGroup for RelayShaped {
    fn description(&self) -> &str {
        "relay-shaped sim"
    }
    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::MULTI_STREAM
    }
    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }
    async fn transport_snapshot(&self) -> TransportSnapshot {
        self.inner.transport_snapshot().await
    }
    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        {
            let _control = self.control.lock().await;
            tokio::time::sleep(ALLOCATE).await;
        }
        tokio::time::sleep(JOIN).await;
        self.inner.open(request).await
    }
    async fn close(&self) -> Result<(), ProviderError> {
        self.inner.close().await
    }
}

/// How long a first connect with `lane_policy` takes against a fresh daemon.
async fn connect_time(lane_policy: LanePolicy) -> Duration {
    let dir = tempfile::tempdir().expect("tempdir");
    let auth = AuthDatabase::load_or_create(dir.path(), "lane-setup", false).expect("auth");
    let (daemon, mut accepted) = RemoteDaemon::with_policy(
        auth,
        SessionLimits::default(),
        DaemonSessionPolicy { resume_lease: DEFAULT_RESUME_LEASE },
    )
    .expect("daemon");
    let expected = daemon.auth().identity().public_key();
    let drain = tokio::spawn(async move {
        let mut held = Vec::new();
        while let Some(connection) = accepted.recv().await {
            held.push(connection);
        }
    });
    let trace = Arc::new(Mutex::new(Vec::new()));
    let ms = ONE_WAY.as_millis() as u64;
    let routes = [
        Route::new("relay-a", Rng::new(1), (ms, ms), trace.clone()),
        Route::new("relay-b", Rng::new(2), (ms, ms), trace.clone()),
    ];
    let group = Arc::new(SimGroup::new(
        routes,
        Arc::new(Mutex::new(0)),
        Arc::new(Mutex::new(Some(daemon))),
        Arc::new(Mutex::new(Vec::new())),
        trace.clone(),
    ));
    let carrier: Arc<dyn LinkGroup> = Arc::new(RelayShaped {
        inner: group,
        control: tokio::sync::Mutex::new(()),
        evidence: CarrierEvidence::Relay { provider: "sim".into() },
    });
    let config = ClientConnectionConfig {
        identity: StaticIdentity::generate().expect("identity"),
        expected_daemon: Some(expected),
        auth: ClientAuthMode::Carrier,
        device_name: "lane-setup".into(),
        session: SessionId([7; 16]),
        lane_policy,
        limits: SessionLimits::default(),
        reconnect: ReconnectPolicy { full_jitter: false, ..ReconnectPolicy::default() },
    };
    let started = Instant::now();
    let client = ClientConnection::connect(carrier, config)
        .await
        .unwrap_or_else(|e| panic!("connect: {e}; trace: {:?}", trace.lock().unwrap()));
    let took = started.elapsed();
    let _ = client.close().await;
    drain.abort();
    took
}

fn paused<F: std::future::Future>(f: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .expect("runtime")
        .block_on(f)
}

/// Three lane links cost one link's open and handshake plus the two allocations that queue ahead
/// of the last one, not a second open and handshake in series after the first.
#[test]
fn pinned_lane_links_open_at_once() {
    let one = paused(connect_time(LanePolicy::Single));
    let three = paused(connect_time(LanePolicy::Auto));
    let bound = one + ALLOCATE * 2 + ONE_WAY;
    println!(
        "lane setup: one link {} ms, three lane links {} ms (bound {} ms)",
        one.as_millis(),
        three.as_millis(),
        bound.as_millis()
    );
    assert!(
        three <= bound,
        "three lane links took {} ms, one link {} ms: lanes 2 and 3 waited on lane 1 \
         (bound {} ms)",
        three.as_millis(),
        one.as_millis(),
        bound.as_millis()
    );
}
