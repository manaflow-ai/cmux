//! A peer's reconnect loop (`Peer::run`) through a long outage, in ticked time: every dial fails
//! at once (`peer::test_dial`), tokio's clock is paused, the wall clock follows it, and jitter is
//! seeded. A day and more of backoff, the hourly park after a day down
//! (`peer_link::Link::retry_delay`) and a laptop sleep in the middle of a wait run in
//! milliseconds, and the same seed gives the same schedule.

use crate::peer::{Peer, test_dial};
use crate::peer_link::{Backoff, SleepWatch, test_jitter};
use crate::store::test_clock;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const DAY: Duration = Duration::from_secs(24 * 60 * 60);
const PARK: Duration = Duration::from_secs(3_600);
const PARK_JITTER: Duration = Duration::from_secs(60);
/// Tokio's timer wheel rounds a deadline up to the next millisecond.
const TICK: Duration = Duration::from_millis(2);

/// A peer with nothing behind it: its notices go nowhere, its dials all fail.
fn unreachable() -> Arc<Peer> {
    let (tx, rx) = mpsc::channel(1);
    drop(rx);
    Peer::new("gone", "ws://127.0.0.1:9", None, None, tx)
}

/// Runs a peer down for `outage` of ticked time and returns the gaps between its dials, each
/// with how long the link had been down (wall clock) when that gap was chosen.
async fn ladder(seed: u64, outage: Duration) -> Vec<(Duration, Duration)> {
    test_clock::follow_tokio();
    test_jitter::seed(seed);
    test_dial::refuse_all();
    let peer = unreachable();
    let run = tokio::spawn(peer.clone().run());
    tokio::time::sleep(outage).await;
    peer.stop();
    run.await.unwrap();
    let attempts = test_dial::attempts();
    test_dial::clear();
    test_jitter::clear();
    test_clock::reset();
    let first_wall = attempts[0].1;
    attempts
        .windows(2)
        .map(|w| (w[1].0 - w[0].0, Duration::from_millis(w[0].1 - first_wall)))
        .collect()
}

/// 26 hours down: the doubling ladder from 500 ms to the 60 s cap, each step in its upper half,
/// then one attempt an hour (plus up to a minute) once a day has passed, the same draws for the
/// same seed, and all of it in well under a second of wall time.
#[tokio::test(start_paused = true)]
async fn a_day_down_runs_the_whole_reconnect_ladder_in_milliseconds() {
    let outage = DAY + Duration::from_secs(2 * 60 * 60);
    let wall = std::time::Instant::now();
    let gaps = ladder(7, outage).await;
    let took = wall.elapsed();

    let mut parked = 0;
    for (i, (gap, down_for)) in gaps.iter().copied().enumerate() {
        if down_for + Duration::from_secs(1) < DAY {
            let step = Backoff::BASE.saturating_mul(1 << i.min(16)).min(Backoff::CAP);
            assert!(
                gap + TICK >= step / 2 && gap <= step + TICK,
                "gap {i} is {gap:?}, outside the upper half of its {step:?} step"
            );
        } else if down_for > DAY + Duration::from_secs(1) {
            assert!(
                gap + TICK >= PARK && gap <= PARK + PARK_JITTER + TICK,
                "gap {i}, {down_for:?} down, is {gap:?}: a day down retries hourly"
            );
            parked += 1;
        }
    }
    let laddered = gaps.iter().filter(|(_, down)| *down < DAY).count();
    // At the cap a gap is 30 to 60 s, so a day holds 1,440 to 2,880 of them.
    assert!((1_440..=2_880).contains(&laddered), "{laddered} attempts in the first day");
    assert!((1..=2).contains(&parked), "{parked} parked attempts in the 2 h after the day");
    // The gaps are ticked time and replay exactly: the followed wall clock is ticked time too
    // (`test_clock::followed_now_ms`), so the day is reached on the same attempt in each run,
    // however long the run takes on a loaded host.
    let schedule = |gaps: &[(Duration, Duration)]| gaps.iter().map(|g| g.0).collect::<Vec<_>>();
    let replay = ladder(7, outage).await;
    assert_eq!(schedule(&gaps), schedule(&replay), "a seed replays its schedule exactly");
    let other = ladder(8, outage).await;
    assert_ne!(schedule(&gaps), schedule(&other), "another seed draws another schedule");
    eprintln!(
        "reconnect ladder: {:?} of outage, {} dials ({laddered} in the first day, {parked} parked) in {took:?} wall",
        outage,
        gaps.len() + 1
    );
    assert!(took < Duration::from_secs(5), "26 h of reconnects took {took:?} of wall time");
}

/// A laptop that sleeps through a capped backoff wait redials at the wake, within one clock
/// check, and its ladder starts over from `Backoff::BASE` (`BackoffWait::Woke`).
#[tokio::test(start_paused = true)]
async fn a_sleep_in_a_backoff_wait_redials_at_the_wake_and_starts_the_ladder_over() {
    test_clock::follow_tokio();
    test_jitter::seed(11);
    test_dial::refuse_all();
    let peer = unreachable();
    let run = tokio::spawn(peer.clone().run());
    // Ten minutes down: the waits are at the cap.
    tokio::time::sleep(Duration::from_secs(600)).await;
    let before = test_dial::attempts().len();
    // The lid closes for an hour: the wall clock jumps, the monotonic one does not.
    let slept_at = tokio::time::Instant::now();
    test_clock::advance(60 * 60 * 1_000);
    tokio::time::sleep(Duration::from_secs(10)).await;
    peer.stop();
    run.await.unwrap();
    let attempts = test_dial::attempts();
    test_dial::clear();
    test_jitter::clear();
    test_clock::reset();

    let woke = attempts[before].0;
    assert!(
        woke - slept_at <= SleepWatch::EVERY + TICK,
        "the first dial after the wake came {:?} after it",
        woke - slept_at
    );
    let next = attempts[before + 1].0 - woke;
    assert!(next <= Backoff::BASE + TICK, "the ladder starts over at the wake: {next:?}");
}

/// A peer down for `minutes` of ticked time while a chat stays open on it and asks every second
/// (a person typing, a pane retrying its read): the dials it made in that time.
async fn dials_while_asked(seed: u64, minutes: u64, login_refused: bool) -> usize {
    let refuse = if login_refused { test_dial::refuse_login_all } else { test_dial::refuse_all };
    asked_attempts(seed, minutes, refuse).await.len()
}

/// The dials of a peer down for `minutes` while a chat asks every second, each dial failing as
/// `refuse` sets up.
async fn asked_attempts(seed: u64, minutes: u64, refuse: fn()) -> Vec<test_dial::Attempt> {
    test_clock::follow_tokio();
    test_jitter::seed(seed);
    refuse();
    let peer = unreachable();
    // The loop runs beside the asks on this task, so it ends with them (`Peer::stop`).
    let asking = async {
        for _ in 0..minutes * 60 {
            peer.want();
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        peer.stop();
    };
    tokio::join!(peer.clone().run(), asking);
    let dials = test_dial::attempts();
    test_dial::clear();
    test_jitter::clear();
    test_clock::reset();
    dials
}

/// cosmic-gray, 2026-11-26: after one "Host key verification failed" the link stayed down
/// about 2 h with ssh working again, held by the refused login's hour-long backoff. A refused
/// host key neither redials each second while a chat asks nor waits longer than
/// `Backoff::HOST_KEY_REFUSED_CAP` (plus its jitter) between attempts.
#[tokio::test(start_paused = true)]
async fn a_refused_host_key_is_redialed_within_minutes_not_hours() {
    let attempts = asked_attempts(5, 60, test_dial::refuse_host_key_all).await;
    let ten_minutes =
        attempts.iter().filter(|a| a.0 - attempts[0].0 <= Duration::from_secs(600)).count();
    assert!(ten_minutes <= 12, "{ten_minutes} host-key dials in 10 minutes");
    assert!(attempts.len() >= 20, "{} host-key dials in an hour", attempts.len());
    let most = Backoff::HOST_KEY_REFUSED_CAP + Backoff::HOST_KEY_REFUSED_CAP / 5 + TICK;
    for pair in attempts.windows(2) {
        let gap = pair[1].0 - pair[0].0;
        assert!(gap <= most, "a refused host key waited {gap:?} for its next dial");
    }
}

/// A remote that refuses this computer's key or password is not dialed again in a loop, however
/// often a chat on it asks: each refused login counts against the remote's own limit
/// (a ban tool blocks an address after a few in 10 minutes), and a redial each
/// second got a computer's address blocked. A wrong key does not fix itself in a second; the
/// attempts space out to minutes, and an explicit reconnect still tries at once.
#[tokio::test(start_paused = true)]
async fn a_refused_ssh_login_is_not_redialed_in_a_loop_while_a_chat_asks() {
    let ten_minutes = dials_while_asked(5, 10, true).await;
    assert!(ten_minutes <= 3, "{ten_minutes} refused logins in 10 minutes");
    let hour = dials_while_asked(5, 60, true).await;
    assert!(hour <= 6, "{hour} refused logins in an hour");
}

/// A link that is down for any other reason (a host that is off, a dead network) still redials
/// within a second while a chat asks: only a refused login waits.
#[tokio::test(start_paused = true)]
async fn an_unreachable_peer_a_chat_asks_for_still_redials_each_second() {
    let dials = dials_while_asked(5, 10, false).await;
    assert!(dials >= 300, "{dials} dials in 10 minutes while asked");
}
