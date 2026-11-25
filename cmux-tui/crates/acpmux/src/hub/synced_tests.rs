use super::*;
use serde_json::json;

fn exchange(a: &Synced, b: &Synced) {
    // Each pulls what it lacks from the other, as a client's pull then push would.
    let (_, from_b, _) = b.pull(&a.lock().vv().clone());
    a.push(&from_b);
    let (_, from_a, _) = a.pull(&b.lock().vv().clone());
    b.push(&from_a);
}

#[test]
fn two_replicas_editing_offline_converge() {
    let mac = Synced::open(None);
    let phone = Synced::open(None);
    mac.record(title_key("s1"), json!("Release notes"));
    mac.record(read_key("s1"), json!(true));
    phone.record(title_key("s2"), json!("Bug bash"));
    phone.record(read_key("s1"), json!(false));
    exchange(&mac, &phone);
    for key in [title_key("s1"), title_key("s2"), read_key("s1")] {
        assert_eq!(mac.get(&key), phone.get(&key), "{key}");
        assert!(mac.get(&key).is_some(), "{key}");
    }
    // The later edit of the same key wins on both sides.
    assert_eq!(mac.get(&read_key("s1")), Some(json!(false)));
    // Exchanging again changes nothing.
    let (_, again, _) = mac.pull(&phone.lock().vv().clone());
    assert!(again.entries.is_empty());
}

#[test]
fn a_pull_carries_only_the_missed_edits() {
    let daemon = Synced::open(None);
    let phone = Synced::open(None);
    for i in 0..1000 {
        daemon.record(title_key(&format!("s{i}")), json!(format!("chat {i}")));
    }
    exchange(&phone, &daemon);
    assert_eq!(phone.get(&title_key("s999")), Some(json!("chat 999")));
    for i in 0..10 {
        daemon.record(read_key(&format!("s{i}")), json!(true));
    }
    let (_, delta, _) = daemon.pull(&phone.lock().vv().clone());
    assert_eq!(delta.entries.len(), 10, "ten edits behind out of 1010 keys");
}

#[test]
fn recording_the_value_already_there_is_no_edit() {
    let a = Synced::open(None);
    assert!(a.record(title_key("s1"), json!("x")));
    let vv = a.lock().vv().clone();
    assert!(!a.record(title_key("s1"), json!("x")));
    assert_eq!(a.lock().vv(), &vv);
}

#[test]
fn a_restart_keeps_the_replica_and_its_actor() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE);
    let actor = {
        let a = Synced::open(Some(path.clone()));
        a.record(title_key("s1"), json!("Kept"));
        a.record(read_key("s1"), json!(true));
        a.lock().actor().0.clone()
    };
    let b = Synced::open(Some(path));
    assert_eq!(b.lock().actor().0, actor);
    assert_eq!(b.get(&title_key("s1")), Some(json!("Kept")));
    assert_eq!(b.get(&read_key("s1")), Some(json!(true)));
}

#[test]
fn keys_name_their_field() {
    assert_eq!(field(&title_key("a")), Some(Field::Title("a".into())));
    assert_eq!(field(&read_key("b")), Some(Field::Read("b".into())));
    assert_eq!(field("pin/c"), None);
}
