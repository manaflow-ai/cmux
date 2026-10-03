//! The datagram service, its priority classes and path events
//! (transport.md 12a). Paused clock: durations are simulated.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_transport::{PathKind, ProbeOutcome, SelectorConfig};
use cmux_wg::testing::sim::{LinkProfile, SimNet, SimSocket, SocketProfile};
use cmux_wg::testing::{ConfigPair, config_pair};
use cmux_wg::{Multipath, Priority, SocketPath, WgError, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::watch;
use tokio::time::{Instant, timeout};

const CLIENT: &str = "192.0.2.110:51820";
const SERVER: &str = "192.0.2.111:51820";
const MEDIA_PORT: u16 = 4103;
const ONE_WAY: Duration = Duration::from_millis(10);

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

fn pair(sim: &SimNet, client_socket: SimSocket) -> (WgNet, WgNet, ConfigPair) {
    let configs = config_pair(addr(SERVER));
    let client_path = SocketPath::new(client_socket, Some(addr(SERVER)));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let client = WgNet::start_with_underlay(configs.client.clone(), client_path).unwrap();
    let server = WgNet::start_with_underlay(configs.server.clone(), server_path).unwrap();
    (client, server, configs)
}

fn plain_link(sim: &SimNet) {
    sim.set_link(addr(CLIENT), addr(SERVER), LinkProfile { latency: ONE_WAY, ..LinkProfile::default() });
}

#[tokio::test(start_paused = true)]
async fn a_datagram_round_trips_and_misdirected_ones_are_refused_or_dropped() {
    let sim = SimNet::new();
    plain_link(&sim);
    let (client, server, configs) = pair(&sim, sim.bind(addr(CLIENT)).unwrap());
    let mut ours = client.bind_datagram(MEDIA_PORT).await.unwrap();
    let mut theirs = server.bind_datagram(MEDIA_PORT).await.unwrap();
    assert!(matches!(client.bind_datagram(MEDIA_PORT).await, Err(WgError::ListenerBusy(_))));
    assert!(matches!(client.bind_datagram(4102).await, Err(WgError::ListenerBusy(_))), "probes");
    assert_eq!(client.max_datagram(), 1200 - 48);

    let peer = SocketAddr::new(configs.server_v6, MEDIA_PORT);
    let too_big = vec![0u8; client.max_datagram() + 1];
    let refused = ours.send_to(&too_big, peer, Priority::Media).await;
    assert!(matches!(refused, Err(WgError::DatagramTooLarge { .. })), "{refused:?}");

    // To a port nobody bound: dropped, and nothing else is disturbed.
    let nowhere = SocketAddr::new(configs.server_v6, 4199);
    ours.send_to(b"lost", nowhere, Priority::Media).await.unwrap();
    let largest = vec![7u8; client.max_datagram()];
    ours.send_to(&largest, peer, Priority::Media).await.unwrap();
    let (payload, from) = timeout(Duration::from_secs(5), theirs.recv_from()).await.unwrap().unwrap();
    assert_eq!(payload, largest, "the largest datagram arrives whole; the misdirected one never");
    assert_eq!(from, SocketAddr::new(configs.client_v6, MEDIA_PORT));

    theirs.send_to(b"ack", from, Priority::Interactive).await.unwrap();
    let (payload, from) = timeout(Duration::from_secs(5), ours.recv_from()).await.unwrap().unwrap();
    assert_eq!((payload.as_slice(), from), (&b"ack"[..], peer));
    client.shutdown().await;
    server.shutdown().await;
}

/// A bulk upload fills a 20,000 datagram/s bottleneck. Media datagrams
/// leave before the upload's queued segments, so they wait only for what
/// is already in the bottleneck's queue, not behind the upload's window.
#[tokio::test(start_paused = true)]
async fn a_media_datagram_overtakes_a_bulk_upload() {
    let sim = SimNet::new();
    let bottleneck =
        LinkProfile { latency: ONE_WAY, rate_pps: 20_000, queue: 64, ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), bottleneck);
    let (client, server, configs) = pair(&sim, sim.bind(addr(CLIENT)).unwrap());
    let mut ours = client.bind_datagram(MEDIA_PORT).await.unwrap();
    let mut theirs = server.bind_datagram(MEDIA_PORT).await.unwrap();

    let mut listener = server.listen(4100).await.unwrap();
    let mut upload = client.connect(SocketAddr::new(configs.server_v4, 4100)).await.unwrap();
    let mut accepted = listener.accept().await.unwrap();
    let (progress_tx, mut progress) = watch::channel(0usize);
    tokio::spawn(async move {
        let chunk = vec![1u8; 64 * 1024];
        for _ in 0..64 {
            if upload.write_all(&chunk).await.is_err() {
                break;
            }
        }
    });
    tokio::spawn(async move {
        let mut buffer = vec![0u8; 64 * 1024];
        let mut total = 0;
        while let Ok(count @ 1..) = accepted.read(&mut buffer).await {
            total += count;
            progress_tx.send_replace(total);
        }
    });
    progress.wait_for(|total| *total >= 1024 * 1024).await.unwrap();

    let peer = SocketAddr::new(configs.server_v6, MEDIA_PORT);
    let mut worst = Duration::ZERO;
    for class in [Priority::Media, Priority::Bulk] {
        let mut slowest = Duration::ZERO;
        for frame in 0..10u8 {
            let sent = Instant::now();
            ours.send_to(&[frame], peer, class).await.unwrap();
            let (payload, _) = timeout(Duration::from_secs(5), theirs.recv_from()).await.unwrap().unwrap();
            assert_eq!(payload, [frame]);
            slowest = slowest.max(sent.elapsed());
        }
        eprintln!("{class:?} datagram during the upload: slowest {slowest:?} (one way {ONE_WAY:?})");
        if class == Priority::Media {
            worst = slowest;
        }
    }
    assert!(*progress.borrow() < 4 * 1024 * 1024, "the upload was still running");
    // One way, plus what the bottleneck already queued (at most 64 packets
    // of 50 us), plus one packet time.
    assert!(worst <= ONE_WAY + Duration::from_millis(5), "media waited {worst:?}");
    client.shutdown().await;
    server.shutdown().await;
}

/// The client's socket drains 1,000 datagrams/s. A burst of 100 media
/// datagrams cannot all leave within 50 ms: the stale ones are dropped,
/// oldest first, and a datagram sent later still gets through.
#[tokio::test(start_paused = true)]
async fn stale_media_is_dropped_oldest_first() {
    let sim = SimNet::new();
    plain_link(&sim);
    let slow = SocketProfile { send_buffer: 4, rate_pps: 1_000 };
    let (client, server, configs) = pair(&sim, sim.bind_with(addr(CLIENT), slow).unwrap());
    client.wait_for_handshake(Duration::from_secs(5)).await.unwrap();
    let ours = client.bind_datagram(MEDIA_PORT).await.unwrap();
    let mut theirs = server.bind_datagram(MEDIA_PORT).await.unwrap();
    let peer = SocketAddr::new(configs.server_v6, MEDIA_PORT);

    for frame in 0..100u32 {
        ours.send_to(&frame.to_be_bytes(), peer, Priority::Media).await.unwrap();
    }
    tokio::time::sleep(Duration::from_millis(30)).await;
    ours.send_to(&1000u32.to_be_bytes(), peer, Priority::Media).await.unwrap();

    let mut received = Vec::new();
    while let Ok(Some((payload, _))) = timeout(Duration::from_millis(500), theirs.recv_from()).await {
        received.push(u32::from_be_bytes(payload.try_into().unwrap()));
    }
    eprintln!("stale media: {} of 101 delivered, last {:?}", received.len(), received.last());
    assert!(received.windows(2).all(|pair| pair[0] < pair[1]), "in order: {received:?}");
    assert_eq!(received.first(), Some(&0));
    assert!(received.len() < 101 && received.len() >= 30, "{} delivered", received.len());
    assert_eq!(received.last(), Some(&1000), "the fresh datagram is not starved by stale ones");
    client.shutdown().await;
    server.shutdown().await;
}

#[tokio::test(start_paused = true)]
async fn a_path_switch_sends_a_path_event() {
    let sim = SimNet::new();
    let configs = config_pair(addr(SERVER));
    let (underlay, control) = Multipath::new(SelectorConfig::default());
    let relay_socket = sim.bind(addr("198.51.100.10:40000")).unwrap();
    let relay = control.add_path(PathKind::DoRelay, SocketPath::new(relay_socket, Some(addr(SERVER))));
    let direct_socket = sim.bind(addr("192.168.9.1:51820")).unwrap();
    let direct =
        control.add_path(PathKind::DirectLan, SocketPath::new(direct_socket, Some(addr(SERVER))));
    let client = WgNet::start_with_underlay(configs.client, underlay).unwrap();
    let mut events = control.path_events();

    control.on_probe(relay, ProbeOutcome::Answered { rtt_us: 16_000 }).unwrap();
    let event = events.recv().await.unwrap();
    assert_eq!((event.path, event.kind), (Some(relay), Some(PathKind::DoRelay)));
    assert_eq!((event.rtt_ms, event.max_datagram), (16.0, 1152));

    control.on_probe(direct, ProbeOutcome::Answered { rtt_us: 2_000 }).unwrap();
    let event = events.recv().await.unwrap();
    assert_eq!((event.path, event.kind, event.rtt_ms), (Some(direct), Some(PathKind::DirectLan), 2.0));

    for _ in 0..3 {
        control.on_probe(direct, ProbeOutcome::Lost).unwrap();
    }
    let event = events.recv().await.unwrap();
    assert_eq!(event.path, Some(relay), "the event follows the fallback");
    client.shutdown().await;
}
