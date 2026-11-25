//! The kin readers on the v2 list against v1's (agent service v2, row 7c part two; decision
//! 146, cmux#42609), through one run of an agent service in this process (acpmux's
//! `test-support` daemon): the children verb and the attach's descendants
//! (`agent_session_children::kin_ids`, then rows by id) against v1's walk of its whole list
//! (`agent_session_children::descendants`). The chief's work list is in `chief_work_tests.rs`.
//!
//! What the test names, each with a chat of its own:
//! 1. The edge followed. v1 follows `startedBy` (a sub-session's link) and `spawnedBy` (shown
//!    only under a root that is not archived); v2 follows each chat's one list parent: its
//!    lineage, else its sub-session's starter, else its `spawnedBy` tag (decisions 137, 140).
//!    So v2 lists more: a chat that `acpmux new` started under a chat that is not a root
//!    (`n1`), or under an archived one (`u1`), and an agent's chat whose lineage names a
//!    parent that is not a root (`l1`). A chat whose lineage and sub-session name two parents
//!    is under both on v1 and under its lineage's on v2 (`h1`); acpmux writes the two the same,
//!    so only a hand-edited store holds such a chat.
//! 2. Archived and side rows: the page's readers leave them out (row 7d); these readers never
//!    did, and an archived child is listed on both (`a1`).
//! 3. `forkSeq` grouping is the page's; a fork is not a child on either (`f1`).
//! 4. A peer's chats: never a child, on either (`peer-child`).
//! 5. A cold child of a cold row comes by a second ask (`list_source::kin`), tested in
//!    `agent_session_list_source_tests.rs`: this daemon's index is in memory, so it holds no
//!    snapshot part.
//! 6. The attach reads the hot part only (decision 301): the hub says `coldUnread` whenever its
//!    snapshot holds a row, so a cold read would grow every attach with the machine's closed
//!    chats. A child that sat in the snapshot's part at attach and is reopened later is not
//!    followed by that attachment until the next attach; part three's follow of `live` closes
//!    that. The children verb and the chief's work list read the cold kin too, at their cost.
//!    `agent_session_list_source_tests.rs` tests the hot-only walk.

use super::CALL_TIMEOUT;
use super::agent_session_children::{descendants, kin_ids, kin_source};
use super::agent_session_link::AcpmuxLink;
use super::agent_session_link::list_source::rows_by_id;
use acpmux::test_support::list_daemon::{self, Serves, insert, seed_down_peer};
use serde_json::{Value, json};
use std::collections::BTreeSet;

fn meta(id: &str, status: &str, at: u64, tags: Value) -> acpmux::store::SessionMeta {
    list_daemon::meta(id, id, status, at, tags).unwrap()
}

fn started_by(parent: &str, depth: u32) -> Option<acpmux::store::SubsessionLink> {
    serde_json::from_value(json!({"startedBy": parent, "shortName": "kin", "depth": depth})).ok()
}

fn lineage(parent: &str, root: &str, depth: u32) -> Option<acpmux::store::Lineage> {
    serde_json::from_value(json!({"parent": parent, "root": root, "depth": depth})).ok()
}

/// Every case of the module's list, and the rows the v2 index holds.
fn fixture(hub: &acpmux::hub::Hub) -> usize {
    let now = acpmux::store::now_ms();
    let at = |n: u64| now - 600_000 + n * 1_000;
    let mut rows = 0;
    let mut add = |meta| {
        insert(hub, meta);
        rows += 1;
    };
    add(meta("root", "ready", at(0), json!({})));
    add(meta("elsewhere", "ready", at(1), json!({})));
    let mut c1 = meta("c1", "running", at(2), json!({}));
    c1.subsession = started_by("root", 1);
    add(c1);
    let mut g1 = meta("g1", "closed", at(3), json!({}));
    g1.subsession = started_by("c1", 2);
    add(g1);
    add(meta("s1", "ready", at(4), json!({"spawnedBy": "root"})));
    let mut a1 = meta("a1", "ready", at(5), json!({"archived": "1"}));
    a1.subsession = started_by("root", 1);
    add(a1);
    let mut ap = meta("ap", "ready", at(6), json!({"archived": "1"}));
    ap.subsession = started_by("root", 1);
    add(ap);
    add(meta("u1", "ready", at(7), json!({"spawnedBy": "ap"})));
    add(meta("n1", "ready", at(8), json!({"spawnedBy": "c1"})));
    let mut l1 = meta("l1", "ready", at(9), json!({}));
    l1.lineage = lineage("c1", "root", 2);
    add(l1);
    let mut h1 = meta("h1", "ready", at(10), json!({}));
    h1.lineage = lineage("root", "root", 1);
    h1.subsession = started_by("elsewhere", 1);
    add(h1);
    let mut f1 = meta("f1", "ready", at(11), json!({}));
    f1.parent_id = Some("root".into());
    f1.fork_seq = Some(2);
    add(f1);
    add(meta("unrelated", "ready", at(12), json!({})));
    seed_down_peer(
        hub,
        "far",
        vec![json!({"sessionId": "peer-child", "qualifiedSessionId": "far/peer-child",
            "name": "far/child", "status": "running", "startedBy": "root", "updatedAt": at(13)})],
    );
    // The v2 index keeps a peer's live rows only.
    rows + 1
}

fn set(ids: impl IntoIterator<Item = impl Into<String>>) -> BTreeSet<String> {
    ids.into_iter().map(Into::into).collect()
}

fn v1_list(link: &AcpmuxLink) -> Vec<Value> {
    let all = link.call_whole_list("_acpmux/sessions", json!({}), CALL_TIMEOUT).unwrap();
    all["sessions"].as_array().unwrap().clone()
}

fn v1_ids(root: &str, sessions: &[Value]) -> BTreeSet<String> {
    set(descendants(root, sessions).iter().map(|row| row["sessionId"].as_str().unwrap().to_owned()))
}

/// Decision 146's differences, each named on its own chat: v2 lists `n1`, `u1` and `l1`
/// beside v1's children of `root`, and `h1` under `root` only, and every row both list is the
/// same row.
#[test]
fn the_kin_readers_differ_from_v1_only_where_decision_146_names() {
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    let daemon = runtime.block_on(list_daemon::serve(Serves::List, fixture)).unwrap();
    let link = AcpmuxLink::connect(&daemon.path, |_| {}).unwrap();
    let sessions = v1_list(&link);
    let v1 = v1_ids("root", &sessions);
    assert_eq!(v1, set(["c1", "g1", "s1", "a1", "ap", "h1"]), "v1's children of root");
    let v2 = set(v2_ids(&daemon.path, &link, "root").expect("the daemon serves v2"));
    let more = set(["n1", "u1", "l1"]);
    assert_eq!(v2, v1.union(&more).cloned().collect(), "v2 lists v1's and decision 146's more");
    // The two-links chat (a hand-edited store's): under both parents on v1, its lineage's on v2.
    assert!(v1_ids("elsewhere", &sessions).contains("h1"));
    let elsewhere = v2_ids(&daemon.path, &link, "elsewhere").unwrap();
    assert!(elsewhere.is_empty(), "{elsewhere:?}");
    // The rows the verb answers are v1's rows, by id, in v1's order.
    let ids: Vec<String> = v2.iter().cloned().collect();
    let rows = rows_by_id(&link, ids, CALL_TIMEOUT).unwrap();
    let whole: Vec<&Value> =
        sessions.iter().filter(|row| v2.contains(row["sessionId"].as_str().unwrap())).collect();
    assert_eq!(rows.iter().collect::<Vec<_>>(), whole, "v1's rows, in v1's order");
}

/// A daemon without the list (or with it off): the readers say so, and v1's walk runs.
#[test]
fn without_the_v2_list_the_kin_readers_read_v1() {
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    for serves in [Serves::NoV2, Serves::ListOff] {
        let daemon = runtime.block_on(list_daemon::serve(serves, fixture)).unwrap();
        let link = AcpmuxLink::connect(&daemon.path, |_| {}).unwrap();
        assert!(kin_source(&daemon.path, &link).unwrap().is_none(), "{serves:?}");
    }
}

/// `root`'s kin through the v2 list, cold kin too (the children verb's read); `None` without it.
fn v2_ids(socket: &std::path::Path, link: &AcpmuxLink, root: &str) -> Option<Vec<String>> {
    let mut source = kin_source(socket, link).unwrap()?;
    Some(kin_ids(&mut source, root, true).unwrap())
}
