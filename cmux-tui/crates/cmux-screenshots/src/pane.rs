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
mod tests {
    use super::*;
    use crate::rule::MediaKind;

    fn source(id: &str, folder: &str, drops: bool, rule: ScanRule) -> PaneSource {
        PaneSource {
            id: id.into(),
            label: id.into(),
            folder: folder.into(),
            accepts_drops: drops,
            rule,
        }
    }

    fn system() -> PaneSource {
        source("system", "/u/Desktop", true, ScanRule::default())
    }

    fn preview() -> PaneSource {
        source(
            "system.preview",
            "/t/TemporaryItems",
            false,
            ScanRule::with_depth(1, Some("NSIRD_screencaptureui_")),
        )
    }

    fn file<'a>(name: &'a str, kind: MediaKind) -> Entry<'a> {
        Entry { kind: EntryKind::File, hidden: false, name, system_kind: kind, modified: 1.0 }
    }

    fn folder_entry(name: &str) -> Entry<'_> {
        Entry {
            kind: EntryKind::Folder,
            hidden: false,
            name,
            system_kind: MediaKind::Other,
            modified: 1.0,
        }
    }

    fn strings(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn new_sources_are_read_and_the_same_sources_change_nothing() {
        let mut pane = Pane::new(true);
        let plan = pane.set_sources(vec![system(), preview()]);
        assert!(plan.changed);
        assert_eq!(plan.read, ["system", "system.preview"]);
        assert!(plan.removed.is_empty());
        assert_eq!(pane.set_sources(vec![system(), preview()]), SourcesPlan::default());
        assert_eq!(pane.watched().unwrap(), ["/t/TemporaryItems", "/u/Desktop"]);
    }

    #[test]
    fn a_changed_source_is_read_again_and_a_kept_one_is_not() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![system(), preview()]);
        let mut moved = system();
        moved.folder = "/u/Shots".into();
        let plan = pane.set_sources(vec![moved, preview()]);
        assert_eq!(plan.read, ["system"]);
        let mut renamed = preview();
        renamed.label = "Preview".into();
        let plan = pane.set_sources(vec![pane.sources()[0].clone(), renamed]);
        assert_eq!(plan.read, ["system.preview"]);
    }

    #[test]
    fn removing_a_source_forgets_its_folders_and_failed_read() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![system(), preview()]);
        assert!(pane.read_done("system.preview", false, vec![]));
        let plan = pane.set_sources(vec![system()]);
        assert_eq!(plan.removed, ["system.preview"]);
        assert!(plan.read.is_empty());
        assert!(pane.unreadable().is_empty());
        assert_eq!(pane.watched().unwrap(), ["/u/Desktop"]);
        assert!(!pane.has_source("system.preview"));
        assert!(!pane.read_done("system.preview", true, vec!["/t".into()]));
    }

    #[test]
    fn a_read_watches_the_subfolders_it_entered() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![preview()]);
        pane.read_done(
            "system.preview",
            true,
            strings(&["/t/TemporaryItems", "/t/TemporaryItems/NSIRD_screencaptureui_1"]),
        );
        assert_eq!(
            pane.watched().unwrap(),
            ["/t/TemporaryItems", "/t/TemporaryItems/NSIRD_screencaptureui_1"]
        );
    }

    #[test]
    fn an_unreadable_folder_is_reported_and_watched_alone() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![system()]);
        assert!(!pane.access_missing());
        pane.read_done("system", false, strings(&["/u/Desktop", "/u/Desktop/x"]));
        assert_eq!(pane.unreadable().into_iter().collect::<Vec<_>>(), ["system"]);
        assert!(pane.access_missing());
        assert_eq!(pane.watched().unwrap(), ["/u/Desktop"]);
        pane.read_done("system", true, strings(&["/u/Desktop"]));
        assert!(!pane.access_missing());
    }

    #[test]
    fn access_is_missing_only_when_every_source_failed_while_listing() {
        let mut pane = Pane::new(true);
        assert!(!pane.access_missing());
        pane.set_sources(vec![system(), preview()]);
        pane.read_done("system", false, vec![]);
        assert!(!pane.access_missing());
        pane.read_done("system.preview", false, vec![]);
        assert!(pane.access_missing());
        pane.pause();
        assert!(!pane.access_missing());
    }

    #[test]
    fn a_pane_not_started_watches_nothing_until_started() {
        let mut pane = Pane::new(false);
        pane.set_sources(vec![system()]);
        assert_eq!(pane.watched(), None);
        assert_eq!(pane.change("/u/Desktop", Some(&strings(&["a.png"]))), ChangePlan::Ignore);
        assert!(pane.start());
        assert!(!pane.start());
        assert_eq!(pane.watched().unwrap(), ["/u/Desktop"]);
    }

    #[test]
    fn pause_forgets_failed_reads_and_entered_subfolders() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![preview()]);
        pane.read_done(
            "system.preview",
            true,
            strings(&["/t/TemporaryItems", "/t/TemporaryItems/NSIRD_screencaptureui_1"]),
        );
        pane.pause();
        assert!(!pane.is_listing());
        assert_eq!(pane.watched(), None);
        pane.start();
        assert_eq!(pane.watched().unwrap(), ["/t/TemporaryItems"]);
    }

    #[test]
    fn drops_go_to_the_selected_folder_when_it_takes_them_else_the_first_that_does() {
        let mut pane = Pane::new(true);
        let custom = source("custom./x", "/x", true, ScanRule::default());
        pane.set_sources(vec![preview(), system(), custom]);
        assert_eq!(pane.drop_source(None).map(|s| s.id.as_str()), Some("system"));
        assert_eq!(pane.drop_source(Some("custom./x")).map(|s| s.id.as_str()), Some("custom./x"));
        assert_eq!(pane.drop_source(Some("system.preview")).map(|s| s.id.as_str()), Some("system"));
        assert_eq!(pane.drop_source(Some("gone")).map(|s| s.id.as_str()), Some("system"));
        pane.set_sources(vec![preview()]);
        assert_eq!(pane.drop_source(None), None);
    }

    #[test]
    fn the_deepest_source_holds_a_path() {
        let mut pane = Pane::new(true);
        let inner =
            source("custom./u/Desktop/Shots", "/u/Desktop/Shots", true, ScanRule::default());
        pane.set_sources(vec![system(), inner]);
        let id = |p: &str| pane.source_containing(p).map(|s| s.id.clone());
        assert_eq!(id("/u/Desktop/a.png").as_deref(), Some("system"));
        assert_eq!(id("/u/Desktop/Shots/a.png").as_deref(), Some("custom./u/Desktop/Shots"));
        assert_eq!(id("/u/Desktop").as_deref(), Some("system"));
        assert_eq!(id("/u/DesktopX/a.png"), None);
    }

    #[test]
    fn a_burst_or_a_non_name_event_reads_the_source_again() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![system()]);
        assert_eq!(pane.change("/u/Desktop", None), ChangePlan::Rescan("system".into()));
        let many: Vec<String> = (0..=RESCAN_THRESHOLD).map(|i| format!("{i}.png")).collect();
        assert_eq!(pane.change("/u/Desktop", Some(&many)), ChangePlan::Rescan("system".into()));
        let fits: Vec<String> = (0..RESCAN_THRESHOLD).map(|i| format!("{i}.png")).collect();
        assert!(matches!(pane.change("/u/Desktop", Some(&fits)), ChangePlan::Look { .. }));
        assert_eq!(pane.change("/elsewhere", Some(&fits)), ChangePlan::Ignore);
    }

    #[test]
    fn changed_names_are_looked_at_once_and_a_known_subfolder_relists() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![preview()]);
        pane.read_done(
            "system.preview",
            true,
            strings(&["/t/TemporaryItems", "/t/TemporaryItems/NSIRD_screencaptureui_1"]),
        );
        let plan = pane.change(
            "/t/TemporaryItems",
            Some(&strings(&[
                "NSIRD_screencaptureui_1",
                "NSIRD_screencaptureui_2",
                "NSIRD_screencaptureui_2",
            ])),
        );
        assert_eq!(
            plan,
            ChangePlan::Look {
                source: "system.preview".into(),
                relist: true,
                paths: strings(&["/t/TemporaryItems/NSIRD_screencaptureui_2"]),
            }
        );
    }

    #[test]
    fn a_new_file_is_listed_and_a_gone_one_removed() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![system()]);
        let png = file("Screenshot 1.png", MediaKind::Image);
        assert_eq!(
            pane.entry_action("system", "/u/Desktop", "/u/Desktop/Screenshot 1.png", Some(&png)),
            EntryAction::Upsert
        );
        assert_eq!(
            pane.entry_action("system", "/u/Desktop", "/u/Desktop/Screenshot 1.png", None),
            EntryAction::Remove
        );
        let txt = file("notes.txt", MediaKind::Other);
        assert_eq!(
            pane.entry_action("system", "/u/Desktop", "/u/Desktop/notes.txt", Some(&txt)),
            EntryAction::Remove
        );
        let hidden = Entry { hidden: true, ..png };
        assert_eq!(
            pane.entry_action("system", "/u/Desktop", "/u/Desktop/Screenshot 1.png", Some(&hidden)),
            EntryAction::Remove
        );
        assert_eq!(
            pane.entry_action("gone", "/u/Desktop", "/u/Desktop/Screenshot 1.png", Some(&png)),
            EntryAction::Remove
        );
    }

    #[test]
    fn a_new_preview_folder_relists_and_files_below_it_are_listed() {
        let mut pane = Pane::new(true);
        pane.set_sources(vec![preview()]);
        let dir = folder_entry("NSIRD_screencaptureui_9");
        assert_eq!(
            pane.entry_action(
                "system.preview",
                "/t/TemporaryItems",
                "/t/TemporaryItems/NSIRD_screencaptureui_9",
                Some(&dir)
            ),
            EntryAction::Relist
        );
        let other = folder_entry("Other");
        assert_eq!(
            pane.entry_action(
                "system.preview",
                "/t/TemporaryItems",
                "/t/TemporaryItems/Other",
                Some(&other)
            ),
            EntryAction::Remove
        );
        let png = file("Screenshot.png", MediaKind::Image);
        assert_eq!(
            pane.entry_action(
                "system.preview",
                "/t/TemporaryItems/NSIRD_screencaptureui_9",
                "/t/TemporaryItems/NSIRD_screencaptureui_9/Screenshot.png",
                Some(&png)
            ),
            EntryAction::Upsert
        );
        let deeper = folder_entry("NSIRD_screencaptureui_x");
        assert_eq!(
            pane.entry_action(
                "system.preview",
                "/t/TemporaryItems/NSIRD_screencaptureui_9",
                "/t/TemporaryItems/NSIRD_screencaptureui_9/NSIRD_screencaptureui_x",
                Some(&deeper)
            ),
            EntryAction::Remove
        );
    }

    #[test]
    fn events_outside_the_rule_are_not_listed() {
        let preview = preview();
        assert!(Pane::is_listed(&preview, "/t/TemporaryItems/NSIRD_screencaptureui_1/a.png"));
        assert!(Pane::is_listed(&preview, "/t/TemporaryItems/a.png"));
        assert!(!Pane::is_listed(&preview, "/t/TemporaryItems/Other/a.png"));
        assert!(!Pane::is_listed(
            &preview,
            "/t/TemporaryItems/NSIRD_screencaptureui_1/NSIRD_screencaptureui_2/a.png"
        ));
        assert!(!Pane::is_listed(&preview, "/t/TemporaryItemsX/a.png"));
        assert!(!Pane::is_listed(&preview, "/t/TemporaryItems"));
        assert!(!Pane::is_listed(&system(), "/u/Desktop/sub/a.png"));
    }

    #[test]
    fn child_paths_and_depths() {
        assert_eq!(child_path("/a", "b.png"), "/a/b.png");
        assert_eq!(child_path("/a/", "b"), "/a/b");
        assert_eq!(depth("/a", "/a"), 0);
        assert_eq!(depth("/a/b/c", "/a"), 2);
    }
}
