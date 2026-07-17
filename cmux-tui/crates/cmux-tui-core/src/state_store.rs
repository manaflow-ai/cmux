//! Versioned, fail-closed persistence for daemon session identity.
//!
//! This first store format intentionally contains no topology, PTY, terminal,
//! or presentation state. It gives later persistence work a crash-safe format
//! boundary without implying that shells survive a daemon process crash yet.

use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{SessionId, platform};

pub const STATE_STORE_VERSION: u32 = 1;

const SESSION_PATH_NAMESPACE: Uuid = Uuid::from_u128(0x9f87_2e39_dcd4_4d89_a43f_2977_1b35_754a);

#[derive(Debug)]
pub enum StateStoreError {
    Io { path: PathBuf, source: std::io::Error },
    Corrupt { path: PathBuf, reason: String },
    Unavailable { reason: String },
}

impl StateStoreError {
    fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Self::Io { path: path.into(), source }
    }
}

impl fmt::Display for StateStoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, source } => {
                write!(formatter, "state store I/O at {}: {source}", path.display())
            }
            Self::Corrupt { path, reason } => {
                write!(formatter, "refusing corrupt state at {}: {reason}", path.display())
            }
            Self::Unavailable { reason } => formatter.write_str(reason),
        }
    }
}

impl std::error::Error for StateStoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { source, .. } => Some(source),
            Self::Corrupt { .. } | Self::Unavailable { .. } => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateRecovery {
    pub session_id: SessionId,
    pub archived_corrupt_state: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct StateStore {
    root: PathBuf,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredSessionV1 {
    version: u32,
    session: String,
    session_id: SessionId,
}

struct TempStateFile {
    path: PathBuf,
    armed: bool,
}

struct SessionLock(File);

impl TempStateFile {
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for TempStateFile {
    fn drop(&mut self) {
        if self.armed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

impl Drop for SessionLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.0);
    }
}

impl StateStore {
    /// Create a store rooted at an explicit directory. Callers can use
    /// [`platform::state_dir`] for the platform default or inject an isolated
    /// directory for tests and alternate daemon installations.
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn platform_default() -> Result<Self, StateStoreError> {
        let root = platform::state_dir().ok_or_else(|| StateStoreError::Unavailable {
            reason: "no platform state directory is available; pass --state-dir".to_string(),
        })?;
        Ok(Self::new(root))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn session_path(&self, session: &str) -> PathBuf {
        let key = session_key(session);
        self.root.join("sessions").join(format!("{key}.json"))
    }

    /// Load an existing session identity or atomically create one. Malformed,
    /// mismatched, and unknown-version files are never overwritten here.
    pub fn load_or_create_session(&self, session: &str) -> Result<SessionId, StateStoreError> {
        if let Some(session_id) = self.load_session(session)? {
            return Ok(session_id);
        }
        let _lock = self.lock_session(session)?;
        if let Some(session_id) = self.load_session(session)? {
            return Ok(session_id);
        }
        self.create_session_if_absent(session, SessionId::new())
    }

    /// Replace a session record using a fully synced same-directory temporary
    /// file followed by one rename. This is the migration/recovery write seam.
    pub fn replace_session(
        &self,
        session: &str,
        session_id: SessionId,
    ) -> Result<(), StateStoreError> {
        let _lock = self.lock_session(session)?;
        let destination = self.session_path(session);
        let mut temp = self.write_temp(session, session_id)?;
        fs::rename(&temp.path, &destination)
            .map_err(|error| StateStoreError::io(&destination, error))?;
        temp.disarm();
        sync_directory(destination.parent().expect("session state has a parent"))?;
        Ok(())
    }

    /// Explicitly recover a corrupt record. Valid state is returned unchanged.
    /// Corrupt bytes are atomically renamed to a unique archive before a new
    /// identity is created, so recovery remains inspectable and reversible.
    pub fn recover_session(&self, session: &str) -> Result<StateRecovery, StateStoreError> {
        // Serialize the load, archive, and replacement as one cross-process
        // transaction. Without this lock, a second recovery could parse the
        // old corrupt bytes, then archive the first recovery's valid result.
        let _lock = self.lock_session(session)?;
        match self.load_session(session) {
            Ok(Some(session_id)) => {
                return Ok(StateRecovery { session_id, archived_corrupt_state: None });
            }
            Ok(None) => {
                let session_id = self.create_session_if_absent(session, SessionId::new())?;
                return Ok(StateRecovery { session_id, archived_corrupt_state: None });
            }
            Err(StateStoreError::Io { path, source }) => {
                return Err(StateStoreError::Io { path, source });
            }
            Err(error @ StateStoreError::Unavailable { .. }) => return Err(error),
            Err(StateStoreError::Corrupt { .. }) => {}
        }

        let path = self.session_path(session);
        let archive = path.with_extension(format!("corrupt-{}.json", Uuid::new_v4()));
        let archived_corrupt_state = match fs::rename(&path, &archive) {
            Ok(()) => {
                platform::restrict_file(&archive)
                    .map_err(|error| StateStoreError::io(&archive, error))?;
                sync_directory(path.parent().expect("session state has a parent"))?;
                Some(archive)
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // A concurrent recovery already archived the record. Its new
                // valid identity wins through create_session_if_absent.
                None
            }
            Err(error) => return Err(StateStoreError::io(&path, error)),
        };
        let session_id = self.create_session_if_absent(session, SessionId::new())?;
        Ok(StateRecovery { session_id, archived_corrupt_state })
    }

    fn lock_session(&self, session: &str) -> Result<SessionLock, StateStoreError> {
        let directory = self.root.join("locks");
        fs::create_dir_all(&directory).map_err(|error| StateStoreError::io(&directory, error))?;
        platform::restrict_directory(&self.root)
            .map_err(|error| StateStoreError::io(&self.root, error))?;
        platform::restrict_directory(&directory)
            .map_err(|error| StateStoreError::io(&directory, error))?;
        let path = directory.join(format!("{}.lock", session_key(session)));
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(&path)
            .map_err(|error| StateStoreError::io(&path, error))?;
        platform::restrict_file(&path).map_err(|error| StateStoreError::io(&path, error))?;
        fs2::FileExt::lock_exclusive(&file).map_err(|error| StateStoreError::io(&path, error))?;
        Ok(SessionLock(file))
    }

    fn load_session(&self, session: &str) -> Result<Option<SessionId>, StateStoreError> {
        let path = self.session_path(session);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(StateStoreError::io(&path, error)),
        };
        let value = serde_json::from_slice::<serde_json::Value>(&bytes).map_err(|error| {
            StateStoreError::Corrupt {
                path: path.clone(),
                reason: format!("invalid JSON: {error}"),
            }
        })?;
        let version =
            value.get("version").and_then(serde_json::Value::as_u64).ok_or_else(|| {
                StateStoreError::Corrupt {
                    path: path.clone(),
                    reason: "missing integer version".to_string(),
                }
            })?;
        if version != u64::from(STATE_STORE_VERSION) {
            return Err(StateStoreError::Corrupt {
                path,
                reason: format!("unsupported version {version}; expected {STATE_STORE_VERSION}"),
            });
        }
        let stored = serde_json::from_value::<StoredSessionV1>(value).map_err(|error| {
            StateStoreError::Corrupt {
                path: path.clone(),
                reason: format!("invalid version-{STATE_STORE_VERSION} record: {error}"),
            }
        })?;
        if stored.session != session {
            return Err(StateStoreError::Corrupt {
                path,
                reason: format!(
                    "session key collision: expected {session:?}, found {:?}",
                    stored.session
                ),
            });
        }
        Ok(Some(stored.session_id))
    }

    fn create_session_if_absent(
        &self,
        session: &str,
        candidate: SessionId,
    ) -> Result<SessionId, StateStoreError> {
        let destination = self.session_path(session);
        let mut temp = self.write_temp(session, candidate)?;
        match fs::hard_link(&temp.path, &destination) {
            Ok(()) => {
                fs::remove_file(&temp.path)
                    .map_err(|error| StateStoreError::io(&temp.path, error))?;
                temp.disarm();
                sync_directory(destination.parent().expect("session state has a parent"))?;
                Ok(candidate)
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                drop(temp);
                self.load_session(session)?.ok_or_else(|| StateStoreError::Corrupt {
                    path: destination,
                    reason: "state disappeared during concurrent creation".to_string(),
                })
            }
            Err(error) => Err(StateStoreError::io(&destination, error)),
        }
    }

    fn write_temp(
        &self,
        session: &str,
        session_id: SessionId,
    ) -> Result<TempStateFile, StateStoreError> {
        let destination = self.session_path(session);
        let directory = destination.parent().expect("session state has a parent");
        fs::create_dir_all(directory).map_err(|error| StateStoreError::io(directory, error))?;
        platform::restrict_directory(&self.root)
            .map_err(|error| StateStoreError::io(&self.root, error))?;
        platform::restrict_directory(directory)
            .map_err(|error| StateStoreError::io(directory, error))?;

        let record = StoredSessionV1 {
            version: STATE_STORE_VERSION,
            session: session.to_string(),
            session_id,
        };
        let mut bytes =
            serde_json::to_vec_pretty(&record).map_err(|error| StateStoreError::Corrupt {
                path: destination.clone(),
                reason: format!("could not encode state: {error}"),
            })?;
        bytes.push(b'\n');
        let temp_path = directory.join(format!(".state-{}.tmp", Uuid::new_v4()));
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&temp_path)
            .map_err(|error| StateStoreError::io(&temp_path, error))?;
        let temp = TempStateFile { path: temp_path.clone(), armed: true };
        platform::restrict_file(&temp_path)
            .map_err(|error| StateStoreError::io(&temp_path, error))?;
        file.write_all(&bytes)
            .and_then(|()| file.sync_all())
            .map_err(|error| StateStoreError::io(&temp_path, error))?;
        Ok(temp)
    }
}

fn session_key(session: &str) -> Uuid {
    Uuid::new_v5(&SESSION_PATH_NAMESPACE, session.as_bytes())
}

fn sync_directory(path: &Path) -> Result<(), StateStoreError> {
    #[cfg(unix)]
    {
        File::open(path)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| StateStoreError::io(path, error))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new(name: &str) -> Self {
            Self(std::env::temp_dir().join(format!(
                "cmux-tui-state-{name}-{}-{}",
                std::process::id(),
                Uuid::new_v4()
            )))
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn session_identity_survives_restart_but_daemon_identity_does_not() {
        let directory = TestDirectory::new("restart");
        let store = StateStore::new(&directory.0);
        let first = crate::Mux::new_with_session_id(
            "main",
            crate::SurfaceOptions::default(),
            store.load_or_create_session("main").unwrap(),
        );
        let first_session = first.session_id;
        let first_daemon = first.daemon_instance_id;
        drop(first);

        let reopened = StateStore::new(&directory.0);
        let second = crate::Mux::new_with_session_id(
            "main",
            crate::SurfaceOptions::default(),
            reopened.load_or_create_session("main").unwrap(),
        );
        let second_session = second.session_id;
        let second_daemon = second.daemon_instance_id;

        assert_eq!(first_session, second_session);
        assert_ne!(first_daemon, second_daemon);
        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(store.session_path("main")).unwrap()).unwrap();
        assert_eq!(value["version"], STATE_STORE_VERSION);
        assert_eq!(value["session"], "main");
        assert_eq!(value["session_id"], first_session.to_string());
        assert_eq!(value.as_object().unwrap().len(), 3);
        assert!(value.get("presentations").is_none());
    }

    #[test]
    fn corrupt_state_fails_closed_then_explicit_recovery_archives_it() {
        let directory = TestDirectory::new("corrupt");
        let store = StateStore::new(&directory.0);
        let path = store.session_path("main");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let corrupt = b"{ definitely-not-json";
        fs::write(&path, corrupt).unwrap();

        let error = store.load_or_create_session("main").unwrap_err();
        assert!(matches!(error, StateStoreError::Corrupt { .. }));
        assert_eq!(fs::read(&path).unwrap(), corrupt);

        let recovered = store.recover_session("main").unwrap();
        let archive = recovered.archived_corrupt_state.unwrap();
        assert_eq!(fs::read(archive).unwrap(), corrupt);
        assert_eq!(store.load_or_create_session("main").unwrap(), recovered.session_id);
    }

    #[test]
    fn concurrent_recovery_converges_without_archiving_valid_state() {
        use std::sync::Barrier;

        let directory = TestDirectory::new("concurrent-recovery");
        let store = StateStore::new(&directory.0);
        let path = store.session_path("main");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let corrupt = b"{ concurrently-corrupt";
        fs::write(&path, corrupt).unwrap();

        let start = std::sync::Arc::new(Barrier::new(16));
        let workers = (0..16)
            .map(|_| {
                let store = store.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    store.recover_session("main").unwrap()
                })
            })
            .collect::<Vec<_>>();
        let recoveries =
            workers.into_iter().map(|worker| worker.join().unwrap()).collect::<Vec<_>>();

        let session_id = recoveries[0].session_id;
        assert!(recoveries.iter().all(|recovery| recovery.session_id == session_id));
        let archives = recoveries
            .iter()
            .filter_map(|recovery| recovery.archived_corrupt_state.as_ref())
            .collect::<Vec<_>>();
        assert_eq!(archives.len(), 1);
        assert_eq!(fs::read(archives[0]).unwrap(), corrupt);
        assert_eq!(store.load_or_create_session("main").unwrap(), session_id);
        assert_eq!(store.recover_session("main").unwrap().archived_corrupt_state, None);
        assert_eq!(store.load_or_create_session("main").unwrap(), session_id);
    }

    #[test]
    fn unknown_state_version_fails_closed() {
        let directory = TestDirectory::new("version");
        let store = StateStore::new(&directory.0);
        let path = store.session_path("main");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            format!(
                "{{\"version\":{},\"session\":\"main\",\"session_id\":\"{}\"}}",
                STATE_STORE_VERSION + 1,
                SessionId::new()
            ),
        )
        .unwrap();

        let error = store.load_or_create_session("main").unwrap_err();
        assert!(error.to_string().contains("unsupported version"));
    }

    #[test]
    fn replacement_writes_one_complete_versioned_record() {
        let directory = TestDirectory::new("replace");
        let store = StateStore::new(&directory.0);
        let first = store.load_or_create_session("main").unwrap();
        let replacement = SessionId::new();
        assert_ne!(first, replacement);

        store.replace_session("main", replacement).unwrap();

        assert_eq!(store.load_or_create_session("main").unwrap(), replacement);
        let sessions = fs::read_dir(store.root().join("sessions"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<Vec<_>>();
        assert_eq!(sessions.len(), 1);
    }

    #[test]
    fn concurrent_first_open_converges_on_one_session_identity() {
        use std::sync::Barrier;

        let directory = TestDirectory::new("concurrent-create");
        let store = StateStore::new(&directory.0);
        let start = std::sync::Arc::new(Barrier::new(8));
        let workers = (0..8)
            .map(|_| {
                let store = store.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    store.load_or_create_session("main").unwrap()
                })
            })
            .collect::<Vec<_>>();
        let identities =
            workers.into_iter().map(|worker| worker.join().unwrap()).collect::<Vec<_>>();

        assert!(identities.iter().all(|identity| *identity == identities[0]));
    }

    #[test]
    fn concurrent_readers_never_observe_a_partial_replacement() {
        use std::sync::Barrier;
        use std::sync::atomic::{AtomicBool, Ordering};

        let directory = TestDirectory::new("concurrent-replace");
        let store = StateStore::new(&directory.0);
        store.load_or_create_session("main").unwrap();
        let start = std::sync::Arc::new(Barrier::new(2));
        let finished = std::sync::Arc::new(AtomicBool::new(false));
        let writer_store = store.clone();
        let writer_start = start.clone();
        let writer_finished = finished.clone();
        let writer = std::thread::spawn(move || {
            writer_start.wait();
            for _ in 0..64 {
                writer_store.replace_session("main", SessionId::new()).unwrap();
                std::thread::yield_now();
            }
            writer_finished.store(true, Ordering::Release);
        });

        start.wait();
        let mut reads = 0;
        while !finished.load(Ordering::Acquire) {
            assert!(store.load_session("main").unwrap().is_some());
            reads += 1;
            std::thread::yield_now();
        }
        writer.join().unwrap();
        assert!(store.load_session("main").unwrap().is_some());
        assert!(reads > 0);
    }
}
