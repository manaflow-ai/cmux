use super::bundle_path_kind;

#[test]
fn durable_harness_journal_is_a_bundle_file() {
    assert_eq!(bundle_path_kind("harness/journal.ndjson"), Some(false));
    assert_eq!(bundle_path_kind("composers.json"), Some(false));
    let image = "ab".repeat(32);
    assert_eq!(bundle_path_kind(&format!("attachments/{image}")), Some(false));
    assert_eq!(bundle_path_kind("attachments/not-a-hash"), None);
    assert_eq!(bundle_path_kind(&format!("attachments/{}", "AB".repeat(32))), None);
    assert_eq!(bundle_path_kind(&format!("attachments/x/{image}")), None);
    assert_eq!(bundle_path_kind("harness/session.jsonl"), Some(false));
    assert_eq!(bundle_path_kind("harness/owner.sqlite"), None);
    assert_eq!(bundle_path_kind("harness/../journal.ndjson"), None);
}

/// The optional bundle files a client leaves out for an older target
/// (`capabilities::OPTIONAL_BUNDLE_FILES`) are the hub's own names, each one a guarded
/// receive here takes as a bundle file, never an agent store file; an unknown one is still
/// refused (the guard is unchanged), and no required file is optional.
#[test]
fn optional_bundle_files_are_the_guards_bundle_files() {
    use crate::capabilities::{TRANSFER_COMPOSERS, TRANSFER_IMAGES, optional_bundle_file};
    let image = format!("{}/{}", super::super::prompt_images::BUNDLE_DIR, "ab".repeat(32));
    let composers = super::super::composers::BUNDLE_FILE;
    assert_eq!(optional_bundle_file(composers), Some(TRANSFER_COMPOSERS));
    assert_eq!(optional_bundle_file(&image), Some(TRANSFER_IMAGES));
    assert_eq!(bundle_path_kind(composers), Some(false));
    assert_eq!(bundle_path_kind(&image), Some(false));
    for required in ["session.json", "manifest.json", "events/000001.ndjson"] {
        assert_eq!(optional_bundle_file(required), None, "{required}");
    }
    assert_eq!(bundle_path_kind("future.json"), None);
    assert_eq!(optional_bundle_file("future.json"), None);
}
