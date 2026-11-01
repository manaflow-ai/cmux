use super::{
    CLEARED, CLEARED_HOST, SET, VM_HOST, could_be_vm_host, settle_grant, settle_imported_grant,
};
use crate::config::PermissionPolicy;
use crate::hub::Hub;
use crate::store::{EventRecord, META_SCHEMA, SessionMeta};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;

const VM_HOST_ERA: &str = "01a15900-0000-7000-8000-000000000001";
const AMBIGUOUS: &str = "01a15900-0000-7000-8000-000000000002";
const LOCAL: &str = "01a15900-0000-7000-8000-000000000003";
const HANDOFF: &str = "01a15900-0000-7000-8000-000000000004";
const FORK_OF_HANDOFF: &str = "01a15900-0000-7000-8000-000000000005";
const FORK_OF_LOCAL: &str = "01a15900-0000-7000-8000-000000000006";

/// A session as an older daemon saved it: no `policySource`.
fn legacy(id: &str, remote: bool, policy: Option<&str>) -> SessionMeta {
    legacy_with(id, remote, policy, json!({}))
}

/// `legacy` with `extra` fields (a `parentId`, `tags`, a `lineage`).
fn legacy_with(id: &str, remote: bool, policy: Option<&str>, extra: Value) -> SessionMeta {
    let mut v = json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/tmp",
        "status": "idle", "createdAt": 1, "updatedAt": 1, "remoteOrigin": remote,
        "permissionPolicy": policy,
    });
    for (k, x) in extra.as_object().cloned().unwrap_or_default() {
        v[k] = x;
    }
    serde_json::from_value(v).unwrap()
}

fn handoff_tag() -> Value {
    json!({"tags": {"handoffKey": {"value": "k1"}}})
}

fn record(seq: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: seq, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

fn hub_at(dir: &std::path::Path) -> Arc<Hub> {
    hub_with(dir, crate::config::Config::default())
}

fn hub_with(dir: &std::path::Path, mut cfg: crate::config::Config) -> Arc<Hub> {
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// A store an older daemon left on a vmHost machine, every chat approve-all with no source:
/// - VM_HOST_ERA: its owner's peer daemon started it with no policy, and the vmHost path set
///   approve-all right after (`created`, then a `policy` record);
/// - AMBIGUOUS: the peer's session/new named approve-all itself (no `policy` record);
/// - LOCAL: started on this machine for its person, which the vmHost path never touched;
/// - HANDOFF: a handoff of VM_HOST_ERA asked for on this machine's socket (local, tagged);
/// - FORK_OF_HANDOFF: a fork of HANDOFF (local); FORK_OF_LOCAL: a fork of LOCAL.
fn legacy_store(dir: &std::path::Path) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    let chats = [
        (VM_HOST_ERA, true, json!({}), true),
        (AMBIGUOUS, true, json!({}), false),
        (LOCAL, false, json!({}), false),
        (HANDOFF, false, handoff_tag(), false),
        (FORK_OF_HANDOFF, false, json!({"parentId": HANDOFF}), false),
        (FORK_OF_LOCAL, false, json!({"parentId": LOCAL}), false),
    ];
    for (id, remote, extra, set_after) in chats {
        store.append(id, &record(1, "created", json!({"harness": "claude"}))).unwrap();
        let mut meta = legacy_with(id, remote, Some("approve-all"), extra);
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

/// [`answers`] for each of `ids`.
fn policies<'a, const N: usize>(
    hub: &Arc<Hub>,
    ids: [&'a str; N],
) -> [(&'a str, PermissionPolicy); N] {
    ids.map(|id| (id, answers(hub, id)))
}

fn saved(dir: &std::path::Path) -> Vec<SessionMeta> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let mut metas = crate::store::open(&cfg.store, dir).unwrap().list().unwrap();
    metas.sort_by(|a, b| a.id.cmp(&b.id));
    metas
}

#[test]
fn only_an_approve_all_with_no_source_is_settled() {
    let mut era = legacy(VM_HOST_ERA, true, Some("approve-all"));
    assert!(settle_grant(&mut era, true));
    assert_eq!(era.permission_policy.as_deref(), Some("ask"));
    assert_eq!(era.policy_source.as_deref(), Some(CLEARED));
    // Its other spelling too.
    assert!(settle_grant(&mut legacy(AMBIGUOUS, true, Some("yolo")), true));
    // One that could not be vmHost's is kept, and says so.
    let mut local = legacy(LOCAL, false, Some("approve-all"));
    assert!(settle_grant(&mut local, false));
    assert_eq!(local.permission_policy.as_deref(), Some("approve-all"));
    assert_eq!(local.policy_source.as_deref(), Some(SET));
    for (why, mut kept) in [
        ("asks already", legacy(LOCAL, true, Some("ask"))),
        ("approve-edits was never vmHost's", legacy(LOCAL, true, Some("approve-edits"))),
        ("no policy of its own", legacy(LOCAL, true, None)),
    ] {
        let before = kept.clone();
        assert!(!settle_grant(&mut kept, true), "{why}");
        assert_eq!(kept, before, "{why}");
    }
    for source in [SET, VM_HOST, "a value a newer daemon writes"] {
        let mut set = legacy(VM_HOST_ERA, true, Some("approve-all"));
        set.policy_source = Some(source.to_owned());
        assert!(!settle_grant(&mut set, true), "{source}: set by a daemon that says who");
    }
}

/// A chat from another machine: nothing it was taken from is here to tell, nor what set an older
/// daemon's approve-all; a vmHost grant was for that machine's VM.
#[test]
fn an_imported_approve_all_is_kept_only_when_a_daemon_says_its_owner_set_it() {
    for (extra, remote) in [
        (json!({}), true),
        (handoff_tag(), false),
        (json!({"parentId": LOCAL}), false),
        (json!({"lineage": {"parent": LOCAL, "root": LOCAL, "depth": 1}}), false),
        (json!({"subsession": {"startedBy": LOCAL, "shortName": "t", "depth": 1}}), false),
        (json!({}), false),
    ] {
        let mut meta = legacy_with(AMBIGUOUS, remote, Some("approve-all"), extra.clone());
        assert!(settle_imported_grant(&mut meta), "{extra}");
        assert_eq!(meta.permission_policy.as_deref(), Some("ask"), "{extra} remote {remote}");
        // What it decided holds at the next load or move.
        meta.remote_origin = true;
        let decided = meta.clone();
        assert!(!settle_grant(&mut meta, true) && !settle_imported_grant(&mut meta));
        assert_eq!(meta, decided);
    }
    let mut vm = legacy(AMBIGUOUS, true, Some("approve-all"));
    vm.policy_source = Some(VM_HOST.into());
    assert!(settle_imported_grant(&mut vm));
    assert_eq!(
        (vm.permission_policy.as_deref(), vm.policy_source.as_deref()),
        (Some("ask"), Some(CLEARED))
    );
    let mut set = legacy(AMBIGUOUS, true, Some("approve-all"));
    set.policy_source = Some(SET.into());
    let before = set.clone();
    assert!(!settle_imported_grant(&mut set));
    assert_eq!(set, before, "the owner's grant moves with it");
}

#[test]
fn a_grant_taken_from_a_chat_that_could_have_it_could_be_vm_hosts() {
    let at = |id: &str, remote: bool, extra: Value| legacy_with(id, remote, None, extra);
    let loop_a = "01a15900-0000-7000-8000-00000000000a";
    let loop_b = "01a15900-0000-7000-8000-00000000000b";
    let recorded = "01a15900-0000-7000-8000-00000000000c";
    let metas = [
        at(VM_HOST_ERA, true, json!({})),
        at(LOCAL, false, json!({})),
        at(HANDOFF, false, handoff_tag()),
        at(recorded, false, json!({})),
        at(FORK_OF_HANDOFF, false, json!({"parentId": HANDOFF})),
        at(FORK_OF_LOCAL, false, json!({"parentId": LOCAL})),
        at(
            "started-by-handoff",
            false,
            json!({"lineage": {"parent": HANDOFF, "root": HANDOFF, "depth": 1}}),
        ),
        at(
            "sub-of-recorded",
            false,
            json!({"subsession": {"startedBy": recorded, "shortName": "t", "depth": 1}}),
        ),
        at(
            "sub-of-local",
            false,
            json!({"subsession": {"startedBy": LOCAL, "shortName": "t", "depth": 1}}),
        ),
        at("fork-of-gone", false, json!({"parentId": "01a15900-0000-7000-8000-0000000000ff"})),
        at(loop_a, false, json!({"parentId": loop_b})),
        at(loop_b, false, json!({"parentId": loop_a})),
    ];
    // `recorded`: a handoff record names it, its tag gone.
    let targets: HashSet<String> = [recorded.to_owned()].into();
    let could = could_be_vm_host(&metas, &targets);
    let mut want: Vec<&str> = vec![
        VM_HOST_ERA,
        HANDOFF,
        recorded,
        FORK_OF_HANDOFF,
        "started-by-handoff",
        "sub-of-recorded",
        "fork-of-gone",
        loop_a,
        loop_b,
    ];
    let mut got: Vec<&str> = could.iter().map(String::as_str).collect();
    want.sort_unstable();
    got.sort_unstable();
    assert_eq!(got, want, "LOCAL, FORK_OF_LOCAL and sub-of-local are this machine's own");
}

#[tokio::test]
async fn a_vm_host_era_ambiguous_or_inherited_grant_asks_after_the_upgrade() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    legacy_store(dir.path());
    let hub = hub_at(dir.path());
    let ask = PermissionPolicy::Ask;
    assert_eq!(
        policies(&hub, [VM_HOST_ERA, AMBIGUOUS, HANDOFF, FORK_OF_HANDOFF]),
        [(VM_HOST_ERA, ask), (AMBIGUOUS, ask), (HANDOFF, ask), (FORK_OF_HANDOFF, ask)]
    );
    let all = PermissionPolicy::ApproveAll;
    assert_eq!(
        policies(&hub, [LOCAL, FORK_OF_LOCAL]),
        [(LOCAL, all), (FORK_OF_LOCAL, all)],
        "here"
    );
    // Saved, so the client lists them as asking and a restart reads ask.
    let metas = saved(dir.path());
    let policy = |id: &str| {
        let m = metas.iter().find(|m| m.id == id).unwrap();
        (m.permission_policy.clone().unwrap(), m.policy_source.clone().unwrap())
    };
    for id in [VM_HOST_ERA, AMBIGUOUS, HANDOFF, FORK_OF_HANDOFF] {
        assert_eq!(policy(id), ("ask".into(), CLEARED.to_owned()), "{id}");
    }
    for id in [LOCAL, FORK_OF_LOCAL] {
        assert_eq!(policy(id), ("approve-all".into(), SET.to_owned()), "{id}");
    }
}

#[tokio::test]
async fn an_owner_grant_after_the_upgrade_still_approves_after_a_restart() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    legacy_store(dir.path());
    let hub = hub_at(dir.path());
    // The owner's one click (`_acpmux/set_policy`).
    let s = hub.resolve(VM_HOST_ERA).unwrap();
    hub.set_policy_unless_moving(&s, PermissionPolicy::ApproveAll).await.unwrap();
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::ApproveAll);
    drop((s, hub));
    let hub = hub_at(dir.path());
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::ApproveAll, "cleared again");
    assert_eq!(hub.resolve(VM_HOST_ERA).unwrap().meta().policy_source.as_deref(), Some(SET));
    assert_eq!(answers(&hub, AMBIGUOUS), PermissionPolicy::Ask);
}

#[tokio::test]
async fn a_second_run_changes_nothing() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    legacy_store(dir.path());
    drop(hub_at(dir.path()));
    let once = saved(dir.path());
    drop(hub_at(dir.path()));
    assert_eq!(saved(dir.path()), once);
    // And the rule itself, on what the first run left.
    for mut meta in once {
        let before = meta.clone();
        assert!(!settle_grant(&mut meta, true), "{}", meta.id);
        assert!(!settle_imported_grant(&mut meta), "{}", meta.id);
        assert_eq!(meta, before);
    }
}

/// A machine whose daemon could have given vmHost's approve-all (`could_have_had_vm_host`): a
/// chat with no link back may have inherited it (an agent in a handoff target started it with no
/// parent), so every approve-all with no source asks. Its config names `vmHost`, or there is no
/// config.json (deleted, it may have named it). A Mac never gave it.
#[tokio::test]
async fn every_approve_all_with_no_source_asks_on_a_machine_that_could_have_had_vm_host() {
    let missing = std::path::Path::new("/nonexistent/acpmux-ps/config.json");
    for (why, mut cfg) in [
        ("vmHost true", crate::config::Config::default()),
        ("vmHost false", crate::config::Config::default()),
        ("no config.json", crate::config::Config::load_from(missing).unwrap()),
    ] {
        cfg.vm_host = cfg.vm_host.or(match why {
            "vmHost true" => Some(true),
            "vmHost false" => Some(false),
            _ => None,
        });
        let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
        legacy_store(dir.path());
        let hub = hub_with(dir.path(), cfg);
        let local = if cfg!(target_os = "macos") {
            PermissionPolicy::ApproveAll
        } else {
            PermissionPolicy::Ask
        };
        assert_eq!(
            policies(&hub, [LOCAL, FORK_OF_LOCAL, VM_HOST_ERA]),
            [(LOCAL, local), (FORK_OF_LOCAL, local), (VM_HOST_ERA, PermissionPolicy::Ask)],
            "{why}"
        );
    }
}

/// Any start of a `clearedHost` chat's agent (here one with no agent host, as a pooled start
/// is not `start_hosted` either) ends the old host first and leaves the chat `cleared`: a later
/// restart adopts the host it started.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn any_start_turns_a_cleared_host_chat_cleared_first() {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"f": {"argv": ["python3", fake]}}, "defaultHarness": "f"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = super::NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
    let s = hub.new_session(req).await.unwrap();
    // No agent runs: the next `child_for` is a start (`reach_or_start`).
    hub.kill(&s, false).await.unwrap();
    s.meta.lock().unwrap().policy_source = Some(CLEARED_HOST.into());
    hub.child_for(&s).await.unwrap();
    assert_eq!(s.meta().policy_source.as_deref(), Some(CLEARED));
    let _ = hub.kill(&s, true).await;
}

/// A policy write to a `clearedHost` chat (the owner's one click, before its old host ended) keeps
/// the duty to end that host; the owner's approve-all then holds once it ended, and after a
/// restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_policy_set_before_the_old_host_ended_keeps_the_end_and_the_grant() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    legacy_store(dir.path());
    let hub = hub_at(dir.path());
    let s = hub.resolve(VM_HOST_ERA).unwrap();
    s.meta.lock().unwrap().policy_source = Some(CLEARED_HOST.into());
    for policy in [PermissionPolicy::Ask, PermissionPolicy::ApproveAll] {
        hub.set_policy_unless_moving(&s, policy).await.unwrap();
        assert_eq!(s.meta().policy_source.as_deref(), Some(CLEARED_HOST), "{policy}");
    }
    // No host runs here: the end is proven, and the owner's grant stays.
    assert!(hub.end_cleared_host(&s).await);
    assert_eq!(s.meta().policy_source.as_deref(), Some(CLEARED));
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::ApproveAll);
    hub.store.flush().unwrap();
    drop((s, hub));
    let hub = hub_at(dir.path());
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::ApproveAll, "cleared again");
}
