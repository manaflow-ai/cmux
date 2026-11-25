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

/// A carrier that keeps what the driver sends, for the test to deliver.
struct Outbox(Arc<std::sync::Mutex<Vec<Vec<u8>>>>);

impl Underlay for Outbox {
    fn send(&mut self, datagram: &[u8]) {
        self.0.lock().unwrap().push(datagram.to_vec());
    }

    fn poll_recv(
        &mut self,
        _cx: &mut std::task::Context<'_>,
        _buffer: &mut [u8],
    ) -> Poll<io::Result<crate::underlay::Received>> {
        Poll::Pending
    }

    fn has_peer(&self) -> bool {
        true
    }
}

type Sent = Arc<std::sync::Mutex<Vec<Vec<u8>>>>;

fn outbox_driver(config: WgConfig) -> (Driver, Sent) {
    let sent = Sent::default();
    let (_commands, receiver) = mpsc::channel(COMMAND_DEPTH);
    let underlay =
        UltraUnderlay::new(Box::new(Outbox(Arc::clone(&sent))), UltraMode::Off, Arc::default());
    let driver = Driver::new(
        config,
        underlay,
        Negotiation::new(UltraMode::Off),
        None,
        receiver,
        Arc::new(Notify::new()),
    )
    .unwrap();
    (driver, sent)
}

fn take(sent: &Sent) -> Vec<Vec<u8>> {
    std::mem::take(&mut *sent.lock().unwrap())
}

fn initiations(datagrams: &[Vec<u8>]) -> usize {
    datagrams.iter().filter(|d| classify(d) == DatagramClass::WireGuardInitiation).count()
}

/// The datagrams arrive, then the pass the run loop makes after every event.
fn deliver(driver: &mut Driver, datagrams: &[Vec<u8>], from: SocketAddr) {
    let origin = Origin { path: cmux_transport::PathId(0), addr: Some(from) };
    for datagram in datagrams {
        driver.handle_datagram(datagram, origin);
    }
    driver.underlay.flush();
    driver.service();
    driver.underlay.flush();
}

/// Both ends initiate at once with data waiting for a session, and each
/// answers the other's initiation. boringtun keeps this side's initiation
/// (as `previous`) for the answer on its way; a new one from the pacer's
/// path right after answering replaces it, the peer's answer is refused
/// (`UnexpectedPacket`), and the two trade handshakes forever.
#[tokio::test(start_paused = true)]
async fn crossing_initiations_with_data_waiting_both_complete() {
    let pair = crate::testing::config_pair("127.0.0.1:9".parse().unwrap());
    let a_addr: SocketAddr = "127.0.0.1:1001".parse().unwrap();
    let b_addr: SocketAddr = "127.0.0.1:1002".parse().unwrap();
    let (mut a, a_sent) = outbox_driver(pair.client);
    let (mut b, b_sent) = outbox_driver(pair.server);
    // Data waiting on both sides: a TCP dial each way.
    let (a_reply, _a_pending) = oneshot::channel();
    a.begin_connect(SocketAddr::new(pair.server_v4, 7000), a_reply);
    let (b_reply, _b_pending) = oneshot::channel();
    b.begin_connect(SocketAddr::new(pair.client_v4, 7001), b_reply);
    // Each pass queues the SYN and, with no session, initiates: they cross.
    deliver(&mut a, &[], b_addr);
    deliver(&mut b, &[], a_addr);
    assert!(a.pacer.has_queued() && b.pacer.has_queued(), "no data waits for a session");
    let (a_init, b_init) = (take(&a_sent), take(&b_sent));
    assert_eq!((initiations(&a_init), initiations(&b_init)), (1, 1));

    // Each answers the other's initiation.
    deliver(&mut a, &b_init, b_addr);
    deliver(&mut b, &a_init, a_addr);
    let (a_out, b_out) = (take(&a_sent), take(&b_sent));
    assert_eq!(
        (initiations(&a_out), initiations(&b_out)),
        (0, 0),
        "an end replaced the initiation its peer is answering"
    );

    // Each answer reaches the initiation it answers.
    deliver(&mut a, &b_out, b_addr);
    deliver(&mut b, &a_out, a_addr);
    assert!(a.tunn.time_since_last_handshake().is_some(), "the dialing end has no session");
    assert!(b.tunn.time_since_last_handshake().is_some(), "the answering end has no session");
}

/// The hold after answering ends: with the answer lost and data waiting, the
/// next pass past the hold (`wait_for_handshake_until`, one REKEY_TIMEOUT)
/// initiates from this side.
#[tokio::test(start_paused = true)]
async fn a_lost_answer_is_retried_from_this_side_after_the_hold() {
    let pair = crate::testing::config_pair("127.0.0.1:9".parse().unwrap());
    let peer_addr: SocketAddr = "127.0.0.1:1002".parse().unwrap();
    let server_private = *pair.server.private_key;
    let client_public = pair.server.peer_public_key;
    let (mut a, a_sent) = outbox_driver(pair.client);
    let (reply, _pending) = oneshot::channel();
    a.begin_connect(SocketAddr::new(pair.server_v4, 7000), reply);
    deliver(&mut a, &[], peer_addr);
    assert_eq!(initiations(&take(&a_sent)), 1);
    let mut peer = Tunn::new(
        StaticSecret::from(server_private),
        PublicKey::from(client_public),
        None,
        None,
        1,
        None,
    );
    let mut buffer = [0u8; 256];
    let initiation = match peer.format_handshake_initiation(&mut buffer, false) {
        TunnResult::WriteToNetwork(packet) => packet.to_vec(),
        other => panic!("no initiation: {other:?}"),
    };
    deliver(&mut a, &[initiation], peer_addr);
    // The answer left (and is lost); no initiation of its own yet.
    assert_eq!(initiations(&take(&a_sent)), 0);
    let hold = a.wait_for_handshake_until.expect("answering holds the pacer's initiation");
    tokio::time::advance(hold.saturating_duration_since(Instant::now()) - Duration::from_millis(1))
        .await;
    deliver(&mut a, &[], peer_addr);
    assert_eq!(initiations(&take(&a_sent)), 0, "initiated inside the hold");
    tokio::time::advance(Duration::from_millis(1)).await;
    deliver(&mut a, &[], peer_addr);
    assert_eq!(initiations(&take(&a_sent)), 1, "nothing retried the lost answer");
    assert!(a.tunn.time_since_last_handshake().is_none());
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

    // Each side listens and dials the other: a SYN waits in each pacer.
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
    assert!(client.pacer.has_queued() && server.pacer.has_queued(), "no data was queued");

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
