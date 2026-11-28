//! A relay at its WebSocket limit answers the registration's upgrade `503` with `Retry-After`.
//! The daemon's registration waits that out (with jitter) instead of retrying every 100 to
//! 300 ms, which kept the relay full so other daemons could not register. Its state reads
//! `RelayBusy`, and it registers once a slot frees.
//!
//! A real native `cmux-relay` limited to one WebSocket, held by another daemon's registration.
//!
//! `cargo test -p cmux-remote --test relay_busy_backoff_e2e`

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use cmux_relay::{Relay, RelayConfig, TicketAuthority};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    RegistrationState, RelayCredentialSource, RelayDaemonConfig, RelayIncoming,
    spawn_relay_daemon_registration,
};
use cmux_remote_protocol::{RelayPermission, RelayRole, RelayTicketClaims};
use tokio::net::TcpListener;
use url::Url;

const ISSUER: &str = "relay.busy.test";

fn ticket(authority: &TicketAuthority, slot: &str) -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    authority
        .issue(&RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: ISSUER.into(),
            permission: RelayPermission::Register,
            role: RelayRole::Daemon,
            slot: slot.into(),
            circuit: None,
            lane: None,
            generation: None,
            issued_at_unix: now,
            expires_at_unix: now + 300,
            grant: None,
            region: None,
        })
        .unwrap()
}

struct Nothing;

#[async_trait]
impl RelayIncoming for Nothing {
    async fn incoming(self: Arc<Self>, _link: Box<dyn FrameLink>) {}
}

fn register(
    address: std::net::SocketAddr,
    authority: &Arc<TicketAuthority>,
    slot: &'static str,
    asks: Arc<AtomicU64>,
) -> cmux_remote::provider::RelayDaemonRegistration {
    let authority = authority.clone();
    spawn_relay_daemon_registration(
        Arc::new(Nothing),
        RelayDaemonConfig {
            endpoint: Url::parse(&format!("relay+ws://{address}")).unwrap(),
            slot: slot.into(),
            ticket: String::new(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(5),
        },
        RelayCredentialSource::callback(move || {
            asks.fetch_add(1, Ordering::SeqCst);
            let ticket = ticket(&authority, slot);
            async move { Ok::<_, String>(ticket) }
        }),
        "busy test",
    )
    .unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_full_relay_is_not_hammered_and_the_registration_lands_once_it_frees() {
    let secret = vec![7_u8; 32];
    let authority =
        Arc::new(TicketAuthority::hmac_with_issuer(secret.clone(), ISSUER.into()).unwrap());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let relay = Relay::new(RelayConfig {
        ticket_secret: Some(secret),
        ticket_issuer: ISSUER.into(),
        max_connections: 1,
        ..RelayConfig::default()
    })
    .unwrap();
    let (listener, router) = relay.server_parts(listener);
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });

    // The one WebSocket the relay allows is taken.
    let holder = register(address, &authority, "slot-holder", Arc::new(AtomicU64::new(0)));
    let mut held = holder.state();
    tokio::time::timeout(
        Duration::from_secs(10),
        held.wait_for(|s| *s == RegistrationState::Registered),
    )
    .await
    .expect("the holder registers")
    .unwrap();

    let asks = Arc::new(AtomicU64::new(0));
    let late = register(address, &authority, "slot-late", asks.clone());
    let mut state = late.state();
    let started = Instant::now();
    let busy = tokio::time::timeout(
        Duration::from_secs(10),
        state.wait_for(|s| matches!(s, RegistrationState::RelayBusy { .. })),
    )
    .await
    .expect("the refused registration reads busy")
    .unwrap()
    .clone();
    assert!(
        matches!(busy, RegistrationState::RelayBusy { retry_after: Some(wait), .. } if wait == Duration::from_secs(1)),
        "{busy:?}"
    );

    // Each wait is at least the relay's 1 s, so 4 s holds at most 5 asks (before: about 7 at a
    // middle draw, and any number at a low one).
    tokio::time::sleep(Duration::from_secs(4).saturating_sub(started.elapsed())).await;
    let seen = asks.load(Ordering::SeqCst);
    eprintln!(
        "relay-503 after: {seen} asks in {} ms against a full relay",
        started.elapsed().as_millis()
    );
    assert!(seen <= 5, "{seen} asks in 4 s against a relay that said Retry-After: 1");
    assert!(seen >= 2, "the registration must keep asking: {seen}");

    // A slot frees: the late daemon registers within one wait.
    drop(holder);
    let freed = Instant::now();
    tokio::time::timeout(
        Duration::from_secs(20),
        state.wait_for(|s| *s == RegistrationState::Registered),
    )
    .await
    .expect("registers once the relay has room")
    .unwrap();
    eprintln!(
        "relay-503 after: registered {} ms after the slot freed",
        freed.elapsed().as_millis()
    );
}
