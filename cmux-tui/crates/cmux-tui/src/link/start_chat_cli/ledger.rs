//! The machine each recent `cloud.startChat` send ran on, newest last, at
//! most [`LIMIT`]: a retry of a send names it, so the retry's tab key (which
//! only that machine's daemon knows) gets back the tab its first try opened,
//! never a second chat elsewhere. With it, the chat's folder there once the
//! send's copy finished: a retry opens its chat there without copying again.
//! And each Mac workspace's own Cloud machine, at most [`WORKSPACE_LIMIT`]: a
//! workspace's later sends go to the machine its first send made (Leo,
//! 2026-10-30: "we'll want a vm for every single workspace").
//!
//! Kept in `<state>/cloud-start-chat/destinations.json` (0600, its folder
//! 0700), read and written under an exclusive lock on a sibling `.lock` file
//! (released when the process exits, also when it is killed)
//! so two sends at once never lose each other's pins, and written to a
//! temporary name and renamed.

use std::collections::BTreeSet;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use serde::{Deserialize, Serialize};

/// How many sends are kept.
pub(crate) const LIMIT: usize = 64;

/// How many workspaces' machines are kept, kept apart from the sends so a
/// workspace keeps its machine however many sends ran since.
pub(crate) const WORKSPACE_LIMIT: usize = 256;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Entry {
    key: String,
    machine_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    copied_chat: Option<String>,
}

/// A Mac workspace's own Cloud machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Binding {
    workspace: String,
    machine_id: String,
}

/// The file: the sends, then the workspaces. An older ledger is the sends' list alone.
#[derive(Default, Serialize, Deserialize)]
struct File {
    #[serde(default)]
    sends: Vec<Entry>,
    #[serde(default)]
    workspaces: Vec<Binding>,
}

/// The pins, in memory.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Ledger {
    entries: Vec<Entry>,
    workspaces: Vec<Binding>,
}

impl Ledger {
    /// The machine the send `key` ran on, if it ran.
    pub(crate) fn machine(&self, key: &str) -> Option<String> {
        let key = key.to_lowercase();
        self.entries
            .iter()
            .rev()
            .find(|entry| entry.key == key)
            .map(|entry| entry.machine_id.clone())
    }

    /// Every machine a kept send ran on or a kept workspace has.
    pub(crate) fn machines(&self) -> BTreeSet<String> {
        self.entries
            .iter()
            .map(|entry| entry.machine_id.clone())
            .chain(self.workspaces.iter().map(|binding| binding.machine_id.clone()))
            .collect()
    }

    /// The Mac workspace `workspace`'s own machine, once a send from it ran on one.
    pub(crate) fn workspace_machine(&self, workspace: &str) -> Option<String> {
        self.workspaces
            .iter()
            .find(|binding| binding.workspace == workspace)
            .map(|binding| binding.machine_id.clone())
    }

    /// The machines that are some workspace's own.
    pub(crate) fn workspace_machines(&self) -> BTreeSet<String> {
        self.workspaces.iter().map(|binding| binding.machine_id.clone()).collect()
    }

    /// `machine` is the workspace `workspace`'s own from now on.
    pub(crate) fn bind(&mut self, workspace: &str, machine: &str) {
        self.workspaces.retain(|kept| kept.workspace != workspace);
        self.workspaces
            .push(Binding { workspace: workspace.to_string(), machine_id: machine.to_string() });
        let over = self.workspaces.len().saturating_sub(WORKSPACE_LIMIT);
        self.workspaces.drain(..over);
    }

    /// Drops the workspace `workspace`'s machine (gone, or no longer the person's).
    pub(crate) fn unbind(&mut self, workspace: &str) {
        self.workspaces.retain(|kept| kept.workspace != workspace);
    }

    /// Pins the send `key` to `machine` (before anything runs there). A pin
    /// to the same machine keeps its finished copy.
    pub(crate) fn record(&mut self, machine: &str, key: &str) {
        let key = key.to_lowercase();
        let copied = self
            .entries
            .iter()
            .rev()
            .find(|entry| entry.key == key && entry.machine_id == machine)
            .and_then(|entry| entry.copied_chat.clone());
        self.put(Entry { key, machine_id: machine.to_string(), copied_chat: copied });
    }

    /// The chat's folder on `machine` when the send `key`'s copy finished there.
    pub(crate) fn copied_chat(&self, key: &str, machine: &str) -> Option<String> {
        let key = key.to_lowercase();
        self.entries
            .iter()
            .rev()
            .find(|entry| entry.key == key && entry.machine_id == machine)
            .and_then(|entry| entry.copied_chat.clone())
    }

    /// The send `key`'s copy finished on `machine`, its chat's folder there `chat`.
    pub(crate) fn record_copy(&mut self, chat: &str, key: &str, machine: &str) {
        let key = key.to_lowercase();
        self.put(Entry {
            key,
            machine_id: machine.to_string(),
            copied_chat: Some(chat.to_string()),
        });
    }

    /// Drops the send `key`'s pin (its machine is gone).
    pub(crate) fn forget(&mut self, key: &str) {
        let key = key.to_lowercase();
        self.entries.retain(|entry| entry.key != key);
    }

    fn put(&mut self, entry: Entry) {
        self.entries.retain(|kept| kept.key != entry.key);
        self.entries.push(entry);
        let over = self.entries.len().saturating_sub(LIMIT);
        self.entries.drain(..over);
    }

    /// Reads the ledger at `path`, runs `change` on it and writes it back
    /// when it changed, under the ledger's lock. A missing or unreadable
    /// ledger reads as empty: a lost pin only makes a retry pick afresh.
    pub(crate) fn update<T>(
        path: &Path,
        change: impl FnOnce(&mut Ledger) -> T,
    ) -> anyhow::Result<T> {
        let dir = path.parent().context("the ledger has no folder")?;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .with_context(|| format!("cannot make {}", dir.display()))?;
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path.with_extension("lock"))
            .with_context(|| format!("cannot open the lock of {}", path.display()))?;
        lock.lock().context("cannot lock the ledger")?;
        let mut ledger = Self::read(path);
        let before = ledger.clone();
        let value = change(&mut ledger);
        if ledger != before {
            ledger.write(path)?;
        }
        drop(lock);
        Ok(value)
    }

    fn read(path: &Path) -> Self {
        let Some(bytes) = std::fs::read(path).ok() else { return Self::default() };
        let file = serde_json::from_slice::<File>(&bytes)
            .ok()
            .or_else(|| {
                serde_json::from_slice::<Vec<Entry>>(&bytes)
                    .ok()
                    .map(|sends| File { sends, workspaces: Vec::new() })
            })
            .unwrap_or_default();
        Self { entries: file.sends, workspaces: file.workspaces }
    }

    fn write(&self, path: &Path) -> anyhow::Result<()> {
        let part = path.with_extension(format!("{}.part", std::process::id()));
        let _ = std::fs::remove_file(&part);
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&part)
            .with_context(|| format!("cannot write {}", part.display()))?;
        let ledger = File { sends: self.entries.clone(), workspaces: self.workspaces.clone() };
        file.write_all(&serde_json::to_vec(&ledger)?)?;
        file.sync_all()?;
        std::fs::rename(&part, path).with_context(|| format!("cannot write {}", path.display()))
    }
}

/// Where this Mac keeps the ledger; None when it has no state folder.
pub(crate) fn path() -> Option<PathBuf> {
    Some(
        cmux_tui_core::platform::workspace_state_dir()?
            .join("cloud-start-chat")
            .join("destinations.json"),
    )
}
