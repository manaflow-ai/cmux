use super::*;

#[tokio::test]
async fn requested_folders_are_checked_canonical_and_listed_once() {
    let root = tempfile::tempdir().unwrap();
    let a = root.path().join("a");
    std::fs::create_dir(&a).unwrap();
    let a = std::fs::canonicalize(a).unwrap();
    let dotted = a.join("..").join("a");
    let got = requested(&json!({FIELD: [a, dotted]})).await.unwrap();
    assert_eq!(got, std::slice::from_ref(&a));
    assert!(requested(&json!({})).await.unwrap().is_empty());
    assert!(requested(&json!({FIELD: null})).await.unwrap().is_empty());
    for bad in [json!("x"), json!([1]), json!(["rel"]), json!([root.path().join("none")])] {
        assert!(requested(&json!({FIELD: bad})).await.is_err(), "{bad}");
    }
    let many: Vec<_> = (0..=MAX_DIRS).map(|_| a.clone()).collect();
    assert!(requested(&json!({FIELD: many})).await.is_err());
    assert!(without_cwd(vec![a.clone()], &a).is_empty());
}

#[test]
fn the_setting_adds_existing_folders_after_the_chats_own() {
    let root = tempfile::tempdir().unwrap();
    let home = std::fs::canonicalize(root.path()).unwrap();
    let (a, b) = (home.join("a"), home.join("b"));
    std::fs::create_dir(&a).unwrap();
    std::fs::create_dir(&b).unwrap();
    let file = home.join("f");
    std::fs::write(&file, "").unwrap();
    let doc = json!({"agents": {"additionalDirectories": [
        "~/a", b, "~/a", "relative", file, home.join("missing"), 3
    ]}});
    let got = from_settings_doc(&doc, Some(&home));
    assert_eq!(got, [a.clone(), b.clone()]);
    let flat = json!({SETTING: ["~/b"]});
    assert_eq!(from_settings_doc(&flat, Some(&home)), std::slice::from_ref(&b));
    assert!(from_settings_doc(&json!({}), Some(&home)).is_empty());
    assert_eq!(merged(vec![b.clone()], got), [b.clone(), a.clone()]);
    let full: Vec<_> = (0..MAX_DIRS).map(|i| home.join(i.to_string())).collect();
    assert_eq!(merged(full.clone(), vec![a]).len(), MAX_DIRS);
}

#[test]
fn the_added_folder_is_named_only_when_it_is_among_the_new_ones() {
    let root = tempfile::tempdir().unwrap();
    let a = std::fs::canonicalize(root.path()).unwrap().join("a");
    std::fs::create_dir(&a).unwrap();
    let dirs = vec![a.clone()];
    assert_eq!(
        added(&json!({"added": {"path": a, "from": "~/a"}}), &dirs),
        Some(json!({"path": a.to_string_lossy(), "from": "~/a"}))
    );
    assert_eq!(
        added(&json!({"added": {"path": a}}), &dirs),
        Some(json!({"path": a.to_string_lossy()}))
    );
    assert_eq!(added(&json!({"added": {"path": "/elsewhere"}}), &dirs), None);
    assert_eq!(added(&json!({}), &dirs), None);
    assert_eq!(
        added(&json!({"added": {"path": a, "from": 3}}), &dirs),
        Some(json!({"path": a.to_string_lossy()}))
    );
}
