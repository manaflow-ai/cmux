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
