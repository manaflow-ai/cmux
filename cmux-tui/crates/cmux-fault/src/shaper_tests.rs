use super::{Disruption, ProfileFile, Shaper};
use crate::trace::Trace;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

async fn echo_server() -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            tokio::spawn(async move {
                let mut buffer = vec![0_u8; 64 * 1024];
                while let Ok(n) = socket.read(&mut buffer).await {
                    if n == 0 || socket.write_all(&buffer[..n]).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    addr
}

async fn round_trip(stream: &mut TcpStream, bytes: usize) -> Duration {
    let started = std::time::Instant::now();
    stream.write_all(&vec![7_u8; bytes]).await.unwrap();
    let mut answer = vec![0_u8; bytes];
    stream.read_exact(&mut answer).await.unwrap();
    started.elapsed()
}

#[test]
fn every_profile_parses_and_names_its_source() {
    let file = ProfileFile::builtin();
    assert!(
        file.profiles.len() >= 11,
        "{:?}",
        file.profiles.iter().map(|p| &p.name).collect::<Vec<_>>()
    );
    for name in [
        "good-wifi",
        "lte",
        "5g-lte-handoff",
        "lossy-3",
        "lossy-10",
        "elevator-30s",
        "2g-trickle",
        "lan",
        "relay-30",
        "relay-80",
        "internet-down-lan-up",
    ] {
        let profile = file.get(name).unwrap_or_else(|| panic!("no profile {name}"));
        assert!(!profile.source.is_empty(), "{name} cites no source");
    }
}

#[tokio::test]
async fn the_lte_link_costs_its_round_trip_and_rate() {
    let profile = ProfileFile::builtin().get("lte").unwrap().clone();
    let shaper = Shaper::start(echo_server().await, profile, 1, &Trace::new()).await.unwrap();
    let mut client = TcpStream::connect(shaper.addr()).await.unwrap();
    let small = round_trip(&mut client, 10).await;
    assert!(small >= Duration::from_millis(70), "{small:?}");
    assert!(small < Duration::from_millis(400), "{small:?}");
    // 120 kB at 12 Mbit/s is 80 ms on the air; the echo answers each segment as it lands, so
    // the two ways overlap: about 80 ms plus the 70 ms round trip.
    let big = round_trip(&mut client, 120_000).await;
    assert!(big >= Duration::from_millis(145), "{big:?}");
    let counters = shaper.counters();
    assert_eq!(counters.up_bytes, 120_010);
    assert_eq!(counters.down_bytes, 120_010);
}

#[tokio::test]
async fn a_relay_hop_adds_its_round_trip_behind_the_phone_link() {
    let file = ProfileFile::builtin();
    let lte = file.get("lte").unwrap().clone();
    let relay = file.get("relay-80").unwrap();
    assert_eq!(lte.label(None), "lte@1");
    assert_eq!(lte.label(Some(relay)), "lte@1+relay-80@1");
    let (shaper, hop) =
        Shaper::start_through(echo_server().await, lte, Some(relay), 1, &Trace::new())
            .await
            .unwrap();
    let hop = hop.expect("the relay hop");
    let mut client = TcpStream::connect(shaper.addr()).await.unwrap();
    let took = round_trip(&mut client, 10).await;
    // 70 ms on the phone's link and 80 ms on the relay's.
    assert!(took >= Duration::from_millis(150), "{took:?}");
    assert!(took < Duration::from_millis(600), "{took:?}");
    // Both hops carried the same bytes; each counts its own.
    assert_eq!(shaper.counters().up_bytes, 10);
    assert_eq!(hop.counters().down_bytes, 10);
}

#[tokio::test]
async fn a_blackout_holds_bytes_until_a_retransmission_after_it() {
    let profile = ProfileFile::builtin().get("lte").unwrap().clone();
    let shaper = Shaper::start(echo_server().await, profile, 1, &Trace::new()).await.unwrap();
    let mut client = TcpStream::connect(shaper.addr()).await.unwrap();
    round_trip(&mut client, 10).await;
    shaper.blackout(Duration::from_millis(500));
    let took = round_trip(&mut client, 10).await;
    // 200 ms RTO doubling from the send: 200, 600 (past 500) and the one-way delay.
    assert!(took >= Duration::from_millis(600), "{took:?}");
    assert!(took < Duration::from_millis(1_500), "{took:?}");
}

#[tokio::test]
async fn an_address_change_silences_live_connections_and_stalls_new_ones() {
    let profile = ProfileFile::builtin().get("5g-lte-handoff").unwrap().clone();
    let shaper = Shaper::start(echo_server().await, profile, 1, &Trace::new()).await.unwrap();
    let mut old = TcpStream::connect(shaper.addr()).await.unwrap();
    round_trip(&mut old, 10).await;
    let flows = shaper.address_change(Some(Duration::from_millis(1_500)));
    old.write_all(b"ping").await.unwrap();
    let mut answer = [0_u8; 4];
    let silent =
        tokio::time::timeout(Duration::from_millis(800), old.read_exact(&mut answer)).await;
    assert!(silent.is_err(), "the old connection answered");
    // Dialed inside the stall: its first round trip lands only after the stall ends.
    let mut new = TcpStream::connect(shaper.addr()).await.unwrap();
    round_trip(&mut new, 10).await;
    let now = tokio::time::Instant::now();
    assert!(now >= flows, "answered {:?} before the stall ended", flows - now);
}

#[tokio::test]
async fn internet_down_kills_the_internet_path_and_leaves_the_lan() {
    let file = ProfileFile::builtin();
    let profile = file.get("internet-down-lan-up").unwrap().clone();
    assert_eq!(profile.disruption, Some(Disruption::InternetDown));
    assert!(!profile.disrupts_lan());
    assert!(file.get("elevator-30s").unwrap().disrupts_lan());
    let lan_numbers = file.get("lan").unwrap();
    assert_eq!(
        (profile.up_kbit, profile.down_kbit, profile.rtt_ms),
        (lan_numbers.up_kbit, lan_numbers.down_kbit, lan_numbers.rtt_ms)
    );
    let shaper = Shaper::start(echo_server().await, profile, 1, &Trace::new()).await.unwrap();
    let internet_addr = shaper.open_internet_path(echo_server().await).await.unwrap();
    let mut lan = TcpStream::connect(shaper.addr()).await.unwrap();
    let mut internet = TcpStream::connect(internet_addr).await.unwrap();
    round_trip(&mut lan, 10).await;
    round_trip(&mut internet, 10).await;

    let back = shaper.disrupt().unwrap();
    assert!(back <= tokio::time::Instant::now(), "the LAN link never drops");
    // The live internet connection goes silent.
    internet.write_all(b"ping").await.unwrap();
    let mut answer = [0_u8; 4];
    let silent =
        tokio::time::timeout(Duration::from_millis(300), internet.read_exact(&mut answer)).await;
    assert!(silent.is_err(), "the dead internet path answered");
    // A new internet connection is refused: closed with nothing through.
    let mut refused = TcpStream::connect(internet_addr).await.unwrap();
    let _ = refused.write_all(b"ping").await;
    let read =
        tokio::time::timeout(Duration::from_secs(2), refused.read(&mut answer)).await.unwrap();
    assert!(matches!(read, Ok(0) | Err(_)), "{read:?}");
    // The LAN keeps flowing, live and new, at its own numbers.
    let took = round_trip(&mut lan, 10).await;
    assert!(took >= Duration::from_millis(4), "{took:?}");
    assert!(took < Duration::from_millis(200), "{took:?}");
    let mut fresh = TcpStream::connect(shaper.addr()).await.unwrap();
    round_trip(&mut fresh, 10).await;
}

#[tokio::test]
async fn one_seed_is_one_link() {
    async fn run(seed: u64) -> Vec<u128> {
        let profile = ProfileFile::builtin().get("lossy-10").unwrap().clone();
        let shaper =
            Shaper::start(echo_server().await, profile, seed, &Trace::new()).await.unwrap();
        let mut client = TcpStream::connect(shaper.addr()).await.unwrap();
        let mut took = Vec::new();
        for _ in 0..6 {
            // Rounded to 50 ms: the scheduler's own wake-up noise is below it.
            took.push((round_trip(&mut client, 3_000).await.as_millis() + 25) / 50);
        }
        took
    }
    assert_eq!(run(9).await, run(9).await);
}
