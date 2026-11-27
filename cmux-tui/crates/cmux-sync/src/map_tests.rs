use super::*;
use crate::hlc::MAX_DRIFT_MS;

type R = Replica<String, String>;

fn r(id: &str) -> R {
    Replica::new(Actor::new(id))
}

fn k(s: &str) -> String {
    s.to_owned()
}

#[test]
fn the_later_edit_wins_on_every_replica_whatever_the_order() {
    let (mut mac, mut phone) = (r("mac"), r("phone"));
    let a = mac.set(k("title"), k("from mac"), 1_000);
    let b = phone.set(k("title"), k("from phone"), 2_000);
    mac.apply(&b, 2_100);
    phone.apply(&a, 2_100);
    assert_eq!(mac.get(&k("title")), Some(&k("from phone")));
    assert_eq!(phone.get(&k("title")), Some(&k("from phone")));
    assert_eq!(mac.vv(), phone.vv());
}

#[test]
fn applying_twice_changes_nothing_the_second_time() {
    let (mut a, mut b) = (r("a"), r("b"));
    let d = a.set(k("pin"), k("yes"), 5);
    assert_eq!(b.apply(&d, 5).changed, vec![k("pin")]);
    assert_eq!(b.apply(&d, 5).changed, Vec::<String>::new());
}

#[test]
fn a_delete_is_not_undone_by_an_older_value_arriving_late() {
    let (mut a, mut b) = (r("a"), r("b"));
    let old = a.set(k("draft"), k("hello"), 10);
    b.apply(&old, 10);
    let del = b.delete(k("draft"), 20);
    a.apply(&del, 21);
    a.apply(&old, 22);
    assert_eq!(a.get(&k("draft")), None);
}

#[test]
fn a_gap_merges_but_does_not_advance_the_vector_until_filled() {
    let (mut a, mut b) = (r("a"), r("b"));
    let first = a.set(k("x"), k("1"), 1);
    let second = a.set(k("y"), k("2"), 2);
    let got = b.apply(&second, 3);
    assert!(got.gap);
    assert_eq!(b.get(&k("y")), Some(&k("2")));
    assert_eq!(b.vv().get(&Actor::new("a")), 0);
    let fill = a.delta_since(b.vv());
    assert!(!b.apply(&fill, 4).gap);
    assert_eq!(b.vv(), a.vv());
    drop(first);
}

#[test]
fn a_gap_for_an_overwritten_key_can_still_be_filled() {
    let (mut a, mut b) = (r("a"), r("b"));
    let first = a.set(k("x"), k("1"), 1);
    let second = a.set(k("x"), k("2"), 2);
    let got = b.apply(&second, 3);
    assert!(got.gap);
    assert_eq!(b.get(&k("x")), Some(&k("2")));
    let fill = a.delta_since(b.vv());
    assert_eq!(fill.entries.len(), 2);
    assert!(!b.apply(&fill, 4).gap);
    assert_eq!(b.vv(), a.vv());
    assert_eq!(b.get(&k("x")), Some(&k("2")));
    drop(first);
}

#[test]
fn a_local_edit_after_a_far_remote_stamp_wins_the_round_trip() {
    let (mut remote, mut local) = (r("remote"), r("local"));
    let far = remote.set(k("x"), k("remote"), MAX_DRIFT_MS + 10_000);
    local.apply(&far, 0);
    let mine = local.set(k("x"), k("local"), 1);
    assert!(mine.entries[0].1.stamp > far.entries[0].1.stamp);
    remote.apply(&mine, 1);
    let local_vv = local.vv().clone();
    let back = remote.delta_since(&local_vv);
    local.apply(&back, 1);
    assert_eq!(remote.get(&k("x")), Some(&k("local")));
    assert_eq!(local.get(&k("x")), Some(&k("local")));
}

#[test]
fn delta_since_ships_only_what_the_receiver_lacks() {
    let (mut a, mut b) = (r("a"), r("b"));
    for i in 0..100 {
        let d = a.set(format!("k{i}"), k("v"), i);
        b.apply(&d, i);
    }
    a.set(k("k3"), k("new"), 200);
    let d = a.delta_since(b.vv());
    assert_eq!(d.entries.len(), 1, "{d:?}");
    assert!(a.delta_since(a.vv()).is_empty());
}

#[test]
fn pending_counts_unacked_local_edits_and_state_follows() {
    let mut phone = r("phone");
    phone.set(k("a"), k("1"), 1);
    phone.set(k("b"), k("2"), 2);
    assert_eq!(phone.state(false), SyncState::Offline { pending: 2 });
    assert_eq!(phone.state(true), SyncState::Syncing { pending: 2 });
    phone.ack(&Vv::from([("phone", 2)]));
    assert_eq!(phone.state(true), SyncState::Synced);
}

#[test]
fn compact_drops_tombstones_only_when_everyone_has_them() {
    let (mut a, mut b) = (r("a"), r("b"));
    let d = a.set(k("x"), k("1"), 1);
    b.apply(&d, 1);
    let del = a.delete(k("x"), 2);
    assert_eq!(a.compact(&[a.vv().clone(), b.vv().clone()]), 0);
    b.apply(&del, 3);
    assert_eq!(a.compact(&[a.vv().clone(), b.vv().clone()]), 1);
    assert_eq!(a.len_with_tombstones(), 0);
}

#[test]
fn a_snapshot_round_trips_through_json_with_its_pending_edits() {
    let mut a = r("a");
    a.set(k("x"), k("1"), 1);
    let json = serde_json::to_string(&a.snapshot()).unwrap();
    let back: R = Replica::restore(serde_json::from_str(&json).unwrap());
    assert_eq!(back, a);
    assert_eq!(back.pending(), 1);
}

#[test]
fn sync_state_serializes_for_the_ui() {
    let s = serde_json::to_string(&SyncState::Offline { pending: 3 }).unwrap();
    assert_eq!(s, r#"{"state":"offline","pending":3}"#);
}
