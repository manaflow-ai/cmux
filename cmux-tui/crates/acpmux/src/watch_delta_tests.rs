use super::*;

fn row(id: &str, status: &str) -> Value {
    json!({"sessionId": id, "name": id, "status": status, "updatedAt": 5, "tags": ["a"]})
}

fn list(rows: &[Value]) -> String {
    json!({"sessions": rows}).to_string()
}

fn ids(rows: &[Value]) -> Vec<String> {
    let mut ids: Vec<String> = rows.iter().filter_map(id_of).map(str::to_owned).collect();
    ids.sort();
    ids
}

/// The daemon side, then the link's: a delta to `known` made whole again.
fn round(known: &mut Known, now: &[Value]) -> (Value, Vec<Value>) {
    let param = known.to_param();
    let reply: Value =
        serde_json::from_str(&delta(&list(now), param.as_object().unwrap()).unwrap()).unwrap();
    let (rows, removed) = read_delta(&reply).expect("a delta");
    let whole = known.patched(rows, &removed);
    (reply, whole)
}

#[test]
fn a_reconnect_reads_only_new_and_changed_rows_and_the_removed_ids() {
    let mut known = Known::default();
    assert!(known.is_empty());
    known.listed(&[row("a", "idle"), row("b", "idle"), row("c", "idle")]);
    let now = [row("a", "idle"), row("b", "working"), row("d", "idle")];
    let (reply, whole) = round(&mut known, &now);
    assert_eq!(ids(reply["sessions"].as_array().unwrap()), ["b", "d"]);
    assert_eq!(reply["removed"], json!(["c"]));
    assert_eq!(reply["unchanged"], 1);
    // The whole list, every row as the daemon lists it now.
    assert_eq!(ids(&whole), ["a", "b", "d"]);
    let b = whole.iter().find(|r| r["sessionId"] == "b").unwrap();
    assert_eq!(b["status"], "working");
    // Nothing changed: an empty delta, the same whole list.
    let (reply, whole) = round(&mut known, &now);
    assert_eq!(reply["sessions"], json!([]));
    assert_eq!(reply["removed"], json!([]));
    assert_eq!(ids(&whole), ["a", "b", "d"]);
}

/// A row that changed and changed back between two lists (A, then B by `session_changed`,
/// then A) is the row kept: it is made whole from what the link kept.
#[test]
fn a_row_changed_back_is_made_whole_from_the_kept_row() {
    let mut known = Known::default();
    known.listed(&[row("a", "idle"), row("b", "idle")]);
    let (reply, whole) = round(&mut known, &[row("a", "idle"), row("b", "idle")]);
    assert_eq!(reply["sessions"], json!([]));
    assert_eq!(reply["unchanged"], 2);
    assert_eq!(whole.iter().filter(|r| r["status"] == "idle").count(), 2);
}

#[test]
fn equal_rows_have_equal_digests_whatever_their_key_order() {
    let a: Value =
        serde_json::from_str(r#"{"b": 1, "a": [1, 2], "c": {"y": null, "x": "t"}}"#).unwrap();
    let b: Value =
        serde_json::from_str(r#"{"c": {"x": "t", "y": null}, "a": [1, 2], "b": 1}"#).unwrap();
    assert_eq!(digest(&a), digest(&b));
    assert_ne!(digest(&a), digest(&json!({"b": 2, "a": [1, 2], "c": {"y": null, "x": "t"}})));
    assert_eq!(digest(&a).len(), 16);
}

#[test]
fn a_whole_list_reply_is_no_delta() {
    assert!(read_delta(&json!({"sessions": []})).is_none());
    assert!(read_delta(&json!({"sessions": [], "delta": false})).is_none());
    assert!(delta("not json", &Map::new()).is_none());
}
