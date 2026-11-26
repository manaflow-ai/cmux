use super::WallClock;
use crate::trace::Trace;
use std::time::{Duration, UNIX_EPOCH};

#[tokio::test(start_paused = true)]
async fn the_wall_clock_jumps_and_monotonic_time_does_not() {
    let clock = WallClock::starting_at(UNIX_EPOCH + Duration::from_secs(1_000), &Trace::new());
    let mono = tokio::time::Instant::now();
    tokio::time::sleep(Duration::from_millis(1_500)).await;
    assert_eq!(clock.unix_seconds(), 1_001);
    assert_eq!(clock.unix_seconds_ceil(), 1_002);
    clock.jump_forward(Duration::from_secs(7_200));
    assert_eq!(clock.unix_seconds(), 8_201);
    assert_eq!(mono.elapsed(), Duration::from_millis(1_500));
    clock.jump_back(Duration::from_secs(7_200));
    assert_eq!(clock.unix_seconds(), 1_001);
}
