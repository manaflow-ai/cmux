//! The plan's thread counts through the v2 list (row 7c, R4) against v1's whole list, from an
//! agent service in this process (acpmux's `test-support` daemon), and its gate.

use super::{CALL_TIMEOUT, count, list_read, list_threads, threads};
use crate::server::agent_session_attach::agent_session_link::AcpmuxLink;
use acpmux::test_support::list_daemon::{
    self, ListDaemon, Serves, bound_away, emit, emit_with_all, insert, seed_down_peer,
};
use serde_json::{Value, json};
use std::path::Path;
use std::time::Instant;

/// The daemons' runtime: its workers serve while a test's thread makes its blocking calls.
fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap()
}

/// A session's record (`list_daemon::meta`).
fn meta(id: &str, name: &str, status: &str, at: u64, tags: Value) -> acpmux::store::SessionMeta {
    list_daemon::meta(id, name, status, at, tags).unwrap()
}

/// Every kind of row the plan counts or leaves out; the rows the v2 index holds.
fn fixture(hub: &acpmux::hub::Hub) -> usize {
    let now = acpmux::store::now_ms();
    let at = |n: u64| now - 600_000 + n * 1_000;
    let mut rows = 0;
    let mut add = |meta| {
        insert(hub, meta);
        rows += 1;
    };
    for (n, status) in
        ["ready", "running", "waiting", "idle", "disconnected", "closed"].into_iter().enumerate()
    {
        add(meta(
            &format!("c-{status}"),
            &format!("chat-{status}"),
            status,
            at(n as u64),
            json!({}),
        ));
    }
    // A running chat that is stuck: its summary's `state` reads `stuck`, its row's `status`
    // `running`.
    let mut stuck = meta("c-stuck", "stuck-run", "running", at(10), json!({}));
    stuck.harness_failures = serde_json::from_value(json!({"throughSeq": 9, "attempts": 3,
        "since": at(9), "reason": "auth", "error": "401 unauthorized"}))
    .unwrap();
    add(stuck);
    // The Home Chief's: by its tag, another chief's tag, its name and its harness.
    add(meta("c-chief", "home", "running", at(11), json!({"cmux.chief": "0a1b2c3d"})));
    add(meta("c-other-chief", "away", "ready", at(12), json!({"cmux.chief": "ffffffff"})));
    add(meta("c-optchat", "optchat-0a1b2c3d", "waiting", at(13), json!({})));
    let mut compact = meta("c-compact", "compact", "ready", at(14), json!({}));
    compact.harness = "optchat-compact-claude".into();
    add(compact);
    // Kin: a chief's child by `mux.parent`, a closed one, children of a closed and of an
    // archived parent, and a fork.
    let child = json!({"mux.parent": "optchat-chief:0a1b2c3d"});
    add(meta("c-chief-child", "worker", "running", at(15), child.clone()));
    add(meta("c-chief-child-closed", "worker-done", "closed", at(16), child));
    add(meta("c-closed-parent", "closed-parent", "closed", at(17), json!({})));
    add(meta("c-archived-parent", "archived-parent", "ready", at(18), json!({"archived": "1"})));
    add(meta(
        "c-under-closed",
        "under-closed",
        "ready",
        at(19),
        json!({"spawnedBy": "c-closed-parent"}),
    ));
    add(meta(
        "c-under-archived",
        "under-archived",
        "running",
        at(20),
        json!({"spawnedBy": "c-archived-parent"}),
    ));
    let mut fork = meta("c-fork", "fork", "ready", at(21), json!({}));
    fork.parent_id = Some("c-ready".into());
    fork.fork_seq = Some(3);
    add(fork);
    // Summaries whose `extra` is bounded away (the by-key read): a chief's and a running chat's.
    add(meta("c-bounded-chief", "home-2", "running", at(22), json!({"cmux.chief": "0a1b2c3d"})));
    add(meta("c-bounded", "bounded", "waiting", at(23), json!({})));
    // A peer's chats, live and closed: neither counted, neither in the local origin.
    seed_down_peer(
        hub,
        "far",
        vec![
            json!({"sessionId": "p-live", "qualifiedSessionId": "far/p-live", "name": "far/lane",
                "status": "running", "updatedAt": at(30)}),
            json!({"sessionId": "p-closed", "qualifiedSessionId": "far/p-closed",
                "name": "far/done", "status": "closed", "updatedAt": at(31)}),
        ],
    );
    // The v2 index keeps a peer's live rows only.
    rows + 1
}

/// A daemon serving [`fixture`] `serves`, its two rows bounded away when it has the list.
fn daemon(runtime: &tokio::runtime::Runtime, serves: Serves) -> ListDaemon {
    runtime.block_on(async {
        let daemon = list_daemon::serve(serves, fixture).await.unwrap();
        if let Some(v2) = &daemon.v2 {
            bound_away(v2, "c-bounded-chief").await.unwrap();
            bound_away(v2, "c-bounded").await.unwrap();
        }
        daemon
    })
}

/// v1's counts: every row, whole.
fn v1_threads(socket: &Path) -> (usize, usize) {
    let link = AcpmuxLink::connect(socket, |_| {}).unwrap();
    threads(&link.call_whole_list("_acpmux/sessions", json!({}), CALL_TIMEOUT).unwrap())
}

fn v2_threads(socket: &Path) -> Option<(usize, usize)> {
    let link = AcpmuxLink::connect(socket, |_| {}).unwrap();
    list_threads(&link, socket).unwrap()
}

/// Through the v2 list the plan counts what v1's whole list counts: ready, running, waiting
/// and stuck chats, a chief's child, children of closed and archived parents, a fork, and a
/// bounded-away running chat; not the Chief's (by tag, name or harness, bounded away too), a
/// peer's, or closed and idle ones.
#[test]
fn the_plan_counts_the_same_threads_through_the_v2_list_as_v1() {
    let runtime = runtime();
    let daemon = daemon(&runtime, Serves::List);
    let v1 = v1_threads(&daemon.path);
    assert_eq!(v1, (10, 6), "the fixture's v1 counts");
    assert_eq!(v2_threads(&daemon.path), Some(v1));
}

/// A daemon without the v2 list, and one whose list is off, give `None`: the plan reads v1.
#[test]
fn without_the_v2_list_the_plan_reads_v1() {
    let runtime = runtime();
    for serves in [Serves::NoV2, Serves::ListOff] {
        let daemon = daemon(&runtime, serves);
        assert_eq!(v2_threads(&daemon.path), None, "{serves:?}");
        assert_eq!(v1_threads(&daemon.path), (10, 6), "{serves:?}");
    }
}

/// The plan's list read: 20 live chats with 11,000 closed beside them against 20 live alone,
/// bytes received and wall time within 1.2x. Both daemons first, then their rounds in turn.
#[ignore = "Linux release gate: 20 live chats beside 11,000 closed against 20 alone"]
#[test]
fn v2_pr07c_update_plan() {
    let runtime = runtime();
    let gate = |closed| {
        runtime
            .block_on(list_daemon::serve(Serves::List, |hub| {
                list_daemon::twenty_live_beside(hub, closed).unwrap()
            }))
            .unwrap()
    };
    let (small, god) = (gate(0), gate(11_000));
    let small_proxy = runtime.block_on(list_daemon::counted(small.path)).unwrap();
    let god_proxy = runtime.block_on(list_daemon::counted(god.path)).unwrap();
    let run = |proxy: &list_daemon::Counted| {
        let before = proxy.sent();
        let started = Instant::now();
        let link = AcpmuxLink::connect(&proxy.path, |_| {}).unwrap();
        let read = list_read(&link, &proxy.path).unwrap();
        let wall = started.elapsed().as_nanos();
        // A timed sample proves it did the work (decision 271): an empty read is idle too.
        let read = read.expect("the gate's daemon serves the list");
        assert_eq!((read.live, read.running), (0, 0), "the gate's chats are idle");
        assert_eq!(read.rows, 20, "the plan read the gate's 20 live chats");
        // The sample's connections end before its bytes are read (`Counted::settled`), the
        // sample's own link with them.
        drop(link);
        runtime.block_on(proxy.settled()).unwrap();
        (wall, u128::from(proxy.sent() - before))
    };
    let fds = list_daemon::open_fds();
    let (mut small_wall, mut small_bytes, mut god_wall, mut god_bytes) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for _ in 0..5 {
        let (mut sw, mut sb, mut gw, mut gb) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for _ in 0..20 {
            let (wall, bytes) = run(&small_proxy);
            sw.push(wall);
            sb.push(bytes);
            let (wall, bytes) = run(&god_proxy);
            gw.push(wall);
            gb.push(bytes);
        }
        small_wall.push(sw);
        small_bytes.push(sb);
        god_wall.push(gw);
        god_bytes.push(gb);
        list_daemon::assert_fds_given_back("v2.pr07c.update_plan_wall", fds);
    }
    let name = "v2.pr07c.update_plan_bytes";
    let (small, god) = emit(name, &small_bytes, &god_bytes, "bytes");
    assert!(god.saturating_mul(100) <= small.saturating_mul(120), "{name}: {god} vs {small}");
    // Wall time: the best round within 1.2x, and every sample's p95 within 2x of it.
    let name = "v2.pr07c.update_plan_wall";
    let (small, god, god_all) = emit_with_all(name, &small_wall, &god_wall, "ns");
    assert!(god.saturating_mul(100) <= small.saturating_mul(120), "{name}: {god} vs {small}");
    assert!(god_all <= small.saturating_mul(2), "{name}: every sample {god_all} vs {small}");
}

/// Old and new acpmux rows side by side: a row with no `residency` (an older acpmux) counts by its
/// status as before; a v1 `residency` counts what is resident and busy; a newer version still
/// reads by the fields this build knows.
#[test]
fn threads_count_residency_when_a_row_has_it_and_status_when_not() {
    let rows = json!({"sessions": [
        {"sessionId": "old-ready", "status": "ready"},
        {"sessionId": "old-running", "status": "running"},
        {"sessionId": "old-idle", "status": "idle"},
        {"sessionId": "new-resident", "status": "ready", "residency": {"v": 1, "resident": true}},
        {"sessionId": "new-busy", "status": "running",
         "residency": {"v": 1, "resident": true, "busy": true,
                       "policy": {"name": "adaptive-v1", "idleSecs": 1800}}},
        {"sessionId": "new-hibernated", "status": "idle",
         "residency": {"v": 1, "resident": false, "hibernatedAt": 5}},
        {"sessionId": "newer", "status": "idle", "residency": {"v": 2, "resident": true, "gpuMb": 1}},
        {"sessionId": "unversioned", "status": "ready", "residency": {"resident": false}},
    ]});
    // live: old-ready, old-running, new-resident, new-busy, newer, unversioned (by status).
    assert_eq!(threads(&rows), (6, 2));
    let (mut live, mut running) = (0, 0);
    count("ready", Some(&json!({"v": 1, "resident": false})), &mut live, &mut running);
    assert_eq!((live, running), (0, 0), "a v1 row that is not resident costs nothing");
}
