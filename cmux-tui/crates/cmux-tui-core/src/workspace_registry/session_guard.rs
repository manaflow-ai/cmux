//! Session guard leases and their short coordinator.
//!
//! A session guard is held for the lifetime of a registry owner. The coordinator
//! serializes guard-file creation and replacement, while leases provide the
//! lock identity checks needed by reset and host adoption.

use super::session_storage_component;
use crate::platform;
use anyhow::Context;
use cmux_file_lock::{FileLock, Kind, LockError};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

pub(super) const SESSION_GUARD_DIR: &str = "session-locks";
const SESSION_GUARD_COORDINATOR_FILE: &str = ".coordinator.lock";
const SESSION_GUARD_COORDINATOR_WAITER_DIR: &str = ".coordinator.waiters";
const SESSION_GUARD_COORDINATOR_TIMEOUT: std::time::Duration =
    std::time::Duration::from_millis(250);
const SESSION_GUARD_COORDINATOR_PUBLICATION_SCAN_LIMIT: usize = 64;
static SESSION_GUARD_COORDINATOR_WAITER_SEQUENCE: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);
pub(super) fn acquire_session_guard(
    root: &Path,
    session_name: &str,
) -> anyhow::Result<SessionLease> {
    fs::create_dir_all(root).with_context(|| format!("create state root {}", root.display()))?;
    acquire_existing_session_guard(root, session_name)
}

pub(super) fn acquire_existing_session_guard(
    root: &Path,
    session_name: &str,
) -> anyhow::Result<SessionLease> {
    platform::restrict_directory(root)?;
    acquire_session_guard_from_private_dir(root, session_name, false)
}

pub(super) fn acquire_existing_session_reset_guard(
    root: &Path,
    session_name: &str,
) -> anyhow::Result<SessionLease> {
    acquire_session_guard_from_private_dir(root, session_name, true)
}

fn acquire_session_guard_from_private_dir(
    root: &Path,
    session_name: &str,
    bounded: bool,
) -> anyhow::Result<SessionLease> {
    let lock_dir = prepare_session_guard_dir(root)?;
    let coordinator_path = session_guard_coordinator_path(&lock_dir);
    let _coordinator = if bounded {
        SessionLease::acquire_coordinator(&coordinator_path)
    } else {
        SessionLease::acquire_coordinator_blocking(&coordinator_path)
    }
    .with_context(|| format!("coordinate session lock directory {}", lock_dir.display()))?;
    let lock_path = session_guard_lock_path(&lock_dir, session_name);
    SessionLease::acquire(&lock_path)
}

/// Whether a daemon owns another session of `root` now, asked by the session
/// guard every owner holds from its registry open to its exit
/// (`mux/unowned_hosts.rs`). `component` is the guard's file stem
/// ([`session_storage_component`]).
pub(crate) enum SessionOwnerProbe {
    /// No daemon holds the guard: the lease is held here until dropped, so
    /// none can start the session meanwhile.
    Unowned(SessionLease),
    /// A daemon holds the guard, or the probe could not tell.
    Owned,
    /// The session has no guard file in `root`.
    NoGuard,
}

/// Takes the guard of the session whose file stem is `component` when no
/// daemon holds it, without waiting on a daemon (the coordinator's short
/// bound). A daemon that starts the session while the lease is held here
/// fails its start, as it does during a session reset.
///
/// The guard file itself is opened, never made: a missing one is
/// [`SessionOwnerProbe::NoGuard`], and any other doubt (it cannot be opened,
/// it changed while opening, its lock is taken) is
/// [`SessionOwnerProbe::Owned`]. Whoever holds the lease checks
/// [`SessionLease::still_guards`] before each step that ends a host.
pub(crate) fn probe_session_owner(root: &Path, component: &str) -> SessionOwnerProbe {
    match lock_free_session_guard(root, component) {
        // The coordinator goes as this returns; the lease stays.
        Ok((lease, _coordinator)) => SessionOwnerProbe::Unowned(lease),
        Err(probe) => probe,
    }
}

/// What [`peek_session_owner`] saw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionOwnerPeek {
    /// No daemon held the guard.
    Unowned,
    /// A daemon holds the guard, or the peek could not tell.
    Owned,
    /// The session has no guard file in `root`.
    NoGuard,
}

/// [`probe_session_owner`] that keeps nothing, for `cmux ps` and a `cmux gc`
/// dry run: the guard's lock is taken and let go while the coordinator is
/// held. A daemon starts a session by taking the coordinator first, so one
/// starting meanwhile waits on the coordinator for that instant instead of
/// failing on a guard held here.
pub(crate) fn peek_session_owner(root: &Path, component: &str) -> SessionOwnerPeek {
    match lock_free_session_guard(root, component) {
        Ok((lease, coordinator)) => {
            drop(lease);
            drop(coordinator);
            SessionOwnerPeek::Unowned
        }
        Err(SessionOwnerProbe::NoGuard) => SessionOwnerPeek::NoGuard,
        Err(_) => SessionOwnerPeek::Owned,
    }
}

/// The free guard of `component` locked here, with the coordinator still
/// held; `Err` with what the probe found otherwise.
fn lock_free_session_guard(
    root: &Path,
    component: &str,
) -> Result<(SessionLease, SessionLease), SessionOwnerProbe> {
    let lock_dir = platform::normalize_filesystem_path(root.join(SESSION_GUARD_DIR));
    let lock_path = session_guard_lock_component_path(&lock_dir, component);
    let file = match open_existing_session_guard(&lock_path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(SessionOwnerProbe::NoGuard);
        }
        Err(_) => return Err(SessionOwnerProbe::Owned),
    };
    let Ok(coordinator) =
        SessionLease::acquire_coordinator(&session_guard_coordinator_path(&lock_dir))
    else {
        return Err(SessionOwnerProbe::Owned);
    };
    // Locked first, then checked: the path must still name the locked file.
    let lock = match FileLock::try_take(file, Kind::Exclusive) {
        Ok(lock) => lock,
        Err(LockError::Busy(_) | LockError::Io(_)) => return Err(SessionOwnerProbe::Owned),
    };
    if validate_session_lock_file(&lock_path, lock.file()).is_err() {
        return Err(SessionOwnerProbe::Owned);
    }
    Ok((SessionLease { lock, path: lock_path, coordinator_waiter_dir: None }, coordinator))
}

/// The top-level files of the session `component` of `root` that only an
/// owner run writes, with their metadata. SQLite's reader side files are left
/// out: the registry is in WAL mode, and a read-only open (`cmux ps`, `cmux
/// gc`, [`stored_terminal_references`]) leaves a `-shm` and an empty `-wal`
/// behind and writes the `-shm` on each read. A reader never writes the main
/// database or appends to the WAL; an owner's commit appends to the WAL (so
/// it is no longer empty) and its checkpoint writes the main database, so the
/// main database and a nonempty `-wal` still show every owner write.
fn owner_written_files(root: &Path, component: &str) -> Vec<fs::Metadata> {
    let dir = platform::normalize_filesystem_path(root.join(component));
    fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let reader_side_file =
                name.ends_with("-shm") || (name.ends_with("-wal") && metadata.len() == 0);
            (metadata.is_file() && !reader_side_file).then_some(metadata)
        })
        .collect()
}

/// Opens the guard file at `lock_path`; never makes it.
fn open_existing_session_guard(lock_path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    }
    options.open(lock_path)
}

/// What [`while_no_daemon_owns`] found for a session.
pub(crate) enum WhileUnowned<T> {
    /// The guard's lock is taken: a daemon owns the session, or another
    /// process holds the guard for a short time (a host sweep, a session
    /// reset).
    Owned,
    /// The guard's lock was free: the act ran with the guard held, and gave
    /// this.
    Ran(T),
}

/// Runs `act` while no daemon owns the session whose guard file stem is
/// `component`, with the session's guard held from before `act` to after
/// it. An error for each doubt, and then `act` did not run: no guard file, no
/// file of the session-locks directory's lock, that lock is busy past its
/// short bound, a path no longer names the opened file, an I/O error. The
/// error names the file and the doubt: the caller does not know whether a
/// daemon owns the session.
///
/// The directory's lock is held from before the try of the guard until the
/// guard is free again. A daemon's start waits for the directory's lock
/// before it tries the guard without waiting, so no start meets the guard
/// that is held here: it waits for `act`, and then it finds the guard free.
/// Keep `act` short.
///
/// It makes no file and no directory: each of the 2 lock files is opened,
/// never made, and the wait for the directory's lock registers no waiter.
pub(crate) fn while_no_daemon_owns<T>(
    root: &Path,
    component: &str,
    act: impl FnOnce() -> T,
) -> anyhow::Result<WhileUnowned<T>> {
    let lock_dir = platform::normalize_filesystem_path(root.join(SESSION_GUARD_DIR));
    let lock_path = session_guard_lock_component_path(&lock_dir, component);
    let coordinator_path = session_guard_coordinator_path(&lock_dir);
    let guard = open_existing_session_guard(&lock_path)
        .with_context(|| format!("open the session guard {}", lock_path.display()))?;
    let coordinator = open_existing_session_guard(&coordinator_path).with_context(|| {
        format!("open the lock of the session guards {}", coordinator_path.display())
    })?;
    let coordinator = FileLock::take_within(
        coordinator,
        Kind::Exclusive,
        SESSION_GUARD_COORDINATOR_TIMEOUT,
        cmux_file_lock::MIN_STEP,
    )
    .map_err(anyhow::Error::new)
    .with_context(|| {
        format!(
            "take the lock of the session guards {} within {} ms",
            coordinator_path.display(),
            SESSION_GUARD_COORDINATOR_TIMEOUT.as_millis()
        )
    })?;
    validate_session_lock_file(&coordinator_path, coordinator.file())?;
    // As a lease: its drop tells a waiter that the directory's lock is free.
    let coordinator = SessionLease::coordinator(coordinator, &coordinator_path);
    // Locked first, then checked: the path must still name the locked file.
    let guard = match FileLock::try_take(guard, Kind::Exclusive) {
        Ok(guard) => guard,
        Err(LockError::Busy(guard)) => {
            validate_session_lock_file(&lock_path, &guard)?;
            return Ok(WhileUnowned::Owned);
        }
        Err(error @ LockError::Io(_)) => {
            return Err(anyhow::Error::new(error))
                .with_context(|| format!("try the session guard {}", lock_path.display()));
        }
    };
    validate_session_lock_file(&lock_path, guard.file())?;
    let ran = act();
    // The guard first: a start that waits for the directory's lock tries the
    // guard as soon as that lock is free.
    drop(guard);
    drop(coordinator);
    Ok(WhileUnowned::Ran(ran))
}

/// What the last owner run of the session `component` of `root` left in its
/// session directory: the newest modification time, the total size and the
/// count of the files only an owner writes ([`owner_written_files`]: the
/// registry, a nonempty WAL, `startup-timings.jsonl`). Every owner start and
/// every adoption commits there, so a change means an owner ran in between,
/// with one exception: a rollback's check that finds the registry with
/// journal subject rows due writes them, with the guard held by the check
/// (`stored_number_for_a_rollback`). That changes this mark one time with no
/// owner run. Nothing else writes them while its guard is free, and reading
/// the registry leaves the mark as it was.
pub(crate) fn session_owner_mark(root: &Path, component: &str) -> String {
    let (mut newest, mut size, mut files) = (0_u128, 0_u64, 0_usize);
    for metadata in owner_written_files(root, component) {
        files += 1;
        size = size.saturating_add(metadata.len());
        let modified = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |since| since.as_nanos());
        newest = newest.max(modified);
    }
    format!("{newest}:{size}:{files}")
}

/// When the last owner run of the session `component` of `root` last wrote
/// its session directory (the newest modification time of the files only an
/// owner writes, as [`session_owner_mark`] reads them); `None` when the
/// directory has no such file or its times cannot be read.
pub(crate) fn session_owner_last_active(
    root: &Path,
    component: &str,
) -> Option<std::time::SystemTime> {
    owner_written_files(root, component)
        .iter()
        .filter_map(|metadata| metadata.modified().ok())
        .max()
}

/// The terminals the workspace registry of the session `component` of
/// `root` still references (every row not tombstoned): what its next start
/// restores. `Ok(None)`: the session keeps no registry. Read-only, without
/// the session's locks.
pub(crate) fn stored_terminal_references(
    root: &Path,
    component: &str,
) -> anyhow::Result<Option<std::collections::HashSet<String>>> {
    let database = platform::normalize_filesystem_path(
        root.join(component).join(super::WORKSPACE_REGISTRY_FILE),
    );
    match fs::symlink_metadata(&database) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("stat {}", database.display()));
        }
    }
    let connection = super::open_registry_database_read_only(&database)
        .with_context(|| format!("open {}", database.display()))?;
    connection.busy_timeout(std::time::Duration::from_millis(500))?;
    let mut statement = connection
        .prepare("SELECT terminal_id FROM terminal_hosts WHERE lifecycle != 'tombstoned'")?;
    let ids = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<std::collections::HashSet<_>, _>>()?;
    Ok(Some(ids))
}

/// The guard file stems in `root` (`session-locks/<stem>.lock`), sorted.
#[cfg(unix)]
pub(crate) fn session_guard_components(root: &Path) -> Vec<String> {
    let lock_dir = platform::normalize_filesystem_path(root.join(SESSION_GUARD_DIR));
    let mut components = fs::read_dir(lock_dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let stem = name.strip_suffix(".lock")?;
            (!stem.starts_with('.')).then(|| stem.to_owned())
        })
        .collect::<Vec<_>>();
    components.sort();
    components
}

/// The guard file stem of `session` ([`session_storage_component`]).
#[cfg(any(windows, test))]
pub(crate) fn session_guard_component(session: &str) -> String {
    session_storage_component(session)
}

fn session_guard_lock_component_path(lock_dir: &Path, component: &str) -> PathBuf {
    platform::normalize_filesystem_path(lock_dir.join(format!("{component}.lock")))
}

/// A daemon's start of `session` in `root` as a session reset takes it: the
/// coordinator with its short bound, then the guard.
#[cfg(test)]
pub(crate) fn start_session_guard_for_test(
    root: &Path,
    session_name: &str,
) -> anyhow::Result<SessionLease> {
    fs::create_dir_all(root)?;
    acquire_session_guard_from_private_dir(root, session_name, true)
}

pub(super) fn prepare_session_guard_dir(root: &Path) -> anyhow::Result<PathBuf> {
    let lock_dir = platform::normalize_filesystem_path(root.join(SESSION_GUARD_DIR));
    match fs::symlink_metadata(&lock_dir) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => anyhow::bail!("session lock directory is not a directory: {}", lock_dir.display()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match fs::create_dir(&lock_dir) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    let metadata = fs::symlink_metadata(&lock_dir)?;
                    if !metadata.file_type().is_dir() {
                        anyhow::bail!(
                            "session lock directory is not a directory: {}",
                            lock_dir.display()
                        );
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
        Err(error) => return Err(error.into()),
    }
    platform::restrict_directory(&lock_dir)?;
    Ok(lock_dir)
}

pub(super) fn session_guard_lock_path(lock_dir: &Path, session_name: &str) -> PathBuf {
    platform::normalize_filesystem_path(
        lock_dir.join(format!("{}.lock", session_storage_component(session_name))),
    )
}

pub(super) fn session_guard_coordinator_path(lock_dir: &Path) -> PathBuf {
    platform::normalize_filesystem_path(lock_dir.join(SESSION_GUARD_COORDINATOR_FILE))
}

pub(crate) struct SessionLease {
    pub(super) lock: FileLock,
    pub(super) path: PathBuf,
    coordinator_waiter_dir: Option<PathBuf>,
}

impl SessionLease {
    pub(super) fn file(&self) -> &File {
        self.lock.file()
    }

    /// Whether the guard path still names the file this lease locked: a
    /// guard deleted (and maybe made again) since is no longer held here,
    /// and a daemon may own the session through the new file.
    pub(crate) fn still_guards(&self) -> bool {
        validate_session_lock_file(&self.path, self.file()).is_ok()
    }

    /// Runs `act` only while this lease still guards its session, with the
    /// session-locks coordinator held from that check until `act` returns.
    /// A daemon makes or replaces a guard file only under that coordinator
    /// (`acquire_session_guard_from_private_dir` takes it before
    /// [`SessionLease::acquire`] opens the guard), so none can own the
    /// session in between. `None`: the coordinator is busy past its short
    /// bound, or the guard no longer names this lease's file. Keep `act`
    /// short: a daemon start waits on the coordinator meanwhile.
    pub(crate) fn while_guarding<T>(&self, act: impl FnOnce() -> T) -> Option<T> {
        let lock_dir = self.path.parent()?;
        let _coordinator =
            SessionLease::acquire_coordinator(&session_guard_coordinator_path(lock_dir)).ok()?;
        self.still_guards().then(act)
    }

    pub(super) fn acquire(path: &Path) -> anyhow::Result<Self> {
        let file = open_session_lock_file(path)?;
        restrict_session_lock_file(path, &file)?;
        validate_session_lock_file(path, &file)?;
        let lock = FileLock::try_take(file, Kind::Exclusive)
            .map_err(anyhow::Error::new)
            .with_context(|| {
                format!("workspace session is already owned by another daemon: {}", path.display())
            })?;
        Ok(Self { lock, path: path.to_path_buf(), coordinator_waiter_dir: None })
    }

    pub(super) fn acquire_coordinator(path: &Path) -> anyhow::Result<Self> {
        Self::acquire_coordinator_until(
            path,
            std::time::Instant::now() + SESSION_GUARD_COORDINATOR_TIMEOUT,
        )
    }

    pub(super) fn acquire_coordinator_until(
        path: &Path,
        deadline: std::time::Instant,
    ) -> anyhow::Result<Self> {
        let mut file = open_session_lock_file(path)?;
        restrict_session_lock_file(path, &file)?;
        validate_session_lock_file(path, &file)?;
        loop {
            match FileLock::try_take(file, Kind::Exclusive) {
                Ok(lock) => return Ok(Self::coordinator(lock, path)),
                Err(LockError::Busy(back)) => {
                    file = back;
                    if std::time::Instant::now() >= deadline {
                        return session_coordinator_busy(path);
                    }
                }
                Err(LockError::Io(error)) => {
                    return Err(error).with_context(|| {
                        format!("lock workspace session coordinator: {}", path.display())
                    });
                }
            }

            let waiter = SessionCoordinatorWaiter::register(path).with_context(|| {
                format!("register workspace session coordinator waiter: {}", path.display())
            })?;

            // Registration precedes this second lock attempt. If the owner
            // released before it saw the registration, this attempt observes
            // the free lock and prevents a lost wakeup.
            match FileLock::try_take(file, Kind::Exclusive) {
                Ok(lock) => return Ok(Self::coordinator(lock, path)),
                Err(LockError::Busy(back)) => file = back,
                Err(LockError::Io(error)) => {
                    return Err(error).with_context(|| {
                        format!("lock workspace session coordinator: {}", path.display())
                    });
                }
            }

            if waiter.wait_until(deadline).with_context(|| {
                format!("wait for workspace session coordinator: {}", path.display())
            })? {
                continue;
            }

            // The file lock remains authoritative when the owner crashes
            // before it publishes a registered waiter signal.
            match FileLock::try_take(file, Kind::Exclusive) {
                Ok(lock) => return Ok(Self::coordinator(lock, path)),
                Err(LockError::Busy(_)) => return session_coordinator_busy(path),
                Err(LockError::Io(error)) => {
                    return Err(error).with_context(|| {
                        format!("lock workspace session coordinator: {}", path.display())
                    });
                }
            }
        }
    }

    pub(super) fn acquire_coordinator_blocking(path: &Path) -> anyhow::Result<Self> {
        let file = open_session_lock_file(path)?;
        restrict_session_lock_file(path, &file)?;
        validate_session_lock_file(path, &file)?;
        let lock = FileLock::take(file, Kind::Exclusive)
            .with_context(|| format!("lock workspace session coordinator: {}", path.display()))?;
        validate_session_lock_file(path, lock.file())?;
        Ok(Self::coordinator(lock, path))
    }

    fn coordinator(lock: FileLock, path: &Path) -> Self {
        Self {
            lock,
            path: path.to_path_buf(),
            coordinator_waiter_dir: Some(session_guard_coordinator_waiter_dir(path)),
        }
    }
}

fn session_coordinator_busy(path: &Path) -> anyhow::Result<SessionLease> {
    Err(std::io::Error::from(std::io::ErrorKind::WouldBlock))
        .with_context(|| format!("workspace session coordinator is busy: {}", path.display()))
}

pub(super) struct SessionCoordinatorWaiter {
    #[cfg(unix)]
    signal_reader: File,
    #[cfg(unix)]
    _signal_anchor: File,
    #[cfg(not(unix))]
    socket: std::net::UdpSocket,
    registration_path: PathBuf,
    #[cfg(not(unix))]
    token: String,
}

impl SessionCoordinatorWaiter {
    pub(super) fn register(coordinator_path: &Path) -> anyhow::Result<Self> {
        use std::sync::atomic::Ordering;

        let waiter_dir = session_guard_coordinator_waiter_dir(coordinator_path);
        prepare_session_coordinator_waiter_dir(&waiter_dir)?;

        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt;
            use std::os::unix::fs::OpenOptionsExt;

            loop {
                let sequence =
                    SESSION_GUARD_COORDINATOR_WAITER_SEQUENCE.fetch_add(1, Ordering::Relaxed);
                let token = format!("{:x}-{sequence:x}", std::process::id());
                let registration_path =
                    platform::normalize_filesystem_path(waiter_dir.join(format!("{token}.waiter")));
                let temporary_path =
                    platform::normalize_filesystem_path(waiter_dir.join(format!(".{token}.tmp")));
                let fifo_path = std::ffi::CString::new(temporary_path.as_os_str().as_bytes())?;
                // SAFETY: fifo_path is a valid NUL-terminated path and mode
                // only grants access to the current user.
                let created = unsafe { libc::mkfifo(fifo_path.as_ptr(), 0o600) };
                if created != 0 {
                    let error = std::io::Error::last_os_error();
                    if error.kind() == std::io::ErrorKind::AlreadyExists {
                        continue;
                    }
                    return Err(error.into());
                }

                let mut reader_options = OpenOptions::new();
                reader_options
                    .read(true)
                    .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK);
                let signal_reader = match reader_options.open(&temporary_path) {
                    Ok(reader) => reader,
                    Err(error) => {
                        let _ = fs::remove_file(&temporary_path);
                        return Err(error.into());
                    }
                };
                let mut anchor_options = OpenOptions::new();
                anchor_options
                    .write(true)
                    .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK);
                let signal_anchor = match anchor_options.open(&temporary_path) {
                    Ok(anchor) => anchor,
                    Err(error) => {
                        let _ = fs::remove_file(&temporary_path);
                        return Err(error.into());
                    }
                };
                if let Err(error) = fs::rename(&temporary_path, &registration_path) {
                    let _ = fs::remove_file(&temporary_path);
                    if error.kind() == std::io::ErrorKind::NotFound {
                        continue;
                    }
                    return Err(error.into());
                }
                return Ok(Self {
                    signal_reader,
                    _signal_anchor: signal_anchor,
                    registration_path,
                });
            }
        }

        #[cfg(not(unix))]
        {
            let socket = std::net::UdpSocket::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
            let address = socket.local_addr()?;

            loop {
                let sequence =
                    SESSION_GUARD_COORDINATOR_WAITER_SEQUENCE.fetch_add(1, Ordering::Relaxed);
                let token = format!("{:x}-{:x}-{:x}", std::process::id(), address.port(), sequence);
                let registration_path =
                    platform::normalize_filesystem_path(waiter_dir.join(format!("{token}.waiter")));
                let temporary_path =
                    platform::normalize_filesystem_path(waiter_dir.join(format!(".{token}.tmp")));
                let mut options = OpenOptions::new();
                options.create_new(true).write(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.mode(0o600).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
                }
                let mut registration = match options.open(&temporary_path) {
                    Ok(registration) => registration,
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(error) => return Err(error.into()),
                };
                if let Err(error) = writeln!(registration, "{address} {token}") {
                    let _ = fs::remove_file(&temporary_path);
                    return Err(error.into());
                }
                if let Err(error) = registration.flush() {
                    let _ = fs::remove_file(&temporary_path);
                    return Err(error.into());
                }
                drop(registration);
                if let Err(error) = fs::rename(&temporary_path, &registration_path) {
                    let _ = fs::remove_file(&temporary_path);
                    if error.kind() == std::io::ErrorKind::NotFound {
                        continue;
                    }
                    return Err(error.into());
                }
                return Ok(Self { socket, registration_path, token });
            }
        }
    }

    pub(super) fn wait_until(&self, deadline: std::time::Instant) -> std::io::Result<bool> {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;

            loop {
                let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                if remaining.is_zero() {
                    return Ok(false);
                }
                let timeout_ms =
                    remaining.as_millis().saturating_add(1).min(i32::MAX as u128) as i32;
                let mut descriptor = libc::pollfd {
                    fd: self.signal_reader.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                };
                // SAFETY: descriptor points to one valid pollfd for the call.
                let ready = unsafe { libc::poll(&raw mut descriptor, 1, timeout_ms) };
                if ready == 0 {
                    return Ok(false);
                }
                if ready < 0 {
                    let error = std::io::Error::last_os_error();
                    if error.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                if descriptor.revents & libc::POLLIN != 0 {
                    let mut signal = [0_u8; 1];
                    let mut signal_reader = &self.signal_reader;
                    match signal_reader.read(&mut signal) {
                        Ok(1) => return Ok(true),
                        Ok(_) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
                        Err(error) => return Err(error),
                    }
                }
                if descriptor.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
                    return Err(std::io::Error::other("session coordinator signal pipe failed"));
                }
            }
        }

        #[cfg(not(unix))]
        {
            let mut message = [0_u8; 128];
            loop {
                let remaining = deadline.saturating_duration_since(std::time::Instant::now());
                if remaining.is_zero() {
                    return Ok(false);
                }
                self.socket.set_read_timeout(Some(remaining))?;
                match self.socket.recv_from(&mut message) {
                    Ok((length, sender))
                        if sender.ip().is_loopback()
                            && message.get(..length) == Some(self.token.as_bytes()) =>
                    {
                        return Ok(true);
                    }
                    Ok(_) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(error)
                        if matches!(
                            error.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) =>
                    {
                        return Ok(false);
                    }
                    Err(error) => return Err(error),
                }
            }
        }
    }
}

impl Drop for SessionCoordinatorWaiter {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.registration_path);
    }
}

pub(super) fn session_guard_coordinator_waiter_dir(coordinator_path: &Path) -> PathBuf {
    platform::normalize_filesystem_path(
        coordinator_path.with_file_name(SESSION_GUARD_COORDINATOR_WAITER_DIR),
    )
}

fn prepare_session_coordinator_waiter_dir(waiter_dir: &Path) -> anyhow::Result<()> {
    match fs::symlink_metadata(waiter_dir) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => anyhow::bail!(
            "session coordinator waiter path is not a directory: {}",
            waiter_dir.display()
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            match fs::create_dir(waiter_dir) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    let metadata = fs::symlink_metadata(waiter_dir)?;
                    if !metadata.file_type().is_dir() {
                        anyhow::bail!(
                            "session coordinator waiter path is not a directory: {}",
                            waiter_dir.display()
                        );
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
        Err(error) => return Err(error.into()),
    }
    platform::restrict_directory(waiter_dir)?;
    Ok(())
}

fn publish_session_coordinator_available(waiter_dir: &Path) {
    let Ok(entries) = fs::read_dir(waiter_dir) else {
        return;
    };
    #[cfg(not(unix))]
    let Ok(socket) = std::net::UdpSocket::bind((std::net::Ipv4Addr::LOCALHOST, 0)) else {
        return;
    };
    for entry in entries.flatten().take(SESSION_GUARD_COORDINATOR_PUBLICATION_SCAN_LIMIT) {
        let path = entry.path();
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            continue;
        };
        match path.extension().and_then(|value| value.to_str()) {
            Some("tmp") => {
                #[cfg(unix)]
                let is_temporary_waiter = {
                    use std::os::unix::fs::FileTypeExt;

                    metadata.file_type().is_file() || metadata.file_type().is_fifo()
                };
                #[cfg(not(unix))]
                let is_temporary_waiter = metadata.file_type().is_file();
                let is_stale = is_temporary_waiter
                    && metadata
                        .modified()
                        .ok()
                        .and_then(|modified| modified.elapsed().ok())
                        .is_some_and(|age| age >= SESSION_GUARD_COORDINATOR_TIMEOUT);
                if is_stale {
                    let _ = fs::remove_file(path);
                }
                continue;
            }
            Some("waiter") => {}
            _ => continue,
        }

        #[cfg(unix)]
        {
            use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};

            if !metadata.file_type().is_fifo() {
                let _ = fs::remove_file(path);
                continue;
            }
            let mut options = OpenOptions::new();
            options.write(true).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK);
            let published =
                options.open(&path).and_then(|mut signal| signal.write_all(&[1])).is_ok();
            let _ = fs::remove_file(path);
            if published {
                break;
            }
            continue;
        }

        #[cfg(not(unix))]
        if !metadata.file_type().is_file() {
            continue;
        }
        #[cfg(not(unix))]
        if let Ok(registration) = fs::read_to_string(&path) {
            let mut fields = registration.split_whitespace();
            let address =
                fields.next().and_then(|value| value.parse::<std::net::SocketAddr>().ok());
            let token = fields.next();
            if fields.next().is_none()
                && let (Some(address), Some(token)) = (address, token)
                && address.ip().is_loopback()
                && token.len() <= 128
                && token.bytes().all(|byte| byte.is_ascii_hexdigit() || byte == b'-')
            {
                if socket.send_to(token.as_bytes(), address).is_ok() {
                    let _ = fs::remove_file(path);
                    break;
                }
            }
        }
        #[cfg(not(unix))]
        let _ = fs::remove_file(path);
    }
}

pub(super) fn open_session_lock_file(path: &Path) -> anyhow::Result<File> {
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    }
    let file = options.open(path)?;
    validate_session_lock_file(path, &file)?;
    Ok(file)
}

pub(super) fn validate_session_lock_file(path: &Path, file: &File) -> anyhow::Result<()> {
    let path_metadata = fs::symlink_metadata(path)?;
    if !path_metadata.file_type().is_file() {
        anyhow::bail!("session lock path is not a file: {}", path.display());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        let file_metadata = file.metadata()?;
        if path_metadata.dev() != file_metadata.dev() || path_metadata.ino() != file_metadata.ino()
        {
            anyhow::bail!("session lock path changed while opening: {}", path.display());
        }
    }
    // Windows: the held handle and a fresh open of the path must be one file
    // (volume serial number and file id). The guard is opened with
    // FILE_SHARE_DELETE (std's default share mode), so it can be deleted or
    // renamed away while held and another file made at its path.
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        use windows_sys::Win32::Storage::FileSystem::{
            FILE_FLAG_OPEN_REPARSE_POINT, FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ,
            FILE_SHARE_WRITE,
        };

        let fresh = OpenOptions::new()
            .access_mode(FILE_READ_ATTRIBUTES)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)?;
        if windows_file_identity(&fresh)? != windows_file_identity(file)? {
            anyhow::bail!("session lock path changed while opening: {}", path.display());
        }
    }
    Ok(())
}

/// A Windows file's identity: its volume serial number and file id, the
/// 128-bit `FILE_ID_INFO` where the file system has it (ReFS ids do not fit
/// in 64 bits), else the 64-bit index of `BY_HANDLE_FILE_INFORMATION`.
#[cfg(windows)]
fn windows_file_identity(file: &File) -> std::io::Result<(u64, [u8; 16])> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, FILE_ID_INFO, FileIdInfo, GetFileInformationByHandle,
        GetFileInformationByHandleEx,
    };

    let handle = file.as_raw_handle();
    // SAFETY: a zeroed plain-old-data struct the call fills.
    let mut id: FILE_ID_INFO = unsafe { std::mem::zeroed() };
    // SAFETY: `handle` is open for the call; `id` is the size passed.
    let filled = unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileIdInfo,
            std::ptr::from_mut(&mut id).cast(),
            u32::try_from(std::mem::size_of::<FILE_ID_INFO>()).unwrap_or(u32::MAX),
        )
    };
    if filled != 0 {
        return Ok((id.VolumeSerialNumber, id.FileId.Identifier));
    }
    // SAFETY: as above.
    let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: `handle` is open for the call.
    if unsafe { GetFileInformationByHandle(handle, &mut info) } == 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut index = [0_u8; 16];
    let low = (u64::from(info.nFileIndexHigh) << 32) | u64::from(info.nFileIndexLow);
    for (slot, byte) in index.iter_mut().zip(low.to_le_bytes()) {
        *slot = byte;
    }
    Ok((u64::from(info.dwVolumeSerialNumber), index))
}

#[cfg(unix)]
fn restrict_session_lock_file(_path: &Path, file: &File) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    Ok(())
}

#[cfg(not(unix))]
fn restrict_session_lock_file(path: &Path, _file: &File) -> anyhow::Result<()> {
    platform::restrict_file(path)?;
    Ok(())
}

impl Drop for SessionLease {
    fn drop(&mut self) {
        if self.lock.file().unlock().is_ok()
            && let Some(waiter_dir) = &self.coordinator_waiter_dir
        {
            publish_session_coordinator_available(waiter_dir);
        }
        let _ = &self.path;
    }
}
