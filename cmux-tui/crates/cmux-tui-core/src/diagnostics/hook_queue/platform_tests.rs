use super::*;

#[test]
fn no_hook_queue_without_file_identity() {
    let root = std::env::temp_dir().join("cmux-hook-queue-no-identity");
    let error = hook_spool_dir(&root.join("s.sock")).unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::Unsupported);
    assert!(existing_hook_spool_dir(&root.join("s.sock")).unwrap().is_none());
}
