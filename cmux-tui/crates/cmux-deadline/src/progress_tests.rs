use super::*;
use std::time::Instant;

const S: fn(u64) -> Duration = Duration::from_secs;

#[test]
fn progress_restarts_the_idle_bound() {
    let t0 = Instant::now();
    let mut d = IdleDeadline::new_at(t0, S(10), None);
    assert_eq!(d.end(), t0 + S(10));
    assert!(d.observe_at(t0 + S(8), 1));
    assert!(!d.observe_at(t0 + S(9), 1), "the same count is no progress");
    assert_eq!(d.end(), t0 + S(18));
    assert_eq!(d.stalled_at(t0 + S(17)), None);
    assert_eq!(d.stalled_at(t0 + S(18)), Some(Stalled::Idle { silent: S(10) }));
}

/// The case the type exists for: work that moves every 5 s for 10 minutes never ends on a
/// 10 s idle bound, where a 10 s wall-clock bound would have ended it at 10 s.
#[test]
fn steady_progress_outlives_any_fixed_bound() {
    let t0 = Instant::now();
    let mut d = IdleDeadline::new_at(t0, S(10), None);
    for step in 1..=120u64 {
        let now = t0 + S(5 * step);
        assert_eq!(d.stalled_at(now), None, "at {} s", 5 * step);
        d.observe_at(now, step);
    }
}

#[test]
fn the_cap_ends_it_even_while_moving() {
    let t0 = Instant::now();
    let mut d = IdleDeadline::new_at(t0, S(10), Some(S(30)));
    d.observe_at(t0 + S(25), 1);
    assert_eq!(d.end(), t0 + S(30));
    assert_eq!(d.stalled_at(t0 + S(30)), Some(Stalled::Cap { elapsed: S(30) }));
}

#[test]
fn a_counter_bumps_and_ignores_zero() {
    let p = Progress::new();
    p.bump();
    p.bump_by(0);
    p.bump_by(4);
    assert_eq!(p.count(), 5);
    let d = IdleDeadline::<Instant>::watching(&p, S(1), None);
    assert_eq!(d.seen, 5);
}

#[cfg(feature = "tokio")]
#[tokio::test(start_paused = true)]
async fn a_future_that_keeps_moving_past_the_old_bound_finishes() {
    let progress = Progress::new();
    let worker = progress.clone();
    let work = async move {
        // 60 s of work, a step every 2 s: six times a 10 s wall-clock bound.
        for _ in 0..30 {
            tokio::time::sleep(S(2)).await;
            worker.bump();
        }
        "done"
    };
    let started = tokio::time::Instant::now();
    let out = progress_timeout(S(10), None, &progress, work).await;
    assert_eq!(out, Ok("done"));
    assert_eq!(started.elapsed(), S(60));
}

#[cfg(feature = "tokio")]
#[tokio::test(start_paused = true)]
async fn a_future_that_goes_silent_ends_one_idle_bound_after_its_last_progress() {
    let progress = Progress::new();
    let worker = progress.clone();
    let work = async move {
        for _ in 0..3 {
            tokio::time::sleep(S(4)).await;
            worker.bump();
        }
        std::future::pending::<()>().await;
    };
    let started = tokio::time::Instant::now();
    let out = progress_timeout(S(10), None, &progress, work).await;
    assert_eq!(out, Err(Stalled::Idle { silent: S(10) }));
    assert_eq!(started.elapsed(), S(22));
}

#[cfg(feature = "tokio")]
#[tokio::test(start_paused = true)]
async fn bytes_through_a_progress_io_are_progress() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (client, mut server) = tokio::io::duplex(64);
    let progress = Progress::new();
    let mut writer = ProgressIo::new(client, progress.clone());
    let reader = tokio::spawn(async move {
        let mut got = Vec::new();
        let mut buf = [0u8; 64];
        // A slow reader: 64 bytes every 3 s, so the writer is held back by it.
        loop {
            tokio::time::sleep(S(3)).await;
            match server.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => got.extend_from_slice(&buf[..n]),
            }
        }
        got
    });
    let payload = vec![7u8; 64 * 20];
    let send = async {
        writer.write_all(&payload).await.unwrap();
        writer.shutdown().await.unwrap();
    };
    // About 60 s for the whole write; each 64-byte step lands within 3 s.
    progress_timeout(S(10), None, &progress, send).await.unwrap();
    drop(writer);
    assert_eq!(reader.await.unwrap().len(), payload.len());
    assert_eq!(progress.count(), payload.len() as u64);
}
