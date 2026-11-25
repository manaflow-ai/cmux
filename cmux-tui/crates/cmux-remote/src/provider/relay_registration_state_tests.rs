//! A registration's reported state through a mint outage and a clock jump past its ticket
//! (split out of `relay_tests.rs`).

use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

use tokio::net::TcpListener;

use super::tests::{accept_with_authorization, receive_test_control, send_test_control};
use super::*;

/// A signed Register ticket (`v2.<claims>.signature`) issued at `issued` (unix seconds) that
/// lives `seconds`: the daemon reads only its lifetime; this relay reads its expiry.
fn signed_ticket(issued: u64, seconds: u64) -> String {
    use base64::Engine as _;
    let claims = serde_json::json!({
        "version": 2,
        "issuer": "relay.test",
        "permission": "register",
        "role": "daemon",
        "slot": "clock-jump-slot",
        "circuit": null,
        "lane": null,
        "generation": null,
        "issued_at_unix": issued,
        "expires_at_unix": issued + seconds,
    });
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(serde_json::to_vec(&claims).unwrap());
    format!("v2.{payload}.signature")
}

fn ticket_expiry(ticket: &str) -> u64 {
    use base64::Engine as _;
    let claims = ticket.split('.').nth(1).unwrap();
    let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(claims).unwrap();
    let claims: serde_json::Value = serde_json::from_slice(&claims).unwrap();
    claims["expires_at_unix"].as_u64().unwrap()
}

/// This thread's wall clock in unix seconds (`test_wall`'s lead included): the true time on a
/// machine that resumed, which the mint and the relay also read.
fn unix_wall() -> u64 {
    wall_now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

/// Fault F21 (design `remote-cloud-durability.md`): `clock-jump` 2 h plus `ticket-expire`. A
/// paused VM resumes with its wall clock 2 h ahead and its monotonic clock where it stopped;
/// the relay retired the registration long ago (its socket is silent, not closed) and the
/// ticket in hand expired by the relay's clock. The registration registers again exactly once,
/// with a fresh ticket the relay takes, and then stays: no storm of Registers, no expired
/// ticket sent.
#[tokio::test(flavor = "current_thread")]
async fn a_two_hour_clock_jump_past_the_tickets_expiry_registers_again_exactly_once() {
    use crate::identity::AuthDatabase;
    use crate::session::SessionLimits;

    const TICKET_SECONDS: u64 = 60;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let registers = Arc::new(AtomicUsize::new(0));
    let expired_sent = Arc::new(AtomicUsize::new(0));
    let frozen = Arc::new(AtomicBool::new(false));
    // The relay: each socket Registers (refused when its ticket expired by the relay's
    // clock, the shared wall clock), then answers pings until the pause freezes it.
    let relay = tokio::spawn({
        let registers = registers.clone();
        let expired_sent = expired_sent.clone();
        let frozen = frozen.clone();
        async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let (mut socket, _) = accept_with_authorization(stream).await;
                let RelayControl::Register { ticket, .. } = receive_test_control(&mut socket).await
                else {
                    panic!("the daemon's first control was not a Register");
                };
                registers.fetch_add(1, AtomicOrdering::SeqCst);
                if ticket_expiry(&ticket) <= unix_wall() {
                    expired_sent.fetch_add(1, AtomicOrdering::SeqCst);
                    let error = RelayControl::Error {
                        code: "ticket-expired".into(),
                        message: "ticket expired".into(),
                        retryable: false,
                    };
                    send_test_control(&mut socket, &error).await;
                    continue;
                }
                send_test_control(&mut socket, &RelayControl::Registered { lease_seconds: 30 })
                    .await;
                let frozen = frozen.clone();
                tokio::spawn(async move {
                    while let Some(Ok(message)) = socket.next().await {
                        if frozen.load(AtomicOrdering::SeqCst) {
                            // Retired during the pause: the socket stays open and silent.
                            std::future::pending::<()>().await;
                        }
                        if let Message::Text(text) = message
                            && let Ok(RelayControl::Ping { nonce }) = serde_json::from_str(&text)
                        {
                            send_test_control(&mut socket, &RelayControl::Pong { nonce }).await;
                        }
                    }
                });
            }
        }
    });
    let minted = Arc::new(AtomicUsize::new(0));
    let credentials = RelayCredentialSource::callback({
        let minted = minted.clone();
        move || {
            minted.fetch_add(1, AtomicOrdering::SeqCst);
            let ticket = signed_ticket(unix_wall(), TICKET_SECONDS);
            async move { Ok::<_, ()>(ticket) }
        }
    });
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "relay-clock-jump", true).unwrap();
    let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
    let registration = register_relay_daemon_with_credentials(
        daemon,
        RelayDaemonConfig {
            endpoint: Url::parse(&format!("relay+ws://{address}")).unwrap(),
            slot: "clock-jump-slot".into(),
            ticket: String::new(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(2),
        },
        credentials,
    )
    .await
    .unwrap();
    assert_eq!(registers.load(AtomicOrdering::SeqCst), 1);

    // The pause: the relay retires the registration, and the machine resumes 2 h later by the
    // wall clock, past the ticket's expiry; the monotonic clock did not move.
    frozen.store(true, AtomicOrdering::SeqCst);
    test_wall::jump(Duration::from_secs(2 * 3_600));
    tokio::time::timeout(Duration::from_secs(5), async {
        while registers.load(AtomicOrdering::SeqCst) < 2 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the registration did not register again after the jump");
    frozen.store(false, AtomicOrdering::SeqCst);
    // A storm shows within a few check intervals; none comes.
    tokio::time::sleep(Duration::from_secs(4)).await;
    assert_eq!(
        (registers.load(AtomicOrdering::SeqCst), expired_sent.load(AtomicOrdering::SeqCst)),
        (2, 0),
        "Registers after the jump (and with an expired ticket), {} tickets minted",
        minted.load(AtomicOrdering::SeqCst)
    );
    tokio::time::timeout(Duration::from_secs(2), registration.shutdown()).await.unwrap();
    relay.abort();
}

/// Fault `mint-stall`: a ticket mint that never answers holds no registration in
/// `Registering` forever. The fetch fails at [`CREDENTIAL_CALLBACK_TIMEOUT`] as a credential
/// source failure, and the registration reads `credential-unavailable`.
#[tokio::test(start_paused = true)]
async fn a_stalled_mint_is_credential_unavailable_after_its_bound() {
    use crate::identity::AuthDatabase;
    use crate::session::SessionLimits;

    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "relay-mint-stall", true).unwrap();
    let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
    let registration = spawn_relay_daemon_registration(
        daemon,
        RelayDaemonConfig {
            endpoint: Url::parse("relay+ws://127.0.0.1:9").unwrap(),
            slot: "mint-stall-slot".into(),
            ticket: String::new(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(1),
        },
        RelayCredentialSource::callback(std::future::pending::<Result<String, ()>>),
        "test",
    )
    .unwrap();
    let mut state = registration.state();
    let started = Instant::now();
    let unavailable =
        state.wait_for(|s| s.reason().is_some()).await.expect("the registration ended").clone();
    assert_eq!(started.elapsed(), CREDENTIAL_CALLBACK_TIMEOUT);
    assert!(
        matches!(&unavailable, RegistrationState::CredentialUnavailable { error }
            if error.contains("callback timed out")),
        "{unavailable:?}"
    );
    registration.shutdown().await;
}
