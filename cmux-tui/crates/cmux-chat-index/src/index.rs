//! The merged chat index: one scan per root, merged by (harness, session id)
//! after roots were merged by real path. Changes come out as upserts and
//! removals for watchers. The cache file keeps per-file read offsets so a
//! restart counts only new lines.

use std::collections::BTreeMap;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::adapters::{PathRole, classify_path};
use crate::entry::{ChatEntry, ChatKey};
use crate::roots::ChatRoot;
use crate::scan::{RootScan, read_file, scan_root};
use crate::store_file;

const CACHE_VERSION: u32 = 1;

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
        let mut index = Self { slots, merged: BTreeMap::new() };
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
        for slot in &mut self.slots {
            let Some(root) = owning_root(&slot.root, path) else { continue };
            let spelled = slot.root.path.join(path.strip_prefix(root).unwrap_or(path));
            match classify_path(slot.root.harness, &slot.root.path, &spelled) {
                PathRole::Store => rescan(slot),
                PathRole::Session if !slot.scan.database => update_file(slot, &spelled),
                PathRole::Session | PathRole::Ignore => {}
            }
        }
        self.remerge()
    }

    /// Every chat, newest first.
    pub fn chats(&self) -> Vec<&IndexedChat> {
        let mut chats: Vec<&IndexedChat> = self.merged.values().collect();
        chats.sort_by(|a, b| {
            b.entry
                .updated_ms
                .cmp(&a.entry.updated_ms)
                .then_with(|| a.entry.key().cmp(&b.entry.key()))
        });
        chats
    }

    pub fn get(&self, key: &ChatKey) -> Option<&IndexedChat> {
        self.merged.get(key)
    }

    fn remerge(&mut self) -> Vec<ChatChange> {
        let next = self.merge();
        let mut changes = Vec::new();
        for (key, chat) in &next {
            if self.merged.get(key) != Some(chat) {
                changes.push(ChatChange::Upsert { chat: Box::new(chat.clone()) });
            }
        }
        for key in self.merged.keys() {
            if !next.contains_key(key) {
                changes.push(ChatChange::Removed { key: key.clone() });
            }
        }
        self.merged = next;
        changes
    }

    fn merge(&self) -> BTreeMap<ChatKey, IndexedChat> {
        let mut merged: BTreeMap<ChatKey, IndexedChat> = BTreeMap::new();
        for slot in &self.slots {
            let account = (slot.root.accounts.len() == 1).then(|| slot.root.accounts[0].clone());
            let root_id = slot.root.id();
            for entry in &slot.scan.entries {
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
        merged
    }
}

fn rescan(slot: &mut Slot) {
    let prior = slot.scan.files.iter().cloned().collect();
    if let Ok(scan) = scan_root(&slot.root.config(), &prior) {
        slot.scan = scan;
    }
}

fn update_file(slot: &mut Slot, path: &Path) {
    let prev_at = slot.scan.files.iter().position(|(file, _)| file == path);
    slot.scan.entries.retain(|entry| entry.source_path != path);
    let prev = prev_at.map(|at| slot.scan.files.swap_remove(at).1);
    if !path.is_file() {
        return;
    }
    if let Ok(read) = read_file(slot.root.harness, path, prev.as_ref()) {
        slot.scan.entries.extend(read.entry);
        slot.scan.files.push((path.to_path_buf(), read.state));
    }
}

/// The spelling of `root` that `path` is under (its path, real path or an alias).
fn owning_root<'a>(root: &'a ChatRoot, path: &Path) -> Option<&'a Path> {
    std::iter::once(&root.path)
        .chain(std::iter::once(&root.real_path))
        .chain(root.aliases.iter())
        .map(|spelling| spelling.as_path())
        .find(|spelling| path.starts_with(spelling))
}
