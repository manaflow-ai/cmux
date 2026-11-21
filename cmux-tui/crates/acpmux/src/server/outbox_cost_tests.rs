//! What the outbox's work costs with many messages waiting for a peer that is down: a daemon at
//! 110% CPU while lanes reported to coordinators on flaky peers. With 4,000 waiting, each attempt
//! opened a connection to this daemon, walked every delivery kept for each of its changes and woke
//! every `send_status` wait; the attempts to one target ran side by side. Measured at 100 and
//! 4,000 waiting, the work an attempt does must be the same, and one target has one attempt at
//! a time.

use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::outbox::Stats;

/// This daemon with `gone`, a peer that is down, and `n` messages to its sessions handed to the
/// outbox (32 targets, as lanes to their coordinators), each having had its first attempt. The
/// counts of that work, per message, and the count of `send_status` wakes of a wait on a message
/// none of the attempts touch.
struct Cost {
    visits: f64,
    connections: f64,
    most_in_flight: u64,
    wakes: u64,
}

async fn first_attempts(n: usize) -> Cost {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    hub.seed_down_peer("gone", vec![]);
    let now = crate::store::now_ms();
    let delivery = |id: String, target: String| Delivery {
        request: json!({"sessionId": target, "prompt": [{"type": "text", "text": "report"}],
                        "_meta": {"acpmux": {"promptId": format!("p-{id}")}}}),
        id,
        target,
        caller: None,
        unproven_caller: None,
        not_terminal: false,
        state: State::Queued,
        attempts: 0,
        never_sent: true,
        relay_post: None,
        open_on_peer: false,
        pin: None,
        proof: None,
        error: None,
        accepted: None,
        created_at: now,
        updated_at: now,
    };
    // A message nothing delivers, whose sender waits on its status.
    hub.outbox.add(delivery("watched".into(), "gone/watched".into())).unwrap();
    let waiting = {
        let hub = hub.clone();
        tokio::spawn(async move {
            let params = json!({"deliveryId": "watched", "waitMs": MAX_STATUS_WAIT_MS});
            outbox_status(&hub, "watched", &params).await
        })
    };
    let mut pending = Vec::with_capacity(n);
    for i in 0..n {
        let d = delivery(format!("d-{i:05}"), format!("gone/lane-{:03}", i % 32));
        pending.push(hub.outbox.add(d).unwrap());
    }
    let (visits, connections) = (hub.outbox.visits(), Stats::read(&hub.outbox.stats.connections));
    resume(&hub, pending);
    // Every message has had its first attempt, and waits for its retry.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
    loop {
        let (all, _) = hub.outbox.list(None, usize::MAX);
        let done = all
            .iter()
            .filter(|d| d.id != "watched")
            .all(|d| d.attempts >= 1 && d.state == State::Queued);
        if done {
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "the first attempts did not end");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let stats = &hub.outbox.stats;
    let cost = Cost {
        visits: (hub.outbox.visits() - visits) as f64 / n as f64,
        connections: (Stats::read(&stats.connections) - connections) as f64 / n as f64,
        most_in_flight: Stats::read(&stats.most_in_flight),
        wakes: Stats::read(&stats.status_wakes),
    };
    waiting.abort();
    cost
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_attempt_to_a_down_peer_costs_the_same_with_100_or_4000_waiting() {
    let small = first_attempts(100).await;
    let large = first_attempts(4_000).await;
    eprintln!(
        "per attempt: deliveries read {:.1} / {:.1}, connections {:.2} / {:.2}; most in flight \
         to one target {} / {}; status wakes {} / {} (100 / 4000 waiting)",
        small.visits,
        large.visits,
        small.connections,
        large.connections,
        small.most_in_flight,
        large.most_in_flight,
        small.wakes,
        large.wakes,
    );
    // The bookkeeping an attempt reads does not grow with what waits beside it.
    assert!(large.visits <= 2.0 * small.visits.max(8.0), "read {} per attempt", large.visits);
    // A peer that is down is known down here: no attempt opens a connection to find that out.
    assert!(large.connections <= 0.01, "{} connections per attempt", large.connections);
    // One attempt at a time for each target.
    assert_eq!(large.most_in_flight, 1, "attempts to one target ran side by side");
    // A wait on one message wakes for that message, not for every other's change.
    assert_eq!(large.wakes, 0, "a status wait woke {} times for other messages", large.wakes);
}
