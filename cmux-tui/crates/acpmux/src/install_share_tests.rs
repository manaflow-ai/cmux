use super::*;

#[test]
fn pending_keeps_clean_keys_bounded() {
    let mut pending = Pending::default();
    pending.add("npm", Some("npm:react"));
    pending.add("npm", Some("npm:react"));
    pending.add("npm", Some("npm:@bad"));
    pending.add("npm", Some("a path/with spaces"));
    pending.add("uv", None);
    pending.add("Bad Manager", None);
    assert_eq!(pending.counts.get("npm:react"), Some(&2));
    assert_eq!(pending.counts.len(), 1, "unclean keys are never kept: {pending:?}");
    assert_eq!(pending.manifests.get("uv"), Some(&1));
    assert_eq!(pending.manifests.len(), 1);

    let mut full = Pending::default();
    for i in 0..MAX_KEYS + 5 {
        full.add("npm", Some(&format!("npm:p{i}")));
    }
    assert_eq!(full.counts.len(), MAX_KEYS);
    full.add("npm", Some("npm:p0"));
    assert_eq!(full.counts.get("npm:p0"), Some(&2), "a known key still counts past the cap");
}

#[test]
fn a_batch_is_resent_with_its_id_until_accepted() {
    let mut pending = Pending::default();
    assert!(pending.next_batch(|| Some("a".repeat(24))).is_none(), "nothing pending: no upload");
    pending.add("npm", Some("npm:react"));
    let first = pending.next_batch(|| Some("a".repeat(24))).unwrap();
    assert_eq!(first.counts.get("npm:react"), Some(&1));
    assert!(pending.counts.is_empty(), "the batch took the counts");
    // A count made while the batch is out waits for the next batch.
    pending.add("npm", Some("npm:zod"));
    let retry = pending.next_batch(|| Some("b".repeat(24))).unwrap();
    assert_eq!(retry, first, "a retry resends the same batch and id");
    pending.sending = None;
    let next = pending.next_batch(|| Some("b".repeat(24))).unwrap();
    assert_eq!(next.id, "b".repeat(24));
    assert_eq!(next.counts.keys().collect::<Vec<_>>(), ["npm:zod"]);
}

#[test]
fn the_setting_reads_nested_or_dotted_and_is_off_by_default() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("cmux.json");
    assert!(!setting_on(&path), "no file: off");
    std::fs::write(&path, r#"{"diagnostics": {"shareInstallCounts": true}}"#).unwrap();
    assert!(setting_on(&path));
    std::fs::write(&path, r#"{"diagnostics.shareInstallCounts": true}"#).unwrap();
    assert!(setting_on(&path));
    std::fs::write(&path, r#"{"diagnostics": {"usagePatterns": true}}"#).unwrap();
    assert!(!setting_on(&path), "Usage Patterns alone shares nothing");
}

#[test]
fn install_ids_are_24_hex_and_differ() {
    let a = new_install_id().unwrap();
    let b = new_install_id().unwrap();
    assert_eq!(a.len(), 24);
    assert!(a.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    assert_ne!(a, b);
}
