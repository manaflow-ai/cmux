//! The durable connection store: the single writer of `conn_…` records.
//!
//! One commit writes the whole state (records, revocations and the replay
//! window) to `conns.json` atomically, then the link's known-hosts file,
//! then publishes the events. The known-hosts file is a projection of the
//! confirmed keys and is rewritten on every commit.

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use tokio::sync::broadcast;

use super::reducer::LinkState;
use super::{ConnEvent, ConnRecord, ConnRequest, Outcome, Principal, Reject, reduce};

const STATE_FILE: &str = "conns.json";
const KNOWN_HOSTS_FILE: &str = "known_hosts";
const EVENT_BUFFER: usize = 256;

#[derive(Debug)]
pub enum StoreError {
    Rejected(Reject),
    Io(std::io::Error),
    Corrupt(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Rejected(reject) => write!(formatter, "{reject}"),
            Self::Io(error) => write!(formatter, "connection store I/O failed: {error}"),
            Self::Corrupt(message) => write!(formatter, "connection store is corrupt: {message}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<Reject> for StoreError {
    fn from(reject: Reject) -> Self {
        Self::Rejected(reject)
    }
}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

pub struct ConnStore {
    directory: PathBuf,
    state: Mutex<LinkState>,
    events: broadcast::Sender<ConnEvent>,
}

impl ConnStore {
    /// Opens (or creates) the store in `directory`, which the link keeps
    /// private (0700).
    pub fn open(directory: &Path) -> Result<Self, StoreError> {
        create_private_directory(directory)?;
        let state = match std::fs::read(directory.join(STATE_FILE)) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|error| StoreError::Corrupt(error.to_string()))?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => LinkState::default(),
            Err(error) => return Err(error.into()),
        };
        let store = Self {
            directory: directory.to_owned(),
            state: Mutex::new(state),
            events: broadcast::channel(EVENT_BUFFER).0,
        };
        store.write_known_hosts(&store.lock())?;
        Ok(store)
    }

    /// The link-owned known-hosts file passed as `UserKnownHostsFile`.
    #[must_use]
    pub fn known_hosts_path(&self) -> PathBuf {
        self.directory.join(KNOWN_HOSTS_FILE)
    }

    #[must_use]
    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// Applies one request and commits it before any event is published.
    pub fn apply(&self, request: &ConnRequest) -> Result<Outcome, StoreError> {
        let mut state = self.lock();
        let (next, outcome, events) = reduce(&state, request)?;
        if outcome.replayed {
            return Ok(outcome);
        }
        let bytes =
            serde_json::to_vec(&next).map_err(|error| StoreError::Corrupt(error.to_string()))?;
        write_private_file(&self.directory.join(STATE_FILE), &bytes)?;
        self.write_known_hosts(&next)?;
        *state = next;
        drop(state);
        for event in events {
            // No subscriber is not an error: events are also in the state.
            let _ = self.events.send(event);
        }
        Ok(outcome)
    }

    /// The records of one (user, app).
    #[must_use]
    pub fn list(&self, principal: &Principal) -> Vec<ConnRecord> {
        self.lock().list(principal)
    }

    /// One record of one (user, app).
    #[must_use]
    pub fn get(&self, principal: &Principal, conn: &str) -> Option<ConnRecord> {
        self.lock().get(principal, conn).cloned()
    }

    /// Every committed change, in commit order.
    #[must_use]
    pub fn subscribe(&self) -> broadcast::Receiver<ConnEvent> {
        self.events.subscribe()
    }

    fn write_known_hosts(&self, state: &LinkState) -> std::io::Result<()> {
        crate::host_key::write_known_hosts(&self.known_hosts_path(), state.confirmed_host_keys())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, LinkState> {
        // A panic while holding the lock cannot leave a half-applied state:
        // the state is replaced only after the commit succeeded.
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// Creates `directory` with mode 0700 if it does not exist.
pub fn create_private_directory(directory: &Path) -> std::io::Result<()> {
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(directory)
}

/// Replaces `path` with `contents`: a 0600 temporary file in the same
/// directory, synced, then renamed over the old file.
pub fn write_private_file(path: &Path, contents: &[u8]) -> std::io::Result<()> {
    let directory = path.parent().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "path has no parent directory")
    })?;
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = directory.join(format!(".{name}.{}.tmp", crate::ids::random_id("")));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let result = (|| {
        let mut file = options.open(&temporary)?;
        file.write_all(contents)?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}
