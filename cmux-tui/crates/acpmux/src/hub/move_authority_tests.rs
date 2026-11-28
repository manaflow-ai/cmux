//! Who moves a chat: the store for an Auto chat, this daemon for any other. A fake mover counts
//! every `session move`; an Auto chat must never reach it.

use super::*;
use crate::auto_session::record::AutoRecord;
use crate::clock::ManualClock;
use serde_json::json;
use std::future::Future;
use std::pin::Pin;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
struct CountingMover(StdMutex<Vec<String>>);

impl Mover for CountingMover {
    fn move_off<'a>(
        &'a self,
        id: &'a str,
    ) -> Pin<Box<dyn Future<Output = Result<String, String>> + Send + 'a>> {
        Box::pin(async move {
            self.0.lock().unwrap().push(id.to_owned());
            Ok("other-host".into())
        })
    }
}

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({"schema": META_SCHEMA, "id": id, "name": id,
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1}))
    .unwrap()
}

/// A hub with `plain`, `auto-here` (the store's holder is this machine) and `auto-away`.
fn fixture() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    for id in ["plain", "auto-here", "auto-away"] {
        store.save(&meta(id)).unwrap();
    }
    let hub = Hub::new(cfg, store);
    hub.set_clock(ManualClock::new());
    for (id, here) in [("auto-here", true), ("auto-away", false)] {
        let s = hub.resolve(id).unwrap();
        hub.update_auto_record(&s, |_| Some(AutoRecord { here, ..AutoRecord::on() }));
    }
    hub
}

#[test]
fn an_auto_chat_is_moved_by_the_store_and_any_other_by_this_daemon() {
    let hub = fixture();
    let of = |id: &str| hub.move_authority(&hub.resolve(id).unwrap());
    assert_eq!(of("plain"), Authority::ThisDaemon);
    assert_eq!(of("auto-here"), Authority::Store { here: true });
    assert_eq!(of("auto-away"), Authority::Store { here: false });
    // Auto turned off: the record stays but this daemon moves it again.
    let s = hub.resolve("auto-here").unwrap();
    hub.update_auto_record(&s, |r| r.map(|r| AutoRecord { auto: false, ..r }));
    assert_eq!(of("auto-here"), Authority::ThisDaemon);
}

#[test]
fn a_store_move_in_flight_reads_as_moving() {
    let hub = fixture();
    let s = hub.resolve("auto-here").unwrap();
    assert!(!hub.store_moving(&s));
    hub.update_auto_record(&s, |r| {
        r.map(|r| AutoRecord { moving: Some(cmux_auto_session::wire::MoveTo::Cloud), ..r })
    });
    assert!(hub.store_moving(&s));
    assert!(!hub.store_moving(&hub.resolve("plain").unwrap()));
}

/// The one-authority number: `session move` calls on Auto chats. Before RFD 0172's one
/// authority every chat here reached the mover; now only the plain chat does.
#[tokio::test]
async fn no_auto_chat_ever_reaches_session_move() {
    let hub = fixture();
    let mover = CountingMover::default();
    assert_eq!(hub.move_off_by_authority("plain", &mover).await.as_deref(), Ok("other-host"));
    let here = hub.move_off_by_authority("auto-here", &mover).await.unwrap_err();
    assert!(here.contains("Auto mode is not running"), "{here}");
    let away = hub.move_off_by_authority("auto-away", &mover).await.unwrap_err();
    assert!(away.contains("another machine runs this Auto chat"), "{away}");
    assert_eq!(*mover.0.lock().unwrap(), ["plain"]);
}
