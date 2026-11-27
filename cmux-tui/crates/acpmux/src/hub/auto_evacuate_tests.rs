//! The daemon side of automatic evacuation, end to end with fakes: a real hub with real chats, a
//! fake budget source and a fake target that records what it was asked to take. Nothing here
//! moves a real chat.

use super::*;
use crate::clock::ManualClock;
use crate::host_pressure::Level;
use serde_json::json;
use std::sync::Mutex as StdMutex;

/// A target that takes every chat it is handed and records which.
#[derive(Default)]
struct FakeTarget {
    took: StdMutex<Vec<String>>,
    refuse: bool,
}

impl Mover for FakeTarget {
    fn move_off<'a>(&'a self, id: &'a str) -> Boxed<'a, Result<String, String>> {
        Box::pin(async move {
            if self.refuse {
                return Err("no machine has room".into());
            }
            self.took.lock().unwrap().push(id.to_owned());
            Ok("fake-target".into())
        })
    }
}

impl FakeTarget {
    fn took(&self) -> Vec<String> {
        self.took.lock().unwrap().clone()
    }
}

/// A budget that reads whatever the test sets.
struct FakeBudget(StdMutex<Option<Level>>);

impl BudgetSource for FakeBudget {
    fn read(&self) -> Boxed<'_, Option<Reading>> {
        let level = *self.0.lock().unwrap();
        Box::pin(async move { level.map(reading_at) })
    }
}

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({"schema": META_SCHEMA, "id": id, "name": id, "harness": "fake",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1}))
    .unwrap()
}

fn running_turn(seq: u64) -> TurnInfo {
    TurnInfo {
        trigger: false,
        started_at: 1,
        client: "test".into(),
        prompt_preview: String::new(),
        masked_preview: String::new(),
        turn_id: "turn-busy".into(),
        prompt_id: "prompt-busy".into(),
        turn_seq: seq,
        control: Control::Web,
        doing: Default::default(),
        notice: false,
        persons: false,
        accepted: true,
        device: None,
    }
}

/// A hub on a manual clock with chats `idle-a`, `idle-b` (idle since 0 and 60 s), `busy` (a
/// running turn) and `watched` (a client shows it), and `autoEvacuate` as `setting`.
fn fixture(setting: Value) -> (Arc<Hub>, Arc<ManualClock>) {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    cfg.auto_evacuate = serde_json::from_value(setting).unwrap();
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    for id in ["idle-a", "idle-b", "busy", "watched"] {
        store.save(&meta(id)).unwrap();
    }
    let hub = Hub::new(cfg, store);
    let clock = ManualClock::new();
    hub.set_clock(clock.clone());
    for (id, idle_since) in [("idle-a", 0), ("idle-b", 60), ("busy", 0), ("watched", 0)] {
        let s = hub.resolve(id).unwrap();
        s.last_active
            .store(std::time::Duration::from_secs(idle_since).as_nanos() as u64, Ordering::SeqCst);
    }
    let busy = hub.resolve("busy").unwrap();
    let seq = hub.append(&busy, "mux", "turn_started", json!({"turnId": "turn-busy"})).seq;
    *busy.turn.lock().unwrap() = Some(running_turn(seq));
    let watched = hub.resolve("watched").unwrap();
    watched.attached.fetch_add(1, Ordering::SeqCst);
    // Every chat has been idle (or running) for ten minutes when the test starts.
    clock.advance(std::time::Duration::from_secs(10 * 60));
    (hub, clock)
}

fn notes(hub: &Hub, id: &str) -> Vec<Value> {
    let s = hub.resolve(id).unwrap();
    hub.store
        .events(&s.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == NOTE_KIND)
        .map(|e| e.msg)
        .collect()
}

/// Ticks every 15 s on the hub clock, `n` times, at `level`; returns the moves of each tick.
async fn ticks(
    ev: &mut Evacuator,
    hub: &Hub,
    clock: &ManualClock,
    level: Level,
    n: usize,
    target: &FakeTarget,
) -> Vec<Vec<String>> {
    let mut out = Vec::new();
    for _ in 0..n {
        clock.advance(TICK);
        let plan = ev.tick(hub, Some(reading_at(level)), target).await;
        out.push(plan.moves.into_iter().map(|m| m.id).collect());
    }
    out
}

#[tokio::test]
async fn sustained_over_budget_moves_one_idle_chat_and_leaves_the_busy_one() {
    let (hub, clock) = fixture(json!({"enabled": true}));
    let target = FakeTarget::default();
    let mut ev = Evacuator::default();
    // Over for less than the 120 s hold: nothing moves.
    let early = ticks(&mut ev, &hub, &clock, Level::Warning, 7, &target).await;
    assert!(early.iter().all(Vec::is_empty), "{early:?}");
    assert!(target.took().is_empty());
    // Held: the chat idle longest moves first, one a tick; the busy and watched ones never.
    let later = ticks(&mut ev, &hub, &clock, Level::Warning, 10, &target).await;
    assert_eq!(target.took(), ["idle-a", "idle-b"], "{later:?}");
    assert!(!target.took().iter().any(|id| id == "busy" || id == "watched"));
    assert!(notes(&hub, "busy").is_empty());

    let note = &notes(&hub, "idle-a")[0];
    let text = note["text"].as_str().unwrap();
    assert!(text.contains("Moved off this machine automatically"), "{text}");
    assert!(text.contains("over budget"), "{text}");
    assert_eq!(note["back"], json!("cmux move idle-a --from MACHINE --to here"));
}

#[tokio::test]
async fn a_moved_chat_is_not_tried_again_and_recovery_stops_the_moves() {
    let (hub, clock) = fixture(json!({"enabled": true, "holdSecs": 0}));
    let target = FakeTarget { refuse: true, ..FakeTarget::default() };
    let mut ev = Evacuator::default();
    let moves = ticks(&mut ev, &hub, &clock, Level::Critical, 4, &target).await;
    // Each idle chat is tried once; refused, it stays and says why, and is not tried again.
    assert_eq!(moves.concat(), ["idle-a", "idle-b"], "{moves:?}");
    let notes = notes(&hub, "idle-a");
    assert_eq!(notes.len(), 2, "{notes:?}");
    assert_eq!(notes[1]["failed"], json!("no machine has room"));
    // Back within budget (the level falls after two calm readings, `Tracker`): nothing more,
    // even once the cooldown is over.
    let calm = ticks(&mut ev, &hub, &clock, Level::Normal, 3, &target).await;
    assert!(calm.iter().all(Vec::is_empty), "{calm:?}");
    clock.advance(std::time::Duration::from_secs(31 * 60));
    let calm = ticks(&mut ev, &hub, &clock, Level::Normal, 8, &target).await;
    assert!(calm.iter().all(Vec::is_empty), "{calm:?}");
}

#[tokio::test]
async fn off_moves_nothing() {
    let (hub, clock) = fixture(json!({}));
    assert!(!hub.config.read().await.auto_evacuate.enabled, "off is the default");
    let target = FakeTarget::default();
    let mut ev = Evacuator::default();
    let moves = ticks(&mut ev, &hub, &clock, Level::Critical, 20, &target).await;
    assert!(moves.iter().all(Vec::is_empty));
    assert!(target.took().is_empty());
}

#[tokio::test]
async fn a_kept_chat_stays() {
    let (hub, clock) = fixture(json!({"enabled": true, "holdSecs": 0, "keep": ["idle-a"]}));
    let target = FakeTarget::default();
    let mut ev = Evacuator::default();
    ticks(&mut ev, &hub, &clock, Level::Critical, 4, &target).await;
    assert_eq!(target.took(), ["idle-b"]);
}

#[tokio::test(start_paused = true)]
async fn the_timer_moves_through_the_fakes_and_ends_once_the_setting_is_off() {
    let (hub, _clock) = fixture(json!({"enabled": true, "holdSecs": 0}));
    let budget = FakeBudget(StdMutex::new(Some(Level::Critical)));
    let target = Arc::new(FakeTarget::default());
    let weak = Arc::downgrade(&hub);
    let looped = {
        let target = target.clone();
        tokio::spawn(async move {
            let budget = budget;
            auto_evacuate_loop(weak, &budget, &*target).await;
        })
    };
    // The manual hub clock does not move, so both idle chats are ten minutes idle: two ticks.
    tokio::time::sleep(TICK * 3).await;
    assert_eq!(target.took(), ["idle-a", "idle-b"]);
    hub.config.write().await.auto_evacuate.enabled = false;
    tokio::time::timeout(TICK * 2, looped).await.expect("off ends the timer").unwrap();
}

#[tokio::test]
async fn off_starts_no_timer() {
    let (hub, _clock) = fixture(json!({}));
    hub.start_auto_evacuate().await;
    assert!(!RUNNING.load(Ordering::SeqCst), "no timer runs while the setting is off");
}
