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

/// `rows` through `cache` as the daemon lists them: each row's id and its compact bytes.
fn cached(cache: &mut RowCache, rows: &[Value], read: Option<&dyn Fn(Value) -> String>) -> Listed {
    let built: Vec<(Option<String>, String)> =
        rows.iter().map(|row| (id_of(row).map(str::to_owned), row.to_string())).collect();
    cache.listed(built.iter().map(|(id, text)| (id.as_deref(), text.as_str())), read)
}

/// A list made from the row cache is the list's text, and its delta to any `known` is the one
/// made from that text: the same rows, removed ids and count.
#[test]
fn a_cached_list_cuts_the_delta_its_text_makes() {
    let mut cache = RowCache::default();
    let rows = [row("a", "idle"), json!({"name": "no id"}), row("b", "working"), row("c", "idle")];
    let listed = cached(&mut cache, &rows, None);
    assert_eq!(*listed.text, list(&rows));
    let mut known = Known::default();
    for held in [&[][..], &[row("a", "idle"), row("b", "idle"), row("gone", "idle")][..]] {
        known.listed(held);
        let param = known.to_param();
        let param = param.as_object().unwrap();
        let ours: Value = serde_json::from_str(&listed.delta(param)).unwrap();
        let theirs: Value = serde_json::from_str(&delta(&listed.text, param).unwrap()).unwrap();
        assert_eq!(ours, theirs);
    }
}

/// A row whose bytes did not change since the last list is not read (masked) or hashed again; a
/// changed or new row is, and a row no longer listed leaves the cache. A masked row's digest is
/// the one the link makes of the row it reads.
#[test]
fn an_unchanged_row_is_read_and_hashed_once() {
    let reads = std::cell::Cell::new(0);
    let mask = |mut row: Value| {
        reads.set(reads.get() + 1);
        row["name"] = json!("masked");
        row.to_string()
    };
    let mut cache = RowCache::default();
    let first = [row("a", "idle"), row("b", "idle"), row("c", "idle")];
    let listed = cached(&mut cache, &first, Some(&mask));
    assert_eq!(reads.get(), 3);
    let read: Value = serde_json::from_str(&listed.text).unwrap();
    let rows = read["sessions"].as_array().unwrap();
    assert!(rows.iter().all(|r| r["name"] == "masked"), "{read}");
    let mut known = Known::default();
    known.listed(rows);
    let param = known.to_param();
    let unchanged: Value = serde_json::from_str(&listed.delta(param.as_object().unwrap())).unwrap();
    let theirs = delta(&listed.text, param.as_object().unwrap()).unwrap();
    assert_eq!(unchanged, serde_json::from_str::<Value>(&theirs).unwrap());
    assert_eq!(unchanged["unchanged"], 3, "{unchanged}");
    // b changed, c went, d came: only b and d are read.
    let listed =
        cached(&mut cache, &[row("a", "idle"), row("b", "working"), row("d", "idle")], Some(&mask));
    assert_eq!(reads.get(), 5);
    assert_eq!(cache.rows.len(), 3);
    assert!(!cache.rows.contains_key("c"));
    let reply: Value = serde_json::from_str(&listed.delta(param.as_object().unwrap())).unwrap();
    assert_eq!(ids(reply["sessions"].as_array().unwrap()), ["b", "d"]);
    assert_eq!(reply["removed"], json!(["c"]));
    // The same list again: nothing read.
    cached(&mut cache, &[row("a", "idle"), row("b", "working"), row("d", "idle")], Some(&mask));
    assert_eq!(reads.get(), 5);
}
