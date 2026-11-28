use super::*;

fn comment(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

#[test]
fn save_stamps_edits_and_deletes() {
    let mut file = File::default();
    let (first, _) = save(&mut file, "/r", "k1", comment(json!({"message": "a"}))).unwrap();
    let id = first["comment"]["id"].as_str().unwrap().to_string();
    assert!(id.starts_with("dc_") && id.len() == 35, "{first}");
    let created = first["comment"]["createdAt"].clone();
    assert_eq!(first["comment"]["updatedAt"], created);
    let edit = comment(json!({"id": id, "message": "b", "createdAt": "1999"}));
    let (edited, _) = save(&mut file, "/r", "k2", edit).unwrap();
    assert_eq!(edited["comment"]["createdAt"], created, "createdAt is the daemon's");
    assert_eq!(edited["comment"]["message"], "b");
    assert_eq!(file.comments.len(), 1);
    let (chosen, _) = save(&mut file, "/r", "k3", comment(json!({"id": "mine"}))).unwrap();
    assert_eq!(chosen["comment"]["id"], "mine");
    let (bad, _) = save(&mut file, "/r", "k4", comment(json!({"id": "has space"}))).unwrap();
    assert!(bad["comment"]["id"].as_str().unwrap().starts_with("dc_"));
    let stale = Map::from_iter([("mine".to_string(), json!("1999"))]);
    let (kept, changed) = delete(&mut file, &["mine".into()], &stale);
    assert_eq!(kept, json!({"deleted": 0, "ids": []}), "an edit since the caller read it stays");
    assert!(!changed);
    let (deleted, changed) = delete(&mut file, &[id.clone(), "unknown".into()], &Map::new());
    assert_eq!(deleted, json!({"deleted": 1, "ids": [id]}));
    assert!(changed);
    assert_eq!(file.comments.len(), 2);
}

#[test]
fn save_refuses_large_comments_and_full_roots() {
    let mut file = File::default();
    let large = comment(json!({"message": "x".repeat(MAX_COMMENT_BYTES)}));
    assert_eq!(save(&mut file, "/r", "k", large).unwrap_err().code, "validation.invalid");
    for index in 0..MAX_COMMENTS {
        save(&mut file, "/r", &format!("k{index}"), comment(json!({}))).unwrap();
    }
    let error = save(&mut file, "/r", "full", comment(json!({}))).unwrap_err();
    assert_eq!(error.details["reason"], "too_many_comments", "{error:?}");
}

#[test]
fn send_clears_only_comments_still_at_their_sent_version() {
    let mut file = File::default();
    let (a, _) = save(&mut file, "/r", "k1", comment(json!({"message": "a"}))).unwrap();
    let (b, _) = save(&mut file, "/r", "k2", comment(json!({"message": "b"}))).unwrap();
    let (a, b) = (a["comment"].clone(), b["comment"].clone());
    let ids = [a["id"].as_str().unwrap().to_string(), b["id"].as_str().unwrap().to_string()];
    let versions = Map::from_iter([
        (ids[0].clone(), a["updatedAt"].clone()),
        (ids[1].clone(), json!("1999-01-01T00:00:00.000Z")),
    ]);
    let (answer, changed) = cleared(&mut file, &ids, &versions, ids.len());
    assert_eq!(answer, json!({"sent": 2, "cleared": [ids[0]]}));
    assert!(changed);
    assert_eq!(file.comments.len(), 1, "the comment edited since the send stays");
    let (answer, changed) = cleared(&mut file, &ids[..1], &Map::new(), 1);
    assert_eq!(answer, json!({"sent": 1, "cleared": []}));
    assert!(!changed);
}

#[test]
fn send_fields_are_checked() {
    let fields = |value: Value| value.as_object().unwrap().clone();
    let ok = fields(json!({"acp_session": "fake-session-1", "text": "Review comment"}));
    assert_eq!(acp_session(&ok).unwrap(), "fake-session-1");
    assert_eq!(prompt(&ok).unwrap(), "Review comment");
    for bad in [json!({}), json!({"acp_session": ""}), json!({"acp_session": "a b"})] {
        let error = acp_session(&fields(bad)).unwrap_err();
        assert_eq!(error.code, "validation.invalid");
    }
    let large = "x".repeat(MAX_PROMPT_BYTES + 1);
    for bad in [json!({}), json!({"text": " \n"}), json!({"text": large})] {
        assert_eq!(prompt(&fields(bad)).unwrap_err().code, "validation.invalid");
    }
    assert!(prompt(&fields(json!({"text": "x".repeat(MAX_PROMPT_BYTES)}))).is_ok());
}

#[test]
fn store_round_trips_and_lists_oldest_first() {
    let directory =
        std::env::temp_dir().join(format!("diff-comments-{}-{}", std::process::id(), now_ms()));
    let store = Store::at(directory.clone());
    assert!(store.read("/repo").unwrap().comments.is_empty());
    let mut file = store.read("/repo").unwrap();
    file.comments.push(comment(json!({"id": "b", "createdAt": "2026-11-07T12:00:01.000Z"})));
    file.comments.push(comment(json!({"id": "a", "createdAt": "2026-11-07T12:00:00.000Z"})));
    store.write("/repo", &file).unwrap();
    let read = store.read("/repo").unwrap();
    let ids: Vec<_> = read.sorted().iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["a", "b"]);
    assert!(store.read("/other").unwrap().comments.is_empty());
    let _ = std::fs::remove_dir_all(directory);
}
