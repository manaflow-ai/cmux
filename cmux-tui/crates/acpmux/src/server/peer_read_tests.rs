//! A forwarded read waits while its link brings the reply, and ends on a quiet link
//! (`peer_read`).

use super::{PEER_READ_STEP, ReadStalled, peer_read};
use std::time::Duration;

const IDLE: Duration = Duration::from_secs(30);
const CAP: Duration = Duration::from_secs(300);

#[tokio::test(start_paused = true)]
async fn a_quiet_link_ends_the_read_at_idle() {
    let read = cmux_deadline::Progress::new();
    let started = tokio::time::Instant::now();
    let out = peer_read(&read, IDLE, CAP, std::future::pending::<()>()).await;
    assert_eq!(out, Err(ReadStalled::Idle(IDLE)));
    assert_eq!(started.elapsed(), IDLE);
}

#[tokio::test(start_paused = true)]
async fn pings_alone_do_not_keep_a_stuck_read() {
    let read = cmux_deadline::Progress::new();
    let pinger = {
        let read = read.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(5)).await;
                read.bump_by(64);
            }
        })
    };
    let out = peer_read(&read, IDLE, CAP, std::future::pending::<()>()).await;
    pinger.abort();
    assert_eq!(out, Err(ReadStalled::Idle(IDLE)));
}

#[tokio::test(start_paused = true)]
async fn a_slow_reply_in_flight_keeps_the_read_past_idle() {
    let read = cmux_deadline::Progress::new();
    let feeder = {
        let read = read.clone();
        tokio::spawn(async move {
            // A 1 MiB page at about 4 KiB/s: four minutes, far past the idle bound.
            for _ in 0..256 {
                tokio::time::sleep(Duration::from_secs(1)).await;
                read.bump_by(4 * 1024);
            }
        })
    };
    let answer = async {
        tokio::time::sleep(Duration::from_secs(257)).await;
        "page"
    };
    let out = peer_read(&read, IDLE, CAP, answer).await;
    feeder.abort();
    assert_eq!(out, Ok("page"));
    const { assert!(PEER_READ_STEP > 64 * 6, "a step stays above a ping budget") };
}

#[tokio::test(start_paused = true)]
async fn a_busy_link_without_an_answer_ends_at_the_cap() {
    let read = cmux_deadline::Progress::new();
    let traffic = {
        let read = read.clone();
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                read.bump_by(PEER_READ_STEP);
            }
        })
    };
    let started = tokio::time::Instant::now();
    let out = peer_read(&read, IDLE, CAP, std::future::pending::<()>()).await;
    traffic.abort();
    assert_eq!(out, Err(ReadStalled::Cap(CAP)));
    assert!(started.elapsed() <= CAP + Duration::from_secs(4));
}
