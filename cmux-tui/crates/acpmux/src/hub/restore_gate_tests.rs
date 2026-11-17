//! Staged restore (`restore_gate.rs`): a restart lets restored chats start a stage at a time,
//! never past the lane cap, one at a time under pressure, and parks the rest with a reason.

use super::*;
use std::sync::atomic::AtomicUsize;

fn hub_with(n: usize) -> (Arc<Hub>, Vec<Arc<Session>>) {
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut sessions = Vec::new();
    for i in 0..n {
        let id = format!("chat-{i}");
        let meta: SessionMeta = serde_json::from_value(json!({
            "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/w",
            "status": "idle", "createdAt": 1, "updatedAt": 1,
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(id, session.clone());
        sessions.push(session);
    }
    (hub, sessions)
}

/// Every chat's restored prompt waits at the gate, as `start_restored` makes them; the count
/// is how many got through.
fn restore_all(hub: &Arc<Hub>, sessions: &[Arc<Session>]) -> Arc<AtomicUsize> {
    let through = Arc::new(AtomicUsize::new(0));
    for session in sessions {
        hub.restore_gate.count_restored();
        let (hub, session, through) = (hub.clone(), session.clone(), through.clone());
        tokio::spawn(async move {
            hub.admit_restored(&session).await;
            through.fetch_add(1, Ordering::SeqCst);
        });
    }
    through
}

fn fake(hub: &Hub, f: impl Fn(usize) -> Reading + Send + Sync + 'static) {
    *hub.restore_gate.fake.lock().unwrap() = Some(Arc::new(f));
}

async fn run_for(d: Duration) {
    let end = tokio::time::Instant::now() + d;
    while tokio::time::Instant::now() < end {
        tokio::time::advance(Duration::from_millis(500)).await;
        tokio::task::yield_now().await;
    }
}

fn reading(live: usize, cap: Option<u64>, over: &[&str]) -> Reading {
    Reading { live, cap, over: over.iter().map(|s| (*s).to_owned()).collect(), cores: 16 }
}

#[test]
fn a_stage_is_a_few_chats_and_never_past_the_cap() {
    assert_eq!(stage_size(2), 2);
    assert_eq!(stage_size(16), 2);
    assert_eq!(stage_size(32), 4);
    assert_eq!(decide(&reading(0, Some(12), &[]), 100), Step::Admit(2));
    assert_eq!(decide(&reading(11, Some(12), &[]), 100), Step::Admit(1));
    assert_eq!(decide(&reading(0, None, &[]), 1), Step::Admit(1));
    let Step::Park(why) = decide(&reading(45, Some(12), &[]), 100) else { panic!("parks") };
    assert!(why.contains("45 live sessions at its lane cap of 12"), "{why}");
    let Step::Hold(why) = decide(&reading(3, Some(12), &["load1 274.0 >= 32 (32 cores)"]), 9)
    else {
        panic!("holds")
    };
    assert!(why.contains("load1 274.0"), "{why}");
    assert!(matches!(decide(&reading(0, None, &["available RAM 3% < 10%"]), 9), Step::Hold(_)));
}

/// The 2026-11-16 restart: about 100 chats came back at once on a host whose cap is 12.
#[tokio::test(start_paused = true)]
async fn a_restart_of_100_chats_starts_a_stage_at_a_time_and_parks_past_the_cap() {
    let (hub, sessions) = hub_with(100);
    fake(&hub, |through| reading(through, Some(12), &[]));
    let through = restore_all(&hub, &sessions);
    tokio::task::yield_now().await;
    run_for(Duration::from_millis(100)).await;
    assert_eq!(through.load(Ordering::SeqCst), 2, "the first stage only");
    run_for(Duration::from_secs(120)).await;
    assert_eq!(through.load(Ordering::SeqCst), 12, "up to the cap, never past it");
    let status = hub.restore_gate.status();
    assert_eq!(status["parked"].as_array().unwrap().len(), 88, "{status}");
    assert_eq!(status["waiting"], 88);
    assert!(status["holding"].as_str().unwrap().contains("lane cap of 12"), "{status}");
    // Each parked chat says why in its own log.
    let filter = EventFilter::parse(Some(&json!(["restore_parked"]))).unwrap();
    let parked = &sessions[99];
    let page = hub.events_page(&parked.id, 0, None, 10, None, false, &filter).unwrap();
    let reason = page.events.first().map(|e| e.msg["reason"].clone()).unwrap_or_default();
    assert!(reason.as_str().unwrap_or_default().contains("lane cap of 12"), "{reason}");
}

#[tokio::test(start_paused = true)]
async fn a_parked_chat_starts_when_a_slot_frees() {
    let (hub, sessions) = hub_with(20);
    let ended = Arc::new(AtomicUsize::new(0));
    let e = ended.clone();
    fake(&hub, move |through| reading(through - e.load(Ordering::SeqCst), Some(12), &[]));
    let through = restore_all(&hub, &sessions);
    run_for(Duration::from_secs(120)).await;
    assert_eq!(through.load(Ordering::SeqCst), 12);
    ended.store(3, Ordering::SeqCst);
    run_for(Duration::from_secs(60)).await;
    assert_eq!(through.load(Ordering::SeqCst), 15, "three slots freed, three more started");
    assert_eq!(hub.restore_gate.status()["parked"].as_array().unwrap().len(), 5);
}

/// A busy host makes restore slower, never stuck: one chat per `TRICKLE` while over budget.
#[tokio::test(start_paused = true)]
async fn under_pressure_one_chat_still_starts_per_trickle() {
    let (hub, sessions) = hub_with(10);
    fake(&hub, |through| reading(through, None, &["load1 274.0 >= 32 (32 cores)"]));
    let through = restore_all(&hub, &sessions);
    run_for(Duration::from_secs(30)).await;
    assert_eq!(through.load(Ordering::SeqCst), 0, "the first trickle is a minute out");
    run_for(Duration::from_secs(200)).await;
    let n = through.load(Ordering::SeqCst);
    assert!((2..=4).contains(&n), "about one a minute, got {n}");
    assert!(hub.restore_gate.status()["holding"].as_str().unwrap().contains("headroom"));
}

#[tokio::test(start_paused = true)]
async fn with_headroom_and_no_cap_every_chat_starts_and_spares_wait_for_it() {
    let (hub, sessions) = hub_with(30);
    fake(&hub, |through| reading(through, None, &[]));
    let through = restore_all(&hub, &sessions);
    let spares_after = Arc::new(AtomicUsize::new(usize::MAX));
    {
        let (hub, through, spares_after) = (hub.clone(), through.clone(), spares_after.clone());
        tokio::spawn(async move {
            hub.restore_gate.wait_drained().await;
            spares_after.store(through.load(Ordering::SeqCst), Ordering::SeqCst);
        });
    }
    run_for(Duration::from_secs(300)).await;
    assert_eq!(through.load(Ordering::SeqCst), 30);
    // `wait_drained` wakes in the same step as the last release; the count it read is 29 or 30.
    assert!(spares_after.load(Ordering::SeqCst) >= 29);
    let status = hub.restore_gate.status();
    assert_eq!(status["drained"], true, "{status}");
    assert_eq!(status["stages"], 15, "two a stage on 16 cores");
}

#[tokio::test(start_paused = true)]
async fn nothing_restored_is_drained_at_once() {
    let (hub, _) = hub_with(0);
    tokio::time::timeout(Duration::from_secs(1), hub.restore_gate.wait_drained())
        .await
        .expect("drained");
    assert_eq!(hub.restore_gate.status()["drained"], true);
}
