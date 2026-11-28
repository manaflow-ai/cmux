//! The PoP in process, behind an impaired socket on the phone leg.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use cmux_hop_relay::bench::{
    MacConfig, Path, PhoneRun, TEST_ECHO, TEST_FRAMES, mac_serve, phone_handshake, phone_run,
};
use cmux_hop_relay::server::{Pop, PopConfig};
use cmux_hop_relay::wire;
use tokio::net::UdpSocket;

/// A UDP proxy that drops every `drop_every`-th datagram each way and delays
/// the rest by `delay`: the phone's lossy leg. Returns its listening address.
async fn impaired(
    upstream: SocketAddr,
    drop_every: u64,
    delay: Duration,
) -> (SocketAddr, Arc<AtomicU64>) {
    let front = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let back = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
    let addr = front.local_addr().unwrap();
    let dropped = Arc::new(AtomicU64::default());
    let client: Arc<std::sync::Mutex<Option<SocketAddr>>> = Arc::default();
    {
        let (front, back, dropped, client) =
            (front.clone(), back.clone(), dropped.clone(), client.clone());
        tokio::spawn(async move {
            let mut buf = vec![0; 65_536];
            let mut n_seen = 0_u64;
            while let Ok((n, from)) = front.recv_from(&mut buf).await {
                *client.lock().unwrap() = Some(from);
                n_seen += 1;
                if n_seen.is_multiple_of(drop_every) {
                    dropped.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
                let (back, d) = (back.clone(), buf[..n].to_vec());
                tokio::spawn(async move {
                    tokio::time::sleep(delay).await;
                    let _ = back.send_to(&d, upstream).await;
                });
            }
        });
    }
    {
        let dropped = dropped.clone();
        tokio::spawn(async move {
            let mut buf = vec![0; 65_536];
            let mut n_seen = 0_u64;
            while let Ok((n, _)) = back.recv_from(&mut buf).await {
                n_seen += 1;
                if n_seen.is_multiple_of(drop_every) {
                    dropped.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
                let Some(to) = *client.lock().unwrap() else { continue };
                let (front, d) = (front.clone(), buf[..n].to_vec());
                tokio::spawn(async move {
                    tokio::time::sleep(delay).await;
                    let _ = front.send_to(&d, to).await;
                });
            }
        });
    }
    (addr, dropped)
}

async fn pop(leg_rate_kbit: u64) -> (SocketAddr, cmux_hop_relay::server::Reports) {
    let mut config = PopConfig::lab("127.0.0.1:0".parse().unwrap());
    config.leg_rate_kbit = leg_rate_kbit;
    let pop = Pop::bind(config).await.unwrap();
    let addr = pop.local_addr().unwrap();
    let reports = pop.reports();
    tokio::spawn(pop.run());
    (addr, reports)
}

async fn udp() -> UdpSocket {
    UdpSocket::bind("127.0.0.1:0").await.unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn echo_through_a_lossy_phone_leg_is_repaired_by_the_pop() {
    let (pop_addr, reports) = pop(0).await;
    let (lossy, dropped) = impaired(pop_addr, 10, Duration::from_millis(10)).await;
    let (mut phone, relayed) = Path::bind(udp().await, lossy, b"loopback-echo").await.unwrap();
    for mac_hop in [false, true] {
        let mut mac = if mac_hop {
            Path::hop(udp().await, relayed)
        } else {
            Path::plain(udp().await, relayed)
        };
        let cfg = MacConfig { fps: 60, frame_bytes: 900, bulk_kbit: 0, bulk_bytes: 1200 };
        let server = tokio::spawn(async move { mac_serve(&mut mac, &cfg).await });
        phone_handshake(&mut phone, Duration::from_secs(10)).await.unwrap();
        let run = PhoneRun {
            test: TEST_ECHO,
            duration: Duration::from_secs(3),
            interval: Duration::from_millis(20),
            ping_bytes: 96,
        };
        let result = phone_run(&mut phone, &run).await;
        server.abort();
        assert_eq!(result["lost"], 0, "{result}");
        assert!(result["sent"].as_u64().unwrap() >= 140, "{result}");
        // A tenth of the phone leg drops each way; the PoP's leg resends, so the app rarely has to.
        let p95 = result["rtt_ms"]["p95"].as_f64().unwrap();
        assert!(p95 < 150.0, "{result}");
    }
    assert!(dropped.load(Ordering::Relaxed) > 20);
    let reports = reports.lock().unwrap().clone();
    let report = reports.values().next().expect("an allocation report");
    assert!(report["phone_leg"]["resent"].as_u64().unwrap() > 0, "{report}");
    assert!(report["phone_leg"]["repaired"].as_u64().unwrap() > 0, "{report}");
    assert_eq!(report["mac_mode"], "hop", "{report}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn latest_wins_keeps_frames_fresh_under_bulk_at_the_leg_rate() {
    // The leg drains at 4 Mbit/s; the Mac offers 8 Mbit/s of bulk beside 60 fps of frames.
    let (pop_addr, reports) = pop(4_000).await;
    let (mut phone, relayed) = Path::bind(udp().await, pop_addr, b"loopback-frames").await.unwrap();
    let mut mac = Path::hop(udp().await, relayed);
    let cfg = MacConfig { fps: 60, frame_bytes: 900, bulk_kbit: 8_000, bulk_bytes: 1200 };
    let server = tokio::spawn(async move { mac_serve(&mut mac, &cfg).await });
    phone_handshake(&mut phone, Duration::from_secs(10)).await.unwrap();
    let run = PhoneRun {
        test: TEST_FRAMES,
        duration: Duration::from_secs(3),
        interval: Duration::ZERO,
        ping_bytes: 96,
    };
    let result = phone_run(&mut phone, &run).await;
    server.abort();
    let age_p95 = result["age_ms"]["p95"].as_f64().unwrap();
    assert!(age_p95 < 60.0, "{result}");
    let bulk = result["bulk_kbit"].as_f64().unwrap();
    assert!(bulk > 2_000.0 && bulk < 4_500.0, "{result}");
    let reports = reports.lock().unwrap().clone();
    let report = reports.values().next().unwrap();
    assert!(report["phone_leg"]["dropped"].as_u64().unwrap() > 0, "{report}");
}

#[tokio::test]
async fn a_rebind_from_a_new_address_keeps_the_relayed_port() {
    let (pop_addr, _) = pop(0).await;
    let (_, first) = Path::bind(udp().await, pop_addr, b"roam").await.unwrap();
    let (mut phone, second) = Path::bind(udp().await, pop_addr, b"roam").await.unwrap();
    assert_eq!(first, second);
    let mut mac = Path::plain(udp().await, second);
    let cfg = MacConfig { fps: 60, frame_bytes: 900, bulk_kbit: 0, bulk_bytes: 1200 };
    let server = tokio::spawn(async move { mac_serve(&mut mac, &cfg).await });
    // Traffic reaches the new address.
    phone_handshake(&mut phone, Duration::from_secs(5)).await.unwrap();
    server.abort();
}

#[tokio::test]
async fn a_bad_ticket_is_refused() {
    let mut config = PopConfig::lab("127.0.0.1:0".parse().unwrap());
    config.authority = cmux_hop_relay::ticket::TicketAuthority::hmac(vec![3; 32]).unwrap();
    let pop = Pop::bind(config).await.unwrap();
    let addr = pop.local_addr().unwrap();
    tokio::spawn(pop.run());
    let err = Path::bind(udp().await, addr, b"hop1.x.1.AAAA").await.err().unwrap();
    assert!(err.to_string().contains(&format!("error {}", wire::E_BAD_TICKET)), "{err}");
}
