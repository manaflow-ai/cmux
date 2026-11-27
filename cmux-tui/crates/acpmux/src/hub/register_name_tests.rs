//! What a gone registered chat's name becomes, and who gets it (`yield_name_of_gone`).
//! Its liveness rule (`registered_chat_gone`) is tested beside it in `register.rs`.

use super::*;

fn hub() -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn registered_session(hub: &Hub, id: &str, name: &str) -> Arc<Session> {
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name,
        "harness": "claude", "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    mark_registered_for_test(&session.id);
    session
}

/// Keeps a token for this test's own process with a start no registry entry has: gone.
fn keep_gone_token(home: &std::path::Path, session: &Session) {
    let kept = crate::claude_peers::ChildToken {
        pid: std::process::id(),
        socket: home.join("inbox.sock"),
        token: "t".into(),
        started: Some(1_000),
    };
    crate::claude_peers::save_token(home, &session.id, &kept).unwrap();
}

/// Leo, 2026-11-25: `acpmux register NAME` takes a name held by a registered chat whose
/// Claude process is gone, renaming the dead holder `NAME-gone-<short>`; both stay reachable.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_gone_holders_name_goes_to_the_new_registration() {
    let (home, claude_home) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let hub = hub();
    let held = registered_session(&hub, &uuid::Uuid::now_v7().to_string(), "mango-reg");
    keep_gone_token(home.path(), &held);
    hub.yield_name_of_gone(&held, "mango-reg", home.path(), claude_home.path()).await.unwrap();
    let renamed = held.meta().name;
    assert!(renamed.starts_with("mango-reg-gone-"), "{renamed}");
    let incoming = registered_session(&hub, &uuid::Uuid::now_v7().to_string(), "incoming");
    hub.rename_as(&incoming, "mango-reg".into(), crate::hub::task_names::Naming::Address)
        .await
        .unwrap();
    assert_eq!(hub.resolve("mango-reg").unwrap().id, incoming.id);
    assert_eq!(hub.resolve(&renamed).unwrap().id, held.id);
}

/// An 80-byte name still yields (its archive fits an address), and two gone holders whose ids
/// share the first 8 characters keep distinct archives.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_repeated_registration_keeps_both_archives_with_the_same_uuid_prefix() {
    let (home, claude_home) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let hub = hub();
    let name = "d".repeat(80);
    let prefix = "d".repeat(55);
    let archives = [
        ("019489cc-ae00-7001-8000-000000000001", format!("{prefix}-gone-019489cc")),
        ("019489cc-ae01-7001-8000-000000000002", format!("{prefix}-gone-019489cc-1")),
    ];
    for (id, _) in &archives {
        let session = registered_session(&hub, id, &name);
        keep_gone_token(home.path(), &session);
        hub.yield_name_of_gone(&session, &name, home.path(), claude_home.path()).await.unwrap();
    }
    for (id, expected) in archives {
        crate::session_name::validate(&expected).unwrap();
        assert_eq!(hub.store.load(id).unwrap().unwrap().name, expected);
    }
}
