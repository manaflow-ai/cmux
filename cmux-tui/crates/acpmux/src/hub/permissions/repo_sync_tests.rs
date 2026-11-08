#![cfg(unix)]
use super::*;
use cmux_git::sync_barrier::Sync;
use std::time::Duration;

fn fixture() -> (tempfile::TempDir, Arc<Hub>, Arc<Session>) {
    let dir = tempfile::tempdir().unwrap();
    let cwd = dir.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir(&cwd).unwrap();
    let mut config =
        Config { permission_policy: PermissionPolicy::ApproveEdits, ..Default::default() };
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let hub = Hub::new(config, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "sync-session", "name": "Sync",
        "harness": "claude", "cwd": cwd, "status": "ready", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    (dir, hub, session)
}

#[tokio::test]
async fn repo_sync_write_waits_then_preserves_the_agent_edit() {
    let (_dir, hub, session) = fixture();
    let cwd = session.meta().cwd;
    let sync = Sync::begin(&cwd).unwrap();
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let write = hub.handle_fs_write(
        &session,
        json!({"path":"source", "content":"agent edit"}),
        epoch,
        None,
    );
    tokio::pin!(write);
    assert!(tokio::time::timeout(Duration::from_millis(50), &mut write).await.is_err());
    assert!(!cwd.join("source").exists());
    std::fs::write(cwd.join("source"), "synced source").unwrap();
    sync.complete().unwrap();
    tokio::time::timeout(Duration::from_secs(2), &mut write).await.unwrap().unwrap();
    assert_eq!(std::fs::read_to_string(cwd.join("source")).unwrap(), "agent edit");
}

#[tokio::test]
async fn repo_sync_failure_and_stop_never_allow_a_write() {
    for cancelled in [false, true] {
        let (_dir, hub, session) = fixture();
        let cwd = session.meta().cwd;
        let sync = Sync::begin(&cwd).unwrap();
        let epoch = session.permission_epoch.load(Ordering::SeqCst);
        let write = hub.handle_fs_write(
            &session,
            json!({"path":"source", "content":"agent edit"}),
            epoch,
            None,
        );
        tokio::pin!(write);
        assert!(tokio::time::timeout(Duration::from_millis(50), &mut write).await.is_err());
        if cancelled {
            session.permission_epoch.fetch_add(1, Ordering::SeqCst);
        }
        drop(sync);
        assert!(tokio::time::timeout(Duration::from_secs(2), &mut write).await.unwrap().is_err());
        assert!(!cwd.join("source").exists());
    }
}

#[tokio::test]
async fn repo_sync_failed_checkout_prevents_even_an_existing_child_lookup() {
    let (_dir, hub, session) = fixture();
    drop(Sync::begin(&session.meta().cwd).unwrap());
    let result = hub.child_for_since(&session, session.stops.load(Ordering::SeqCst)).await;
    let Err(error) = result else { panic!("partial checkout started a harness") };
    assert_eq!(error.data.unwrap()["reason"], "repo_sync_incomplete");
    assert!(session.child.lock().await.is_none());
}

#[tokio::test]
async fn repo_sync_failed_checkout_refuses_moves_and_unclassified_tools() {
    let (_dir, hub, session) = fixture();
    drop(Sync::begin(&session.meta().cwd).unwrap());
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    for kind in [Some("edit"), Some("execute"), Some("delete"), Some("move"), Some("other"), None] {
        let request = json!({"toolCall": {
            "toolCallId": "native", "title": "Native tool", "kind": kind
        }});
        let answer = hub.handle_permission(&session, request, epoch, None).await;
        assert_eq!(answer["outcome"]["outcome"], "cancelled", "{kind:?}");
    }
}
