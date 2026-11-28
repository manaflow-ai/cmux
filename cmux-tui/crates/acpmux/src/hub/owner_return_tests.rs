//! The daemon side of the owner's return, end to end with a fake mover: a real hub with real
//! chats, some placed by AutoCloud. Nothing here moves a real chat or signals a real process.

use super::*;
use crate::clock::ManualClock;
use serde_json::json;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
struct FakeTarget(StdMutex<Vec<String>>);

impl Mover for FakeTarget {
    fn move_off<'a>(
        &'a self,
        id: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<String, String>> + Send + 'a>> {
        Box::pin(async move {
            self.0.lock().unwrap().push(id.to_owned());
            Ok("fake-target".into())
        })
    }
}

fn meta(id: &str, placed: bool) -> SessionMeta {
    let mut m: SessionMeta = serde_json::from_value(json!({"schema": META_SCHEMA, "id": id,
        "name": id, "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1,
        "updatedAt": 1}))
    .unwrap();
    m.placed_by = placed.then(|| crate::autocloud_enroll::PLACED_BY_AUTOCLOUD.to_owned());
    m
}

/// A hub with placed chats `placed-idle` and `placed-busy` (a running turn) and the owner's own
/// `mine`.
fn fixture() -> (Arc<Hub>, Arc<ManualClock>) {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    for (id, placed) in [("placed-idle", true), ("placed-busy", true), ("mine", false)] {
        store.save(&meta(id, placed)).unwrap();
    }
    let hub = Hub::new(cfg, store);
    let clock = ManualClock::new();
    hub.set_clock(clock.clone());
    for id in ["placed-idle", "placed-busy", "mine"] {
        hub.resolve(id).unwrap();
    }
    let busy = hub.resolve("placed-busy").unwrap();
    busy.turn_claimed.store(true, Ordering::SeqCst);
    clock.advance(std::time::Duration::from_secs(60));
    (hub, clock)
}

/// The owner comes back: the idle placed chat moves with a note, the busy one stays (paused,
/// never moved), the owner's own chat is never touched; away, nothing moves.
#[tokio::test]
async fn owner_return_moves_placed_idle_chats_only() {
    let (hub, clock) = fixture();
    let target = FakeTarget::default();
    let mut r = Returner::default();
    let plan = r.tick(&hub, true, Some(900.0), &target).await;
    assert!(plan.actions.is_empty());
    clock.advance(TICK);
    let plan = r.tick(&hub, true, Some(1.0), &target).await;
    assert!(plan.returned);
    assert_eq!(*target.0.lock().unwrap(), ["placed-idle"]);
    assert!(plan.actions.contains(&Action::Pause { id: "placed-busy".into() }));
    let s = hub.resolve("placed-idle").unwrap();
    let notes = hub.store.events(&s.id, 0, 1000).unwrap();
    assert!(notes.iter().any(|e| e.dir == "mux" && e.kind == NOTE_KIND));
    // Tried within the cooldown: not moved again.
    clock.advance(TICK);
    r.tick(&hub, true, Some(1.0), &target).await;
    assert_eq!(*target.0.lock().unwrap(), ["placed-idle"]);
}

/// Not enrolled: nothing placed moves, even with the owner at the keyboard.
#[tokio::test]
async fn owner_return_not_enrolled_moves_nothing() {
    let (hub, _clock) = fixture();
    let target = FakeTarget::default();
    let mut r = Returner::default();
    r.tick(&hub, false, Some(0.0), &target).await;
    assert!(target.0.lock().unwrap().is_empty());
}

/// One authority (RFD 0172): a busy placed Auto chat held here is not paused (its move is the
/// store's give, which stops the turn itself) and never reaches `session move`; an Auto chat
/// another machine holds is not in the plan at all.
#[tokio::test]
async fn owner_return_never_session_moves_or_pauses_an_auto_chat() {
    let (hub, clock) = fixture();
    let busy = hub.resolve("placed-busy").unwrap();
    hub.update_auto_record(&busy, |_| {
        Some(crate::auto_session::record::AutoRecord {
            here: true,
            ..crate::auto_session::record::AutoRecord::on()
        })
    });
    let idle = hub.resolve("placed-idle").unwrap();
    hub.update_auto_record(&idle, |_| {
        Some(crate::auto_session::record::AutoRecord {
            here: false,
            ..crate::auto_session::record::AutoRecord::on()
        })
    });
    let target = FakeTarget::default();
    let mut r = Returner::default();
    r.tick(&hub, true, Some(900.0), &target).await;
    clock.advance(TICK);
    let plan = r.tick(&hub, true, Some(1.0), &target).await;
    assert!(plan.returned);
    assert!(!plan.actions.contains(&Action::Pause { id: "placed-busy".into() }), "{plan:?}");
    assert!(target.0.lock().unwrap().is_empty());
}
