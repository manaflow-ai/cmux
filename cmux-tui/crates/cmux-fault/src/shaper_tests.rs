use super::{Disruption, Link, LinkProfile, ProfileFile, SEGMENT, Shaper};
use crate::rng::Rng;
use crate::trace::Trace;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::Instant;

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

/// A link with `profile` and no traffic yet, for the model's own checks.
fn idle_link(profile: LinkProfile) -> Link {
    let now = Instant::now();
    Link {
        profile,
        free_at: [now, now],
        dark: None,
        orphaned_below: 0,
        stalled_until: None,
        internet_down: false,
    }
}

fn ms(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1e3
}

/// The shaper applies the profile it claims: for every shipped profile, 20,000 segments
/// through the model, measured against the numbers the profile configures (one-way delay,
/// jitter, loss, rate, and the mean delay all of them make together). Prints one
/// `SHAPER-VALIDATE` row per profile.
#[test]
fn every_profile_measures_as_configured() {
    const N: u32 = 20_000;
    for profile in ProfileFile::builtin().profiles {
        let one_way = profile.one_way();
        let air = profile.serialize(SEGMENT, true);
        // Far enough apart that no segment queues behind another on the radio.
        let gap = (air * 2).max(Duration::from_millis(1));
        // (delay past serialization, per segment) with the floor off: each segment's own draw.
        let draw = |profile: &LinkProfile| -> Vec<Duration> {
            let mut link = idle_link(profile.clone());
            let mut rng = Rng::new(7);
            let base = Instant::now();
            (0..N)
                .map(|i| {
                    let now = base + gap * i;
                    let arrive = link.schedule_at(now, SEGMENT, true, &mut rng, now, &mut None);
                    arrive - now - air
                })
                .collect()
        };
        // One-way delay and jitter, loss off.
        let mut no_loss = profile.clone();
        no_loss.loss_percent = 0.0;
        let delays = draw(&no_loss);
        let (low, high) = (
            delays.iter().min().copied().unwrap_or_default(),
            delays.iter().max().copied().unwrap_or_default(),
        );
        // Loss, jitter off: a lost segment is one RTO (or more) late.
        let mut no_jitter = profile.clone();
        no_jitter.jitter_ms = 0;
        let late =
            draw(&no_jitter).iter().filter(|delay| **delay >= one_way + profile.rto()).count();
        let loss = late as f64 * 100.0 / f64::from(N);
        // Rate: 200 back-to-back segments, loss and jitter off.
        let mut clean = no_loss.clone();
        clean.jitter_ms = 0;
        let mut link = idle_link(clean);
        let mut rng = Rng::new(7);
        let base = Instant::now();
        let mut last = base;
        for _ in 0..200 {
            last = link.schedule_at(base, SEGMENT, true, &mut rng, base, &mut None);
        }
        let rate_kbit = if profile.down_kbit == 0 {
            0.0
        } else {
            (200 * SEGMENT * 8) as f64 / (last - base - one_way).as_secs_f64() / 1e3
        };
        // Everything together: one-way + mean jitter + the loss ladder's mean.
        let all = draw(&profile);
        let mean = all.iter().map(|delay| ms(*delay)).sum::<f64>() / f64::from(N);
        let p = profile.loss_percent / 100.0;
        let rto = ms(profile.rto());
        let ladder: f64 = (1..12).map(|k| p.powi(k) * rto * f64::from(1_u32 << (k - 1))).sum();
        let expect = ms(one_way) + profile.jitter_ms as f64 / 2.0 + ladder;
        println!(
            "SHAPER-VALIDATE profile={} n={N} one_way_ms cfg={:.1} meas_min={:.1} jitter_ms cfg=0..{} meas={:.1}..{:.1} loss_pct cfg={:.2} meas={loss:.2} down_kbit cfg={} meas={rate_kbit:.0} mean_ms expect={expect:.1} meas={mean:.1}",
            profile.label(None),
            ms(one_way),
            ms(low),
            profile.jitter_ms,
            ms(low - one_way),
            ms(high - one_way),
            profile.loss_percent,
            profile.down_kbit,
        );
        let name = &profile.name;
        assert_eq!(low, one_way, "{name}: one-way delay");
        assert!(high - one_way <= Duration::from_millis(profile.jitter_ms), "{name}: jitter");
        if profile.jitter_ms >= 10 {
            assert!(
                high - one_way >= Duration::from_millis(profile.jitter_ms * 9 / 10),
                "{name}: jitter never reaches its range"
            );
        }
        // 20,000 draws: the standard error at 10% loss is 0.21 points.
        assert!((loss - profile.loss_percent).abs() < 0.8, "{name}: loss {loss}");
        if profile.down_kbit > 0 {
            let off = (rate_kbit - profile.down_kbit as f64).abs() / profile.down_kbit as f64;
            assert!(off < 0.01, "{name}: rate {rate_kbit}");
        }
        assert!((mean - expect).abs() <= expect * 0.05 + 1.0, "{name}: mean {mean} vs {expect}");
    }
}

/// One timer per connection through a blackout (#59268): a segment sent every 250 ms through
/// a 5 s blackout on lossy-3's link all land behind the first segment's retry, 6.2 s after
/// the blackout began (200 ms doubling: 0.2, 0.6, 1.4, 3.0, 6.2), not behind the latest
/// ladder among them (a segment sent at 1.75 s would retry at 7.95 s on its own ladder).
#[test]
fn a_blackout_backlog_rides_the_first_segments_timer() {
    let mut profile = ProfileFile::builtin().get("lossy-3").unwrap().clone();
    profile.loss_percent = 0.0;
    profile.jitter_ms = 0;
    let mut link = idle_link(profile.clone());
    let mut rng = Rng::new(1);
    let base = Instant::now();
    let until = base + Duration::from_secs(5);
    link.dark = Some((base, until));
    let (mut floor, mut recovery) = (base, None);
    let mut last = base;
    for i in 0..20_u32 {
        let now = base + Duration::from_millis(250) * i;
        last = link.schedule_at(now, 100, false, &mut rng, floor, &mut recovery);
        floor = last;
    }
    let head = base + Duration::from_millis(6_200) + profile.one_way();
    let resume = last - until;
    println!(
        "SHAPER-VALIDATE blackout profile=lossy-3@1 blackout_ms=5000 segments=20 resume_after_ms={:.1} expect={:.1}",
        ms(resume),
        ms(head - until)
    );
    assert!(last >= head, "{:?} before the first retry", head - last);
    assert!(last - head < Duration::from_millis(5), "the backlog trails by {:?}", last - head);
    // A segment sent once the window is over, while the timer still backs off, waits for it.
    let after = link.schedule_at(until, 100, false, &mut rng, floor, &mut recovery);
    assert!(after >= head, "{:?} ahead of the timer", head - after);
    // A direction that sent nothing into the dark is not held.
    let fresh = link.schedule_at(until, 100, true, &mut rng, until, &mut None);
    assert_eq!(fresh, until + profile.serialize(100, true) + profile.one_way());
}

/// The same through the proxy: three writes 250 ms apart into a 2 s blackout come back
/// behind the first one's retry at 3.0 s (0.2, 0.6, 1.4, 3.0), not at the 3.5 s ladder the
/// write at 0.5 s would have on its own.
#[tokio::test]
async fn a_blackout_backlog_resumes_on_one_timer_through_the_proxy() {
    let profile = ProfileFile::builtin().get("relay-30").unwrap().clone();
    let shaper = Shaper::start(echo_server().await, profile, 1, &Trace::new()).await.unwrap();
    let mut client = TcpStream::connect(shaper.addr()).await.unwrap();
    round_trip(&mut client, 10).await;
    let started = std::time::Instant::now();
    shaper.blackout(Duration::from_secs(2));
    for _ in 0..3 {
        client.write_all(&[7_u8; 10]).await.unwrap();
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    let mut answer = [0_u8; 30];
    client.read_exact(&mut answer).await.unwrap();
    let took = started.elapsed();
    println!(
        "SHAPER-VALIDATE blackout-proxy profile=relay-30@1 blackout_ms=2000 back_ms={}",
        took.as_millis()
    );
    assert!(took >= Duration::from_millis(3_000), "{took:?}");
    assert!(took < Duration::from_millis(3_400), "{took:?}");
}

/// The proxy applies lossy-3's delay: 30 small round trips, their mean against the
/// profile's (70 ms round trip, two 0..300 ms jitter draws, 3% loss each way at 200 ms).
#[tokio::test]
async fn the_proxy_delays_lossy_3_as_configured() {
    let profile = ProfileFile::builtin().get("lossy-3").unwrap().clone();
    let p = profile.loss_percent / 100.0;
    let expect = profile.rtt_ms as f64 + profile.jitter_ms as f64 + 2.0 * p * ms(profile.rto());
    let shaper = Shaper::start(echo_server().await, profile, 3, &Trace::new()).await.unwrap();
    let mut client = TcpStream::connect(shaper.addr()).await.unwrap();
    let mut total = 0.0;
    for _ in 0..30 {
        total += ms(round_trip(&mut client, 10).await);
    }
    let mean = total / 30.0;
    println!(
        "SHAPER-VALIDATE proxy profile=lossy-3@1 n=30 round_trip_ms expect={expect:.1} meas={mean:.1}"
    );
    // The standard error of 30 trips is about 25 ms.
    assert!((mean - expect).abs() < 110.0, "{mean} vs {expect}");
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
