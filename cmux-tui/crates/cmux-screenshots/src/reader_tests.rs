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

/// Reads a fake disk (folder path to its entries) the way the app drives a walk.
fn walk(
    root: &str,
    rule: ScanRule,
    disk: &[(&str, Vec<Entry<'static>>)],
) -> (Vec<String>, Vec<String>, bool) {
    let mut walk = Walk::new(root, rule);
    let mut items = Vec::new();
    while let Some(folder) = walk.next_folder().map(str::to_owned) {
        let entries =
            disk.iter().find(|(path, _)| *path == folder).map(|(_, entries)| entries.as_slice());
        let kinds = walk.listed(entries);
        for (entry, kind) in entries.unwrap_or_default().iter().zip(kinds) {
            if kind.is_some() {
                items.push(child(&folder, entry.name));
            }
        }
    }
    (items, walk.folders().to_vec(), walk.readable())
}

fn file(name: &'static str, system_kind: MediaKind) -> Entry<'static> {
    entry(EntryKind::File, name, system_kind, 0.0)
}

fn folder(name: &'static str) -> Entry<'static> {
    entry(EntryKind::Folder, name, MediaKind::Other, 0.0)
}

/// Swift `listsPicturesAndMoviesOnlyAndSkipsHiddenFiles`: depth 0 stays in the folder.
#[test]
fn walk_lists_pictures_and_movies_only_and_skips_hidden_files() {
    let disk = [
        (
            "/s",
            vec![
                file("Screenshot 1.png", MediaKind::Image),
                file("Recording.mov", MediaKind::Video),
                file("notes.txt", MediaKind::Other),
                Entry { hidden: true, ..file(".Screenshot 2.png", MediaKind::Image) },
                folder("subfolder"),
            ],
        ),
        ("/s/subfolder", vec![file("deep.png", MediaKind::Image)]),
    ];
    let (items, folders, readable) = walk("/s", ScanRule::default(), &disk);
    assert!(readable);
    assert_eq!(folders, ["/s"]);
    assert_eq!(items, ["/s/Screenshot 1.png", "/s/Recording.mov"]);
}

/// Swift `entersOnlyPrefixedSubfoldersToTheRuleDepthAndReportsThem`.
#[test]
fn walk_enters_only_prefixed_subfolders_to_the_rule_depth() {
    let disk = [
        (
            "/s",
            vec![
                folder("NSIRD_screencaptureui_ab12"),
                folder("SomethingElse"),
                file("top.png", MediaKind::Image),
            ],
        ),
        (
            "/s/NSIRD_screencaptureui_ab12",
            vec![file("Screenshot.png", MediaKind::Image), folder("inner")],
        ),
        ("/s/NSIRD_screencaptureui_ab12/inner", vec![file("too-deep.png", MediaKind::Image)]),
        ("/s/SomethingElse", vec![file("other.png", MediaKind::Image)]),
    ];
    let rule = ScanRule::with_depth(1, Some("NSIRD_screencaptureui_"));
    let (mut items, folders, _) = walk("/s", rule, &disk);
    items.sort();
    assert_eq!(items, ["/s/NSIRD_screencaptureui_ab12/Screenshot.png", "/s/top.png"]);
    assert_eq!(folders, ["/s", "/s/NSIRD_screencaptureui_ab12"]);
}

/// Swift `aMissingFolderIsUnreadable`; an unreadable subfolder is skipped, not a failed read.
#[test]
fn walk_of_a_missing_folder_is_unreadable() {
    let (items, folders, readable) = walk("/gone", ScanRule::default(), &[]);
    assert!(!readable);
    assert!(items.is_empty() && folders.is_empty());
    let disk = [("/s", vec![folder("a"), file("x.png", MediaKind::Image)])];
    let (items, folders, readable) = walk("/s", ScanRule::with_depth(1, None), &disk);
    assert!(readable);
    assert_eq!((items, folders), (vec!["/s/x.png".to_owned()], vec!["/s".to_owned()]));
}

/// Folders come out depth first, in listing order (the order Swift's recursion read them).
#[test]
fn walk_reads_depth_first_in_listing_order() {
    let disk = [
        ("/", vec![folder("a"), folder("b")]),
        ("/a", vec![folder("c")]),
        ("/a/c", vec![]),
        ("/b", vec![]),
    ];
    let (_, folders, _) = walk("/", ScanRule::with_depth(2, None), &disk);
    assert_eq!(folders, ["/", "/a", "/a/c", "/b"]);
}
