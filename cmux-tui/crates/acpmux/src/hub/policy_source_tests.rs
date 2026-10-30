use super::{
    CLEARED, CLEARED_HOST, SET, VM_HOST, could_be_vm_host, settle_grant, settle_imported_grant,
};
use crate::config::PermissionPolicy;
use crate::hub::Hub;
use crate::store::Store as _;
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
    assert_eq!(hub.end_cleared_host(&s).await, super::ClearedHostEnd::Ended);
    assert_eq!(s.meta().policy_source.as_deref(), Some(CLEARED));
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::ApproveAll);
    hub.store.flush().unwrap();
    drop((s, hub));
    let hub = hub_at(dir.path());
    assert_eq!(answers(&hub, VM_HOST_ERA), PermissionPolicy::ApproveAll, "cleared again");
}

/// A store whose saved records lag their logs (a lost async save, `meta_writer.rs`): the
/// VM_HOST_ERA chat's `policy` approve-all record (seq 2) is past its saved `lastSeq` (1), and
/// an owner grant made after the upgrade (seq 3, with its source) is past it too on LOCAL.
fn lagging_store(dir: &std::path::Path) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    store.append(VM_HOST_ERA, &record(1, "created", json!({"harness": "claude"}))).unwrap();
    store.append(VM_HOST_ERA, &record(2, "policy", json!({"policy": "approve-all"}))).unwrap();
    let mut era = legacy(VM_HOST_ERA, true, Some("approve-all"));
    era.last_seq = 1;
    era.event_count = 1;
    store.save(&era).unwrap();
    store.append(LOCAL, &record(1, "created", json!({"harness": "claude"}))).unwrap();
    store.append(LOCAL, &record(2, "policy", json!({"policy": "ask", "source": SET}))).unwrap();
    store
        .append(LOCAL, &record(3, "policy", json!({"policy": "approve-all", "source": SET})))
        .unwrap();
    let mut local = legacy(LOCAL, false, Some("ask"));
    local.policy_source = Some(SET.into());
    local.last_seq = 1;
    local.event_count = 1;
    store.save(&local).unwrap();
    store.flush().unwrap();
}

/// A cleared approve-all stays cleared when the log tail is replayed over the saved record: the
/// load clears the stale record's grant, and the tail's older `policy` record (no source, an
/// older daemon's) must not bring it back. An owner's grant in the tail, logged with its source,
/// comes back with it.
#[tokio::test]
async fn a_cleared_approve_all_stays_cleared_when_the_log_tail_is_replayed() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
    lagging_store(dir.path());
    let hub = hub_at(dir.path());
    let era = hub.resolve(VM_HOST_ERA).unwrap();
    hub.catch_up(&era);
    assert_eq!(
        answers(&hub, VM_HOST_ERA),
        PermissionPolicy::Ask,
        "the replay granted approve-all again"
    );
    assert_eq!(era.meta().policy_source.as_deref(), Some(CLEARED));
    let local = hub.resolve(LOCAL).unwrap();
    hub.catch_up(&local);
    assert_eq!(
        answers(&hub, LOCAL),
        PermissionPolicy::ApproveAll,
        "the owner's logged grant was lost"
    );
    assert_eq!(local.meta().policy_source.as_deref(), Some(SET));
}

const HOSTED: &str = "01a15900-0000-7000-8000-000000000007";

/// A store whose approve-all is only in the log tail: HOSTED's saved record (`lastSeq` 1) names
/// no policy, and an older daemon's `policy` approve-all record (seq 2, no source) is past it.
fn tail_only_grant_store(dir: &std::path::Path) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    store.append(HOSTED, &record(1, "created", json!({"harness": "claude"}))).unwrap();
    store.append(HOSTED, &record(2, "policy", json!({"policy": "approve-all"}))).unwrap();
    let mut meta = legacy(HOSTED, true, None);
    meta.last_seq = 1;
    meta.event_count = 1;
    store.save(&meta).unwrap();
    store.flush().unwrap();
}

/// A daemon start over [`tail_only_grant_store`] in `dir`, its logs not read yet; HOSTED is in
/// the start's index of agent hosts still running (`load_from_store` reads it from the host
/// records) when `indexed`.
fn loaded_tail_only_grant(dir: &std::path::Path, indexed: bool) -> (Arc<Hub>, Arc<super::Session>) {
    tail_only_grant_store(dir);
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    let hub = Hub::new_loading(cfg, store, super::Mailbox::memory(), crate::supervised::embedded());
    if indexed {
        hub.load_plan.lock().unwrap().hosted.insert(HOSTED.into());
    }
    hub.load_from_store(true);
    let s = hub.resolve(HOSTED).unwrap();
    (hub, s)
}

/// The kinds of HOSTED's log records past the store's seed (`tail_only_grant_store`).
fn logged_kinds(hub: &Arc<Hub>) -> Vec<String> {
    hub.store.flush().unwrap();
    hub.store.events(HOSTED, 2, usize::MAX).unwrap().into_iter().map(|e| e.kind).collect()
}

/// A grant only the log replay clears ends the chat's surviving agent host too, as one the load
/// clears does (`settle_legacy_grants`): the host ran under it, maybe in a mode that never asks.
/// The replay makes it `clearedHost` when the start's index lists the host; and adoption, which
/// can reach a host before the background pass reads that chat's log, checks after the replay
/// (`ends_before_adoption`): the host is ended, never adopted, and nothing answers approve-all.
/// Adoption first, then the replay first, so each order is proven on its own.
#[tokio::test]
async fn a_grant_only_the_replay_clears_ends_its_surviving_host_before_adoption() {
    for replay_first in [false, true] {
        let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
        let (hub, s) = loaded_tail_only_grant(dir.path(), true);
        if replay_first {
            // As a daemon does: the hosted chats' logs, then adoption (`load_live_logs`).
            hub.load_live_logs();
            assert_eq!(s.meta().policy_source.as_deref(), Some(CLEARED_HOST), "replayed first");
        }
        assert!(
            hub.ends_before_adoption(&s, false).await,
            "replay first {replay_first}: adoption reached the host that ran under the approve-all"
        );
        assert_eq!(answers(&hub, HOSTED), PermissionPolicy::Ask, "replay first {replay_first}");
        // Ended (`cleared`), or not proven ended and kept unadoptable (`clearedHost`).
        let source = s.meta().policy_source;
        assert!(matches!(source.as_deref(), Some(CLEARED | CLEARED_HOST)), "{source:?}");
    }
}

/// The other side of the host rule: a chat the start's index does not list, whose host records
/// prove no host of it runs, has no host to end. Its replayed grant is `cleared` (ask), and
/// neither adoption nor a start ends anything, marks it unadoptable or refuses it.
#[tokio::test]
async fn a_grant_only_the_replay_clears_with_no_host_is_cleared_and_ends_nothing() {
    for replay_first in [false, true] {
        let dir = cmux_unix_socket::short_test_dir("acpmux-ps");
        let (hub, s) = loaded_tail_only_grant(dir.path(), false);
        assert!(Hub::host_record_gone(HOSTED), "the host records must prove no host runs");
        if replay_first {
            // As the background pass does (`load_session_logs`).
            hub.catch_up(&s);
            assert_eq!(s.meta().policy_source.as_deref(), Some(CLEARED), "replayed first");
        }
        assert!(
            !hub.ends_before_adoption(&s, false).await,
            "replay first {replay_first}: a chat with no host had a host to end"
        );
        assert!(hub.refuse_cleared_host(&s).await.is_ok(), "replay first {replay_first}: refused");
        assert_eq!(s.meta().policy_source.as_deref(), Some(CLEARED), "replay first {replay_first}");
        assert_eq!(answers(&hub, HOSTED), PermissionPolicy::Ask, "replay first {replay_first}");
        let kinds = logged_kinds(&hub);
        assert!(
            !kinds.iter().any(|k| k == "host_unadoptable" || k == "grant_cleared"),
            "replay first {replay_first}: {kinds:?}"
        );
    }
}

/// A memory store whose `tail_after` (the catch-up's one read of the log tail) fails, as a disk
/// that fails while the segments are listed or read.
struct TailUnreadable(crate::store::MemoryStore);

impl crate::store::Store for TailUnreadable {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        self.0.append(id, record)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn tail_after(
        &self,
        _id: &str,
        _after: u64,
        _kinds: &[&str],
        _visit: &mut dyn FnMut(EventRecord),
    ) -> anyhow::Result<(u64, u64)> {
        anyhow::bail!("the log segments could not be read")
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.0.delete(id)
    }
}

/// HOSTED as [`tail_only_grant_store`] leaves it, its host in the start's index, on a store whose
/// log tail cannot be read, and not caught up (its log not read yet).
fn tail_unreadable_hub() -> (Arc<Hub>, Arc<super::Session>) {
    let store = TailUnreadable(crate::store::MemoryStore::default());
    store.append(HOSTED, &record(1, "created", json!({"harness": "claude"}))).unwrap();
    store.append(HOSTED, &record(2, "policy", json!({"policy": "approve-all"}))).unwrap();
    let mut meta = legacy(HOSTED, true, None);
    meta.last_seq = 1;
    meta.event_count = 1;
    store.save(&meta).unwrap();
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(store));
    hub.load_plan.lock().unwrap().hosted.insert(HOSTED.into());
    let s = hub.make_session(meta);
    s.caught_up.store(false, std::sync::atomic::Ordering::SeqCst);
    hub.sessions.lock().unwrap().insert(HOSTED.into(), s.clone());
    (hub, s)
}

/// A tail replay that fails with an I/O error (not a panic) fails closed too: the tail may hold
/// a grant its replay would clear, so the host that ran under it is never adopted, and the start
/// that would reach it is refused. Once no host of it runs (proven here: there is none), the
/// chat's next start runs a new agent in its policy's mode.
#[tokio::test]
async fn a_tail_replay_that_fails_never_adopts_or_reaches_the_host() {
    let (hub, s) = tail_unreadable_hub();
    assert!(
        hub.ends_before_adoption(&s, false).await,
        "adoption reached a host whose log tail could not be replayed"
    );
    assert_eq!(answers(&hub, HOSTED), PermissionPolicy::Ask);
    let events = hub.store.events(HOSTED, 0, usize::MAX).unwrap();
    assert!(
        events
            .iter()
            .any(|e| e.kind == "host_unadoptable" && e.msg["reason"] == "grant_replay_failed"),
        "not marked unadoptable: {events:?}"
    );
    let (hub, s) = tail_unreadable_hub();
    assert!(
        hub.refuse_cleared_host(&s).await.is_err(),
        "a start went on to reach a host whose log tail could not be replayed"
    );
    assert!(Hub::host_record_gone(HOSTED), "the host records must prove no host runs");
    assert!(hub.refuse_cleared_host(&s).await.is_ok(), "the next start is refused for good");
}

/// The refusal of a start whose log tail could not be replayed says why, typed: the pane maps
/// `policy.replay_failed` to its own localized sentence (failureCopy.ts), and the recovery says
/// that sending again starts a fresh agent. The turn's record keeps the kind (`annotate` never
/// retypes a typed error), and the read's I/O error is kept for the refusal's log line.
#[tokio::test]
async fn a_failed_policy_replay_refuses_with_its_kind_and_recovery() {
    let (hub, s) = tail_unreadable_hub();
    let mut e = hub.refuse_cleared_host(&s).await.expect_err("the start was not refused");
    assert_eq!(e.message, "The chat's saved policy could not be read; its agent was stopped.");
    let data = e.data.clone().expect("the refusal is not typed");
    assert_eq!(data["errorKind"], crate::recovery::kind::POLICY_REPLAY_FAILED);
    assert_eq!(data["errorKind"], "policy.replay_failed");
    let recovery = data["recovery"].as_str().expect("no recovery");
    assert!(recovery.starts_with("Send the message again to start a fresh agent."), "{recovery}");
    let cause = s.tail_error.lock().unwrap().clone().expect("the I/O error was not kept");
    assert!(cause.contains("the log segments could not be read"), "{cause}");
    // As the unstarted turn's failure records it (`turns.rs` `fail_unstarted_turn`).
    crate::recovery::annotate(&mut e, None);
    let typed = crate::recovery::fields(&e);
    assert_eq!(typed["errorKind"], "policy.replay_failed");
    assert_eq!(typed["recovery"], data["recovery"]);
}
