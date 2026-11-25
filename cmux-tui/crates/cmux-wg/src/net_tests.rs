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
        None,
        receiver,
        Arc::new(Notify::new()),
    )
    .unwrap();
    let (reply, pending) = oneshot::channel();
    driver.connect_now(SocketAddr::new(pair.server_v6, 1337), reply);
    assert_eq!(driver.stack.conns.len(), 1);
    assert_eq!(driver.stack.sockets.iter().count(), 1);

    drop(pending);
    driver.stack.process_conns();

    assert!(driver.stack.conns.is_empty(), "a cancelled dial must not wait for TCP_TIMEOUT");
    assert_eq!(driver.stack.sockets.iter().count(), 0);

    // With no session yet the dial waits for one, holding no socket; cancelled,
    // it leaves at the next pass.
    let (reply, pending) = oneshot::channel();
    driver.begin_connect(SocketAddr::new(pair.server_v6, 1337), reply);
    assert_eq!(driver.held_connects.len(), 1, "a dial with no session waits for one");
    assert_eq!(driver.stack.sockets.iter().count(), 0);
    drop(pending);
    driver.release_held_connects();
    assert!(driver.held_connects.is_empty(), "a cancelled held dial must not wait for a session");
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
        None,
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

/// Both peers of a hybrid dial initiate at once, and every handshake message
/// arrives on each candidate path: past the 10 a second limit the peer
/// answers with a cookie. A handshake carrying that cookie goes out at once,
/// and the peer, still under load, answers it, instead of the session (and
/// the stream dial queued on it) waiting out boringtun's 5 s retry.
#[tokio::test]
async fn a_cookie_reply_sends_a_handshake_that_carries_it_at_once() {
    use boringtun::noise::rate_limiter::RateLimiter;

    let pair = crate::testing::loopback_pair().await.unwrap();
    let server = pair.server_socket.local_addr().unwrap();
    let client = pair.client_socket.local_addr().unwrap();
    let origin = Origin { path: cmux_transport::PathId(0), addr: Some(server) };
    let server_private = StaticSecret::from(*pair.server.private_key);
    let server_public = PublicKey::from(&server_private);
    let client_public = PublicKey::from(pair.server.peer_public_key);
    let (_commands, receiver) = mpsc::channel(COMMAND_DEPTH);
    let underlay = SocketPath::new(pair.client_socket, Some(server));
    let mut driver = Driver::new(
        pair.client,
        UltraUnderlay::new(Box::new(underlay), UltraMode::Off, Arc::default()),
        Negotiation::new(UltraMode::Off),
        None,
        receiver,
        Arc::new(Notify::new()),
    )
    .unwrap();
    // A server past its handshake rate: every handshake without a valid
    // MAC2 gets a cookie.
    let under_load = Arc::new(RateLimiter::new(&server_public, 0));
    let mut peer = Tunn::new(server_private, client_public, None, None, 1, Some(under_load));

    driver.initiate_handshake();
    std::future::poll_fn(|cx| driver.underlay.poll_flush(cx)).await;
    let mut datagram = [0u8; 2048];
    let mut scratch = [0u8; 2048];
    let receive = async |datagram: &mut [u8]| {
        tokio::time::timeout(Duration::from_millis(500), pair.server_socket.recv(datagram))
            .await
            .ok()
            .map(Result::unwrap)
    };
    let len = receive(&mut datagram).await.expect("no first initiation");
    let cookie = match peer.decapsulate(Some(client.ip()), &datagram[..len], &mut scratch) {
        TunnResult::WriteToNetwork(packet) => packet.to_vec(),
        other => panic!("the loaded peer did not challenge: {other:?}"),
    };
    assert_eq!(classify(&cookie), DatagramClass::WireGuardCookieReply);

    driver.handle_datagram(&cookie, origin);
    std::future::poll_fn(|cx| driver.underlay.poll_flush(cx)).await;
    let len = receive(&mut datagram)
        .await
        .expect("the cookie reply left the handshake to boringtun's 5 s retry");
    assert_eq!(classify(&datagram[..len]), DatagramClass::WireGuardInitiation);
    match peer.decapsulate(Some(client.ip()), &datagram[..len], &mut scratch) {
        TunnResult::WriteToNetwork(packet) => {
            assert_eq!(classify(packet), DatagramClass::WireGuardResponse, "challenged again");
        }
        other => panic!("the retry was not answered: {other:?}"),
    }
}

fn loopback_driver(config: WgConfig, socket: UdpSocket, peer: SocketAddr) -> Driver {
    let (_commands, receiver) = mpsc::channel(COMMAND_DEPTH);
    let underlay = SocketPath::new(socket, Some(peer));
    Driver::new(
        config,
        UltraUnderlay::new(Box::new(underlay), UltraMode::Off, Arc::default()),
        Negotiation::new(UltraMode::Off),
        None,
        receiver,
        Arc::new(Notify::new()),
    )
    .unwrap()
}

/// A driver's loop by hand: every datagram already waiting, each followed
/// (as in `Driver::run`) by a pass that lets the stack and the pacer send.
/// Returns how many handshake initiations arrived.
async fn pump(driver: &mut Driver) -> usize {
    let mut initiations = 0;
    let mut buffer = vec![0u8; BUFFER_BYTES];
    loop {
        let recv = std::future::poll_fn(|cx| driver.underlay.poll_recv(cx, &mut buffer));
        match tokio::time::timeout(Duration::from_millis(5), recv).await {
            Ok(Ok(received)) => {
                let datagram = buffer[..received.len].to_vec();
                initiations +=
                    usize::from(classify(&datagram) == DatagramClass::WireGuardInitiation);
                driver.handle_datagram(&datagram, received.origin);
            }
            Ok(Err(error)) => panic!("receive failed: {error}"),
            Err(_) => break,
        }
        send(driver).await;
    }
    initiations
}

/// A pass, then what it queued onto the wire. A fresh socket refuses
/// `try_send_to` until its readiness is polled, which `Driver::run` does.
async fn send(driver: &mut Driver) {
    driver.underlay.flush();
    driver.service();
    driver.underlay.flush();
    let flushed = std::future::poll_fn(|cx| driver.underlay.poll_flush(cx));
    tokio::time::timeout(Duration::from_secs(1), flushed).await.expect("the socket never drained");
}

/// Both peers have data queued before any session, so both initiate and the
/// initiations cross. Each answers the other's; neither may then start a new
/// initiation, which would make boringtun drop the state that the peer's
/// response to its first one needs (both replies rejected as UnexpectedPacket,
/// over and over, until the 20 s dial timeout).
#[tokio::test]
async fn crossed_initiations_with_queued_data_bring_up_a_session() {
    let pair = crate::testing::loopback_pair().await.unwrap();
    let client_addr = pair.client_socket.local_addr().unwrap();
    let server_addr = pair.server_socket.local_addr().unwrap();
    let mut client = loopback_driver(pair.client, pair.client_socket, server_addr);
    let mut server = loopback_driver(pair.server, pair.server_socket, client_addr);

    // Each side listens and dials the other: each dial waits for a session.
    let mut client_incoming = client.stack.begin_listen(2001).unwrap();
    let mut server_incoming = server.stack.begin_listen(2002).unwrap();
    let (client_reply, mut client_dial) = oneshot::channel();
    let (server_reply, mut server_dial) = oneshot::channel();
    client.begin_connect(SocketAddr::new(pair.server_v4, 2002), client_reply);
    server.begin_connect(SocketAddr::new(pair.client_v4, 2001), server_reply);
    // Both initiate before either hears the other, as each driver does at start.
    for driver in [&mut client, &mut server] {
        driver.initiate_handshake();
        send(driver).await;
    }
    assert!(
        !client.held_connects.is_empty() && !server.held_connects.is_empty(),
        "no dial waits for a session"
    );

    // Well inside REKEY_TIMEOUT (5 s): no retry timer may be what rescues it.
    let deadline = Instant::now() + Duration::from_secs(3);
    let (mut client_dialed, mut server_dialed) = (false, false);
    let (mut client_accepted, mut server_accepted) = (false, false);
    let (mut client_initiations, mut server_initiations) = (0, 0);
    while !(client_dialed && server_dialed && client_accepted && server_accepted) {
        assert!(
            Instant::now() < deadline,
            "no session within 3 s: client handshake {:?}, server handshake {:?}",
            client.tunn.time_since_last_handshake(),
            server.tunn.time_since_last_handshake(),
        );
        client_initiations += pump(&mut client).await;
        server_initiations += pump(&mut server).await;
        if let Ok(dialed) = client_dial.try_recv() {
            dialed.unwrap();
            client_dialed = true;
        }
        if let Ok(dialed) = server_dial.try_recv() {
            dialed.unwrap();
            server_dialed = true;
        }
        client_accepted |= client_incoming.try_recv().is_ok();
        server_accepted |= server_incoming.try_recv().is_ok();
    }
    // Each side's SYN, SYN-ACK and ACK crossed the tunnel: data flowed both ways.
    assert!(client.tunn.time_since_last_handshake().is_some());
    assert!(server.tunn.time_since_last_handshake().is_some());
    // The first crossed pair is what completes: a fresh initiation in
    // between would leave both responses unexpected, costing another round.
    assert_eq!((client_initiations, server_initiations), (1, 1), "initiations each side answered");
}

/// Data with the given receiver index, as a WireGuard data message.
fn data_to(index: u32) -> Vec<u8> {
    let mut message = vec![0u8; 32];
    message[0] = 4;
    message[4..8].copy_from_slice(&index.to_le_bytes());
    message
}

#[test]
fn responder_sample_waits_for_data_on_the_answered_session() {
    let answered = Instant::now() - Duration::from_millis(400);
    let mut responded_at = Some((answered, 7));
    let mut handshake_rtt = None;
    // Data on the session the peer initiated (crossed handshakes) is not
    // an answer to this side's response.
    note_answered(&data_to(9), &mut responded_at, &mut handshake_rtt);
    assert_eq!(handshake_rtt, None, "sampled data on another session");
    assert!(responded_at.is_some(), "dropped the pending sample");
    note_answered(&data_to(7), &mut responded_at, &mut handshake_rtt);
    assert!(
        handshake_rtt.is_some_and(|rtt| rtt >= Duration::from_millis(400)),
        "answered session's data gave {handshake_rtt:?}"
    );
    assert!(responded_at.is_none());
}
