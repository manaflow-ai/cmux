use super::{UdpShaper, Way};
use crate::shaper::ProfileFile;
use crate::trace::Trace;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::UdpSocket;

/// A host that echoes every datagram to its sender and remembers the senders it saw.
async fn echo_host() -> (SocketAddr, Arc<Mutex<Vec<SocketAddr>>>) {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let addr = socket.local_addr().unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        let mut buffer = vec![0_u8; 64 * 1024];
        while let Ok((n, from)) = socket.recv_from(&mut buffer).await {
            {
                let mut log = log.lock().unwrap();
                if !log.contains(&from) {
                    log.push(from);
                }
            }
            let _ = socket.send_to(&buffer[..n], from).await;
        }
    });
    (addr, seen)
}

async fn phone(shaper: &UdpShaper) -> UdpSocket {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    socket.connect(shaper.addr()).await.unwrap();
    socket
}

/// The round trip of one datagram, or `None` when nothing came back within `bound`.
async fn ping(socket: &UdpSocket, bound: Duration) -> Option<Duration> {
    let started = std::time::Instant::now();
    socket.send(b"ping").await.unwrap();
    let mut answer = [0_u8; 16];
    tokio::time::timeout(bound, socket.recv(&mut answer)).await.ok()?.ok()?;
    Some(started.elapsed())
}

fn profile(name: &str) -> crate::shaper::LinkProfile {
    ProfileFile::builtin().get(name).unwrap().clone()
}

#[tokio::test]
async fn a_datagram_costs_the_round_trip() {
    let (host, _) = echo_host().await;
    let mut lte = profile("lte");
    lte.loss_percent = 0.0;
    let shaper = UdpShaper::start(host, lte, 1, &Trace::new()).await.unwrap();
    let socket = phone(&shaper).await;
    let took = ping(&socket, Duration::from_secs(2)).await.unwrap();
    assert!(took >= Duration::from_millis(70), "{took:?}");
    assert!(took < Duration::from_millis(400), "{took:?}");
    let counters = shaper.counters();
    assert_eq!((counters.up_datagrams, counters.down_datagrams), (1, 1));
}

#[tokio::test]
async fn a_blackout_drops_both_ways_then_the_same_addresses_flow() {
    let (host, seen) = echo_host().await;
    let mut lte = profile("lte");
    lte.loss_percent = 0.0;
    let shaper = UdpShaper::start(host, lte, 1, &Trace::new()).await.unwrap();
    let socket = phone(&shaper).await;
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    let back = shaper.blackout(Duration::from_millis(500));
    assert!(ping(&socket, Duration::from_millis(300)).await.is_none());
    tokio::time::sleep_until(back).await;
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    assert_eq!(seen.lock().unwrap().len(), 1, "the host saw a new address");
    assert!(shaper.counters().up_dropped >= 1);
}

#[tokio::test]
async fn a_rebind_shows_the_host_a_new_port() {
    let (host, seen) = echo_host().await;
    let shaper = UdpShaper::start(host, profile("good-wifi"), 1, &Trace::new()).await.unwrap();
    let socket = phone(&shaper).await;
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    let before = shaper.phone_addr_at_host().unwrap();
    let after = shaper.rebind().await.unwrap();
    assert_ne!(before, after);
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    assert_eq!(*seen.lock().unwrap(), vec![before, after]);
}

#[tokio::test]
async fn one_way_loss_drops_only_that_way() {
    let (host, seen) = echo_host().await;
    let shaper = UdpShaper::start(host, profile("good-wifi"), 1, &Trace::new()).await.unwrap();
    let socket = phone(&shaper).await;
    let back = shaper.one_way_loss(Way::Down, Duration::from_millis(400));
    assert!(ping(&socket, Duration::from_millis(200)).await.is_none());
    let counters = shaper.counters();
    assert_eq!((counters.up_dropped, counters.down_dropped), (0, 1));
    assert_eq!(seen.lock().unwrap().len(), 1, "the ping reached the host");
    tokio::time::sleep_until(back).await;
    ping(&socket, Duration::from_secs(2)).await.unwrap();
}

#[tokio::test]
async fn a_step_changes_the_round_trip() {
    let (host, _) = echo_host().await;
    let shaper = UdpShaper::start(host, profile("good-wifi"), 1, &Trace::new()).await.unwrap();
    let socket = phone(&shaper).await;
    let fast = ping(&socket, Duration::from_secs(2)).await.unwrap();
    let mut slow = profile("lte");
    slow.rtt_ms = 300;
    slow.loss_percent = 0.0;
    shaper.set_profile(slow);
    let took = ping(&socket, Duration::from_secs(2)).await.unwrap();
    assert!(fast < Duration::from_millis(100), "{fast:?}");
    assert!(took >= Duration::from_millis(300), "{took:?}");
}

#[tokio::test]
async fn internet_down_blackholes_the_internet_path_and_leaves_the_lan() {
    let (lan_host, _) = echo_host().await;
    let (internet_host, internet_seen) = echo_host().await;
    let shaper = UdpShaper::start(lan_host, profile("internet-down-lan-up"), 1, &Trace::new())
        .await
        .unwrap();
    let internet_addr = shaper.open_internet_path(internet_host).await.unwrap();
    let lan = phone(&shaper).await;
    let internet = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    internet.connect(internet_addr).await.unwrap();
    ping(&lan, Duration::from_secs(2)).await.unwrap();
    ping(&internet, Duration::from_secs(2)).await.unwrap();
    shaper.internet_down();
    assert!(ping(&internet, Duration::from_millis(300)).await.is_none());
    assert_eq!(internet_seen.lock().unwrap().len(), 1);
    let took = ping(&lan, Duration::from_secs(2)).await.unwrap();
    assert!(took >= Duration::from_millis(4), "{took:?}");
    assert!(took < Duration::from_millis(200), "{took:?}");
    // The internet path's drops are its own: the LAN counters show none.
    assert_eq!(shaper.counters().up_dropped, 0);
}

#[tokio::test]
async fn one_seed_drops_the_same_datagrams() {
    async fn run(seed: u64) -> Vec<bool> {
        let (host, _) = echo_host().await;
        let shaper =
            UdpShaper::start(host, profile("lossy-10"), seed, &Trace::new()).await.unwrap();
        let socket = phone(&shaper).await;
        let mut answered = Vec::new();
        for _ in 0..12 {
            answered.push(ping(&socket, Duration::from_millis(2_500)).await.is_some());
        }
        answered
    }
    assert_eq!(run(5).await, run(5).await);
}

/// The nat-rebind row: the host sees a new port at once and the phone's socket flows on it.
#[tokio::test]
async fn the_nat_rebind_row_rebinds_with_no_stall() {
    let (host, seen) = echo_host().await;
    let mut nat = profile("nat-rebind");
    nat.loss_percent = 0.0;
    let shaper = UdpShaper::start(host, nat, 1, &Trace::new()).await.unwrap();
    let socket = phone(&shaper).await;
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    let before = shaper.phone_addr_at_host().unwrap();
    let back = shaper.disrupt().await.unwrap().unwrap();
    assert!(back <= tokio::time::Instant::now());
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    let after = shaper.phone_addr_at_host().unwrap();
    assert_eq!(*seen.lock().unwrap(), vec![before, after]);
}

/// The wifi-to-cell row: a new port and the cellular link's numbers from the change on.
#[tokio::test]
async fn the_wifi_to_cell_row_rebinds_and_steps_to_the_cell_link() {
    let (host, seen) = echo_host().await;
    let shaper = UdpShaper::start(host, profile("wifi-to-cell"), 1, &Trace::new()).await.unwrap();
    let socket = phone(&shaper).await;
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    shaper.disrupt().await.unwrap().unwrap();
    assert_eq!(shaper.profile().name, "cell-after-wifi");
    let mut cell = profile("cell-after-wifi");
    cell.loss_percent = 0.0;
    shaper.set_profile(cell);
    let took = ping(&socket, Duration::from_secs(2)).await.unwrap();
    assert!(took >= Duration::from_millis(42), "{took:?}");
    assert_eq!(seen.lock().unwrap().len(), 2, "the host saw one new address");
}

/// A blackout row through the datagram twin: nothing either way, then the same addresses.
#[tokio::test]
async fn a_blackout_row_drops_both_ways_for_its_window() {
    let (host, seen) = echo_host().await;
    let mut row = profile("blackout-2s");
    row.loss_percent = 0.0;
    let shaper = UdpShaper::start(host, row, 1, &Trace::new()).await.unwrap();
    let socket = phone(&shaper).await;
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    let back = shaper.disrupt().await.unwrap().unwrap();
    assert!(ping(&socket, Duration::from_millis(500)).await.is_none());
    tokio::time::sleep_until(back).await;
    ping(&socket, Duration::from_secs(2)).await.unwrap();
    assert_eq!(seen.lock().unwrap().len(), 1);
}
