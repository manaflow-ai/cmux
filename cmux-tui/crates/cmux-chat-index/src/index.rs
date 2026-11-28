//! The merged chat index: one scan per root, merged by (harness, session id)
//! after roots were merged by real path. Changes come out as upserts and
//! removals for watchers. The cache file keeps per-file read offsets so a
//! restart counts only new lines.

use std::cmp::Reverse;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::OsString;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::adapters::{PathRole, classify_path};
use crate::entry::{ChatEntry, ChatKey};
use crate::roots::ChatRoot;
use crate::scan::{RootScan, read_file, scan_root};
use crate::stamp::{FileStamp, FileState};
use crate::store_file;

// 2: Codex rollouts count their typed prompts from message items (current Codex writes no
// user_message events), so tallies saved without them are read again.
const CACHE_VERSION: u32 = 2;

/// One chat across every root that holds it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct IndexedChat {
    #[serde(flatten)]
    pub entry: ChatEntry,
    /// Account labels of single-account roots that hold the chat. A root
    /// shared by many accounts (subrouter symlinks) gives no label.
    pub accounts: Vec<String>,
    /// Ids of the roots that hold the chat.
    pub roots: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ChatChange {
    Upsert { chat: Box<IndexedChat> },
    Removed { key: ChatKey },
}

#[derive(Debug)]
struct Slot {
    root: ChatRoot,
    /// The scan's flags (`database`, `skipped`); its entries and files are held split below, and
    /// put back together only for [`ChatIndex::save`].
    scan: RootScan,
    /// The root's entries by the file they came from (`source_path`): one written file replaces
    /// its own entries without a pass over the root's. Keyed by the path's bytes (`OsString`
    /// orders by memcmp): a `PathBuf` key compares path components on each of ~15 steps per
    /// insert, which doubled a 20,000-chat cache load.
    by_path: BTreeMap<OsString, Vec<ChatEntry>>,
    /// The files that hold each chat: a burst that touched a chat merges its copies only, where
    /// it walked every entry of every root to find them (10 ms per event at 20,000 chats).
    /// Sorted, so a full merge and a merge of some chats fold a chat's copies in one order;
    /// nearly always one path, so a Vec, not a set.
    by_key: HashMap<ChatKey, Vec<OsString>>,
    /// Read state per session file, by path (a lookup where it was a scan of every file).
    files: HashMap<PathBuf, FileState>,
    /// Each store file's stamp when an event last named it (None: it was not there).
    store_stamps: HashMap<PathBuf, Option<FileStamp>>,
}

impl Slot {
    fn new(root: ChatRoot, scan: RootScan) -> Self {
        let mut slot = Self {
            root,
            scan: RootScan::default(),
            by_path: BTreeMap::new(),
            by_key: HashMap::new(),
            files: HashMap::new(),
            store_stamps: HashMap::new(),
        };
        slot.set_scan(scan);
        slot
    }

    /// Takes a whole scan in, split by file and by chat.
    fn set_scan(&mut self, mut scan: RootScan) {
        self.by_path.clear();
        self.by_key.clear();
        self.files = std::mem::take(&mut scan.files).into_iter().collect();
        let entries = std::mem::take(&mut scan.entries);
        self.scan = scan;
        for entry in entries {
            self.add_entry(entry);
        }
    }

    /// The scan as one value again (the cache's shape).
    fn to_scan(&self) -> RootScan {
        RootScan {
            entries: self.by_path.values().flatten().cloned().collect(),
            files: self.files.iter().map(|(path, state)| (path.clone(), state.clone())).collect(),
            ..self.scan.clone()
        }
    }

    fn add_entry(&mut self, entry: ChatEntry) {
        let paths = self.by_key.entry(entry.key()).or_default();
        let path = entry.source_path.as_os_str();
        if let Err(at) = paths.binary_search_by(|held| held.as_os_str().cmp(path)) {
            paths.insert(at, path.to_owned());
        }
        match self.by_path.get_mut(path) {
            Some(held) => held.push(entry),
            None => {
                let path = path.to_owned();
                self.by_path.insert(path, vec![entry]);
            }
        }
    }

    /// Drops the entries read from `path`; returns their keys.
    fn remove_path(&mut self, path: &Path) -> Vec<ChatKey> {
        let path = path.as_os_str();
        let Some(old) = self.by_path.remove(path) else { return Vec::new() };
        let keys: Vec<ChatKey> = old.iter().map(ChatEntry::key).collect();
        for key in &keys {
            if let Some(paths) = self.by_key.get_mut(key) {
                paths.retain(|held| held != path);
                if paths.is_empty() {
                    self.by_key.remove(key);
                }
            }
        }
        keys
    }

    /// Every entry, in the order a full merge folds them (path bytes, then file order).
    fn entries(&self) -> impl Iterator<Item = &ChatEntry> {
        self.by_path.values().flatten()
    }

    /// The entries of chat `key`: its files in path order, each file's entries in file order.
    fn entries_of<'a>(&'a self, key: &'a ChatKey) -> impl Iterator<Item = &'a ChatEntry> + 'a {
        self.by_key
            .get(key)
            .into_iter()
            .flatten()
            .filter_map(|path| self.by_path.get(path.as_os_str()))
            .flatten()
            .filter(move |entry| entry.harness == key.harness && entry.session_id == key.session_id)
    }

    /// Whether store file `path` moved since an event last named it. macOS reports an extended
    /// attribute event on a WAL while processes read it, with nothing written; taken for a change,
    /// each daemon's read made every other daemon read the whole store again.
    fn store_file_changed(&mut self, path: &Path) -> bool {
        let now = std::fs::metadata(path).ok().map(|meta| FileStamp::of(&meta));
        self.store_stamps.insert(path.to_path_buf(), now) != Some(now)
    }

    /// Whether any store file an event has named moved: a writer that holds its connection open
    /// may report nothing on the store, so a transcript written beside it says to look.
    fn known_store_files_changed(&mut self) -> bool {
        let known: Vec<PathBuf> = self.store_stamps.keys().cloned().collect();
        known.iter().fold(false, |changed, path| self.store_file_changed(path) | changed)
    }
}

#[derive(Serialize, Deserialize)]
struct CacheFile {
    version: u32,
    roots: Vec<(String, RootScan)>,
}

#[derive(Debug, Default)]
pub struct ChatIndex {
    slots: Vec<Slot>,
    merged: BTreeMap<ChatKey, IndexedChat>,
    /// `merged`'s keys newest first ([`ChatIndex::newest_first`]), kept in step with each
    /// insert and removal: a reader walks the first rows of the order and stops, where it sorted
    /// every chat on each read (a window refresh per activity change, ~3,000 chats).
    order: BTreeMap<OrderKey, ChatKey>,
    /// Root entries the last change merged (see ``merge_visits``).
    visits: usize,
    /// A chat appeared or went away since the last ``take_structural_change``.
    structural: bool,
}

impl ChatIndex {
    pub fn new(roots: Vec<ChatRoot>) -> Self {
        let mut index = Self::default();
        index.set_roots(roots);
        index
    }

    /// Restores scans from `cache` for roots with the same id. A missing or
    /// other-version cache gives an empty index for those roots.
    pub fn load(cache: &Path, roots: Vec<ChatRoot>) -> Self {
        let mut saved: BTreeMap<String, RootScan> = store_file::read_json::<CacheFile>(cache)
            .filter(|file| file.version == CACHE_VERSION)
            .map(|file| file.roots.into_iter().collect())
            .unwrap_or_default();
        let slots = roots
            .into_iter()
            .map(|root| {
                let scan = saved.remove(&root.id()).unwrap_or_default();
                Slot::new(root, scan)
            })
            .collect();
        let mut index = Self { slots, ..Self::default() };
        let merged = index.merge();
        index.set_merged(merged);
        index
    }

    /// Writes the cache (mode 0600). Titles are user data; nothing else of a
    /// transcript is stored.
    pub fn save(&self, cache: &Path) -> io::Result<()> {
        self.save_with(cache, &store_file::write_private)
    }

    /// [`Self::save`] through `write` ([`crate::write_private`]'s shape): the caller's own way to
    /// write the file (acpmux writes under the home it holds through the folder it locked).
    pub fn save_with(
        &self,
        cache: &Path,
        write: &dyn Fn(&Path, &[u8]) -> io::Result<()>,
    ) -> io::Result<()> {
        let roots = self.slots.iter().map(|slot| (slot.root.id(), slot.to_scan())).collect();
        let bytes = serde_json::to_vec(&CacheFile { version: CACHE_VERSION, roots })
            .map_err(io::Error::other)?;
        write(cache, &bytes)
    }

    /// Replaces the root set, keeping scans of roots that stay.
    pub fn set_roots(&mut self, roots: Vec<ChatRoot>) -> Vec<ChatChange> {
        let mut old: Vec<Slot> = std::mem::take(&mut self.slots);
        for root in roots {
            let scan = old
                .iter()
                .position(|slot| slot.root.id() == root.id())
                .map(|at| old.swap_remove(at).to_scan())
                .unwrap_or_default();
            self.slots.push(Slot::new(root, scan));
        }
        self.remerge()
    }

    pub fn roots(&self) -> impl Iterator<Item = &ChatRoot> {
        self.slots.iter().map(|slot| &slot.root)
    }

    /// Scans every root again (incremental per file).
    pub fn rescan_all(&mut self) -> Vec<ChatChange> {
        for slot in &mut self.slots {
            rescan(slot);
        }
        self.remerge()
    }

    pub fn rescan_root(&mut self, root_id: &str) -> Vec<ChatChange> {
        if let Some(slot) = self.slots.iter_mut().find(|slot| slot.root.id() == root_id) {
            rescan(slot);
        }
        self.remerge()
    }

    /// Applies one changed path (a watcher event) to every root that holds it.
    pub fn path_changed(&mut self, path: &Path) -> Vec<ChatChange> {
        self.paths_changed(std::slice::from_ref(&path.to_path_buf()))
    }

    /// Applies one burst of changed paths. A root whose store changed (its
    /// database, WAL or index) is scanned once for the whole burst, however
    /// many of its store files the burst names: a store scan reads the
    /// whole database.
    pub fn paths_changed(&mut self, paths: &[PathBuf]) -> Vec<ChatChange> {
        // The chats the burst touched: the old and new entries of each named
        // transcript. Only those are merged again; a store scan can change
        // any chat of its root, so it merges everything.
        let mut touched: HashSet<ChatKey> = HashSet::new();
        let mut full = false;
        for slot in &mut self.slots {
            let mut store_changed = false;
            let mut sessions = Vec::new();
            for path in paths {
                let Some(root) = owning_root(&slot.root, path) else { continue };
                let spelled = slot.root.path.join(path.strip_prefix(root).unwrap_or(path));
                match classify_path(slot.root.harness, &slot.root.path, &spelled) {
                    PathRole::Store => store_changed |= slot.store_file_changed(&spelled),
                    PathRole::Session => sessions.push(spelled),
                    PathRole::Ignore => {}
                }
            }
            if slot.scan.database && !sessions.is_empty() {
                store_changed |= slot.known_store_files_changed();
            }
            if store_changed {
                rescan(slot);
                full = true;
            }
            // Database stores take their chats from the query only.
            if !slot.scan.database {
                for spelled in &sessions {
                    touched.extend(update_file(slot, spelled));
                }
            }
        }
        if full { self.remerge() } else { self.remerge_keys(&touched) }
    }

    /// True once after a chat appeared or went away (the cache's chat set
    /// changed), so a caller saves the cache only then.
    pub fn take_structural_change(&mut self) -> bool {
        std::mem::take(&mut self.structural)
    }

    /// Every chat, newest first.
    pub fn chats(&self) -> Vec<&IndexedChat> {
        self.newest_first().collect()
    }

    /// Every chat, newest first, read from the kept order: a reader that stops after a page
    /// costs the page, however many chats the index holds. Ties: the key text
    /// (`<harness id>:<session id>`) ascending, the order clients keep (the windows of
    /// `_acpmux/chats_window`), not the enum's declaration order.
    pub fn newest_first(&self) -> impl Iterator<Item = &IndexedChat> + '_ {
        self.order.values().filter_map(|key| self.merged.get(key))
    }

    /// How many chats the index holds.
    pub fn len(&self) -> usize {
        self.merged.len()
    }

    pub fn is_empty(&self) -> bool {
        self.merged.is_empty()
    }

    pub fn get(&self, key: &ChatKey) -> Option<&IndexedChat> {
        self.merged.get(key)
    }

    /// How many root entries the last change merged: the cost of one watcher
    /// burst. A burst that names one transcript merges that chat's copies
    /// only, however many chats the index holds.
    pub fn merge_visits(&self) -> usize {
        self.visits
    }

    fn remerge(&mut self) -> Vec<ChatChange> {
        let next = self.merge();
        let mut changes = Vec::new();
        for (key, chat) in &next {
            match self.merged.get(key) {
                Some(old) if old == chat => {}
                old => {
                    self.structural |= old.is_none();
                    changes.push(ChatChange::Upsert { chat: Box::new(chat.clone()) });
                }
            }
        }
        for key in self.merged.keys() {
            if !next.contains_key(key) {
                self.structural = true;
                changes.push(ChatChange::Removed { key: key.clone() });
            }
        }
        self.set_merged(next);
        changes
    }

    /// ``remerge`` for the chats in `keys` only: the same result for those keys, every other chat
    /// left as it is. Costs the copies of those chats, however many chats the index holds.
    fn remerge_keys(&mut self, keys: &HashSet<ChatKey>) -> Vec<ChatChange> {
        if keys.is_empty() {
            self.visits = 0;
            return Vec::new();
        }
        let next = self.merge_keys(keys);
        let stale: Vec<ChatKey> = keys
            .iter()
            .filter(|key| self.merged.contains_key(*key) && !next.contains_key(*key))
            .cloned()
            .collect();
        let mut changes = Vec::new();
        for (key, chat) in next {
            match self.merged.get(&key) {
                Some(old) if *old == chat => {}
                old => {
                    self.structural |= old.is_none();
                    changes.push(ChatChange::Upsert { chat: Box::new(chat.clone()) });
                    self.insert(key, chat);
                }
            }
        }
        for key in stale {
            self.remove(&key);
            self.structural = true;
            changes.push(ChatChange::Removed { key });
        }
        changes
    }

    /// Replaces every chat, and the order with them.
    fn set_merged(&mut self, merged: BTreeMap<ChatKey, IndexedChat>) {
        self.order =
            merged.iter().map(|(key, chat)| (order_key(&chat.entry), key.clone())).collect();
        self.merged = merged;
    }

    /// One chat in or replaced: its old place in the order goes, its new one comes.
    fn insert(&mut self, key: ChatKey, chat: IndexedChat) {
        if let Some(old) = self.merged.get(&key) {
            self.order.remove(&order_key(&old.entry));
        }
        self.order.insert(order_key(&chat.entry), key.clone());
        self.merged.insert(key, chat);
    }

    fn remove(&mut self, key: &ChatKey) {
        if let Some(old) = self.merged.remove(key) {
            self.order.remove(&order_key(&old.entry));
        }
    }

    /// Merges every root entry, in root order (the newest copy of a chat wins, accounts and roots
    /// in root order).
    fn merge(&mut self) -> BTreeMap<ChatKey, IndexedChat> {
        let mut fold = Fold::default();
        for slot in &self.slots {
            let (account, root_id) = slot_labels(slot);
            for entry in slot.entries() {
                fold.add(entry, &account, &root_id);
            }
        }
        self.visits = fold.visits;
        fold.merged
    }

    /// [`Self::merge`] for the chats in `keys` only, each from its own copies.
    fn merge_keys(&mut self, keys: &HashSet<ChatKey>) -> BTreeMap<ChatKey, IndexedChat> {
        let mut fold = Fold::default();
        for slot in &self.slots {
            let (account, root_id) = slot_labels(slot);
            for key in keys {
                for entry in slot.entries_of(key) {
                    fold.add(entry, &account, &root_id);
                }
            }
        }
        self.visits = fold.visits;
        fold.merged
    }

    /// Whether the kept chats and order are what a full merge of every root gives now: the
    /// incremental path's oracle in tests.
    #[doc(hidden)]
    pub fn matches_full_merge(&mut self) -> bool {
        let visits = self.visits;
        let full = self.merge();
        self.visits = visits;
        let order: BTreeMap<OrderKey, ChatKey> =
            full.iter().map(|(key, chat)| (order_key(&chat.entry), key.clone())).collect();
        full == self.merged && order == self.order
    }
}

fn slot_labels(slot: &Slot) -> (Option<String>, String) {
    ((slot.root.accounts.len() == 1).then(|| slot.root.accounts[0].clone()), slot.root.id())
}

#[derive(Default)]
struct Fold {
    merged: BTreeMap<ChatKey, IndexedChat>,
    visits: usize,
}

impl Fold {
    // Only person chats: not the Chief's sessions (cx-eb0m), acpmux's harness probes, or a
    // session with no user message (Lawrence 2026-10-11).
    fn add(&mut self, entry: &ChatEntry, account: &Option<String>, root_id: &String) {
        if !crate::scan::is_person_chat(entry) {
            return;
        }
        self.visits += 1;
        let chat = self.merged.entry(entry.key()).or_insert_with(|| IndexedChat {
            entry: entry.clone(),
            accounts: Vec::new(),
            roots: Vec::new(),
        });
        // The newest copy (sr copies a transcript before a resume) wins.
        if entry.updated_ms > chat.entry.updated_ms {
            chat.entry = entry.clone();
        }
        if let Some(account) = account
            && !chat.accounts.contains(account)
        {
            chat.accounts.push(account.clone());
        }
        if !chat.roots.contains(root_id) {
            chat.roots.push(root_id.clone());
        }
    }
}

fn rescan(slot: &mut Slot) {
    // Moved, not cloned: each state holds its kept read.
    let prior = std::mem::take(&mut slot.files);
    match scan_root(&slot.root.config(), &prior) {
        Ok(scan) => slot.set_scan(scan),
        Err(_) => slot.files = prior,
    }
}

/// Reads `path` again. Returns the keys of its old and new entries.
fn update_file(slot: &mut Slot, path: &Path) -> Vec<ChatKey> {
    let mut keys = slot.remove_path(path);
    let prev = slot.files.remove(path);
    if !path.is_file() {
        return keys;
    }
    if let Ok(read) = read_file(slot.root.harness, path, prev.as_ref()) {
        let mut entries: Vec<ChatEntry> = read.entry.into_iter().collect();
        crate::adapters::finish_file(slot.root.harness, &slot.root.path, &mut entries);
        for entry in entries {
            keys.push(entry.key());
            slot.add_entry(entry);
        }
        slot.files.insert(path.to_path_buf(), read.state);
    }
    keys
}

/// A chat's place in [`ChatIndex::newest_first`]: newest first, then the key text
/// (`<harness id>:<session id>`) ascending, byte by byte as `str` compares.
type OrderKey = (Reverse<i64>, String);

fn order_key(entry: &ChatEntry) -> OrderKey {
    (Reverse(entry.updated_ms), format!("{}:{}", entry.harness.id(), entry.session_id))
}

/// The spelling of `root` that `path` is under (its path, real path or an alias).
fn owning_root<'a>(root: &'a ChatRoot, path: &Path) -> Option<&'a Path> {
    std::iter::once(&root.path)
        .chain(std::iter::once(&root.real_path))
        .chain(root.aliases.iter())
        .map(|spelling| spelling.as_path())
        .find(|spelling| path.starts_with(spelling))
}
