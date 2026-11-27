//! The admission lease charges the runtime's time, not the wall's (RFD 0124: starved is slow,
//! never dead). Leo's Mac, 2026-11-27, load 187 on 15 cores: "prompt admission lease lapsed"
//! 388 times, 346 of them in the setup step, each holder still alive.

use super::*;
use crate::hub::{Hub, NewRequest};

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// Lets the lease task run what the clock made due.
async fn settle() {
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
}

/// Moves the paused clock `total` in steps of `step`, the runtime answering after each.
async fn run_for(total: Duration, step: Duration) {
    let mut moved = Duration::ZERO;
    while moved < total {
        tokio::time::advance(step).await;
        settle().await;
        moved += step;
    }
}

async fn held_admission() -> (Arc<Hub>, Arc<Admission>) {
    let (hub, s) = chat().await;
    tokio::time::pause();
    let admission = admit(&s, &hub.scope, Instant::now()).await;
    assert!(admission.held(), "an uncontended prompt holds its admission");
    (hub, admission)
}

/// The runtime ran nothing for 4 s (a host at load 187): the live holder keeps its place. Before,
/// the 3 s wall-clock lease let it go the moment the runtime came back.
#[tokio::test]
async fn a_starved_runtime_does_not_lapse_a_live_holders_lease() {
    let (_hub, admission) = held_admission().await;
    tokio::time::advance(Duration::from_secs(4)).await;
    settle().await;
    assert!(admission.held(), "4 s the runtime gave no task is starvation, not a stuck holder");
    // Starved again and again, it is charged only the ticks the runtime ran.
    for _ in 0..4 {
        tokio::time::advance(Duration::from_secs(2)).await;
        settle().await;
    }
    assert!(admission.held(), "12 s of starvation in four stalls charges about 1.5 s");
}

/// A holder stuck on an await while the runtime answers is let go after the bound, as before.
#[tokio::test]
async fn a_stuck_holder_on_a_responsive_runtime_lapses_at_the_bound() {
    let (_hub, admission) = held_admission().await;
    run_for(ADMISSION_BOUND - LEASE_TICK, Duration::from_millis(50)).await;
    assert!(admission.held(), "under the bound it still holds");
    run_for(LEASE_TICK * 2, Duration::from_millis(50)).await;
    assert!(!admission.held(), "past the bound of runtime time it is let go");
}

/// However starved the host, the wall cap lets a holder go.
#[tokio::test]
async fn a_holder_on_a_host_starved_for_good_lapses_at_the_wall_cap() {
    let (_hub, admission) = held_admission().await;
    let stall = Duration::from_secs(5);
    let mut wall = Duration::ZERO;
    while wall + stall < LEASE_WALL_CAP {
        tokio::time::advance(stall).await;
        settle().await;
        wall += stall;
    }
    assert!(admission.held(), "under the wall cap it still holds");
    tokio::time::advance(stall).await;
    settle().await;
    assert!(!admission.held(), "past the wall cap it is let go");
}

/// A holder that let go ends its lease task at its next tick.
#[tokio::test]
async fn a_released_admission_ends_its_lease_at_once() {
    let (_hub, admission) = held_admission().await;
    admission.release();
    run_for(LEASE_TICK * 2, LEASE_TICK).await;
    assert!(!admission.held());
}
