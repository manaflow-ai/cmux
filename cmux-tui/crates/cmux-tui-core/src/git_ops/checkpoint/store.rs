//! The checkpoint owner's durable state, under the session's state
//! directory in `git-checkpoints/` (directories 0700, files 0600, every
//! write atomic): daemon-minted repository and worktree ids, one record per
//! checkpoint, and the mutation ledger that binds each idempotency key to
//! its operation, arguments, identity and first result.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::record::Stored;
use crate::Mux;
use crate::resource::ResourceError;

const DIRECTORY: &str = "git-checkpoints";

pub(super) struct Store {
    root: PathBuf,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Identities {
    /// Canonical common git directory -> repository id.
    repositories: BTreeMap<String, String>,
    /// Canonical per-worktree git directory -> worktree id.
    worktrees: BTreeMap<String, Worktree>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Worktree {
    worktree_id: String,
    repository_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum LedgerState {
    /// The intent is journaled; the ref may or may not be published.
    Pending,
    Done,
}

/// One idempotency key's entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct LedgerEntry {
    pub idempotency_key: String,
    pub operation: String,
    pub fingerprint: String,
    pub repository_id: String,
    pub worktree_id: String,
    pub checkpoint_id: String,
    pub state: LedgerState,
    /// A create's record before its ref is published.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub draft: Option<Stored>,
    /// The first result, once done.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default)]
    pub revision: u64,
}

impl Store {
    /// The session's store, or `no_state_directory` for an in-memory session.
    pub(super) fn open(mux: &Mux, operation: &'static str) -> Result<Self, ResourceError> {
        let Some(session) = mux.session_state_directory() else {
            return Err(ResourceError::operation_failed(
                operation,
                "this session keeps no durable state, so it cannot hold checkpoints",
                json!({"code":"no_state_directory"}),
            ));
        };
        let store = Self { root: session.join(DIRECTORY) };
        for directory in [store.root.clone(), store.hooks(), store.root.join("ledger")] {
            private_directory(&directory).map_err(|error| io_failed(operation, &error))?;
        }
        Ok(store)
    }

    /// An empty directory git takes as its hooks directory, so no hook runs.
    pub(super) fn hooks(&self) -> PathBuf {
        self.root.join("hooks")
    }

    /// A fresh private directory for temporary index files; removed on drop.
    pub(super) fn scratch(&self) -> io::Result<Scratch> {
        let parent = self.root.join("tmp");
        private_directory(&parent)?;
        let path = parent.join(mint("tmp"));
        private_directory(&path)?;
        Ok(Scratch { path })
    }

    /// Runs `body` while holding this store's mutation lock: every capture,
    /// pin, unpin, ref change and id mint of the session is serialized.
    pub(super) fn exclusive<T>(&self, body: impl FnOnce() -> T) -> T {
        static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
        let lock = LOCKS
            .get_or_init(Mutex::default)
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .entry(self.root.clone())
            .or_default()
            .clone();
        let _guard = lock.lock().unwrap_or_else(PoisonError::into_inner);
        body()
    }

    /// The repository and worktree ids for a common and a per-worktree git
    /// directory, minting new ones the first time. Call under
    /// [`Self::exclusive`].
    pub(super) fn identify(
        &self,
        common_dir: &Path,
        git_dir: &Path,
    ) -> io::Result<(String, String)> {
        let path = self.root.join("identities.json");
        let mut identities: Identities = read_json(&path)?.unwrap_or_default();
        let common = common_dir.to_string_lossy().into_owned();
        let own = git_dir.to_string_lossy().into_owned();
        let mut changed = false;
        let repository_id = identities
            .repositories
            .entry(common)
            .or_insert_with(|| {
                changed = true;
                mint("repo")
            })
            .clone();
        let worktree = identities.worktrees.get(&own).cloned();
        let worktree_id = match worktree {
            Some(worktree) if worktree.repository_id == repository_id => worktree.worktree_id,
            _ => {
                changed = true;
                let worktree_id = mint("wt");
                let entry = Worktree {
                    worktree_id: worktree_id.clone(),
                    repository_id: repository_id.clone(),
                };
                identities.worktrees.insert(own, entry);
                worktree_id
            }
        };
        if changed {
            write_json(&path, &identities)?;
        }
        Ok((repository_id, worktree_id))
    }

    fn records(&self, repository_id: &str) -> PathBuf {
        self.root.join("records").join(repository_id)
    }

    /// A record of `repository_id`, or `None`. Ids that are not well formed
    /// are never found.
    pub(super) fn load(
        &self,
        repository_id: &str,
        checkpoint_id: &str,
    ) -> io::Result<Option<Stored>> {
        if !well_formed("ckpt", checkpoint_id) || !well_formed("repo", repository_id) {
            return Ok(None);
        }
        read_json(&self.records(repository_id).join(format!("{checkpoint_id}.json")))
    }

    pub(super) fn save(&self, stored: &Stored) -> io::Result<()> {
        let directory = self.records(&stored.record.repository_id);
        private_directory(&self.root.join("records"))?;
        private_directory(&directory)?;
        write_json(&directory.join(format!("{}.json", stored.record.checkpoint_id)), stored)
    }

    pub(super) fn remove(&self, repository_id: &str, checkpoint_id: &str) -> io::Result<()> {
        let path = self.records(repository_id).join(format!("{checkpoint_id}.json"));
        match fs::remove_file(path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    /// Every record of a repository, in no particular order.
    pub(super) fn all(&self, repository_id: &str) -> io::Result<Vec<Stored>> {
        let entries = match fs::read_dir(self.records(repository_id)) {
            Ok(entries) => entries,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error),
        };
        let mut records = Vec::new();
        for entry in entries {
            let path = entry?.path();
            if path.extension().is_some_and(|extension| extension == "json")
                && let Some(stored) = read_json::<Stored>(&path)?
            {
                records.push(stored);
            }
        }
        Ok(records)
    }

    fn ledger_path(&self, idempotency_key: &str) -> PathBuf {
        let digest = Sha256::digest(idempotency_key.as_bytes());
        self.root.join("ledger").join(format!("{}.json", hex(&digest)))
    }

    pub(super) fn ledger(&self, idempotency_key: &str) -> io::Result<Option<LedgerEntry>> {
        let entry: Option<LedgerEntry> = read_json(&self.ledger_path(idempotency_key))?;
        Ok(entry.filter(|entry| entry.idempotency_key == idempotency_key))
    }

    pub(super) fn record_ledger(&self, entry: &LedgerEntry) -> io::Result<()> {
        write_json(&self.ledger_path(&entry.idempotency_key), entry)
    }
}

/// A temporary directory, removed with everything in it when dropped.
pub(super) struct Scratch {
    pub path: PathBuf,
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// `<prefix>_<32 lowercase hex digits>` from the system's random source.
pub(super) fn mint(prefix: &str) -> String {
    let mut bytes = [0_u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        // Unique enough for a scratch name or an id when the random source
        // fails: the clock and the process.
        let seed = format!("{:?}{}", std::time::SystemTime::now(), std::process::id());
        bytes.copy_from_slice(&Sha256::digest(seed.as_bytes())[..16]);
    }
    format!("{prefix}_{}", hex(&bytes))
}

pub(super) fn well_formed(prefix: &str, id: &str) -> bool {
    id.strip_prefix(prefix).and_then(|rest| rest.strip_prefix('_')).is_some_and(|digits| {
        digits.len() == 32 && digits.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    })
}

pub(super) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub(super) fn io_failed(operation: &'static str, error: &io::Error) -> ResourceError {
    ResourceError::operation_failed(
        operation,
        format!("the checkpoint store could not be read or written: {error}"),
        json!({"code":"store_failed"}),
    )
}

fn private_directory(path: &Path) -> io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> io::Result<Option<T>> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

/// Writes a temporary file beside `path` (0600), syncs it and renames it
/// over `path`, so a reader sees the old or the new contents.
fn write_json(path: &Path, value: &impl Serialize) -> io::Result<()> {
    let bytes = serde_json::to_vec(value).map_err(io::Error::other)?;
    let directory = path.parent().ok_or_else(|| io::Error::other("no parent directory"))?;
    let temporary = directory.join(format!(".{}.tmp", mint("write")));
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_data()?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
