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
