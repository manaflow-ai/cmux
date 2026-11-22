//! Where the backlog of a saturated uplink waits (transport.md 12a, fs
//! round 5). The driver can reorder only what it still holds: a datagram it
//! handed to the kernel waits behind everything the socket buffer already
//! holds. With a small socket buffer, `WouldBlock` is backpressure: the
//! datagram stays queued, the driver waits for writability, and the backlog
//! forms in the driver's priority queues, where media overtakes bulk.
//! Paused clock: durations are simulated.

use std::net::SocketAddr;
use std::time::Duration;

use cmux_wg::testing::config_pair;
use cmux_wg::testing::sim::{LinkProfile, SimNet, SocketProfile};
use cmux_wg::{Priority, SocketPath, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::watch;
use tokio::time::{Instant, timeout};

const CLIENT: &str = "192.0.2.120:51820";
const SERVER: &str = "192.0.2.121:51820";
const MEDIA_PORT: u16 = 4103;
const ONE_WAY: Duration = Duration::from_millis(10);
/// The uplink: the client's socket drains 2,000 datagrams/s (about 20 Mbit/s
/// of full-size datagrams).
const UPLINK_PPS: u32 = 2_000;
const FRAMES: u32 = 20;

fn addr(text: &str) -> SocketAddr {
    text.parse().expect("literal address")
}

/// The slowest of `FRAMES` media datagrams sent every 10 ms during a bulk
/// upload, when the client's socket holds `send_buffer` datagrams. Every
/// frame must arrive, in order, and none may be dropped for age.
async fn slowest_media_during_upload(send_buffer: u32) -> Duration {
    let sim = SimNet::new();
    let link = LinkProfile { latency: ONE_WAY, ..LinkProfile::default() };
    sim.set_link(addr(CLIENT), addr(SERVER), link);
    let configs = config_pair(addr(SERVER));
    let uplink = SocketProfile { send_buffer, rate_pps: UPLINK_PPS };
    let client_socket = sim.bind_with(addr(CLIENT), uplink).unwrap();
    let client_path = SocketPath::new(client_socket, Some(addr(SERVER)));
    let server_path = SocketPath::new(sim.bind(addr(SERVER)).unwrap(), None);
    let client = WgNet::start_with_underlay(configs.client.clone(), client_path).unwrap();
    let server = WgNet::start_with_underlay(configs.server.clone(), server_path).unwrap();
    let ours = client.bind_datagram(MEDIA_PORT).await.unwrap();
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
    progress.wait_for(|total| *total >= 512 * 1024).await.unwrap();

    let peer = SocketAddr::new(configs.server_v6, MEDIA_PORT);
    let mut slowest = Duration::ZERO;
    for frame in 0..FRAMES {
        let sent = Instant::now();
        ours.send_to(&frame.to_be_bytes(), peer, Priority::Media).await.unwrap();
        let (payload, _) =
            timeout(Duration::from_secs(5), theirs.recv_from()).await.unwrap().unwrap();
        assert_eq!(payload, frame.to_be_bytes(), "every frame arrives, in order");
        slowest = slowest.max(sent.elapsed());
        tokio::time::sleep_until(sent + Duration::from_millis(10)).await;
    }
    assert!(*progress.borrow() < 4 * 1024 * 1024, "the upload was still running");
    let drops = client.datagram_drops();
    assert_eq!((drops.media_stale, drops.media_full), (0, 0), "no media dropped");
    client.shutdown().await;
    server.shutdown().await;
    slowest
}

/// A socket buffer of 100 datagrams holds 50 ms of the upload, and media
/// waits behind it: the round 5 symptom. A buffer of 4 holds 2 ms, the
/// backlog waits in the driver, and media leaves first.
#[tokio::test(start_paused = true)]
async fn a_small_socket_buffer_keeps_the_backlog_where_media_overtakes_it() {
    let deep = slowest_media_during_upload(100).await;
    let shallow = slowest_media_during_upload(4).await;
    eprintln!("slowest media during the upload: deep buffer {deep:?}, shallow {shallow:?}");
    assert!(deep >= ONE_WAY + Duration::from_millis(40), "deep buffer: media waited {deep:?}");
    // One way, plus the 4 datagrams already in the buffer (2 ms), plus one
    // datagram time.
    let bound = ONE_WAY + Duration::from_millis(4);
    assert!(shallow <= bound, "shallow buffer: media waited {shallow:?}");
}
