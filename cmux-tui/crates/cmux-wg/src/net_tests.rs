//! Unit tests of the driver internals in `net.rs`.

use super::*;

#[tokio::test]
async fn cancelled_hub_dial_releases_the_pending_tcp_socket() {
    let pair = crate::testing::loopback_pair().await.unwrap();
    let (_commands, receiver) = mpsc::channel(COMMAND_DEPTH);
    let underlay =
        SocketPath::new(pair.client_socket, Some(pair.server_socket.local_addr().unwrap()));
    let mut driver = Driver::new(
        pair.client,
        UltraUnderlay::new(Box::new(underlay), UltraMode::Off, Arc::default()),
        Negotiation::new(UltraMode::Off),
        receiver,
        Arc::new(Notify::new()),
    )
    .unwrap();
    let (reply, pending) = oneshot::channel();
    driver.begin_connect(SocketAddr::new(pair.server_v6, 1337), reply);
    assert_eq!(driver.stack.conns.len(), 1);
    assert_eq!(driver.stack.sockets.iter().count(), 1);

    drop(pending);
    driver.stack.process_conns();

    assert!(driver.stack.conns.is_empty(), "a cancelled dial must not wait for TCP_TIMEOUT");
    assert_eq!(driver.stack.sockets.iter().count(), 0);
}

/// Past this side's handshake rate its session answers a handshake with a
/// cookie challenge, which checked only the MAC1: no session begins, so a
/// watchdog armed by unanswered data stays armed.
#[tokio::test]
async fn a_cookie_challenge_leaves_the_watchdog_armed() {
    let pair = crate::testing::loopback_pair().await.unwrap();
    let server = pair.server_socket.local_addr().unwrap();
    let origin = Origin { path: cmux_transport::PathId(0), addr: Some(server) };
    let server_private = *pair.server.private_key;
    let client_public = pair.server.peer_public_key;
    let (_commands, receiver) = mpsc::channel(COMMAND_DEPTH);
    let underlay = SocketPath::new(pair.client_socket, Some(server));
    let mut driver = Driver::new(
        pair.client,
        UltraUnderlay::new(Box::new(underlay), UltraMode::Off, Arc::default()),
        Negotiation::new(UltraMode::Off),
        receiver,
        Arc::new(Notify::new()),
    )
    .unwrap();
    // A fresh initiation from the server's key each time (a newer timestamp).
    let initiation = || {
        let mut tunn = Tunn::new(
            StaticSecret::from(server_private),
            PublicKey::from(client_public),
            None,
            None,
            1,
            None,
        );
        let mut buffer = [0u8; 256];
        match tunn.format_handshake_initiation(&mut buffer, false) {
            TunnResult::WriteToNetwork(packet) => packet.to_vec(),
            other => panic!("no initiation: {other:?}"),
        }
    };
    // The first is answered; it and its replays spend the session's handshake
    // rate (10 a second).
    let first = initiation();
    for _ in 0..12 {
        driver.handle_datagram(&first, origin);
    }
    driver.watchdog.on_data_sent(Instant::now(), &[0x45]);
    assert!(driver.watchdog.deadline(None).is_some(), "unanswered data did not arm the watchdog");
    // A newer one would begin a session; under load it is only challenged.
    driver.handle_datagram(&initiation(), origin);
    assert!(driver.watchdog.deadline(None).is_some(), "a cookie challenge began a session");
}
