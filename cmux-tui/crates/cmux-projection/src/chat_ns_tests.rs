//! The chat namespace authority's rules on an injected clock (RFD 0007, "Consistency" and
//! "Leases"): close-to-open versions, acquire, renew, contend, expire, owner steal, and each
//! conflict copy raising exactly one popover-2 event.

use super::*;

const OWNER: &str = "agent";

fn writer(member: &str, actor: &str) -> Writer {
    Writer { member: member.into(), actor: actor.into() }
}

fn meta(size: u64) -> Meta {
    Meta {
        size,
        mtime_ns: i64::try_from(size).unwrap_or(0),
        mode: 0o644,
        chunks: vec![format!("c{size}")],
    }
}

fn ns() -> Authority {
    Authority::new("chat-1", [OWNER.to_owned()])
}

fn granted(answer: &Acquire) -> u64 {
    match answer {
        Acquire::Granted { token, .. } => *token,
        other => panic!("expected a grant, got {other:?}"),
    }
}

#[test]
fn close_bumps_version_and_invalidates_other_members() {
    let mut ns = ns();
    let a = writer("vm-a", OWNER);
    assert_eq!(ns.open("vm-b", "src/lib.rs", None, 0).version.seq, 0);
    assert_eq!(ns.open("vm-c", "src/lib.rs", None, 0).version.seq, 0);
    let token = granted(&ns.acquire(&a, "src/lib.rs", 10));
    let closed = ns.close(token, meta(7), 20).unwrap();
    assert_eq!(closed.path, "src/lib.rs");
    assert_eq!(closed.version.seq, 1);
    assert_eq!(closed.version.by, Some(a.clone()));
    assert_eq!(closed.invalidate, vec!["vm-b".to_owned(), "vm-c".to_owned()]);
    assert!(closed.released);
    assert!(closed.conflict.is_none());
    assert_eq!(ns.take_invalidations("vm-b"), vec!["src/lib.rs".to_owned()]);
    assert!(ns.take_invalidations("vm-b").is_empty(), "taken once");
    assert!(ns.take_invalidations("vm-a").is_empty(), "the writer keeps its own pages");

    let token = granted(&ns.acquire(&a, "src/lib.rs", 30));
    assert_eq!(ns.close(token, meta(9), 40).unwrap().version.seq, 2);
}

#[test]
fn open_after_close_sees_the_new_version() {
    let mut ns = ns();
    let a = writer("vm-a", OWNER);
    let before = ns.open("vm-b", "f", None, 0);
    let token = granted(&ns.acquire(&a, "f", 1));
    ns.close(token, meta(3), 2).unwrap();
    let after = ns.open("vm-b", "f", Some(before.version.seq), 3);
    assert!(after.stale, "B's cached pages are of the old version");
    assert_eq!(after.version.meta, meta(3));
    assert!(ns.take_invalidations("vm-b").is_empty(), "the open revalidated it already");
    let again = ns.open("vm-b", "f", Some(after.version.seq), 4);
    assert!(!again.stale);
}

#[test]
fn reads_never_take_a_lease() {
    let mut ns = ns();
    ns.open("vm-b", "f", None, 0);
    assert_eq!(ns.holder("f", 0), None);
    let token = granted(&ns.acquire(&writer("vm-c", "collab"), "f", 0));
    assert!(token > 0);
}

#[test]
fn lease_renews_on_any_call_and_heartbeat_then_expires_after_ttl() {
    let mut ns = ns();
    let a = writer("vm-a", "collab");
    granted(&ns.acquire(&a, "f", 0));
    assert_eq!(ns.heartbeat("vm-a", RENEW_EVERY_MS), 1);
    assert_eq!(ns.heartbeat("vm-a", 2 * RENEW_EVERY_MS), 1);
    // Any call renews too.
    ns.open("vm-a", "other", None, 3 * RENEW_EVERY_MS);
    assert_eq!(ns.holder("f", 3 * RENEW_EVERY_MS + LEASE_TTL_MS - 1), Some(a.clone()));
    assert_eq!(
        ns.holder("f", 3 * RENEW_EVERY_MS + LEASE_TTL_MS),
        None,
        "TTL 30 s past the last renewal"
    );
}

#[test]
fn concurrent_acquire_waits_up_to_five_seconds_then_writes_a_conflict_copy() {
    let mut ns = ns();
    let a = writer("vm-a", "collab-a");
    let b = writer("vm-b", "collab-b");
    let held = granted(&ns.acquire(&a, "notes.md", 0));
    match ns.acquire(&b, "notes.md", 1_000) {
        Acquire::Wait { retry_at_ms, holder } => {
            assert_eq!(retry_at_ms, 1_000 + CONTEND_MS);
            assert_eq!(holder, a);
        }
        other => panic!("expected a wait, got {other:?}"),
    }
    // Still waiting just before the bound; the first ask's time counts, not the latest.
    assert!(matches!(ns.acquire(&b, "notes.md", 5_999), Acquire::Wait { retry_at_ms: 6_000, .. }));
    ns.heartbeat("vm-a", 5_000);
    let private = match ns.acquire(&b, "notes.md", 6_000) {
        Acquire::Private { token, reason, theirs } => {
            assert_eq!(reason, ConflictReason::Contended);
            assert_eq!(theirs, a);
            token
        }
        other => panic!("never EBUSY: expected a private copy, got {other:?}"),
    };
    let closed = ns.close(private, meta(5), 6_500).unwrap();
    assert_eq!(closed.path, format!("notes.md{CONFLICT_SUFFIX}"));
    let event = closed.conflict.expect("one event");
    assert_eq!(event.kind, CONFLICT_KIND);
    assert_eq!(event.path, "notes.md");
    assert_eq!(event.mine, b);
    assert_eq!(event.theirs, Some(a.clone()));
    assert_eq!(event.choices, vec![Choice::KeepMine, Choice::KeepTheirs, Choice::OpenBoth]);
    // The holder's write is untouched and still publishes at the path.
    let mine = ns.close(held, meta(4), 7_000).unwrap();
    assert_eq!(mine.path, "notes.md");
    assert!(mine.conflict.is_none());
    assert_eq!(ns.version("notes.md").meta, meta(4));
    assert_eq!(ns.version(&format!("notes.md{CONFLICT_SUFFIX}")).meta, meta(5));
    assert_eq!(ns.pending().len(), 1);
}

#[test]
fn a_freed_lease_goes_to_the_waiter_without_a_conflict() {
    let mut ns = ns();
    let a = writer("vm-a", "collab-a");
    let b = writer("vm-b", "collab-b");
    let held = granted(&ns.acquire(&a, "f", 0));
    assert!(matches!(ns.acquire(&b, "f", 100), Acquire::Wait { .. }));
    ns.close(held, meta(1), 2_000).unwrap();
    let token = granted(&ns.acquire(&b, "f", 2_100));
    assert!(ns.close(token, meta(2), 2_200).unwrap().conflict.is_none());
    assert!(ns.pending().is_empty());
}

#[test]
fn members_of_one_actor_hand_the_lease_over_at_once() {
    let mut ns = ns();
    let agent_vm = writer("agent-vm", OWNER);
    let work_vm = writer("work-vm", OWNER);
    let first = granted(&ns.acquire(&agent_vm, "Cargo.lock", 0));
    let second = granted(&ns.acquire(&work_vm, "Cargo.lock", 1));
    assert_ne!(first, second);
    assert_eq!(ns.holder("Cargo.lock", 1), Some(work_vm.clone()));
    assert!(ns.close(first, meta(1), 2).unwrap().conflict.is_none());
    let closed = ns.close(second, meta(2), 3).unwrap();
    assert!(closed.conflict.is_none());
    assert!(closed.released);
    assert_eq!(ns.version("Cargo.lock").by, Some(work_vm));
}

#[test]
fn expired_holder_writes_become_a_conflict_copy_never_over_the_new_holder() {
    let mut ns = ns();
    let crashed = writer("vm-a", "collab-a");
    let next = writer("vm-b", "collab-b");
    let stale = granted(&ns.acquire(&crashed, "f", 0));
    // vm-a is partitioned: no renewals for 30 s.
    let fresh = granted(&ns.acquire(&next, "f", LEASE_TTL_MS));
    ns.close(fresh, meta(2), LEASE_TTL_MS + 10).unwrap();
    // vm-a reconnects and closes.
    let closed = ns.close(stale, meta(1), 90_000).unwrap();
    assert_eq!(closed.path, format!("f{CONFLICT_SUFFIX}"));
    let event = closed.conflict.unwrap();
    assert_eq!(event.reason, ConflictReason::Expired);
    assert_eq!(event.mine, crashed);
    assert_eq!(event.theirs, Some(next));
    assert_eq!(ns.version("f").meta, meta(2), "the new holder's bytes stay");
}

#[test]
fn expired_lease_with_no_new_holder_is_still_a_conflict() {
    let mut ns = ns();
    let a = writer("vm-a", "collab-a");
    let stale = granted(&ns.acquire(&a, "f", 0));
    let closed = ns.close(stale, meta(1), LEASE_TTL_MS + 1).unwrap();
    assert_eq!(closed.conflict.unwrap().reason, ConflictReason::Expired);
    assert_eq!(ns.version("f").seq, 0);
}

#[test]
fn owner_steals_without_waiting_and_collaborator_flush_window_is_two_seconds() {
    let mut ns = ns();
    let collab = writer("vm-c", "collab");
    let owner = writer("vm-o", OWNER);
    let theirs = granted(&ns.acquire(&collab, "README.md", 0));
    let mine = match ns.acquire(&owner, "README.md", 1_000) {
        Acquire::Granted { token, stole_from } => {
            assert_eq!(stole_from, Some(collab.clone()));
            token
        }
        other => panic!("the owner never waits, got {other:?}"),
    };
    assert_eq!(ns.holder("README.md", 1_000), Some(owner.clone()));
    // Within 2 s and before the owner publishes, what the collaborator closed still lands.
    let flushed = ns.close(theirs, meta(1), 1_000 + STEAL_FLUSH_MS).unwrap();
    assert_eq!(flushed.path, "README.md");
    assert!(flushed.conflict.is_none());
    assert!(!flushed.released, "the owner holds it now");
    ns.close(mine, meta(2), 3_500).unwrap();
    assert_eq!(ns.version("README.md").by, Some(owner));
}

#[test]
fn collaborator_close_after_steal_window_is_a_conflict_copy() {
    let mut ns = ns();
    let collab = writer("vm-c", "collab");
    let owner = writer("vm-o", OWNER);
    let theirs = granted(&ns.acquire(&collab, "f", 0));
    granted(&ns.acquire(&owner, "f", 1_000));
    let closed = ns.close(theirs, meta(1), 1_000 + STEAL_FLUSH_MS + 1).unwrap();
    assert_eq!(closed.path, format!("f{CONFLICT_SUFFIX}"));
    let event = closed.conflict.unwrap();
    assert_eq!(event.reason, ConflictReason::Stolen);
    assert_eq!(event.theirs, Some(owner));
}

#[test]
fn collaborator_close_after_owner_published_is_a_conflict_even_inside_the_window() {
    let mut ns = ns();
    let collab = writer("vm-c", "collab");
    let owner = writer("vm-o", OWNER);
    let theirs = granted(&ns.acquire(&collab, "f", 0));
    let mine = granted(&ns.acquire(&owner, "f", 1_000));
    ns.close(mine, meta(2), 1_100).unwrap();
    let closed = ns.close(theirs, meta(1), 1_200).unwrap();
    assert_eq!(closed.conflict.unwrap().reason, ConflictReason::Stolen);
    assert_eq!(ns.version("f").meta, meta(2));
}

#[test]
fn a_collaborator_cannot_steal_from_the_owner() {
    let mut ns = ns();
    let owner = writer("vm-o", OWNER);
    let collab = writer("vm-c", "collab");
    granted(&ns.acquire(&owner, "f", 0));
    assert!(matches!(ns.acquire(&collab, "f", 1), Acquire::Wait { .. }));
}

#[test]
fn each_conflict_copy_raises_exactly_one_event() {
    let mut ns = ns();
    let collab = writer("vm-c", "collab");
    let owner = writer("vm-o", OWNER);
    // Two open handles on one lease, then the owner steals it.
    let theirs = granted(&ns.acquire(&collab, "f", 0));
    assert_eq!(granted(&ns.acquire(&collab, "f", 1)), theirs);
    granted(&ns.acquire(&owner, "f", 10));
    let late = 10 + STEAL_FLUSH_MS + 1;
    let first = ns.close(theirs, meta(1), late).unwrap();
    let second = ns.close(theirs, meta(2), late + 1).unwrap();
    assert!(first.conflict.is_some());
    assert!(second.conflict.is_none(), "the same copy, no second event");
    assert_eq!(first.path, second.path);
    assert_eq!(ns.version(&first.path).meta, meta(2));
    assert_eq!(ns.pending().len(), 1);
    assert_eq!(ns.close(theirs, meta(3), late + 2), Err(NsError::UnknownToken(theirs)));
}

#[test]
fn repeated_conflicts_take_numbered_names_and_resolve_clears_them() {
    let mut ns = ns();
    let a = writer("vm-a", "collab-a");
    let mut ids = Vec::new();
    let mut paths = Vec::new();
    for round in 0..3u64 {
        let start = round * 100_000;
        let token = granted(&ns.acquire(&a, "f", start));
        let closed = ns.close(token, meta(round), start + LEASE_TTL_MS).unwrap();
        let event = closed.conflict.unwrap();
        ids.push(event.id);
        paths.push(closed.path);
    }
    assert_eq!(
        paths,
        vec![
            format!("f{CONFLICT_SUFFIX}"),
            format!("f{CONFLICT_SUFFIX}-2"),
            format!("f{CONFLICT_SUFFIX}-3")
        ]
    );
    let (event, choice) = ns.resolve(ids[1], Choice::KeepTheirs).unwrap();
    assert_eq!(event.conflict_path, paths[1]);
    assert_eq!(choice, Choice::KeepTheirs);
    assert_eq!(ns.pending().len(), 2);
    assert_eq!(ns.resolve(ids[1], Choice::OpenBoth), Err(NsError::UnknownEvent(ids[1])));
}

#[test]
fn reopen_by_holder_shares_the_grant_and_releases_at_last_close() {
    let mut ns = ns();
    let a = writer("vm-a", OWNER);
    let one = granted(&ns.acquire(&a, "f", 0));
    let two = granted(&ns.acquire(&a, "f", 1));
    assert_eq!(one, two);
    let first = ns.close(one, meta(1), 2).unwrap();
    assert!(!first.released);
    assert_eq!(ns.holder("f", 2), Some(a.clone()));
    let last = ns.close(two, meta(2), 3).unwrap();
    assert!(last.released);
    assert_eq!(ns.holder("f", 3), None);
    assert_eq!(ns.version("f").seq, 2, "each close is a version");
}

#[test]
fn authority_moves_whole_and_retimes_on_the_new_clock() {
    let mut ns = ns();
    let a = writer("vm-a", "collab-a");
    let token = granted(&ns.acquire(&a, "f", 0));
    let wire = serde_json::to_string(&ns).unwrap();
    let arrived: Authority = serde_json::from_str(&wire).unwrap();
    assert_eq!(arrived, ns);
    // The new machine's clock reads 5 ms; the lease does not lapse from the old clock's reading.
    let mut moved = arrived.moved(5);
    assert_eq!(moved.holder("f", 5 + LEASE_TTL_MS - 1), Some(a));
    let closed = moved.close(token, meta(1), 10).unwrap();
    assert!(closed.conflict.is_none());
}

#[test]
fn conflict_event_json_is_popover_two_shape() {
    let event = ConflictEvent {
        id: 1,
        kind: CONFLICT_KIND.into(),
        chat: "c".into(),
        path: "p".into(),
        conflict_path: format!("p{CONFLICT_SUFFIX}"),
        mine: writer("m", "a"),
        theirs: Some(writer("n", "b")),
        reason: ConflictReason::Contended,
        at_ms: 1,
        choices: vec![Choice::KeepMine, Choice::KeepTheirs, Choice::OpenBoth],
    };
    let value = serde_json::to_value(&event).unwrap();
    assert_eq!(value["kind"], "sync_conflict");
    assert_eq!(value["reason"], "contended");
    assert_eq!(value["choices"], serde_json::json!(["keep_mine", "keep_theirs", "open_both"]));
    assert_eq!(value["mine"]["member"], "m");
}
