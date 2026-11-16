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

/// A seed that is still running holds its lock: it is alive, however long it takes. A write
/// waits for it (or for its failure, or a stop), never fails on a deadline while it runs (the
/// timer rule: no deadline fails a request while the other side is alive). Before, a seed past
/// 10 minutes refused the agent's write with "repository sync is still running".
#[tokio::test(start_paused = true)]
async fn repo_sync_a_write_waits_for_a_live_seed_past_ten_minutes() {
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
    let early = tokio::time::timeout(Duration::from_secs(11 * 60), &mut write).await;
    assert!(early.is_err(), "a live seed's wait ended after 11 minutes: {early:?}");
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

#[tokio::test]
async fn repo_sync_head_lets_only_a_self_gating_start_through() {
    let (_dir, hub, session) = fixture();
    let cwd = session.meta().cwd;
    let mut sync = Sync::begin(&cwd).unwrap();
    sync.head_ready();
    let never = || false;
    let start = super::super::repo_sync::wait_for_start(&session, cwd.clone(), true, never);
    let ready = tokio::time::timeout(Duration::from_secs(2), start).await.unwrap().unwrap();
    assert!(ready.is_none(), "a start at the head holds no lease: the seed runs on");
    let other = super::super::repo_sync::wait_for_start(&session, cwd.clone(), false, never);
    tokio::pin!(other);
    assert!(tokio::time::timeout(Duration::from_millis(150), &mut other).await.is_err());
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let write = hub.handle_fs_write(
        &session,
        json!({"path":"source", "content":"agent edit"}),
        epoch,
        None,
    );
    tokio::pin!(write);
    let pending = tokio::time::timeout(Duration::from_millis(150), &mut write).await;
    assert!(pending.is_err(), "a write waits for the fill");
    sync.complete().unwrap();
    let after = tokio::time::timeout(Duration::from_secs(2), &mut other).await.unwrap().unwrap();
    assert!(after.is_some());
    tokio::time::timeout(Duration::from_secs(2), &mut write).await.unwrap().unwrap();
    assert!(super::super::repo_sync::gates_its_tools(crate::config::HarnessKind::ClaudeStdio));
    assert!(!super::super::repo_sync::gates_its_tools(crate::config::HarnessKind::Acp));
}

/// Review F1 (cmux#38084, 4514531c49c): a reload can make the profile Claude's without
/// replacing a running ACP agent, whose tools never wait on the sync. At the head, a prompt
/// for that agent waits for the whole checkout, whatever the profile says now.
#[tokio::test]
async fn repo_sync_head_holds_a_running_agent_that_does_not_gate_its_tools() {
    let (_dir, hub, session) = fixture();
    let cwd = session.meta().cwd;
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile: crate::config::HarnessProfile =
        serde_json::from_value(json!({"argv": ["/usr/bin/env", "python3", fake]})).unwrap();
    let (inbound, _rx) = tokio::sync::mpsc::channel(16);
    let tap: crate::agent::Tap = Arc::new(|_, _, _| true);
    let child = crate::agent::ChildAgent::spawn("acp", &profile, &cwd, inbound, tap).await.unwrap();
    assert!(!super::super::repo_sync::child_gates_its_tools(&child));
    *session.child.lock().await = Some(child.clone());
    let mut sync = Sync::begin(&cwd).unwrap();
    sync.head_ready();
    let stops = session.stops.load(Ordering::SeqCst);
    let prompt = hub.child_for_since(&session, stops);
    tokio::pin!(prompt);
    let early = tokio::time::timeout(Duration::from_millis(150), &mut prompt).await;
    assert!(early.is_err(), "an agent that does not gate its tools waits past the head");
    sync.complete().unwrap();
    let handed = tokio::time::timeout(Duration::from_secs(2), &mut prompt).await.unwrap().unwrap();
    assert!(Arc::ptr_eq(&handed, &child));
}
