//! The remembered race on paused time: no network and no wall time.

use std::io;
use std::net::SocketAddr;
use std::time::Duration;

use tokio::time::Instant;

use super::{race_remembered, v6_first};
use crate::{LastGood, RacePolicy};

fn addr(text: &str) -> SocketAddr {
    text.parse().unwrap()
}

#[test]
fn v6_first_alternates_families_keeping_each_order() {
    let a4 = addr("192.0.2.1:443");
    let b4 = addr("192.0.2.2:443");
    let a6 = addr("[2001:db8::1]:443");
    let b6 = addr("[2001:db8::2]:443");
    assert_eq!(v6_first(&[a4, b4, a6, b6]), vec![a6, a4, b6, b4]);
    assert_eq!(v6_first(&[a4, b4]), vec![a4, b4]);
    assert!(v6_first(&[]).is_empty());
}

#[tokio::test(start_paused = true)]
async fn the_winner_is_recorded_and_every_failure_forgets_it() {
    let v6 = addr("[2001:db8::1]:443");
    let v4 = addr("192.0.2.1:443");
    let memory = LastGood::new(Duration::from_secs(60));
    let began = Instant::now();
    let (winner, won) = race_remembered(
        &memory,
        "peer",
        &[v6, v4],
        RacePolicy::INTERNET,
        |a: SocketAddr| async move {
            if a.is_ipv6() {
                std::future::pending::<()>().await;
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
            Ok::<_, io::Error>(a)
        },
    )
    .await
    .unwrap();
    assert_eq!((winner, won.value, won.connect), (v4, v4, Duration::from_millis(30)));
    assert_eq!(began.elapsed(), Duration::from_millis(430));
    assert_eq!(memory.get(&"peer").unwrap().target, v4);

    let failed =
        race_remembered(&memory, "peer", &[v6, v4], RacePolicy::INTERNET, |_a: SocketAddr| async {
            Err::<(), _>(io::Error::from(io::ErrorKind::ConnectionRefused))
        })
        .await;
    assert!(failed.is_err());
    assert!(memory.get(&"peer").is_none());
}

/// One simulated connect on a network that drops UDP: the `quic` leg never answers (the race
/// times it out), `tcp` connects in 30 ms.
async fn udp_blocked(leg: &'static str) -> io::Result<&'static str> {
    if leg == "quic" {
        std::future::pending::<()>().await;
    }
    tokio::time::sleep(Duration::from_millis(30)).await;
    Ok(leg)
}

/// The before/after on a UDP-blocked network: five connects in a row, QUIC listed first.
/// Before (memory off) each connect waits out QUIC's stagger before TCP starts; after, the
/// first connect learns TCP won and the rest dial it first. Also: QUIC is counted as outrun,
/// TCP as the winner, and a QUIC timeout marks it broken so it is raced late.
#[tokio::test(start_paused = true)]
async fn on_a_udp_blocked_network_the_cached_winner_goes_first() {
    let policy = RacePolicy { attempt_timeout: Duration::from_secs(1), ..RacePolicy::INTERNET };
    let connects = |memory: LastGood<&'static str, &'static str>| async move {
        let mut times = Vec::new();
        for _ in 0..5 {
            let began = Instant::now();
            let (winner, _) =
                race_remembered(&memory, "peer", &["quic", "tcp"], policy, udp_blocked)
                    .await
                    .unwrap();
            assert_eq!(winner, "tcp");
            times.push(began.elapsed());
        }
        times
    };
    let off = LastGood::new(Duration::ZERO).named("test.udp-blocked.off");
    let before = connects(off).await;
    let on = LastGood::new(Duration::from_secs(600)).named("test.udp-blocked.on");
    let after = connects(on).await;
    let total = |times: &[Duration]| times.iter().sum::<Duration>();
    eprintln!(
        "udp-blocked time to winning leg, 5 connects: before {before:?} (sum {:?}), after {after:?} (sum {:?})",
        total(&before),
        total(&after)
    );
    assert_eq!(before, vec![Duration::from_millis(430); 5]);
    assert_eq!(after[0], Duration::from_millis(430));
    assert_eq!(&after[1..], &[Duration::from_millis(30); 4]);

    let tally = crate::legs::snapshot();
    let count = |dial: &str, leg: &str, outcome| {
        tally.get(&(dial.to_string(), leg.to_string(), outcome)).copied().unwrap_or(0)
    };
    assert_eq!(count("test.udp-blocked.on", "tcp", crate::Outcome::Won), 5);
    assert_eq!(count("test.udp-blocked.on", "quic", crate::Outcome::Outrun), 1);
    assert_eq!(count("test.udp-blocked.off", "quic", crate::Outcome::Outrun), 5);
}

#[tokio::test(start_paused = true)]
async fn a_leg_that_times_out_is_marked_broken_and_counted() {
    // QUIC times out alone (attempt timeout shorter than the stagger), then TCP wins.
    let policy = RacePolicy {
        stagger: Duration::from_secs(5),
        attempt_timeout: Duration::from_millis(200),
        ..RacePolicy::INTERNET
    };
    let memory = LastGood::new(Duration::from_secs(600)).named("test.timeout");
    let (winner, _) =
        race_remembered(&memory, "peer", &["quic", "tcp"], policy, udp_blocked).await.unwrap();
    assert_eq!(winner, "tcp");
    assert!(memory.is_broken(&"peer", &"quic"));
    assert_eq!(memory.order(&"peer", &["quic", "tcp"]).0, vec!["tcp", "quic"]);
    let tally = crate::legs::snapshot();
    assert_eq!(
        tally.get(&("test.timeout".into(), "quic".into(), crate::Outcome::Timeout)),
        Some(&1)
    );
}
