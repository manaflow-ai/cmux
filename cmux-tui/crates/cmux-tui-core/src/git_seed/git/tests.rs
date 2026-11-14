use super::*;

#[test]
fn progress_lines_give_objects_and_bytes() {
    let mut progress = Progress::default();
    read_progress("Receiving objects:  45% (450/1000), 1.50 MiB | 2.00 MiB/s", &mut progress);
    assert_eq!(progress.objects, 450);
    assert_eq!(progress.total_objects, 1000);
    assert_eq!(progress.received_bytes, 1024 * 1024 * 3 / 2);
    read_progress("Resolving deltas:  10% (1/10)", &mut progress);
    assert_eq!(progress.objects, 450, "other lines change nothing");
    read_progress(
        "Receiving objects: 100% (1000/1000), 12 bytes | 1 bytes/s, done.",
        &mut progress,
    );
    assert_eq!(progress.objects, 1000);
    assert_eq!(progress.received_bytes, 12);
}

#[test]
fn failures_are_told_apart() {
    let auth = Failure {
            lines: vec![
                "cmux github credential: o/n: needs_github: install the cmux app at https://github.com/apps/cmux/installations/new.".into(),
                "fatal: could not read Username for 'https://github.com': terminal prompts disabled".into(),
            ],
        };
    assert!(auth.auth());
    assert!(!auth.disk_full());
    assert_eq!(
        auth.install_url().as_deref(),
        Some("https://github.com/apps/cmux/installations/new")
    );
    assert!(auth.message().starts_with("fatal: could not read Username"));
    let full = Failure::of("fatal: write error: No space left on device");
    assert!(full.disk_full());
    assert!(!full.auth());
    assert_eq!(full.install_url(), None);
}
