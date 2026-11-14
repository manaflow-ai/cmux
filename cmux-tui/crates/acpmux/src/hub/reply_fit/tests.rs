use super::*;

#[test]
fn a_row_too_large_keeps_its_keys_and_a_preview_and_says_what_it_trimmed() {
    let mut row = json!({"sessionId": "s1", "status": "idle", "updatedAt": 5, "cwd": "/w",
            "title": "é".repeat(1 << 20), "turn": {"plan": ["x".repeat(1 << 19)]}});
    let before = size(&row);
    assert!(fit_object(&mut row, 64 << 10));
    assert!(size(&row) <= 64 << 10, "{}", size(&row));
    assert_eq!((row["sessionId"].as_str(), row["cwd"].as_str()), (Some("s1"), Some("/w")));
    let title = row["title"].as_str().unwrap();
    assert!(title.len() <= PREVIEW_BYTES && title.starts_with('é'));
    assert!(row.get("turn").is_none());
    assert_eq!(row["omitted"]["bytes"], before);
    assert_eq!(row["omitted"]["reason"], "too_large");
    assert_eq!(row["omitted"]["fields"], json!(["title", "turn"]));
    // One that fits is left as it was.
    let small = json!({"sessionId": "s2", "title": "t"});
    let mut same = small.clone();
    assert!(fit_object(&mut same, 1 << 10));
    assert_eq!(same, small);
}

#[test]
fn a_reply_whose_kept_field_alone_is_too_large_goes_as_a_stub() {
    let mut detail = json!({"sessionId": "s", "name": "n".repeat(REPLY_BYTES), "cwd": "/w"});
    fit_reply_object(&mut detail);
    assert_eq!(detail["sessionId"], "s");
    // The kept fields that are small stay, the huge one goes.
    assert!(detail.get("name").is_none());
    assert_eq!(detail["cwd"], "/w");
    assert_eq!(detail["omitted"]["reason"], "too_large");
}

#[test]
fn shrink_largest_replaces_largest_first_and_stops_once_it_fits() {
    let mut v = json!({"a": "x".repeat(100), "b": "y".repeat(300), "c": "z".repeat(200)});
    let bytes = size(&v);
    let ptrs = ["/a", "/b", "/c", "/missing"].map(str::to_owned);
    let done = shrink_largest(&mut v, bytes, bytes - 250, ptrs, |p, _| *p = Value::Null);
    assert_eq!(done, ["/b"]);
    assert!(v["b"].is_null() && v["a"].is_string() && v["c"].is_string());
}
