use super::*;

#[test]
fn a_rollback_is_kept_as_the_last_failure_across_later_runs() {
    let home = tempfile::tempdir().unwrap();
    assert_eq!(read_in(home.path()), Value::Null, "no update ran here");
    record_in(
        home.path(),
        json!({"channel": "feat-cmux-next", "outcome": "rolledBack",
        "reason": "abiIncompatible", "build": "0b3a76d55 2026-10-20", "error": null}),
    );
    let first = read_in(home.path());
    assert_eq!(first["schema"], json!(SCHEMA));
    assert_eq!(first["outcome"], json!("rolledBack"));
    assert!(first.get("error").is_none(), "nulls are dropped");
    assert!(first["at"].as_u64().unwrap() > 0);
    assert_eq!(first["lastFailure"]["reason"], json!("abiIncompatible"));

    record_in(home.path(), json!({"channel": "feat-cmux-next", "skipped": "rolledBack"}));
    let second = read_in(home.path());
    assert!(second.get("outcome").is_none());
    assert_eq!(second["skipped"], json!("rolledBack"));
    assert_eq!(second["lastFailure"]["reason"], json!("abiIncompatible"), "kept");
}

#[test]
fn a_file_that_is_not_an_inventory_reads_as_none() {
    let home = tempfile::tempdir().unwrap();
    std::fs::write(path_in(home.path()), b"{\"schema\": \"other\"}").unwrap();
    assert_eq!(read_in(home.path()), Value::Null);
}
