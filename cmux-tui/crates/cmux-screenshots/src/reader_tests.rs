use super::*;

fn entry(kind: EntryKind, name: &str, system_kind: MediaKind, modified: f64) -> Entry<'_> {
    Entry { kind, hidden: false, name, system_kind, modified }
}

#[test]
fn lists_files_the_rule_takes() {
    let rule = ScanRule::default();
    let png = entry(EntryKind::File, "a.png", MediaKind::Image, 1.0);
    assert_eq!(item_kind(&png, &rule), Some(MediaKind::Image));
    assert_eq!(item_kind(&Entry { hidden: true, ..png }, &rule), None);
    assert_eq!(item_kind(&Entry { kind: EntryKind::Folder, ..png }, &rule), None);
    assert_eq!(item_kind(&entry(EntryKind::File, "a.txt", MediaKind::Other, 1.0), &rule), None);
}

#[test]
fn enters_folders_within_depth_and_prefix() {
    let rule = ScanRule::with_depth(1, Some("NSIRD_screencaptureui_"));
    let folder = entry(EntryKind::Folder, "NSIRD_screencaptureui_x", MediaKind::Other, 0.0);
    assert!(enters(&folder, 0, &rule));
    assert!(!enters(&folder, 1, &rule));
    assert!(enters(&Entry { kind: EntryKind::Package, ..folder }, 0, &rule));
    assert!(!enters(&Entry { kind: EntryKind::File, ..folder }, 0, &rule));
    assert!(!enters(&Entry { hidden: true, ..folder }, 0, &rule));
    assert!(!enters(&Entry { name: "Other", ..folder }, 0, &rule));
}

#[test]
fn newest_picture_skips_movies_and_folders_and_keeps_the_first_of_a_tie() {
    let entries = [
        entry(EntryKind::File, "old.png", MediaKind::Image, 1.0),
        entry(EntryKind::File, "newer.mov", MediaKind::Video, 9.0),
        entry(EntryKind::Folder, "dir.png", MediaKind::Image, 9.0),
        entry(EntryKind::File, "tie-a.png", MediaKind::Image, 5.0),
        entry(EntryKind::File, "tie-b.png", MediaKind::Image, 5.0),
    ];
    assert_eq!(newest_picture(&entries), Some(3));
    assert_eq!(newest_picture(&entries[1..3]), None);
}
