use std::cell::Cell;

thread_local!(static AHEAD_MS: Cell<u64> = const { Cell::new(0) });
// Followed: tokio's instant and the real wall time (ms) at the follow.
thread_local!(static FOLLOW: Cell<Option<(tokio::time::Instant, u64)>> = const { Cell::new(None) });

pub(crate) fn ahead_ms() -> u64 {
    AHEAD_MS.with(Cell::get)
}

/// This thread's wall clock while it follows tokio: the wall time at the follow, the ticked
/// time since and what it was moved. None when it does not follow.
pub(crate) fn followed_now_ms() -> Option<u64> {
    let (origin, wall) = FOLLOW.with(Cell::get)?;
    let ticked = u64::try_from(origin.elapsed().as_millis()).unwrap_or(u64::MAX);
    Some(wall.saturating_add(ticked).saturating_add(ahead_ms()))
}

/// Moves this thread's clock `ms` ahead. With `follow_tokio` on, this is the computer
/// sleeping: the wall clock runs ahead of the monotonic one (`peer_link::SleepWatch`).
pub(crate) fn advance(ms: u64) {
    AHEAD_MS.with(|a| a.set(a.get() + ms));
}

/// From now on this thread's wall clock moves with tokio's, so a test under
/// `start_paused` runs a day of wall-clock rules (a peer parked after a day down) in
/// milliseconds, with the wall and monotonic clocks in step as on an awake computer.
pub(crate) fn follow_tokio() {
    let wall = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX));
    FOLLOW.with(|f| f.set(Some((tokio::time::Instant::now(), wall))));
}

/// Back to the real wall clock.
pub(crate) fn reset() {
    AHEAD_MS.with(|a| a.set(0));
    FOLLOW.with(|f| f.set(None));
}

/// A followed clock is ticked time only: the real milliseconds a run takes, more on a loaded
/// host, never move it, so the wall-clock rules a test drives (a peer parked after a day
/// down) fall on the same tick in every run (`stress::reconnect`, "a seed replays its
/// schedule exactly", failed at 9dc6d10f under load 22-60).
#[tokio::test(start_paused = true)]
async fn a_followed_clock_moves_with_ticked_time_only() {
    follow_tokio();
    let before = super::now_ms();
    // Real time passes, as when a loaded host deschedules the test; tokio's paused clock
    // does not (no await, so it cannot auto-advance).
    let real = std::time::Instant::now();
    while real.elapsed() < std::time::Duration::from_millis(20) {
        std::hint::spin_loop();
    }
    let after_real = super::now_ms();
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    let after_tick = super::now_ms();
    advance(5_000);
    let after_sleep = super::now_ms();
    reset();
    assert_eq!(after_real, before, "20 ms of real time moved the followed clock");
    assert_eq!(after_tick, before + 1_000, "1 s of ticked time");
    assert_eq!(after_sleep, before + 6_000, "a computer sleep still runs the wall clock ahead");
}
