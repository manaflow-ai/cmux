//! The race on paused time: what [`race`] reports about its winner, and the stagger rule.

use std::io;
use std::time::Duration;

use super::{RacePolicy, STAGGER_FLOOR, race, stagger_after};

fn ms(n: u64) -> Duration {
    Duration::from_millis(n)
}

#[tokio::test(start_paused = true)]
async fn the_winner_reports_its_target_and_its_own_connect_time() {
    // Attempt 0 ("a") never answers; attempt 1 ("b") starts at 400 ms and connects in 30 ms.
    let mut n = 0_u64;
    let won = race(&["a", "b"], RacePolicy::INTERNET, move |target| {
        n += 1;
        let first = n == 1;
        async move {
            if first {
                std::future::pending::<()>().await;
            }
            tokio::time::sleep(ms(30)).await;
            Ok::<_, io::Error>(target)
        }
    })
    .await
    .unwrap();
    assert_eq!((won.value, won.attempt, won.target_index), ("b", 1, 1));
    assert_eq!(won.elapsed, ms(430));
    assert_eq!(won.connect, ms(30));
}

#[tokio::test(start_paused = true)]
async fn no_targets_is_not_found() {
    let error = race(&[] as &[&str], RacePolicy::INTERNET, |_| async { Ok::<_, io::Error>(()) })
        .await
        .unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::NotFound);
}

#[test]
fn stagger_is_one_and_a_half_times_the_remembered_connect_within_the_bounds() {
    let ceiling = RacePolicy::INTERNET.stagger;
    assert_eq!(stagger_after(None, STAGGER_FLOOR, ceiling), ceiling);
    assert_eq!(stagger_after(Some(ms(20)), STAGGER_FLOOR, ceiling), STAGGER_FLOOR);
    assert_eq!(stagger_after(Some(ms(100)), STAGGER_FLOOR, ceiling), ms(150));
    assert_eq!(stagger_after(Some(ms(2000)), STAGGER_FLOOR, ceiling), ceiling);
    assert_eq!(RacePolicy::INTERNET.with_lead(Some(ms(80))).stagger, ms(120));
    assert_eq!(RacePolicy::INTERNET.with_lead(None), RacePolicy::INTERNET);
}

#[tokio::test(start_paused = true)]
async fn a_failure_starts_the_next_attempt_at_once_while_others_run() {
    // "a" hangs, "b" starts at 400 ms and fails at 410 ms, "c" starts then (not at 800 ms)
    // and connects in 30 ms.
    let won = race(&["a", "b", "c"], RacePolicy::INTERNET, |target| async move {
        match target {
            "a" => std::future::pending().await,
            "b" => {
                tokio::time::sleep(ms(10)).await;
                Err(io::Error::from(io::ErrorKind::ConnectionRefused))
            }
            _ => {
                tokio::time::sleep(ms(30)).await;
                Ok(target)
            }
        }
    })
    .await
    .unwrap();
    assert_eq!((won.value, won.attempt), ("c", 2));
    assert_eq!(won.elapsed, ms(440));
}
