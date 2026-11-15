use super::*;

#[test]
fn records_deliveries_erasure_and_forgetting_with_one_holder_id() {
    let home = tempfile::tempdir().unwrap();
    let record = Record::new(home.path());
    let id = record.holder_id();
    assert_eq!(id.len(), 36);
    assert_eq!(record.holder_id(), id, "the id is kept");
    assert!(record.entries().is_empty());
    record.delivered("one");
    record.delivered("two");
    assert_eq!(record.entries(), HashMap::from([("one".into(), false), ("two".into(), false)]));
    record.mark_all_for_erasure();
    assert_eq!(record.entries(), HashMap::from([("one".into(), true), ("two".into(), true)]));
    record.delivered("one");
    assert!(!record.entries()["one"]);
    record.forget("one");
    record.forget("two");
    assert!(!record.file.exists(), "an empty record is no file");
}

#[test]
fn reads_the_swift_holders_record() {
    let home = tempfile::tempdir().unwrap();
    let record = Record::new(home.path());
    std::fs::write(
        &record.file,
        r#"{"machines":{"a":{"erase":true},"b":{"erase":false},"":{}},"schema":1}"#,
    )
    .unwrap();
    std::fs::write(home.path().join("holder-id"), "abc\n").unwrap();
    assert_eq!(record.entries(), HashMap::from([("a".into(), true), ("b".into(), false)]));
    assert_eq!(record.holder_id(), "abc");
    std::fs::write(&record.file, r#"{"machines":{"a":{}},"schema":2}"#).unwrap();
    assert!(record.entries().is_empty(), "another schema is none");
}
