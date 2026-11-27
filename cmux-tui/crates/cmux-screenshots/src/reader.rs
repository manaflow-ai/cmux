//! Which directory entries a folder scan lists or enters, and a folder's newest picture (Swift
//! `ScreenshotFolderReader`). The app lists the folder; these rules pick from the entries.

use crate::rule::{MediaKind, ScanRule};

/// What a directory entry is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    /// A regular file.
    File,
    /// A folder.
    Folder,
    /// A package (a folder Finder shows as a file).
    Package,
    /// A symlink, socket or anything else.
    Other,
}

impl EntryKind {
    /// The kind of a C ABI raw value (1 file, 2 folder, 3 package, anything else other).
    pub const fn from_raw(raw: u32) -> Self {
        match raw {
            1 => Self::File,
            2 => Self::Folder,
            3 => Self::Package,
            _ => Self::Other,
        }
    }
}

/// One entry of a folder listing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Entry<'a> {
    /// What it is.
    pub kind: EntryKind,
    /// Whether the file system hides it.
    pub hidden: bool,
    /// Its name.
    pub name: &'a str,
    /// What the system says its extension is.
    pub system_kind: MediaKind,
    /// Its modification time, seconds.
    pub modified: f64,
}

/// The kind the grid shows the entry as, or None when the rule does not list it.
pub fn item_kind(entry: &Entry<'_>, rule: &ScanRule) -> Option<MediaKind> {
    if entry.kind != EntryKind::File || entry.hidden {
        return None;
    }
    rule.kind_of_file_named(entry.name, entry.system_kind)
}

/// Whether the scan reads the entry as a subfolder, `depth` levels below the source folder.
pub fn enters(entry: &Entry<'_>, depth: usize, rule: &ScanRule) -> bool {
    matches!(entry.kind, EntryKind::Folder | EntryKind::Package)
        && !entry.hidden
        && depth < rule.depth
        && rule.enters_folder(entry.name)
}

/// The position of the newest picture among `entries` (the first listed wins a tie).
pub fn newest_picture(entries: &[Entry<'_>]) -> Option<usize> {
    let rule = ScanRule { kinds: MediaKind::Image.bit(), ..ScanRule::default() };
    let mut newest: Option<usize> = None;
    for (index, entry) in entries.iter().enumerate() {
        if item_kind(entry, &rule).is_none() {
            continue;
        }
        if newest.is_none_or(|n| entries.get(n).is_some_and(|old| old.modified < entry.modified)) {
            newest = Some(index);
        }
    }
    newest
}

#[cfg(test)]
mod tests {
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
}
