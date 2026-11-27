//! The standby pool's budget and the loser feed, on paused time where a race runs.

use std::io;
use std::time::Duration;

use super::{Family, Standby};
use crate::{RacePolicy, race_keeping_losers};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[test]
fn one_per_peer_and_kind_the_newest_kept() {
    let pool = Standby::new(8, Duration::from_secs(60));
    pool.put("a", Family::V4, 1);
    pool.put("a", Family::V4, 2);
    pool.put("a", Family::V6, 3);
    pool.put("b", Family::V4, 4);
    assert_eq!(pool.len(), 3);
    assert_eq!(pool.take(&"a", |_, _| true), Some((Family::V6, 3)));
    assert_eq!(pool.take(&"a", |_, _| true), Some((Family::V4, 2)));
    assert_eq!(pool.take(&"a", |_, _| true), None);
    assert_eq!(pool.take(&"b", |_, _| true), Some((Family::V4, 4)));
}

#[test]
fn past_the_budget_the_oldest_goes() {
    let pool = Standby::new(2, Duration::from_secs(60));
    pool.put("a", Family::V4, 1);
    pool.put("b", Family::V4, 2);
    pool.put("c", Family::V4, 3);
    assert_eq!(pool.len(), 2);
    assert_eq!(pool.take(&"a", |_, _| true), None);
    assert_eq!(pool.take(&"c", |_, _| true), Some((Family::V4, 3)));
}

#[test]
fn a_refused_standby_is_dropped_and_the_next_offered() {
    let pool = Standby::new(8, Duration::from_secs(60));
    pool.put("a", Family::V4, 1);
    pool.put("a", Family::V6, 2);
    let mut asked = Vec::new();
    let taken = pool.take(&"a", |_, value| {
        asked.push(*value);
        *value == 1
    });
    assert_eq!(taken, Some((Family::V4, 1)));
    assert_eq!(asked, vec![2, 1]);
    assert!(pool.is_empty());
}

#[test]
fn an_expired_or_disabled_pool_holds_nothing() {
    let expired = Standby::new(8, Duration::ZERO);
    expired.put("a", Family::V4, 1);
    assert_eq!(expired.take(&"a", |_, _| true), None);
    let off = Standby::<&str, Family, i32>::new(0, Duration::from_secs(60));
    assert!(!off.enabled());
    off.put("a", Family::V4, 1);
    assert!(off.is_empty());
}

#[test]
fn family_of_an_address() {
    assert_eq!(Family::of(&"192.0.2.1:443".parse().unwrap()), Family::V4);
    assert_eq!(Family::of(&"[2001:db8::1]:443".parse().unwrap()), Family::V6);
}

/// IPv6 connects in 600 ms, IPv4 starts at 400 ms and connects in 25: IPv4 wins at 425 ms and
/// IPv6, the loser, is handed back connected at 600 ms instead of dropped.
#[tokio::test(start_paused = true)]
async fn the_race_hands_back_the_loser_that_connects_after_the_winner() {
    let (won, mut losers) =
        race_keeping_losers(&["v6", "v4"], RacePolicy::INTERNET, |target| async move {
            tokio::time::sleep(if target == "v6" { ms(600) } else { ms(25) }).await;
            Ok::<_, io::Error>(target)
        })
        .await
        .unwrap();
    assert_eq!((won.value, won.elapsed), ("v4", ms(425)));
    assert!(!losers.is_empty());
    let began = tokio::time::Instant::now();
    let lost = losers.next().await.unwrap();
    assert_eq!((lost.target, lost.value), ("v6", "v6"));
    assert_eq!(began.elapsed(), ms(175));
    assert!(losers.next().await.is_none());
}

/// A loser that fails is skipped; one that never answers ends at its own attempt timeout.
#[tokio::test(start_paused = true)]
async fn failed_and_silent_losers_yield_nothing() {
    let mut n = 0;
    let (_, mut losers) = race_keeping_losers(&["a"], RacePolicy::INTERNET, move |target| {
        n += 1;
        let this = n;
        async move {
            match this {
                1 => std::future::pending().await,
                2 => {
                    tokio::time::sleep(ms(10)).await;
                    Ok::<_, io::Error>(target)
                }
                _ => unreachable!(),
            }
        }
    })
    .await
    .unwrap();
    let began = tokio::time::Instant::now();
    assert!(losers.next().await.is_none());
    // Attempt 0 started at 0 with a 3 s timeout; the winner answered at 410 ms.
    assert_eq!(began.elapsed(), ms(2590));
}
