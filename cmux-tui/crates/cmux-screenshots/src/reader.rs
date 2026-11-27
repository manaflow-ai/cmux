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
        if newest.is_none_or(|n| entries[n].modified < entry.modified) {
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
#[path = "reader_tests.rs"]
mod tests;
