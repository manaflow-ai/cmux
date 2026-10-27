use super::{CLEARED, SET, VM_HOST, clear_legacy_grant};
use crate::config::PermissionPolicy;
use crate::hub::Hub;
use crate::store::{EventRecord, META_SCHEMA, SessionMeta};
use serde_json::{Value, json};
use std::sync::Arc;

const VM_HOST_ERA: &str = "01a15900-0000-7000-8000-000000000001";
const AMBIGUOUS: &str = "01a15900-0000-7000-8000-000000000002";
const LOCAL: &str = "01a15900-0000-7000-8000-000000000003";

/// A session as an older daemon saved it: no `policySource`.
fn legacy(id: &str, remote: bool, policy: Option<&str>) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/tmp",
        "status": "idle", "createdAt": 1, "updatedAt": 1, "remoteOrigin": remote,
        "permissionPolicy": policy,
    }))
    .unwrap()
}

fn record(seq: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: seq, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

fn hub_at(dir: &std::path::Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// A store an older daemon left on a vmHost machine:
/// - VM_HOST_ERA: its owner's peer daemon started it with no policy, and the vmHost path set
///   approve-all right after (`created`, then a `policy` record);
/// - AMBIGUOUS: the peer's session/new named approve-all itself (no `policy` record); the
///   store cannot tell it from the vmHost path's;
/// - LOCAL: started on this machine with approve-all, which the vmHost path never touched.
fn legacy_store(dir: &std::path::Path) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    for (id, remote, set_after) in
        [(VM_HOST_ERA, true, true), (AMBIGUOUS, true, false), (LOCAL, false, false)]
    {
        store.append(id, &record(1, "created", json!({"harness": "claude"}))).unwrap();
        let mut meta = legacy(id, remote, Some("approve-all"));
        meta.last_seq = 1;
        if set_after {
            store.append(id, &record(2, "policy", json!({"policy": "approve-all"}))).unwrap();
            meta.last_seq = 2;
        }
        meta.event_count = meta.last_seq;
        store.save(&meta).unwrap();
    }
    store.flush().unwrap();
}

/// What answers each chat's permission requests (`handle_permission_for`).
fn answers(hub: &Arc<Hub>, id: &str) -> PermissionPolicy {
    hub.policy_for(&hub.resolve(id).unwrap(), PermissionPolicy::Ask)
}

fn saved(dir: &std::path::Path) -> Vec<SessionMeta> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let mut metas = crate::store::open(&cfg.store, dir).unwrap().list().unwrap();
    metas.sort_by(|a, b| a.id.cmp(&b.id));
    metas
}

#[test]
fn only_a_remote_approve_all_with_no_source_is_cleared() {
    let mut era = legacy(VM_HOST_ERA, true, Some("approve-all"));
    assert!(clear_legacy_grant(&mut era));
    assert_eq!(era.permission_policy.as_deref(), Some("ask"));
    assert_eq!(era.policy_source, Some(CLEARED.to_owned()));
    // Its other spelling too.
    assert!(clear_legacy_grant(&mut legacy(AMBIGUOUS, true, Some("yolo"))));
    for (why, mut kept) in [
        ("started on this machine", legacy(LOCAL, false, Some("approve-all"))),
        ("asks already", legacy(LOCAL, true, Some("ask"))),
        ("approve-edits was never vmHost's", legacy(LOCAL, true, Some("approve-edits"))),
        ("no policy of its own", legacy(LOCAL, true, None)),
    ] {
        let before = kept.clone();
        assert!(!clear_legacy_grant(&mut kept), "{why}");
        assert_eq!(kept, before, "{why}");
    }
    for source in [SET, VM_HOST, "a value a newer daemon writes"] {
        let mut set = legacy(VM_HOST_ERA, true, Some("approve-all"));
        set.policy_source = Some(source.to_owned());
        assert!(!clear_legacy_grant(&mut set), "{source}: set by a daemon that says who");
    }
}

#[tokio::test]
async fn a_vm_host_era_or_ambiguous_grant_asks_after_the_upgrade() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-vg");
    legacy_store(dir.path());
    let hub = hub_at(dir.path());
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::Ask, "the vmHost-era grant");
    assert_eq!(answers(&hub, AMBIGUOUS), PermissionPolicy::Ask, "the ambiguous grant");
    assert_eq!(answers(&hub, LOCAL), PermissionPolicy::ApproveAll, "a chat started here");
    // Saved, so the client lists them as asking and a restart reads ask.
    let metas = saved(dir.path());
    let policy = |id: &str| {
        let m = metas.iter().find(|m| m.id == id).unwrap();
        (m.permission_policy.clone(), m.policy_source)
    };
    assert_eq!(policy(VM_HOST_ERA), (Some("ask".into()), Some(CLEARED.to_owned())));
    assert_eq!(policy(AMBIGUOUS), (Some("ask".into()), Some(CLEARED.to_owned())));
    assert_eq!(policy(LOCAL), (Some("approve-all".into()), None));
}

#[tokio::test]
async fn an_owner_grant_after_the_upgrade_still_approves_after_a_restart() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-vg");
    legacy_store(dir.path());
    let hub = hub_at(dir.path());
    // The owner's one click (`_acpmux/set_policy`).
    let s = hub.resolve(VM_HOST_ERA).unwrap();
    hub.set_policy_unless_moving(&s, PermissionPolicy::ApproveAll).await.unwrap();
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::ApproveAll);
    drop((s, hub));
    let hub = hub_at(dir.path());
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::ApproveAll, "cleared again");
    assert_eq!(hub.resolve(VM_HOST_ERA).unwrap().meta().policy_source, Some(SET.to_owned()));
    assert_eq!(answers(&hub, AMBIGUOUS), PermissionPolicy::Ask);
}

#[tokio::test]
async fn a_second_run_changes_nothing() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-vg");
    legacy_store(dir.path());
    drop(hub_at(dir.path()));
    let once = saved(dir.path());
    drop(hub_at(dir.path()));
    assert_eq!(saved(dir.path()), once);
    // And the rule itself, on what the first run left.
    for mut meta in once {
        let before = meta.clone();
        assert!(!clear_legacy_grant(&mut meta), "{}", meta.id);
        assert_eq!(meta, before);
    }
}
