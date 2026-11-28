//! Which directory entries a folder scan lists or enters, the order a source read lists its folders
//! in, and a folder's newest picture (Swift
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
        if newest.is_none_or(|n| entries.get(n).is_some_and(|e| e.modified < entry.modified)) {
            newest = Some(index);
        }
    }
    newest
}

/// One read of a source: which folders to list, in the order Swift's recursion listed them
/// (the source's folder, then each subfolder the rule enters, depth first), and which entries
/// of each listing are items. The app lists each folder `next_folder` names and hands the
/// listing back to `listed`.
#[derive(Clone, Debug)]
pub struct Walk {
    rule: ScanRule,
    pending: Vec<(String, usize)>,
    current: Option<(String, usize)>,
    folders: Vec<String>,
    readable: bool,
}

impl Walk {
    /// A read of the folder at `root` under `rule`.
    pub fn new(root: &str, rule: ScanRule) -> Self {
        Self {
            rule,
            pending: vec![(root.to_owned(), 0)],
            current: None,
            folders: Vec::new(),
            readable: true,
        }
    }

    /// The next folder to list, or None when the read is done.
    pub fn next_folder(&mut self) -> Option<&str> {
        self.current = self.pending.pop();
        self.current.as_ref().map(|(path, _)| path.as_str())
    }

    /// Takes the listing of the folder `next_folder` named (None: it could not be read) and
    /// returns the kind each entry is listed as (None: not listed, or a subfolder to read).
    pub fn listed(&mut self, entries: Option<&[Entry<'_>]>) -> Vec<Option<MediaKind>> {
        let Some((folder, depth)) = self.current.take() else { return Vec::new() };
        let Some(entries) = entries else {
            if depth == 0 && self.folders.is_empty() {
                self.readable = false;
            }
            return Vec::new();
        };
        self.folders.push(folder.clone());
        let mut entered = Vec::new();
        let kinds = entries
            .iter()
            .map(|entry| {
                if enters(entry, depth, &self.rule) {
                    entered.push((child(&folder, entry.name), depth + 1));
                    None
                } else {
                    item_kind(entry, &self.rule)
                }
            })
            .collect();
        self.pending.extend(entered.into_iter().rev());
        kinds
    }

    /// The folders listed so far: the source's folder and every subfolder the rule entered.
    pub fn folders(&self) -> &[String] {
        &self.folders
    }

    /// False when the source's own folder could not be read.
    pub const fn readable(&self) -> bool {
        self.readable
    }
}

/// `name` inside `folder` (Swift `appendingPathComponent(_:isDirectory:).path`).
fn child(folder: &str, name: &str) -> String {
    if folder.ends_with('/') { format!("{folder}{name}") } else { format!("{folder}/{name}") }
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

    /// Reads a fake disk (folder path to its entries) the way the app drives a walk.
    fn walk(
        root: &str,
        rule: ScanRule,
        disk: &[(&str, Vec<Entry<'static>>)],
    ) -> (Vec<String>, Vec<String>, bool) {
        let mut walk = Walk::new(root, rule);
        let mut items = Vec::new();
        while let Some(folder) = walk.next_folder().map(str::to_owned) {
            let entries = disk
                .iter()
                .find(|(path, _)| *path == folder)
                .map(|(_, entries)| entries.as_slice());
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
}
