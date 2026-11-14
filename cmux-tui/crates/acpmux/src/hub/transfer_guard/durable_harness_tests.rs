use super::bundle_path_kind;

#[test]
fn durable_harness_journal_is_a_bundle_file() {
    assert_eq!(bundle_path_kind("harness/journal.ndjson"), Some(false));
    assert_eq!(bundle_path_kind("harness/session.jsonl"), Some(false));
    assert_eq!(bundle_path_kind("harness/owner.sqlite"), None);
    assert_eq!(bundle_path_kind("harness/../journal.ndjson"), None);
}
