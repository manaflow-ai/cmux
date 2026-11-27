//! Drive an automatic restart through the real idle reaper with an injected clock.
use acpmux::{clock::ManualClock, hub::Hub};
use std::{sync::Arc, time::Duration};

pub fn clock(hub: &Arc<Hub>) -> Arc<ManualClock> {
    let clock = ManualClock::new();
    hub.set_clock(clock.clone());
    clock
}

pub async fn hibernate(hub: &Arc<Hub>, id: &str, clock: &ManualClock) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        clock.advance(Duration::from_secs(31));
        if hub.resolve(id).unwrap().meta().hibernated_ms != 0 {
            return;
        }
        assert!(tokio::time::Instant::now() < deadline, "automatic restart never hibernated");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}
