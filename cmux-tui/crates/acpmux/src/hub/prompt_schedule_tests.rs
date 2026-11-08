//! A chat's scheduled prompt (`prompt_schedule.rs`), on a fake wall clock and the manual hub
//! clock: it sends into the chat through the person's path, ends on its stop, waits for a busy
//! chat, and comes back after a daemon restart.

use super::*;
use crate::clock::ManualClock;
use crate::config::{Config, StoreMode};
use crate::prompt_schedule::{IDLE_GRACE_MS, Request, Trigger};
use std::path::Path;
use std::sync::atomic::AtomicU64;

const T0: u64 = 1_800_000_000_000;
const MIN: u64 = 60_000;

struct Clocks {
    wall: Arc<AtomicU64>,
    mono: Arc<ManualClock>,
}

impl Clocks {
    fn advance(&self, ms: u64) {
        self.wall.fetch_add(ms, Ordering::SeqCst);
        self.mono.advance(std::time::Duration::from_millis(ms));
    }
    fn now(&self) -> u64 {
        self.wall.load(Ordering::SeqCst)
    }
}

fn config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg
}

fn clocks(hub: &Hub) -> Clocks {
    let wall = Arc::new(AtomicU64::new(T0));
    let mono = ManualClock::new();
    let read = wall.clone();
    hub.set_schedule_wall(Arc::new(move || read.load(Ordering::SeqCst)));
    *hub.clock.lock().unwrap() = mono.clone() as Arc<dyn crate::clock::Clock>;
    Clocks { wall, mono }
}

/// A hub with one open chat whose stand-in agent is running, on fake clocks.
async fn chat() -> (Arc<Hub>, Arc<Session>, Clocks) {
    let store = crate::store::open(&config().store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config(), store);
    let clocks = clocks(&hub);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session, clocks)
}

fn every(minutes: u64, max_runs: Option<u32>) -> Request {
    Request { prompt: "check CI".into(), trigger: Trigger::Every { minutes }, max_runs, until: None }
}

/// Whether the chat's log holds a prompt the schedule `id` sent, named as the schedule's.
fn sent_by_schedule(hub: &Hub, session: &Session, id: &str) -> bool {
    hub.events(&session.id, 0, 10_000).unwrap().into_iter().any(|e| {
        let m = e.msg.to_string();
        e.kind != "session_info_update" && m.contains(&format!("{id}-run-1")) && m.contains("\"kind\":\"schedule\"")
    })
}

/// Waits (at most 10 s) until `n` turns have ended and none runs.
async fn turns_reach(session: &Session, n: u64) {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while session.meta().turn_count < n || session.turn().is_some() {
        assert!(tokio::time::Instant::now() < deadline, "turn {n} never ended");
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}

fn logged_schedules(hub: &Hub, session: &Session) -> Vec<Value> {
    hub.events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "in" && e.kind == "session_info_update")
        .filter_map(|e| e.msg.pointer("/params/update/_meta/schedule").cloned())
        .collect()
}

#[tokio::test]
async fn an_every_schedule_sends_on_time_and_ends_after_its_runs() {
    let (hub, session, clocks) = chat().await;
    let set = hub.schedule_set(&session, every(5, Some(2))).unwrap();
    let id = set["id"].as_str().unwrap().to_owned();
    assert_eq!(set["nextRunAt"], json!(T0 + 5 * MIN));
    assert_eq!(hub.run_due_schedules(clocks.now()), Some(T0 + 5 * MIN), "nothing is due yet");
    assert_eq!(session.meta().turn_count, 0);

    clocks.advance(5 * MIN);
    assert_eq!(hub.run_due_schedules(clocks.now()), Some(T0 + 10 * MIN));
    turns_reach(&session, 1).await;
    assert_eq!(session.meta().prompt_schedule.unwrap().runs, 1);

    clocks.advance(5 * MIN);
    assert_eq!(hub.run_due_schedules(clocks.now()), None, "its last run");
    turns_reach(&session, 2).await;
    assert_eq!(session.meta().prompt_schedule, None, "it ended with its second run");
    assert!(sent_by_schedule(&hub, &session, &id), "it went in as the schedule's prompt");
    assert_eq!(logged_schedules(&hub, &session).last(), Some(&Value::Null), "clients see it end");
}

#[tokio::test]
async fn the_timer_task_fires_on_the_hub_clock() {
    let (hub, session, clocks) = chat().await;
    hub.schedule_set(&session, every(1, Some(1))).unwrap();
    // The timer task takes its wake and waits for the run on the manual clock.
    for _ in 0..5 {
        tokio::task::yield_now().await;
    }
    assert_eq!(session.meta().turn_count, 0);
    clocks.advance(MIN);
    turns_reach(&session, 1).await;
    assert_eq!(session.meta().prompt_schedule, None);
}

#[tokio::test]
async fn a_busy_chat_holds_the_run_until_its_turn_ends() {
    let (hub, session, clocks) = chat().await;
    hub.schedule_set(&session, every(5, None)).unwrap();
    clocks.advance(5 * MIN);
    // A turn is running: the due run waits rather than queueing behind it.
    session.harness_turn.store(true, Ordering::SeqCst);
    hub.run_due_schedules(clocks.now());
    assert_eq!(session.meta().prompt_schedule.as_ref().unwrap().runs, 0);
    session.harness_turn.store(false, Ordering::SeqCst);
    // The turn's end: it looks again once the turn settled, then sends.
    hub.prompt_schedule_turn_ended(&session);
    assert_eq!(hub.run_due_schedules(clocks.now()), Some(clocks.now() + SETTLE_MS));
    assert_eq!(session.meta().prompt_schedule.as_ref().unwrap().runs, 0);
    clocks.advance(SETTLE_MS);
    hub.run_due_schedules(clocks.now());
    assert_eq!(session.meta().prompt_schedule.as_ref().unwrap().runs, 1);
    turns_reach(&session, 1).await;
}

#[tokio::test]
async fn an_idle_schedule_sends_after_each_turn() {
    let (hub, session, clocks) = chat().await;
    let req = Request { prompt: "keep going".into(), trigger: Trigger::Idle, max_runs: Some(2), until: None };
    hub.schedule_set(&session, req).unwrap();
    clocks.advance(IDLE_GRACE_MS);
    hub.run_due_schedules(clocks.now());
    turns_reach(&session, 1).await;
    // Its own turn ended: the next run counts its grace from that end.
    let next = session.meta().prompt_schedule.unwrap().next_run_at.expect("armed by the turn end");
    assert!(next > clocks.now() - 1 && next <= clocks.now() + IDLE_GRACE_MS);
    clocks.advance(IDLE_GRACE_MS + SETTLE_MS);
    hub.run_due_schedules(clocks.now());
    turns_reach(&session, 2).await;
    assert_eq!(session.meta().prompt_schedule, None);
}

#[tokio::test]
async fn pause_and_clear_stop_it() {
    let (hub, session, clocks) = chat().await;
    hub.schedule_set(&session, every(5, None)).unwrap();
    assert_eq!(hub.schedule_pause(&session, true)["paused"], json!(true));
    clocks.advance(30 * MIN);
    assert_eq!(hub.run_due_schedules(clocks.now()), None);
    assert_eq!(session.meta().turn_count, 0);
    assert!(hub.schedule_clear(&session));
    assert_eq!(hub.schedule_get(&session), Value::Null);
    assert!(!hub.schedule_clear(&session));
    assert_eq!(hub.schedule_pause(&session, false), Value::Null);
}

#[tokio::test]
async fn a_schedule_outlives_a_daemon_restart() {
    let (hub, session, _clocks) = chat().await;
    hub.schedule_set(&session, every(5, None)).unwrap();
    // The next daemon reads the same record.
    let cfg = hub.config.read().await.clone();
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    store.save(&session.meta()).unwrap();
    let restored = Hub::new(cfg, store);
    let clocks = clocks(&restored);
    restored.begin_startup(false);
    let session = restored.resolve(&session.id).unwrap();
    assert_eq!(session.meta().prompt_schedule.as_ref().unwrap().next_run_at, Some(T0 + 5 * MIN));
    restored.restore_prompt_schedules();
    // The daemon was down past its run: one run goes now, the next five minutes on.
    clocks.advance(60 * MIN);
    assert_eq!(restored.run_due_schedules(clocks.now()), Some(clocks.now() + 5 * MIN));
    assert_eq!(session.meta().prompt_schedule.unwrap().runs, 1);
}
