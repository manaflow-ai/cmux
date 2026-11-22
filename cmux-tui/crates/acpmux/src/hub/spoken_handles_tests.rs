//! A new chat starts with a cute name and no hex tail, picks its own on its first turn, and
//! keeps its derived hex handle as an alias.
use crate::config::{Config, StoreMode};
use crate::hub::{Hub, NewRequest};
use serde_json::json;
use std::path::Path;
use std::sync::Arc;

fn hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn new(handle: Option<&str>) -> NewRequest {
    NewRequest {
        harness: Some("fake".into()),
        cwd: Some(std::env::temp_dir()),
        handle: handle.map(str::to_owned),
        ..Default::default()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_chat_gets_a_free_cute_name_and_can_pick_its_own() {
    let hub = hub();
    let a = hub.new_session(new(None)).await.unwrap();
    let b = hub.new_session(new(None)).await.unwrap();
    let (ha, hb) = (a.meta().spoken_handle().into_owned(), b.meta().spoken_handle().into_owned());
    assert!(crate::session_handle::valid(&ha) && !ha.contains('-'), "{ha}");
    assert!(!hb.contains('-') && !ha.eq_ignore_ascii_case(&hb), "{ha} {hb}");
    assert!(a.meta().handle_assigned, "the daemon gave it, so the first turn asks");

    // Asked for at the start: kept, and not asked again; a taken one is refused.
    let c = hub.new_session(new(Some("Pickle"))).await.unwrap();
    assert_eq!(c.meta().spoken_handle(), "Pickle");
    assert!(!c.meta().handle_assigned);
    let taken = hub.new_session(new(Some("pickle"))).await.err().expect("refused");
    assert!(taken.message.contains("taken"), "{}", taken.message);
    let taken = hub.new_session(new(Some(&ha))).await.err().expect("refused");
    assert!(taken.message.contains("taken"), "{}", taken.message);

    // The chat picks its own: the flag clears, and a collision is refused so it picks again.
    hub.rename_spoken_handle(&a, "Waffle").unwrap();
    assert_eq!(a.meta().spoken_handle(), "Waffle");
    assert!(!a.meta().handle_assigned);
    assert!(hub.rename_spoken_handle(&b, "waffle").is_err());

    // Free picks never offer a name in use.
    let free = hub.free_handles(&b.id, 5);
    assert!(free.iter().all(|n| !["Waffle", "Pickle"].iter().any(|t| t.eq_ignore_ascii_case(n))));

    // Its old derived hex handle still names it.
    let hex = crate::session_handle::default_handle(&a.id);
    assert!(crate::session_handle::matches(a.meta().handle.as_deref(), &a.id, &hex));
    assert!(crate::session_handle::matches(a.meta().handle.as_deref(), &a.id, "WAFFLE"));
}
