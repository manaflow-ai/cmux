//! Startup self-recovery of a dead predecessor's remote daemon state.
//!
//! A remote daemon refuses to start over lifecycle evidence its predecessor
//! left behind when it was killed or its machine hard-stopped: legacy or
//! fence-less authorization state, a runtime record with no shutdown outcome
//! or with another lifecycle's outcome, or a failed finalization. The
//! operator repair is `cmux remote stop --acknowledge-legacy-finalization` or
//! `--acknowledge-failed-finalization`, sometimes one after the other. A Cloud
//! machine's supervisor has no operator: it restarts the refused daemon
//! forever and the machine stays unreachable.
//!
//! [`recover_inactive_daemon_state`] runs those same acknowledgements, in the
//! order the evidence needs them, before the session owner starts its remote
//! daemon. Each acknowledgement keeps its own safeguards: it probes the
//! recorded and the current link and admin sockets before and after taking
//! the authorization lease, refuses while any socket answers or another
//! process holds the lease, and changes only the byte snapshot it validated.
//! The caller adds one more fence: it is the session's owner, holding the
//! workspace registry's writer lease and the bound session socket, which any
//! live predecessor of the same session would hold.
//!
//! An entry with the wrong file type (a socket where `shutdown.json` belongs,
//! a regular file at `admin.sock`) cannot be read by any acknowledgement.
//! After the same socket probe each such entry moves into
//! `<remote root>/recovery/<session>-<unix ms>/` and the acknowledgements
//! handle what is left: a socket at `shutdown.json` becomes "no outcome". The
//! authorization state stays, so the daemon keeps its identity and paired
//! clients. Only when `auth/` itself is not a directory, or holds a socket,
//! FIFO or device, does the whole session directory move there, and the
//! daemon starts with a new identity.

use super::*;

/// The most acknowledgements one start runs. Observed predecessor states need
/// at most two (legacy, then failed); a third would mean no progress.
const MAX_ACKNOWLEDGEMENTS: usize = 3;

/// The directory beside `sessions/` that keeps quarantined session state.
pub(crate) const REMOTE_STATE_RECOVERY_DIR: &str = "recovery";

/// What a start would refuse over, and the acknowledgement that clears it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PredecessorEvidence {
    /// The daemon's own startup accepts this state.
    Accepted,
    /// `--acknowledge-legacy-finalization` clears it.
    NeedsLegacyAcknowledgement,
    /// `--acknowledge-failed-finalization` clears it.
    NeedsFailedAcknowledgement,
    /// No acknowledgement clears it; the start reports its refusal.
    Unrecoverable,
}

/// Mirrors `run_daemon`'s checks of a predecessor's state: the authorization
/// schema gate, `recover_inactive_predecessor_state` (which already clears a
/// fenced modern runtime whose outcome is missing or stale-successful) and
/// `verify_previous_shutdown_outcome`. A modern runtime record goes to the
/// failed acknowledgement first, because the legacy one refuses it; the
/// legacy one then handles whatever authorization state remains.
pub(crate) fn classify_predecessor_evidence(
    state_dir: &Path,
) -> anyhow::Result<PredecessorEvidence> {
    use PredecessorEvidence::*;

    let fenced =
        read_daemon_lifecycle_fence(state_dir).context(catalog().remote.verify_lifecycle_fence)?;
    let auth_state_dir = state_dir.join("auth");
    let auth_exists =
        auth_state_dir.try_exists().context(catalog().remote.inspect_authorization_state)?;
    let legacy_auth = if auth_exists {
        match persisted_auth_state_schema(&auth_state_dir)
            .context(catalog().remote.inspect_authorization_schema)?
        {
            PersistedAuthStateSchema::Legacy | PersistedAuthStateSchema::Missing => true,
            PersistedAuthStateSchema::Current => false,
            PersistedAuthStateSchema::Unsupported(_) => return Ok(Unrecoverable),
        }
    } else {
        fenced
    };
    // Fresh state (no authorization yet): the start writes the fence itself.
    let fenced = fenced || !auth_exists;

    let Ok(runtime) = read_runtime_info(state_dir) else { return Ok(Unrecoverable) };
    let Ok(outcome) = read_shutdown_outcome(state_dir) else { return Ok(Unrecoverable) };
    let failed = |outcome: &DaemonShutdownOutcome| outcome.status == DaemonShutdownStatus::Failed;
    Ok(match (runtime, outcome) {
        (Some(runtime), outcome) => match runtime.lifecycle_id.as_deref() {
            Some(lifecycle_id) if !lifecycle_id.is_empty() => {
                let accepted = !legacy_auth
                    && match &outcome {
                        // `recover_inactive_predecessor_state` clears these when fenced.
                        None => fenced,
                        Some(outcome) if failed(outcome) => false,
                        Some(outcome) => fenced || outcome.lifecycle_id == lifecycle_id,
                    };
                if accepted { Accepted } else { NeedsFailedAcknowledgement }
            }
            Some(_) => Unrecoverable,
            None => match outcome {
                Some(outcome) if failed(&outcome) => Unrecoverable,
                _ => NeedsLegacyAcknowledgement,
            },
        },
        (None, Some(outcome)) if failed(&outcome) => NeedsFailedAcknowledgement,
        (None, _) if legacy_auth || !fenced => NeedsLegacyAcknowledgement,
        (None, _) => Accepted,
    })
}

/// The entries of `state_dir` whose file type no daemon wrote there, each as
/// `(path, what it should be)`, and whether the authorization state itself is
/// among them.
fn misplaced_entries(state_dir: &Path) -> anyhow::Result<(Vec<(PathBuf, &'static str)>, bool)> {
    use std::os::unix::fs::FileTypeExt as _;

    let file_type = |path: &Path| -> anyhow::Result<Option<fs::FileType>> {
        match fs::symlink_metadata(path) {
            Ok(metadata) => Ok(Some(metadata.file_type())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => {
                Err(error).with_context(|| format!("could not inspect {}", path.display()))
            }
        }
    };
    let mut misplaced = Vec::new();
    for name in ["runtime.json", "shutdown.json", "lifecycle-fence.json"] {
        let path = state_dir.join(name);
        if file_type(&path)?.is_some_and(|kind| !kind.is_file()) {
            misplaced.push((path, "a regular file"));
        }
    }
    for name in ["link.sock", "admin.sock"] {
        let path = state_dir.join(name);
        if file_type(&path)?.is_some_and(|kind| !kind.is_socket()) {
            misplaced.push((path, "a socket"));
        }
    }
    let auth = state_dir.join("auth");
    match file_type(&auth)? {
        None => {}
        Some(kind) if !kind.is_dir() => {
            misplaced.push((auth, "a directory"));
            return Ok((misplaced, true));
        }
        Some(_) => {
            for entry in
                fs::read_dir(&auth).with_context(|| format!("could not list {}", auth.display()))?
            {
                let entry = entry.with_context(|| format!("could not list {}", auth.display()))?;
                let kind = entry
                    .file_type()
                    .with_context(|| format!("could not inspect {}", entry.path().display()))?;
                if kind.is_socket()
                    || kind.is_fifo()
                    || kind.is_char_device()
                    || kind.is_block_device()
                {
                    misplaced.push((entry.path(), "a regular file or directory"));
                    return Ok((misplaced, true));
                }
            }
        }
    }
    Ok((misplaced, false))
}

/// Fails while any recorded or current socket path accepts a connection. A
/// path that exists but is not a socket cannot be listened on, so it is
/// skipped; every other connect error but "refused" and "not found" fails.
async fn verify_sockets_inactive(
    runtime: Option<&DaemonRuntimeInfo>,
    link_socket: &Path,
    admin_socket: &Path,
) -> anyhow::Result<()> {
    use std::os::unix::fs::FileTypeExt as _;

    let mut sockets: Vec<&Path> = Vec::with_capacity(4);
    if let Some(runtime) = runtime {
        sockets.push(&runtime.link_socket);
        sockets.push(&runtime.admin_socket);
    }
    for socket in [link_socket, admin_socket] {
        if !sockets.contains(&socket) {
            sockets.push(socket);
        }
    }
    for socket in sockets {
        if fs::symlink_metadata(socket).is_ok_and(|metadata| !metadata.file_type().is_socket()) {
            continue;
        }
        match bounded_unix_socket_connect(tokio::net::UnixStream::connect(socket)).await {
            Ok(_) => {
                return Err(anyhow!(catalog().remote.refuse_active_socket(
                    catalog().remote.legacy_finalization_label,
                    &socket.display().to_string()
                )));
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                ) => {}
            Err(error) => {
                return Err(error).with_context(|| {
                    catalog().remote.verify_socket_inactive(&socket.display().to_string())
                });
            }
        }
    }
    Ok(())
}

/// A new directory under `<remote root>/recovery/` for this session's state.
fn new_recovery_dir(state_dir: &Path) -> anyhow::Result<PathBuf> {
    let component = state_dir
        .file_name()
        .ok_or_else(|| anyhow!("remote state directory has no name: {}", state_dir.display()))?;
    let sessions = state_dir
        .parent()
        .ok_or_else(|| anyhow!("remote state directory has no parent: {}", state_dir.display()))?;
    let root = sessions.parent().unwrap_or(sessions);
    let recovery_root = root.join(REMOTE_STATE_RECOVERY_DIR);
    ensure_secure_directory(&recovery_root, DirectoryAccess::OwnerControlled).with_context(
        || format!("could not prepare remote state recovery directory {}", recovery_root.display()),
    )?;
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis())
        .unwrap_or(0);
    let base = format!("{}-{millis}", component.to_string_lossy());
    for attempt in 0..100u32 {
        let name = match attempt {
            0 => base.clone(),
            _ => format!("{base}-{attempt}"),
        };
        let candidate = recovery_root.join(name);
        match fs::create_dir(&candidate) {
            Ok(()) => return Ok(candidate),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("could not create recovery directory {}", candidate.display())
                });
            }
        }
    }
    Err(anyhow!("no free remote state recovery directory under {}", recovery_root.display()))
}

/// Moves each misplaced entry into a new recovery directory.
fn quarantine_entries(
    state_dir: &Path,
    entries: &[(PathBuf, &'static str)],
) -> anyhow::Result<PathBuf> {
    let destination = new_recovery_dir(state_dir)?;
    for (path, _) in entries {
        let target = destination.join(path.file_name().unwrap_or_default());
        fs::rename(path, &target).with_context(|| {
            format!("could not move {} aside to {}", path.display(), target.display())
        })?;
    }
    let _ = fs::File::open(state_dir).and_then(|directory| directory.sync_all());
    let _ = fs::File::open(&destination).and_then(|directory| directory.sync_all());
    Ok(destination)
}

/// Moves the whole session state directory aside and returns where it went.
fn quarantine_state_dir(state_dir: &Path) -> anyhow::Result<PathBuf> {
    let destination = new_recovery_dir(state_dir)?;
    // `new_recovery_dir` made an empty directory; the state replaces it.
    fs::remove_dir(&destination)
        .with_context(|| format!("could not prepare {}", destination.display()))?;
    fs::rename(state_dir, &destination).with_context(|| {
        format!("could not move {} aside to {}", state_dir.display(), destination.display())
    })?;
    if let Some(sessions) = state_dir.parent() {
        let _ = fs::File::open(sessions).and_then(|directory| directory.sync_all());
    }
    Ok(destination)
}

/// Clears a dead predecessor's lifecycle evidence for the session's remote
/// daemon, as the operator acknowledgements would, and returns one line per
/// action taken. Only for a caller that owns the session (its registry
/// writer lease and bound session socket). An `Err` means the evidence stays
/// as it was; the daemon's start then reports its own refusal.
pub fn recover_inactive_daemon_state(
    session: &str,
    state_override: Option<&Path>,
    link_override: Option<&Path>,
    admin_override: Option<&Path>,
) -> anyhow::Result<Vec<String>> {
    let (state_dir, default_link, default_admin) = daemon_paths(session, state_override)?;
    let link_socket = link_override.map(Path::to_path_buf).unwrap_or(default_link);
    let admin_socket = admin_override.map(Path::to_path_buf).unwrap_or(default_admin);
    if !state_dir.try_exists().context(catalog().remote.inspect_authorization_state)? {
        return Ok(Vec::new());
    }
    build_remote_runtime("cmux-remote-startup-recovery")?.block_on(recover_state_dir(
        &state_dir,
        session,
        &link_socket,
        &admin_socket,
    ))
}

pub(crate) async fn recover_state_dir(
    state_dir: &Path,
    session: &str,
    link_socket: &Path,
    admin_socket: &Path,
) -> anyhow::Result<Vec<String>> {
    let mut actions = Vec::new();
    let (misplaced, authorization_misplaced) = misplaced_entries(state_dir)?;
    if !misplaced.is_empty() {
        // The runtime record names the predecessor's sockets when it is still
        // readable; the current defaults are probed either way.
        let runtime = fs::symlink_metadata(state_dir.join("runtime.json"))
            .ok()
            .filter(fs::Metadata::is_file)
            .and_then(|_| read_runtime_info(state_dir).ok().flatten());
        verify_sockets_inactive(runtime.as_ref(), link_socket, admin_socket).await?;
        let found = misplaced
            .iter()
            .map(|(path, expected)| format!("{} is not {expected}", path.display()))
            .collect::<Vec<_>>()
            .join("; ");
        if authorization_misplaced {
            let destination = quarantine_state_dir(state_dir)?;
            actions.push(format!(
                "{found}; moved the remote daemon state {} to {} and starting with fresh \
                 state and a new identity",
                state_dir.display(),
                destination.display()
            ));
            return Ok(actions);
        }
        let destination = quarantine_entries(state_dir, &misplaced)?;
        actions.push(format!("{found}; moved them to {}", destination.display()));
    }
    for _ in 0..MAX_ACKNOWLEDGEMENTS {
        match classify_predecessor_evidence(state_dir)? {
            PredecessorEvidence::Accepted | PredecessorEvidence::Unrecoverable => break,
            PredecessorEvidence::NeedsLegacyAcknowledgement => {
                acknowledge_legacy_shutdown_state(state_dir, session, link_socket, admin_socket)
                    .await?;
                actions.push(format!(
                    "acknowledged the inactive predecessor's legacy finalization in {} \
                     (as cmux remote stop --acknowledge-legacy-finalization)",
                    state_dir.display()
                ));
            }
            PredecessorEvidence::NeedsFailedAcknowledgement => {
                acknowledge_failed_shutdown_outcome(state_dir, session, link_socket, admin_socket)
                    .await?;
                actions.push(format!(
                    "acknowledged the inactive predecessor's unfinished finalization in {} \
                     (as cmux remote stop --acknowledge-failed-finalization)",
                    state_dir.display()
                ));
            }
        }
    }
    Ok(actions)
}

#[cfg(test)]
#[path = "startup_recovery_tests.rs"]
mod tests;
