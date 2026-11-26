//! A create sent again with its key gets the session the first one made, on the same daemon or
//! on the next one after a restart (`create_key.rs`).

use super::*;

fn test_hub(root: Option<&std::path::Path>) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = if root.is_some() {
        crate::config::StoreMode::Local
    } else {
        crate::config::StoreMode::Memory
    };
    let store =
        crate::store::open(&cfg.store, root.unwrap_or(std::path::Path::new("/nonexistent")))
            .unwrap();
    Hub::new(cfg, store)
}

fn keyed(key: &str) -> NewRequest {
    NewRequest {
        cwd: Some(std::env::temp_dir()),
        create_key: Some(key.to_owned()),
        ..Default::default()
    }
}

#[tokio::test]
async fn a_create_sent_again_with_its_key_gets_the_session_the_first_made() {
    let hub = test_hub(None);
    let key = uuid::Uuid::now_v7().to_string();
    let first = hub.new_session(keyed(&key)).await.unwrap();
    let again = hub.new_session(keyed(&key)).await.unwrap();
    assert!(Arc::ptr_eq(&first, &again), "a second session for one key");
    // Another key, or none, is another create.
    let other = hub.new_session(keyed(&uuid::Uuid::now_v7().to_string())).await.unwrap();
    assert_ne!(other.id, first.id);
    assert_eq!(hub.sessions.lock().unwrap().len(), 2);
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_creates_with_one_key_make_one_session() {
    let hub = test_hub(None);
    let key = uuid::Uuid::now_v7().to_string();
    let (a, b) = tokio::join!(hub.new_session(keyed(&key)), hub.new_session(keyed(&key)));
    let (a, b) = (a.unwrap(), b.unwrap());
    assert_eq!(a.id, b.id);
    assert_eq!(hub.sessions.lock().unwrap().len(), 1);
    hub.shutdown_all().await;
}

/// A Linux lane VM, 2026-11-21 09:58:45Z: a self-update restarted the daemon while
/// `acpmux new -d --json` waited for its reply. The CLI sends the create again, with its key,
/// to the next daemon: that one finds the session in the store and makes no second one.
#[tokio::test]
async fn the_next_daemon_answers_a_resent_create_with_the_session_the_last_one_made() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ckey");
    let hub = test_hub(Some(dir.path()));
    let key = uuid::Uuid::now_v7().to_string();
    let made = hub.new_session(keyed(&key)).await.unwrap();
    let id = made.id.clone();
    drop(made);
    hub.shutdown_all().await;
    drop(hub);

    let restarted = test_hub(Some(dir.path()));
    let again = restarted.new_session(keyed(&key)).await.unwrap();
    assert_eq!(again.id, id, "the resent create made another session");
    assert_eq!(restarted.store.list().unwrap().len(), 1);
    assert_eq!(restarted.store.load(&id).unwrap().unwrap().create_key.as_deref(), Some(&*key));
    restarted.shutdown_all().await;
}

#[test]
fn a_key_is_a_short_bare_word() {
    let meta = |v: Value| json!({ (FIELD): v });
    assert_eq!(super::requested(None).unwrap(), None);
    assert_eq!(super::requested(Some(&meta(Value::Null))).unwrap(), None);
    let uuid = uuid::Uuid::now_v7().to_string();
    assert_eq!(super::requested(Some(&meta(json!(uuid)))).unwrap(), Some(uuid));
    for bad in [json!(""), json!("a b"), json!("../x"), json!(7), json!("k".repeat(129))] {
        assert!(super::requested(Some(&meta(bad.clone()))).is_err(), "{bad}");
    }
}
