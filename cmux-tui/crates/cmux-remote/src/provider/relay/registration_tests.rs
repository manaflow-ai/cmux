//! The daemon's relay registration loop against a fake relay control socket
//! on a paused clock: when the lease renewal Pings go out, and how the
//! re-registration backoff grows and resets.
//!
//! The fake relay is real loopback TCP, and tokio's auto-advance would jump the
//! paused clock while a socket read waits. A running `spawn_blocking` task
//! turns auto-advance off, so the clock moves only on `advance`. Every check
//! that depends on the daemon having read a message waits for its answer on the
//! socket first; only timer wake-ups, which run inside the runtime, are left to
//! `settle`.

use std::sync::Mutex as StdMutex;

use tokio::net::TcpListener;
use tokio_tungstenite::WebSocketStream;

use super::tests::{accept_with_authorization, receive_test_control, send_test_control};
use super::*;
use crate::identity::AuthDatabase;
use crate::session::SessionLimits;

const LEASE_SECONDS: u32 = 30;
const STEP: Duration = Duration::from_millis(10);

type RelayStream = WebSocketStream<TcpStream>;

/// Keeps tokio's paused clock from auto-advancing until dropped.
struct ClockHold(#[allow(dead_code)] std::sync::mpsc::Sender<()>);

fn hold_clock() -> ClockHold {
    let (release, released) = std::sync::mpsc::channel::<()>();
    tokio::task::spawn_blocking(move || {
        let _ = released.recv();
    });
    ClockHold(release)
}

/// Lets tasks a timer woke run at the current instant.
async fn settle() {
    for _ in 0..64 {
        tokio::task::yield_now().await;
    }
}

async fn register(
    endpoint: Url,
    slot: &str,
    credentials: RelayCredentialSource,
) -> (RelayDaemonRegistration, tempfile::TempDir) {
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "relay-renewal", true).unwrap();
    let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
    let registration = register_relay_daemon_with_credentials(
        daemon,
        RelayDaemonConfig {
            endpoint,
            slot: slot.into(),
            ticket: String::new(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(5),
        },
        credentials,
    )
    .await
    .expect("relay registration did not become ready");
    (registration, directory)
}

/// Accepts the next control socket and answers its Register with the lease.
async fn grant(listener: &TcpListener) -> RelayStream {
    let (stream, _) = listener.accept().await.unwrap();
    let (mut socket, _) = accept_with_authorization(stream).await;
    assert!(matches!(receive_test_control(&mut socket).await, RelayControl::Register { .. }));
    send_test_control(&mut socket, &RelayControl::Registered { lease_seconds: LEASE_SECONDS })
        .await;
    socket
}

/// The renewal Pings the daemon sent before it answered two relay Pings: the
/// daemon handles one control event per turn, so a renewal already due at this
/// instant is on the socket before the second Pong.
async fn renewals(socket: &mut RelayStream) -> usize {
    let mut renewals = 0;
    for probe in [1_000, 1_001] {
        send_test_control(socket, &RelayControl::Ping { nonce: probe }).await;
        loop {
            match receive_test_control(socket).await {
                RelayControl::Pong { nonce } if nonce == probe => break,
                RelayControl::Ping { .. } => renewals += 1,
                other => panic!("unexpected daemon control {other:?}"),
            }
        }
    }
    renewals
}

/// Closes the control socket and waits until the daemon has dropped its end,
/// which it does right before it starts the backoff sleep.
async fn drop_registration(mut socket: RelayStream) -> Instant {
    socket.close(None).await.unwrap();
    while let Some(Ok(_)) = socket.next().await {}
    Instant::now()
}

/// Steps the clock until the daemon fetches a credential for its next
/// registration; the virtual time since `closed`.
async fn next_attempt(attempts: &StdMutex<Vec<Instant>>, seen: usize, closed: Instant) -> Duration {
    loop {
        settle().await;
        if let Some(at) = attempts.lock().unwrap().get(seen) {
            return at.duration_since(closed);
        }
        assert!(closed.elapsed() < Duration::from_secs(10), "the daemon did not register again");
        tokio::time::advance(STEP).await;
    }
}

#[test]
fn renewal_runs_at_half_the_granted_lease() {
    assert_eq!(registration_renewal_period(30), Duration::from_secs(15));
    assert_eq!(registration_renewal_period(0), Duration::from_millis(500));
}

#[tokio::test(start_paused = true)]
async fn registration_pings_once_per_half_lease_and_not_at_registration() {
    let _hold = hold_clock();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("relay+ws://{}", listener.local_addr().unwrap())).unwrap();
    let credentials = RelayCredentialSource::static_ticket("registration-ticket").unwrap();
    let registering = tokio::spawn(register(endpoint, "renewal-slot", credentials));
    let mut socket = grant(&listener).await;
    // The daemon arms its renewal before it reports ready.
    let (registration, _state) = registering.await.unwrap();

    assert_eq!(renewals(&mut socket).await, 0, "a Ping at registration");
    for half_lease in 1..=3 {
        tokio::time::advance(Duration::from_secs(14)).await;
        settle().await;
        assert_eq!(renewals(&mut socket).await, 0, "renewed early in half lease {half_lease}");
        tokio::time::advance(Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(
            renewals(&mut socket).await,
            1,
            "no renewal at the end of half lease {half_lease}"
        );
    }
    registration.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn reregistration_backoff_grows_and_resets_only_after_a_renewal() {
    let _hold = hold_clock();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("relay+ws://{}", listener.local_addr().unwrap())).unwrap();
    // Each registration attempt fetches a credential first, right after the
    // backoff sleep ends: the virtual instant of each fetch.
    let attempts = Arc::new(StdMutex::new(Vec::new()));
    let credentials = RelayCredentialSource::callback({
        let attempts = attempts.clone();
        move || {
            attempts.lock().unwrap().push(Instant::now());
            async { Ok::<_, ()>("registration-ticket".to_owned()) }
        }
    });
    let registering = tokio::spawn(register(endpoint, "backoff-slot", credentials));
    let mut socket = grant(&listener).await;
    let (registration, _state) = registering.await.unwrap();

    // Four registrations the relay drops before any renewal: the gap doubles.
    let mut gaps = Vec::new();
    for _ in 0..4 {
        let closed = drop_registration(socket).await;
        gaps.push(next_attempt(&attempts, gaps.len() + 1, closed).await);
        socket = grant(&listener).await;
    }
    // This one holds for a renewal before the relay drops it: the gap starts
    // again from the first step.
    assert_eq!(renewals(&mut socket).await, 0);
    tokio::time::advance(Duration::from_secs(15)).await;
    settle().await;
    assert_eq!(renewals(&mut socket).await, 1, "the held registration did not renew");
    let closed = drop_registration(socket).await;
    gaps.push(next_attempt(&attempts, gaps.len() + 1, closed).await);
    let _held = grant(&listener).await;

    // RELAY_REGISTRATION_BACKOFF: 100 ms doubling, +-20% jitter; the clock
    // moves in STEPs, so a gap reads up to one STEP late.
    for (gap, base) in gaps.iter().zip([100_u64, 200, 400, 800, 100]) {
        let earliest = Duration::from_millis(base * 8 / 10);
        let latest = Duration::from_millis(base * 12 / 10) + STEP;
        assert!(
            (earliest..=latest).contains(gap),
            "gaps {gaps:?}: expected about {base} ms, not {gap:?}"
        );
    }
    registration.shutdown().await;
}
