//! The `list-notifications` change log: versions, deltas and the fall back to the whole ledger.

use super::*;

fn row(id: &str, title: &str) -> Value {
    json!({ "id": id, "title": title, "acknowledged": false })
}

fn ids(rows: &[Value]) -> Vec<&str> {
    rows.iter().filter_map(row_id).collect()
}

#[test]
fn an_unchanged_ledger_keeps_its_version_and_answers_an_empty_delta() {
    let mut log = NotificationListLog::default();
    let first = log.answer(vec![row("b", "two"), row("a", "one")], None);
    assert_eq!(first["notifications"].as_array().unwrap().len(), 2);
    let version = first["version"].as_str().unwrap().to_string();
    let again = log.answer(vec![row("b", "two"), row("a", "one")], Some(&version));
    assert_eq!(again["version"], version.as_str());
    assert_eq!(again["delta"], true);
    assert_eq!(again["notifications"], json!([]));
    assert_eq!(again["removed"], json!([]));
}

#[test]
fn a_delta_holds_the_changed_and_new_rows_newest_first_and_the_removed_ids() {
    let mut log = NotificationListLog::default();
    let base = log.answer(vec![row("c", "three"), row("b", "two"), row("a", "one")], None);
    let since = base["version"].as_str().unwrap().to_string();
    // One new row, one changed (read), one cleared.
    let mut read = row("b", "two");
    read["acknowledged"] = json!(true);
    let delta = log.answer(vec![row("d", "four"), row("c", "three"), read.clone()], Some(&since));
    assert_eq!(delta["delta"], true);
    assert_ne!(delta["version"], since.as_str());
    let rows = delta["notifications"].as_array().unwrap();
    assert_eq!(ids(rows), ["d", "b"]);
    assert_eq!(rows[1], read);
    assert_eq!(delta["removed"], json!(["a"]));
}

#[test]
fn a_delta_spans_every_version_after_since() {
    let mut log = NotificationListLog::default();
    let since = log.answer(vec![row("a", "one")], None)["version"].as_str().unwrap().to_string();
    log.record(vec![row("b", "two"), row("a", "one")]);
    log.record(vec![row("c", "three"), row("b", "two")]);
    // Added then removed: a client that never saw it is told to drop it, which it ignores.
    log.record(vec![row("c", "three")]);
    let (rows, removed) = log.since(&since).unwrap();
    assert_eq!(ids(&rows), ["c"]);
    assert_eq!(removed, ["a", "b"]);
}

#[test]
fn a_version_the_log_does_not_reach_gets_the_whole_ledger() {
    let mut log = NotificationListLog::default();
    let since = log.answer(vec![row("a", "x0")], None)["version"].as_str().unwrap().to_string();
    for i in 1..=LOGGED_VERSIONS + 1 {
        log.record(vec![row("a", &format!("x{i}"))]);
    }
    let whole = log.answer(vec![row("a", "last")], Some(&since));
    assert!(whole.get("delta").is_none(), "{whole}");
    assert_eq!(ids(whole["notifications"].as_array().unwrap()), ["a"]);

    // Another daemon run's version, one from the future, and garbage.
    let current = log.token();
    let (epoch, version) = current.rsplit_once('.').unwrap();
    let future = format!("{epoch}.{}", version.parse::<u64>().unwrap() + 1);
    for since in ["other.1", future.as_str(), "nonsense", ""] {
        assert!(log.since(since).is_none(), "{since}");
    }
    // The oldest version the log still reaches answers a delta.
    let oldest = log.changes.front().unwrap().version - 1;
    assert!(log.since(&format!("{epoch}.{oldest}")).is_some());
    assert!(log.since(&format!("{epoch}.{}", oldest - 1)).is_none());
}

#[test]
fn two_logs_never_share_versions() {
    let (a, b) = (NotificationListLog::default(), NotificationListLog::default());
    assert_ne!(a.token(), b.token());
    assert!(b.since(&a.token()).is_none());
}
