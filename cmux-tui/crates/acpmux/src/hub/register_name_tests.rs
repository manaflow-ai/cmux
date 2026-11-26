use super::*;

fn hub() -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn registered_session(hub: &Hub, id: &str, name: &str, conversation: Option<&str>) -> Arc<Session> {
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": name,
        "harness": "claude", "family": "claude", "agentSessionId": conversation, "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    mark_registered_for_test(&session.id);
    session
}

fn keep_token(home: &std::path::Path, session: &Session, started: u64) {
    let kept = crate::claude_peers::ChildToken {
        pid: std::process::id(),
        socket: home.join("inbox.sock"),
        token: "t".into(),
        started: Some(started),
    };
    crate::claude_peers::save_token(home, &session.id, &kept).unwrap();
}

fn holder(home: &std::path::Path, name: &str, started: u64) -> (Arc<Hub>, Arc<Session>) {
    let hub = hub();
    let session = registered_session(&hub, &uuid::Uuid::now_v7().to_string(), name, None);
    keep_token(home, &session, started);
    (hub, session)
}

/// Leo, 2026-11-25: `acpmux register NAME` takes a name held by a registered chat whose
/// Claude process is gone, renaming the dead holder `NAME-gone-<short>`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_gone_registered_holder_yields_its_name() {
    let home = tempfile::tempdir().unwrap();
    let (hub, held) = holder(home.path(), "mango-reg", 1_000);
    // The saved process start predates this test process.
    hub.yield_name_of_gone(&held, "mango-reg", home.path()).await.unwrap();
    let renamed = held.meta().name;
    assert!(renamed.starts_with("mango-reg-gone-"), "{renamed}");
    assert_eq!(renamed.len(), "mango-reg-gone-".len() + 8, "{renamed}");
    let incoming = registered_session(&hub, &uuid::Uuid::now_v7().to_string(), "incoming", None);
    hub.rename_as(&incoming, "mango-reg".into(), crate::hub::task_names::Naming::Address)
        .await
        .unwrap();
    assert_eq!(hub.resolve("mango-reg").unwrap().id, incoming.id);
    assert_eq!(hub.resolve(&renamed).unwrap().id, held.id);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_live_registered_holder_still_refuses_with_name_taken() {
    let (home, claude_home) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    // Its process (this test's own) runs, with the start its token names.
    let me = std::process::id();
    let started = crate::adopt_live::pid_start_ms(me).expect("this process's start");
    let (hub, held) = holder(home.path(), "mango-live", started);
    let registry = crate::claude_peers::registry(claude_home.path());
    std::fs::create_dir_all(&registry).unwrap();
    let entry = json!({"pid": me, "sessionId": "sid-live", "startedAt": started});
    std::fs::write(registry.join(format!("{me}.json")), entry.to_string()).unwrap();
    assert_eq!(crate::claude_peers::started_at(claude_home.path(), me), Some(started));
    let e = hub.yield_name_of_gone(&held, "mango-live", home.path()).await.unwrap_err();
    assert_eq!(e.data.as_ref().unwrap()["reason"], "register.name_taken", "{}", e.message);
    assert_eq!(held.meta().name, "mango-live");
    // Its process runs with no registry entry at all: still taken.
    std::fs::remove_file(registry.join(format!("{me}.json"))).unwrap();
    let e = hub.yield_name_of_gone(&held, "mango-live", home.path()).await.unwrap_err();
    assert_eq!(e.data.as_ref().unwrap()["reason"], "register.name_taken", "{}", e.message);
    // Nor does a chat that was never registered yield, gone or not.
    assert!(!registered_chat_gone(false, None));
    let kept = crate::claude_peers::ChildToken {
        pid: me,
        socket: home.path().join("inbox.sock"),
        token: "t".into(),
        started: Some(2_000),
    };
    assert!(!registered_chat_gone(false, Some(&kept)));
    assert!(registered_chat_gone(true, Some(&kept)));
    // A token with no recorded start proves nothing either way: the name stays.
    let unknown = crate::claude_peers::ChildToken { started: None, ..kept };
    assert!(!registered_chat_gone(true, Some(&unknown)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_repeated_registration_keeps_both_archives_with_the_same_uuid_prefix() {
    let home = tempfile::tempdir().unwrap();
    let hub = hub();
    let name = "d".repeat(80);
    let prefix = "d".repeat(55);
    let archives = [
        ("019489cc-ae00-7001-8000-000000000001", format!("{prefix}-gone-019489cc")),
        ("019489cc-ae01-7001-8000-000000000002", format!("{prefix}-gone-019489cc-1")),
    ];
    for (id, _) in &archives {
        let session = registered_session(&hub, id, &name, None);
        keep_token(home.path(), &session, 1_000);
        hub.yield_name_of_gone(&session, &name, home.path()).await.unwrap();
    }
    for (id, expected) in archives {
        crate::session_name::validate(&expected).unwrap();
        assert_eq!(hub.store.load(id).unwrap().unwrap().name, expected);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_registration_preserves_the_current_name() {
    let home = tempfile::tempdir().unwrap();
    let claude_home = tempfile::tempdir().unwrap();
    let (hub, holder) = holder(home.path(), "desk", 1_000);
    let peer = super::tests::peer(42, "/unused");
    let incoming = registered_session(
        &hub,
        &uuid::Uuid::now_v7().to_string(),
        "other",
        Some(&peer.session_id),
    );
    let err = hub
        .prepare_registered_name("desk", &peer, 2_000, None, home.path(), claude_home.path())
        .await
        .err()
        .expect("the incoming conversation failed validation");
    assert!(err.message.contains("--resume"), "{}", err.message);
    for (session, expected) in [(&holder, "desk"), (&incoming, "other")] {
        assert_eq!(session.meta().name, expected);
        assert_eq!(hub.store.load(&session.id).unwrap().unwrap().name, expected);
    }
}
