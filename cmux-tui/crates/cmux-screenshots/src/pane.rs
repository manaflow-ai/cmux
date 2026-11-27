//! The Screenshots pane's source bookkeeping (Swift `ScreenshotsModel`): which folders each
//! source's last read covered, which sources could not be read, which folders are watched, which
//! source a path belongs to, and what one watch event means. The app reads the disk, runs the
//! reads and watches and keeps the listing; this decides what to read, watch, drop and look at.
//!
//! Each call returns a plan the app carries out: [`Pane::set_sources`] names the sources to drop
//! and to read, [`Pane::change`] says whether a watch event reads its source again or which
//! paths to look at, and [`Pane::entry_action`] says what one looked-at path does to the listing.

use crate::reader::{self, Entry, EntryKind};
use crate::rule::ScanRule;
use std::collections::{BTreeSet, HashMap, HashSet};

/// Above this many changed names in one watch batch, the source is read again.
pub const RESCAN_THRESHOLD: usize = 128;

/// One folder the pane shows, as the app's `ScreenshotSource` gives it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PaneSource {
    /// Stable id (`system`, `tool.<raw>`, `custom.<path>`...).
    pub id: String,
    /// What the source menu shows (a new label is a changed source).
    pub label: String,
    /// The folder's path, no trailing slash.
    pub folder: String,
    /// Whether files dropped on the pane may be saved here.
    pub accepts_drops: bool,
    /// Which files it lists.
    pub rule: ScanRule,
}

/// What [`Pane::set_sources`] asks the app to do.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SourcesPlan {
    /// Whether the sources differ from the ones shown (false: nothing else to do).
    pub changed: bool,
    /// Sources gone: cancel their reads and drop their files.
    pub removed: Vec<String>,
    /// Sources new or changed, in menu order: read them (when listing).
    pub read: Vec<String>,
}

/// What one watch event of a folder asks the app to do ([`Pane::change`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChangePlan {
    /// Not listing, or the folder is in no source: nothing.
    Ignore,
    /// Read the source again (lost events, a burst, or a non-file event).
    Rescan(String),
    /// Look at each path alone ([`Pane::entry_action`]), then read the source again when `relist`
    /// (a known subfolder changed).
    Look {
        /// The source the folder is in.
        source: String,
        /// Whether the source is read again after the looks.
        relist: bool,
        /// The changed paths that are not known subfolders, each once, in event order.
        paths: Vec<String>,
    },
}

/// What one looked-at path does to the listing ([`Pane::entry_action`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryAction {
    /// Drop the path from the listing (gone, or the rule leaves it out).
    Remove,
    /// A subfolder the rule enters appeared: read the source again.
    Relist,
    /// List the file (add it or move it to its new place).
    Upsert,
}

/// The pane's sources and what their reads found.
#[derive(Clone, Debug, Default)]
pub struct Pane {
    listing: bool,
    sources: Vec<PaneSource>,
    /// The folders each source's last read covered, by source id.
    folders: HashMap<String, Vec<String>>,
    /// Sources whose last read failed.
    unreadable: HashSet<String>,
}

/// How many folder levels `path` is below `root` (0 for the root itself).
fn depth(path: &str, root: &str) -> usize {
    if path == root {
        return 0;
    }
    path.get(root.len() + 1..).map_or(0, |rest| rest.split('/').filter(|p| !p.is_empty()).count())
}

/// `folder` joined with `name` (`URL.appendingPathComponent(_:).path`).
pub fn child_path(folder: &str, name: &str) -> String {
    let folder = folder.trim_end_matches('/');
    let name = name.trim_matches('/');
    if name.is_empty() {
        return folder.to_owned();
    }
    format!("{folder}/{name}")
}

impl Pane {
    /// A pane with no sources; `listing` reads and watches as soon as sources are set.
    pub fn new(listing: bool) -> Self {
        Self { listing, ..Self::default() }
    }

    /// Whether the folders are read and watched.
    pub const fn is_listing(&self) -> bool {
        self.listing
    }

    /// The sources, in menu order.
    pub fn sources(&self) -> &[PaneSource] {
        &self.sources
    }

    fn source(&self, id: &str) -> Option<&PaneSource> {
        self.sources.iter().find(|s| s.id == id)
    }

    /// Starts reading and watching; false when it already was (nothing to do). On true the app
    /// reads every source and watches [`Pane::watched`].
    pub fn start(&mut self) -> bool {
        if self.listing {
            return false;
        }
        self.listing = true;
        true
    }

    /// Stops reading and watching (access was taken back): forgets which sources failed and
    /// which subfolders they entered. The app stops its reads and watches and drops the listing.
    pub fn pause(&mut self) {
        self.listing = false;
        self.unreadable.clear();
        let mut folders = HashMap::new();
        for source in &self.sources {
            folders.entry(source.id.clone()).or_insert_with(|| vec![source.folder.clone()]);
        }
        self.folders = folders;
    }

    /// Shows these sources (menu order). The same sources again change nothing; a source gone
    /// forgets its folders and its failed read; a new or changed one is read from its folder.
    pub fn set_sources(&mut self, new: Vec<PaneSource>) -> SourcesPlan {
        if new == self.sources {
            return SourcesPlan::default();
        }
        let kept: HashSet<&str> = new.iter().map(|s| s.id.as_str()).collect();
        let mut removed = Vec::new();
        for source in &self.sources {
            if !kept.contains(source.id.as_str()) {
                removed.push(source.id.clone());
            }
        }
        for id in &removed {
            self.folders.remove(id);
            self.unreadable.remove(id);
        }
        let mut read = Vec::new();
        for source in &new {
            if self.source(&source.id) != Some(source) {
                read.push(source.id.clone());
            }
        }
        for id in &read {
            if let Some(source) = new.iter().find(|s| &s.id == id) {
                self.folders.insert(id.clone(), vec![source.folder.clone()]);
            }
        }
        self.sources = new;
        SourcesPlan { changed: true, removed, read }
    }

    /// Whether `id` is a source now (the selection keeps it, a finished read applies).
    pub fn has_source(&self, id: &str) -> bool {
        self.source(id).is_some()
    }

    /// Takes a finished read of `id`: the folders it covered (when `readable`) are watched from
    /// now on. False when `id` is no longer a source (the app drops the read).
    pub fn read_done(&mut self, id: &str, readable: bool, folders: Vec<String>) -> bool {
        let Some(source) = self.source(id) else { return false };
        let covered = if readable { folders } else { vec![source.folder.clone()] };
        self.folders.insert(id.to_owned(), covered);
        if readable {
            self.unreadable.remove(id);
        } else {
            self.unreadable.insert(id.to_owned());
        }
        true
    }

    /// The sources whose last read failed.
    pub fn unreadable(&self) -> BTreeSet<&str> {
        self.unreadable.iter().map(String::as_str).collect()
    }

    /// Whether the pane lists and every source's last read failed (missing permission, removed).
    pub fn access_missing(&self) -> bool {
        self.listing
            && !self.sources.is_empty()
            && self.sources.iter().all(|s| self.unreadable.contains(&s.id))
    }

    /// The source a drop is saved into: `selected` when it takes drops, else the first that does.
    pub fn drop_source(&self, selected: Option<&str>) -> Option<&PaneSource> {
        selected
            .and_then(|id| self.source(id))
            .filter(|s| s.accepts_drops)
            .or_else(|| self.sources.iter().find(|s| s.accepts_drops))
    }

    /// The folders to watch: every source's last read's folders (its folder before one), sorted.
    /// None when not listing (the app watches nothing and keeps its watches).
    pub fn watched(&self) -> Option<Vec<String>> {
        if !self.listing {
            return None;
        }
        let mut wanted = BTreeSet::new();
        for source in &self.sources {
            match self.folders.get(&source.id) {
                Some(folders) => wanted.extend(folders.iter().cloned()),
                None => {
                    wanted.insert(source.folder.clone());
                }
            }
        }
        Some(wanted.into_iter().collect())
    }

    /// The source whose folder holds `path` (the deepest; the first listed wins a tie).
    pub fn source_containing(&self, path: &str) -> Option<&PaneSource> {
        let mut best: Option<&PaneSource> = None;
        for source in &self.sources {
            let root = source.folder.as_str();
            let inside =
                path == root || path.strip_prefix(root).is_some_and(|rest| rest.starts_with('/'));
            if inside && best.is_none_or(|b| b.folder.len() < root.len()) {
                best = Some(source);
            }
        }
        best
    }

    /// What a watch event of `folder` asks: `names` are the changed entries' names, None for an
    /// event that is not a list of names (lost events, the folder itself went).
    pub fn change(&self, folder: &str, names: Option<&[String]>) -> ChangePlan {
        if !self.listing {
            return ChangePlan::Ignore;
        }
        let Some(source) = self.source_containing(folder) else { return ChangePlan::Ignore };
        let Some(names) = names.filter(|n| n.len() <= RESCAN_THRESHOLD) else {
            return ChangePlan::Rescan(source.id.clone());
        };
        let known: HashSet<&str> = self
            .folders
            .get(&source.id)
            .map(|f| f.iter().map(String::as_str).collect())
            .unwrap_or_default();
        let mut seen = HashSet::new();
        let mut relist = false;
        let mut paths = Vec::new();
        for name in names {
            if !seen.insert(name.as_str()) {
                continue;
            }
            let path = child_path(folder, name);
            if known.contains(path.as_str()) {
                relist = true;
            } else {
                paths.push(path);
            }
        }
        ChangePlan::Look { source: source.id.clone(), relist, paths }
    }

    /// Whether `path` sits where `source`'s rule lists files: below its folder, no deeper than
    /// its depth, every folder on the way one the rule enters.
    pub fn is_listed(source: &PaneSource, path: &str) -> bool {
        let root = source.folder.as_str();
        let Some(rest) = path.strip_prefix(root).and_then(|r| r.strip_prefix('/')) else {
            return false;
        };
        let parts: Vec<&str> = rest.split('/').filter(|p| !p.is_empty()).collect();
        if parts.is_empty() || parts.len() - 1 > source.rule.depth {
            return false;
        }
        parts[..parts.len() - 1].iter().enumerate().all(|(level, name)| {
            let entry = Entry {
                kind: EntryKind::Folder,
                hidden: false,
                name,
                system_kind: crate::rule::MediaKind::Other,
                modified: 0.0,
            };
            reader::enters(&entry, level, &source.rule)
        })
    }

    /// What the looked-at `path` of a watch event of `folder` in source `id` does to the
    /// listing: `entry` is what the disk says is there now, None when it is gone.
    pub fn entry_action(
        &self,
        id: &str,
        folder: &str,
        path: &str,
        entry: Option<&Entry<'_>>,
    ) -> EntryAction {
        let (Some(source), Some(entry)) = (self.source(id), entry) else {
            return EntryAction::Remove;
        };
        if reader::enters(entry, depth(folder, &source.folder), &source.rule) {
            return EntryAction::Relist;
        }
        if reader::item_kind(entry, &source.rule).is_some() && Self::is_listed(source, path) {
            EntryAction::Upsert
        } else {
            EntryAction::Remove
        }
    }
}

#[cfg(test)]
#[path = "pane_tests.rs"]
mod tests;
