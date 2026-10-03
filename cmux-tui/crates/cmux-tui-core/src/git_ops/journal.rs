//! The attempt journal of `git.commit` and `git.push`: proof that a keyed
//! request started git, kept until its result is in the mutation ledger.
//! A retry with the same key and arguments finds the attempt and finishes
//! it instead of acting twice: a commit is recovered only when HEAD's
//! reflog names the attempt (`commit`), and a push sends the commit the
//! attempt read (`push`).
//!
//! Entries live under the session's state directory in `git-attempts/`
//! (0700, files 0600, written atomically), named by the repository's
//! identity and the key, so the same key in two repositories never meets.
//! A session without durable state keeps them in memory. Both are bounded:
//! entries older than 7 days go, and at most 256 stay (oldest go first).

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::checkpoint::store::{hex, private_directory, read_json, write_json};
use super::mutation::refused;
use crate::Mux;
use crate::resource::ResourceError;

const DIRECTORY: &str = "git-attempts";
pub(super) const MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);
pub(super) const MAX_ENTRIES: usize = 256;

/// One attempt: the request it belongs to and what the operation records.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Entry {
    idempotency_key: String,
    fingerprint: Value,
    /// Seconds since the epoch.
    started_at: u64,
    body: Value,
}

enum Place {
    Disk(PathBuf),
    /// The key of the in-memory entry.
    Memory(String),
}

/// The journal entry of one key in one repository.
pub(super) struct Journal {
    place: Place,
    key: String,
    operation: &'static str,
}

/// In-memory entries of sessions without durable state, with the order
/// they were written in.
type Memory = Mutex<(u64, HashMap<String, (u64, Entry)>)>;

fn memory() -> &'static Memory {
    static MEMORY: OnceLock<Memory> = OnceLock::new();
    MEMORY.get_or_init(Mutex::default)
}

impl Journal {
    /// `repository` is the identity the request resolved to.
    pub(super) fn open(
        mux: &Mux,
        repository: &str,
        key: &str,
        operation: &'static str,
    ) -> Result<Self, ResourceError> {
        let name = hex(&Sha256::digest(format!("{operation}\0{repository}\0{key}").as_bytes()));
        let place = match mux.session_state_directory() {
            Some(session) => {
                let directory = session.join(DIRECTORY);
                private_directory(&directory).map_err(|error| failed(operation, &error))?;
                prune(&directory, SystemTime::now());
                Place::Disk(directory.join(format!("{name}.json")))
            }
            None => {
                // The registry's identity names this session instance.
                let (registry, generation) = mux.registry_identity();
                Place::Memory(format!("{registry}\0{generation}\0{name}"))
            }
        };
        Ok(Self { place, key: key.to_string(), operation })
    }

    /// The unfinished attempt of this key with this fingerprint.
    pub(super) fn attempt<T: DeserializeOwned>(&self, fingerprint: &Value) -> Option<T> {
        let entry = match &self.place {
            Place::Disk(path) => read_json::<Entry>(path).ok().flatten()?,
            Place::Memory(name) => {
                let memory = memory().lock().unwrap_or_else(PoisonError::into_inner);
                memory.1.get(name)?.1.clone()
            }
        };
        if entry.idempotency_key != self.key || &entry.fingerprint != fingerprint {
            return None;
        }
        serde_json::from_value(entry.body).ok()
    }

    /// Records an attempt before git runs.
    pub(super) fn start(
        &self,
        fingerprint: &Value,
        body: &impl Serialize,
    ) -> Result<(), ResourceError> {
        let entry = Entry {
            idempotency_key: self.key.clone(),
            fingerprint: fingerprint.clone(),
            started_at: seconds(SystemTime::now()),
            body: serde_json::to_value(body).expect("attempts serialize"),
        };
        match &self.place {
            Place::Disk(path) => {
                write_json(path, &entry).map_err(|error| failed(self.operation, &error))
            }
            Place::Memory(name) => {
                let mut memory = memory().lock().unwrap_or_else(PoisonError::into_inner);
                memory.0 += 1;
                let order = memory.0;
                memory.1.insert(name.clone(), (order, entry));
                while memory.1.len() > MAX_ENTRIES {
                    let oldest = memory.1.iter().min_by_key(|(_, (order, _))| *order);
                    let Some(oldest) = oldest.map(|(name, _)| name.clone()) else { break };
                    memory.1.remove(&oldest);
                }
                Ok(())
            }
        }
    }

    /// Drops the attempt.
    pub(super) fn finish(&self) {
        match &self.place {
            Place::Disk(path) => {
                let _ = fs::remove_file(path);
            }
            Place::Memory(name) => {
                memory().lock().unwrap_or_else(PoisonError::into_inner).1.remove(name);
            }
        }
    }
}

/// Removes entries older than [`MAX_AGE`], then the oldest past
/// [`MAX_ENTRIES`].
pub(super) fn prune(directory: &Path, now: SystemTime) {
    let Ok(listing) = fs::read_dir(directory) else { return };
    let mut entries: Vec<(SystemTime, PathBuf)> = listing
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "json"))
        .filter_map(|path| Some((fs::metadata(&path).ok()?.modified().ok()?, path)))
        .collect();
    entries.retain(|(modified, path)| {
        let expired = now.duration_since(*modified).is_ok_and(|age| age > MAX_AGE);
        if expired {
            let _ = fs::remove_file(path);
        }
        !expired
    });
    if entries.len() > MAX_ENTRIES {
        entries.sort();
        for (_, path) in &entries[..entries.len() - MAX_ENTRIES] {
            let _ = fs::remove_file(path);
        }
    }
}

fn seconds(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_secs())
}

fn failed(operation: &'static str, error: &std::io::Error) -> ResourceError {
    let message = format!("the attempt journal could not be read or written: {error}");
    refused(operation, "store_failed", message, Value::Null)
}
