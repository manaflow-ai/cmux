//! `daemon stop --end-terminals` (W5-R, bench round 4 item 10): after the
//! owner ended every terminal and exited, the stopping client removes the
//! session's terminal and resume state, and only that. The registry, the
//! Chief store, conversations, git checkpoints, diff comments and session
//! settings in the same directory stay.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::Context;
use fs4::FileExt;

use super::{
    PersistentSessionStateResetter, ResetFingerprintBudget, SESSION_GUARD_DIR,
    SESSION_WRITER_LOCK_FILE, SessionLease, acquire_existing_session_reset_guard,
    ensure_checked_reset_deletion_supported, open_session_lock_file,
    prepare_terminal_host_root_for_reset, remove_reset_dir_all, rename_terminal_host_dir_for_reset,
    reset_dir_fingerprint, session_guard_lock_path, validate_session_reset_dir,
    validate_terminal_host_reset_dir, workspace_state_root_exists,
};
use crate::platform;

/// What [`PersistentSessionStateResetter::end_terminal_state`] removed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EndedTerminalState {
    /// The launch snapshot (`launch-snapshot.json`) was removed.
    pub removed_launch_snapshot: bool,
    /// The terminal-host records directory was removed.
    pub removed_terminal_hosts: bool,
}

impl PersistentSessionStateResetter {
    /// Removes the terminal and resume state of `session_name` once its
    /// owner ended every terminal and exits: the launch snapshot (the last
    /// layout a frontend draws before it connects) and the terminal-host
    /// records. Every other store in the session directory stays.
    ///
    /// Waits until `deadline` for the stopping owner to release the
    /// session's locks. The wait is a blocking lock call that the kernel
    /// wakes when the owner releases them or exits; it never polls. A
    /// session whose owner still runs at `deadline` fails with "workspace
    /// session is already owned by another daemon", and nothing is removed.
    pub fn end_terminal_state(
        &self,
        session_name: &str,
        deadline: Instant,
    ) -> anyhow::Result<EndedTerminalState> {
        let root = self.state_root();
        let mut ended = EndedTerminalState::default();
        if !workspace_state_root_exists(root)? {
            return Ok(ended);
        }
        let session_dir = self.session_dir(session_name);
        let terminal_host_root =
            crate::terminal_host_runtime::terminal_host_root(root, session_name);
        let session_dir_exists = validate_session_reset_dir(&session_dir)?;
        if !session_dir_exists && !validate_terminal_host_reset_dir(&terminal_host_root)? {
            return Ok(ended);
        }
        wait_for_session_release(root, session_name, &session_dir, session_dir_exists, deadline)?;
        let _session_guard = acquire_existing_session_reset_guard(root, session_name)?;
        let lease = if validate_session_reset_dir(&session_dir)? {
            let lock_path =
                platform::normalize_filesystem_path(session_dir.join(SESSION_WRITER_LOCK_FILE));
            Some(SessionLease::acquire(&lock_path)?)
        } else {
            None
        };
        if lease.is_some() {
            let snapshot = session_dir.join(crate::server::LAUNCH_SNAPSHOT_FILE);
            match fs::remove_file(&snapshot) {
                Ok(()) => {
                    ended.removed_launch_snapshot = true;
                    platform::sync_directory(&session_dir).with_context(|| {
                        format!("sync workspace session state {}", session_dir.display())
                    })?;
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => {
                    return Err(error)
                        .with_context(|| format!("remove launch snapshot {}", snapshot.display()));
                }
            }
        }
        if validate_terminal_host_reset_dir(&terminal_host_root)? {
            ensure_checked_reset_deletion_supported(root)?;
            let _reset_lock = crate::terminal_host_runtime::acquire_terminal_host_reset_lock(
                &terminal_host_root,
            )?;
            let _live_marker_leases = prepare_terminal_host_root_for_reset(&terminal_host_root)?;
            let fingerprint = reset_dir_fingerprint(
                "terminal-hosts",
                &terminal_host_root,
                &mut ResetFingerprintBudget::default(),
            )?;
            let staged = rename_terminal_host_dir_for_reset(
                root,
                session_name,
                &terminal_host_root,
                &fingerprint,
            )?;
            remove_reset_dir_all(&staged, "terminal host state", "terminal-hosts", &fingerprint)?;
            ended.removed_terminal_hosts = true;
            platform::sync_directory(root)
                .with_context(|| format!("sync workspace state root {}", root.display()))?;
        }
        Ok(ended)
    }
}

/// Blocks until no process holds the session's writer lease or session
/// guard, or fails at `deadline`. Each lock is taken with a blocking call
/// and released at once; the kernel wakes the call when the owner drops the
/// lock or exits. On timeout the helper thread stays blocked until the
/// owner releases, then drops the lock it got; it holds nothing else.
fn wait_for_session_release(
    root: &Path,
    session_name: &str,
    session_dir: &Path,
    session_dir_exists: bool,
    deadline: Instant,
) -> anyhow::Result<()> {
    let mut locks: Vec<PathBuf> = Vec::new();
    if session_dir_exists {
        locks.push(platform::normalize_filesystem_path(session_dir.join(SESSION_WRITER_LOCK_FILE)));
    }
    let guard_dir = platform::normalize_filesystem_path(root.join(SESSION_GUARD_DIR));
    if fs::symlink_metadata(&guard_dir).is_ok_and(|metadata| metadata.file_type().is_dir()) {
        locks.push(session_guard_lock_path(&guard_dir, session_name));
    }
    let (released, waited) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("session-release-wait".into())
        .spawn(move || {
            let result = locks.iter().try_for_each(|path| -> anyhow::Result<()> {
                let file = open_session_lock_file(path)?;
                FileExt::lock(&file)
                    .with_context(|| format!("wait for workspace session {}", path.display()))?;
                FileExt::unlock(&file)
                    .with_context(|| format!("release workspace session {}", path.display()))
            });
            // The stop may have given up waiting; nobody reads then.
            let _ = released.send(result);
        })
        .context("start the session release wait")?;
    match waited.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
        Ok(result) => result,
        Err(_) => anyhow::bail!(
            "workspace session is already owned by another daemon: {}",
            session_dir.display()
        ),
    }
}
