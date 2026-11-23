//! Fault F2 (design `remote-cloud-durability.md`): the ticket mint goes down, then the
//! registration's ticket expires. Before, the registration retried forever and said so only on
//! stderr; nothing a status line or a peer's `reason` could read told "the mint is down" apart
//! from "still connecting". Now its state reads `credential-unavailable` within one renewal of
//! the expiry, and goes back to registered once the mint answers again.
//!
//! The faults, in the style `cmux-fault` adopts (`mint-down`, `ticket-expire`): a real native
//! `cmux-relay` with signed Register tickets that live [`TICKET_SECONDS`], a mint (the
//! registration's credential callback) that answers once and then fails, and later answers
//! again. A stalled mint (one that never answers) is the same state, bounded by
//! `CREDENTIAL_CALLBACK_TIMEOUT`; `relay_tests.rs` checks that bound on a paused clock.
//!
//! `cargo test -p cmux-remote --test relay_mint_down_e2e`

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use cmux_relay::{Relay, RelayConfig, TicketAuthority};
use cmux_remote::link::FrameLink;
use cmux_remote::provider::{
    RegistrationState, RelayCredentialSource, RelayDaemonConfig, RelayIncoming,
    spawn_relay_daemon_registration,
};
use cmux_remote_protocol::{RelayPermission, RelayRole, RelayTicketClaims};
use tokio::net::TcpListener;
use tokio::sync::watch;
use url::Url;

const ISSUER: &str = "relay.mint-down.test";
const SLOT: &str = "slot-mint-down";
/// The Register ticket's lifetime: the registration renews at 2/3 of it, and the relay ends the
/// registration about a second (its sweep) after it.
const TICKET_SECONDS: u64 = 3;

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs()
}

fn ticket(authority: &TicketAuthority) -> String {
    let now = unix_now();
    authority
        .issue(&RelayTicketClaims {
            version: RelayTicketClaims::VERSION,
            issuer: ISSUER.into(),
            permission: RelayPermission::Register,
            role: RelayRole::Daemon,
            slot: SLOT.into(),
            circuit: None,
            lane: None,
            generation: None,
            issued_at_unix: now,
            expires_at_unix: now + TICKET_SECONDS,
        })
        .unwrap()
}

struct Nothing;

#[async_trait]
impl RelayIncoming for Nothing {
    async fn incoming(self: Arc<Self>, _link: Box<dyn FrameLink>) {}
}

/// Waits until `state` satisfies `want`, at most `bound`: the state found, or what it was instead.
async fn wait_for(
    state: &mut watch::Receiver<RegistrationState>,
    bound: Duration,
    want: impl Fn(&RegistrationState) -> bool,
) -> Result<RegistrationState, String> {
    let found = tokio::time::timeout(bound, async {
        state.wait_for(|s| want(s)).await.map(|found| found.clone())
    })
    .await;
    match found {
        Ok(Ok(found)) => Ok(found),
        Ok(Err(_)) => Err("the registration ended".into()),
        Err(_) => Err(format!("still {:?} after {bound:?}", *state.borrow())),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_mint_outage_past_the_ticket_reads_credential_unavailable_within_one_renewal() {
    let secret = vec![9_u8; 32];
    let authority =
        Arc::new(TicketAuthority::hmac_with_issuer(secret.clone(), ISSUER.into()).unwrap());
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let relay = Relay::new(RelayConfig {
        ticket_secret: Some(secret),
        ticket_issuer: ISSUER.into(),
        ..RelayConfig::default()
    })
    .unwrap();
    let cleanup = relay.spawn_cleanup();
    let (listener, router) = relay.server_parts(listener);
    let relay_task = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });

    let mint_up = Arc::new(AtomicBool::new(true));
    let minted = Arc::new(AtomicU64::new(0));
    let registration = spawn_relay_daemon_registration(
        Arc::new(Nothing),
        RelayDaemonConfig {
            endpoint: Url::parse(&format!("relay+ws://{address}")).unwrap(),
            slot: SLOT.into(),
            ticket: String::new(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(5),
        },
        RelayCredentialSource::callback({
            let authority = authority.clone();
            let mint_up = mint_up.clone();
            let minted = minted.clone();
            move || {
                let answer = if mint_up.load(Ordering::SeqCst) {
                    minted.fetch_add(1, Ordering::SeqCst);
                    Ok(ticket(&authority))
                } else {
                    Err(())
                };
                async move { answer }
            }
        }),
        "mint-down test",
    )
    .unwrap();
    let mut state = registration.state();

    wait_for(&mut state, Duration::from_secs(10), |s| *s == RegistrationState::Registered)
        .await
        .expect("the registration never registered");
    // mint-down: every ticket asked for from now on is refused, the renewal at 2/3 included.
    mint_up.store(false, Ordering::SeqCst);
    // ticket-expire: the relay ends the registration about a second after the ticket expires.
    // Within one renewal period after that the state names the reason (here, at once: the
    // next attempt's fetch fails).
    let renewal = Duration::from_secs(TICKET_SECONDS * 2 / 3);
    let bound = Duration::from_secs(TICKET_SECONDS + 1) + renewal + Duration::from_secs(2);
    let unavailable = wait_for(&mut state, bound, |s| s.reason().is_some())
        .await
        .expect("a mint outage past the ticket's expiry never read credential-unavailable");
    assert!(
        matches!(&unavailable, RegistrationState::CredentialUnavailable { error }
            if error.contains("relay credential source")),
        "{unavailable:?}"
    );
    assert_eq!(unavailable.reason(), Some("credential-unavailable"));

    // The mint comes back: retrying went on behind the reason, and the registration returns
    // (the credential backoff is capped at 60 s; its first waits are a second or two).
    mint_up.store(true, Ordering::SeqCst);
    let before = minted.load(Ordering::SeqCst);
    wait_for(&mut state, Duration::from_secs(20), |s| *s == RegistrationState::Registered)
        .await
        .expect("the registration did not come back once the mint answered");
    assert!(minted.load(Ordering::SeqCst) > before);

    registration.shutdown().await;
    cleanup.abort();
    relay_task.abort();
}
