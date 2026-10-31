//! The merged chat index: one scan per root, merged by (harness, session id)
//! after roots were merged by real path. Changes come out as upserts and
//! removals for watchers. The cache file keeps per-file read offsets so a
//! restart counts only new lines.

use std::collections::{BTreeMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::adapters::{PathRole, classify_path};
use crate::entry::{ChatEntry, ChatKey};
use crate::roots::ChatRoot;
use crate::scan::{RootScan, read_file, scan_root};
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
    scan: RootScan,
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
            .map(|root| Slot { scan: saved.remove(&root.id()).unwrap_or_default(), root })
            .collect();
        let mut index = Self { slots, merged: BTreeMap::new(), visits: 0, structural: false };
        index.merged = index.merge();
        index
    }

    /// Writes the cache (mode 0600). Titles are user data; nothing else of a
    /// transcript is stored.
    pub fn save(&self, cache: &Path) -> io::Result<()> {
        let roots = self.slots.iter().map(|slot| (slot.root.id(), slot.scan.clone())).collect();
        store_file::write_json_private(cache, &CacheFile { version: CACHE_VERSION, roots })
    }

    /// Replaces the root set, keeping scans of roots that stay.
    pub fn set_roots(&mut self, roots: Vec<ChatRoot>) -> Vec<ChatChange> {
        let mut old: Vec<Slot> = std::mem::take(&mut self.slots);
        for root in roots {
            let scan = old
                .iter()
                .position(|slot| slot.root.id() == root.id())
                .map(|at| old.swap_remove(at).scan)
                .unwrap_or_default();
            self.slots.push(Slot { root, scan });
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
        let mut touched: HashSet<String> = HashSet::new();
        let mut full = false;
        for slot in &mut self.slots {
            let mut store_changed = false;
            let mut sessions = Vec::new();
            for path in paths {
                let Some(root) = owning_root(&slot.root, path) else { continue };
                let spelled = slot.root.path.join(path.strip_prefix(root).unwrap_or(path));
                match classify_path(slot.root.harness, &slot.root.path, &spelled) {
                    PathRole::Store => store_changed = true,
                    PathRole::Session => sessions.push(spelled),
                    PathRole::Ignore => {}
                }
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
        if full { self.remerge() } else { self.remerge_sessions(&touched) }
    }

    /// True once after a chat appeared or went away (the cache's chat set
    /// changed), so a caller saves the cache only then.
    pub fn take_structural_change(&mut self) -> bool {
        std::mem::take(&mut self.structural)
    }

    /// Every chat, newest first.
    pub fn chats(&self) -> Vec<&IndexedChat> {
        let mut chats: Vec<&IndexedChat> = self.merged.values().collect();
        chats.sort_by(|a, b| {
            b.entry
                .updated_ms
                .cmp(&a.entry.updated_ms)
                // Ties: the key text (`<harness id>:<session id>`) ascending, the order
                // clients keep (the windows of `_acpmux/chats_window`), not the enum's declaration order.
                .then_with(|| key_text(&a.entry).cmp(key_text(&b.entry)))
        });
        chats
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
        self.merged = next;
        changes
    }

    /// ``remerge`` for the chats whose session id is in `sessions` only: the
    /// same result for those keys, every other chat left as it is.
    fn remerge_sessions(&mut self, sessions: &HashSet<String>) -> Vec<ChatChange> {
        if sessions.is_empty() {
            self.visits = 0;
            return Vec::new();
        }
        let next = self.merge_where(|entry| sessions.contains(entry.session_id.as_str()));
        let stale: Vec<ChatKey> = self
            .merged
            .keys()
            .filter(|key| sessions.contains(key.session_id.as_str()) && !next.contains_key(*key))
            .cloned()
            .collect();
        let mut changes = Vec::new();
        for (key, chat) in next {
            match self.merged.get(&key) {
                Some(old) if *old == chat => {}
                old => {
                    self.structural |= old.is_none();
                    changes.push(ChatChange::Upsert { chat: Box::new(chat.clone()) });
                    self.merged.insert(key, chat);
                }
            }
        }
        for key in stale {
            self.merged.remove(&key);
            self.structural = true;
            changes.push(ChatChange::Removed { key });
        }
        changes
    }

    fn merge(&mut self) -> BTreeMap<ChatKey, IndexedChat> {
        self.merge_where(|_| true)
    }

    /// Merges the root entries `include` accepts, in root order (the newest
    /// copy of a chat wins, accounts and roots in root order).
    fn merge_where(
        &mut self,
        include: impl Fn(&ChatEntry) -> bool,
    ) -> BTreeMap<ChatKey, IndexedChat> {
        let mut visits = 0;
        let mut merged: BTreeMap<ChatKey, IndexedChat> = BTreeMap::new();
        for slot in &self.slots {
            let account = (slot.root.accounts.len() == 1).then(|| slot.root.accounts[0].clone());
            let root_id = slot.root.id();
            // Only person chats: not the Chief's sessions (cx-eb0m), acpmux's harness probes, or a
            // session with no user message (Lawrence 2026-10-11).
            for entry in slot
                .scan
                .entries
                .iter()
                .filter(|entry| include(entry) && crate::scan::is_person_chat(entry))
            {
                visits += 1;
                let chat = merged.entry(entry.key()).or_insert_with(|| IndexedChat {
                    entry: entry.clone(),
                    accounts: Vec::new(),
                    roots: Vec::new(),
                });
                // The newest copy (sr copies a transcript before a resume) wins.
                if entry.updated_ms > chat.entry.updated_ms {
                    chat.entry = entry.clone();
                }
                if let Some(account) = &account
                    && !chat.accounts.contains(account)
                {
                    chat.accounts.push(account.clone());
                }
                if !chat.roots.contains(&root_id) {
                    chat.roots.push(root_id.clone());
                }
            }
        }
        self.visits = visits;
        merged
    }
}

fn rescan(slot: &mut Slot) {
    let prior = slot.scan.files.iter().cloned().collect();
    if let Ok(scan) = scan_root(&slot.root.config(), &prior) {
        slot.scan = scan;
    }
}

/// Reads `path` again. Returns the session ids of its old and new entries.
fn update_file(slot: &mut Slot, path: &Path) -> Vec<String> {
    let prev_at = slot.scan.files.iter().position(|(file, _)| file == path);
    let mut sessions: Vec<String> = Vec::new();
    slot.scan.entries.retain(|entry| {
        let keep = entry.source_path != path;
        if !keep {
            sessions.push(entry.session_id.clone());
        }
        keep
    });
    let prev = prev_at.map(|at| slot.scan.files.swap_remove(at).1);
    if !path.is_file() {
        return sessions;
    }
    if let Ok(read) = read_file(slot.root.harness, path, prev.as_ref()) {
        let mut entries: Vec<ChatEntry> = read.entry.into_iter().collect();
        crate::adapters::finish_file(slot.root.harness, &slot.root.path, &mut entries);
        sessions.extend(entries.iter().map(|entry| entry.session_id.clone()));
        slot.scan.entries.extend(entries);
        slot.scan.files.push((path.to_path_buf(), read.state));
    }
    sessions
}

/// The key as text (`<harness id>:<session id>`), compared without building it.
fn key_text(entry: &ChatEntry) -> impl Iterator<Item = u8> + '_ {
    entry.harness.id().bytes().chain(std::iter::once(b':')).chain(entry.session_id.bytes())
}

/// The spelling of `root` that `path` is under (its path, real path or an alias).
fn owning_root<'a>(root: &'a ChatRoot, path: &Path) -> Option<&'a Path> {
    std::iter::once(&root.path)
        .chain(std::iter::once(&root.real_path))
        .chain(root.aliases.iter())
        .map(|spelling| spelling.as_path())
        .find(|spelling| path.starts_with(spelling))
}
