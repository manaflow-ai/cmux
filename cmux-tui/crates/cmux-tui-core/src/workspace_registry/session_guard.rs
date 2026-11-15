//! Session guard leases and their short coordinator.
//!
//! A session guard is held for the lifetime of a registry owner. The coordinator
//! serializes guard-file creation and replacement, while leases provide the
//! lock identity checks needed by reset and host adoption.

use super::session_storage_component;
use crate::platform;
use anyhow::Context;
use fs4::FileExt;
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
    let lock_dir = platform::normalize_filesystem_path(root.join(SESSION_GUARD_DIR));
    let lock_path = session_guard_lock_component_path(&lock_dir, component);
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    }
    let file = match options.open(&lock_path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return SessionOwnerProbe::NoGuard;
        }
        Err(_) => return SessionOwnerProbe::Owned,
    };
    let Ok(_coordinator) =
        SessionLease::acquire_coordinator(&session_guard_coordinator_path(&lock_dir))
    else {
        return SessionOwnerProbe::Owned;
    };
    // Locked first, then checked: the path must still name the locked file.
    if FileExt::try_lock(&file).is_err() || validate_session_lock_file(&lock_path, &file).is_err() {
        return SessionOwnerProbe::Owned;
    }
    SessionOwnerProbe::Unowned(SessionLease { file, path: lock_path, coordinator_waiter_dir: None })
}

/// What the last owner run of the session `component` of `root` left in its
/// session directory: the newest modification time and the total size of
/// its top-level files (registry, its WAL, `startup-timings.jsonl`). Every
/// owner start and every adoption commits there, so a change means an owner
/// ran in between; nothing else writes there while its guard is free.
pub(crate) fn session_owner_mark(root: &Path, component: &str) -> String {
    let dir = platform::normalize_filesystem_path(root.join(component));
    let (mut newest, mut size, mut files) = (0_u128, 0_u64, 0_usize);
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let Ok(metadata) = entry.metadata() else { continue };
        if !metadata.is_file() {
            continue;
        }
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
