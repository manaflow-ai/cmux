//! The daemon's lifecycle records in its state directory (`runtime.json`, `shutdown.json`,
//! `lifecycle-fence.json`): their durable writes and reads, the check of a predecessor's outcome
//! at startup, and the operator recovery paths that acknowledge a failed or legacy shutdown.

use super::*;

#[cfg(test)]
static STATE_DIRECTORY_SYNC_FAILURES: std::sync::Mutex<Vec<(PathBuf, usize)>> =
    std::sync::Mutex::new(Vec::new());

#[cfg(test)]
pub(super) fn fail_state_directory_sync_after(state_dir: &Path, successful_syncs: usize) {
    STATE_DIRECTORY_SYNC_FAILURES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .push((state_dir.to_path_buf(), successful_syncs));
}

#[cfg(unix)]
pub(super) async fn recover_inactive_predecessor_state(
    state_dir: &Path,
    link_socket: &Path,
    admin_socket: &Path,
) -> anyhow::Result<()> {
    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    let initial_runtime = read_optional_file(&runtime_path)
        .context(catalog().remote.snapshot_runtime_for_recovery)?;
    let initial_outcome = read_optional_file(&outcome_path)
        .context(catalog().remote.snapshot_finalization_for_recovery)?;
    let Some(runtime) = initial_runtime
        .as_deref()
        .map(serde_json::from_slice::<DaemonRuntimeInfo>)
        .transpose()
        .context(catalog().remote.verify_runtime_for_recovery)?
    else {
        return Ok(());
    };
    let Some(lifecycle_id) = runtime.lifecycle_id.as_deref().filter(|id| !id.is_empty()) else {
        // Legacy and malformed lifecycle metadata must continue through the
        // existing explicit migration/recovery paths.
        return Ok(());
    };
    let outcome = initial_outcome
        .as_deref()
        .map(decode_shutdown_outcome)
        .transpose()
        .context(catalog().remote.verify_previous_finalization)?;
    let stale = match outcome {
        Some(outcome) if outcome.status == DaemonShutdownStatus::Succeeded => {
            outcome.lifecycle_id != lifecycle_id
        }
        Some(_) => false,
        None => true,
    };
    if !stale {
        return Ok(());
    }

    // The authorization lease is held by the caller. Probe every socket from
    // the recorded lifecycle and the current defaults before treating its
    // evidence as stale; a live predecessor must remain an explicit handoff.
    verify_recovery_sockets_inactive(
        Some(&runtime),
        link_socket,
        admin_socket,
        catalog().remote.failed_finalization_label,
    )
    .await?;

    let runtime_snapshot = read_optional_file(&runtime_path)
        .context(catalog().remote.resnapshot_runtime_for_recovery)?;
    let outcome_snapshot = read_optional_file(&outcome_path)
        .context(catalog().remote.resnapshot_finalization_for_recovery)?;
    if runtime_snapshot != initial_runtime || outcome_snapshot != initial_outcome {
        return Err(anyhow!(catalog().remote.lifecycle_evidence_changed_before_recovery));
    }
    let Some(runtime) = runtime_snapshot
        .as_deref()
        .map(serde_json::from_slice::<DaemonRuntimeInfo>)
        .transpose()
        .context(catalog().remote.verify_runtime_for_recovery)?
    else {
        return Ok(());
    };
    if runtime.lifecycle_id.as_deref() != Some(lifecycle_id) {
        return Err(anyhow!(catalog().remote.lifecycle_evidence_changed_before_recovery));
    }
    verify_recovery_sockets_inactive(
        Some(&runtime),
        link_socket,
        admin_socket,
        catalog().remote.failed_finalization_label,
    )
    .await?;
    remove_shutdown_recovery_evidence(state_dir, runtime_snapshot, outcome_snapshot)
        .context("could not remove stale remote daemon lifecycle evidence")?;
    Ok(())
}

pub(super) fn verify_previous_shutdown_outcome(
    state_dir: &Path,
    lifecycle_fenced: bool,
) -> anyhow::Result<()> {
    let previous_runtime = read_runtime_info(state_dir)
        .context(catalog().remote.verify_previous_lifecycle_metadata)?;
    let outcome =
        read_shutdown_outcome(state_dir).context(catalog().remote.verify_previous_finalization)?;

    if let Some(previous_runtime) = &previous_runtime {
        match previous_runtime.lifecycle_id.as_deref() {
            Some(expected_lifecycle_id) if !expected_lifecycle_id.is_empty() => {
                let outcome = outcome
                    .as_ref()
                    .ok_or_else(|| anyhow!(catalog().remote.modern_predecessor_missing_outcome))?;
                if outcome.lifecycle_id != expected_lifecycle_id {
                    return Err(anyhow!(catalog().remote.finalization_wrong_lifecycle));
                }
            }
            Some(_) => {
                return Err(anyhow!(catalog().remote.runtime_empty_lifecycle));
            }
            None => {
                return Err(anyhow!(catalog().remote.state_predates_lifecycle_fence));
            }
        }
    }

    if !lifecycle_fenced && previous_runtime.is_none() {
        // A stale successful outcome is insufficient: an older daemon can run
        // after that lifecycle and remove its own runtime metadata before its
        // final authorization write completes.
        return Err(anyhow!(catalog().remote.state_missing_lifecycle_fence));
    }

    match outcome.map(|outcome| outcome.status) {
        None | Some(DaemonShutdownStatus::Succeeded) => Ok(()),
        Some(DaemonShutdownStatus::Failed) => {
            Err(anyhow!(catalog().remote.previous_finalization_failed_ack))
        }
    }
}

#[derive(Debug)]
pub(super) struct CommittedRuntimeInfoError(IdentityError);

impl fmt::Display for CommittedRuntimeInfoError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "remote runtime metadata was committed but durability confirmation failed: {}",
            self.0
        )
    }
}

impl std::error::Error for CommittedRuntimeInfoError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.0)
    }
}

pub(super) fn persist_runtime_info(
    state_dir: &Path,
    info: &DaemonRuntimeInfo,
) -> anyhow::Result<()> {
    use std::io::Write as _;

    let mut persisted = info.clone();
    persisted.routes.clear();
    for route in &info.routes {
        let route = credential_free_route_hint(route)
            .map_err(|_| anyhow!("remote runtime route metadata is invalid"))?;
        push_unique_route(&mut persisted.routes, route);
    }

    let path = state_dir.join("runtime.json");
    let temporary =
        state_dir.join(format!(".runtime-{}-{}.json", std::process::id(), uuid::Uuid::new_v4()));
    let result: anyhow::Result<()> = (|| {
        let encoded = serde_json::to_vec_pretty(&persisted)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&encoded)?;
        file.sync_all()?;
        fs::rename(&temporary, &path)?;
        if let Err(error) = sync_state_directory(state_dir) {
            return Err(anyhow::Error::new(CommittedRuntimeInfoError(error)));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub(super) fn finalize_daemon_lifecycle(
    state_dir: &Path,
    lifecycle_id: &str,
    status: DaemonShutdownStatus,
) -> Result<(), IdentityError> {
    persist_shutdown_outcome(
        state_dir,
        &DaemonShutdownOutcome {
            version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
            lifecycle_id: lifecycle_id.to_owned(),
            status,
        },
    )?;
    remove_owned_runtime_info(state_dir, lifecycle_id)
}

pub(super) fn persist_shutdown_outcome(
    state_dir: &Path,
    outcome: &DaemonShutdownOutcome,
) -> Result<(), IdentityError> {
    use std::io::Write as _;

    let path = state_dir.join("shutdown.json");
    let temporary =
        state_dir.join(format!(".shutdown-{}-{}.json", std::process::id(), uuid::Uuid::new_v4()));
    let result = (|| {
        let encoded = serde_json::to_vec_pretty(outcome).map_err(IdentityError::Json)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(IdentityError::Io)?;
        file.write_all(&encoded).map_err(IdentityError::Io)?;
        file.sync_all().map_err(IdentityError::Io)?;
        fs::rename(&temporary, &path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub(crate) fn persist_daemon_lifecycle_fence(state_dir: &Path) -> Result<(), IdentityError> {
    use std::io::Write as _;

    if read_daemon_lifecycle_fence(state_dir)? {
        // A prior attempt may have renamed the fence before its directory sync
        // failed, so visibility alone does not confirm durability.
        return sync_state_directory(state_dir);
    }
    let path = state_dir.join("lifecycle-fence.json");
    let temporary = state_dir.join(format!(
        ".lifecycle-fence-{}-{}.json",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let result = (|| {
        let encoded = serde_json::to_vec_pretty(&DaemonLifecycleFence {
            version: DAEMON_LIFECYCLE_FENCE_VERSION,
        })
        .map_err(IdentityError::Json)?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary).map_err(IdentityError::Io)?;
        file.write_all(&encoded).map_err(IdentityError::Io)?;
        file.sync_all().map_err(IdentityError::Io)?;
        fs::rename(&temporary, path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn remove_owned_runtime_info(state_dir: &Path, lifecycle_id: &str) -> Result<(), IdentityError> {
    let path = state_dir.join("runtime.json");
    let current = match fs::read(&path) {
        Ok(current) => current,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(IdentityError::Io(error)),
    };
    let current: DaemonRuntimeInfo =
        serde_json::from_slice(&current).map_err(IdentityError::Json)?;
    if current.lifecycle_id.as_deref() != Some(lifecycle_id) {
        return Err(IdentityError::Invalid(
            "remote runtime lifecycle ownership changed during shutdown".into(),
        ));
    }
    match fs::remove_file(path) {
        Ok(()) => sync_state_directory(state_dir),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(IdentityError::Io(error)),
    }
}

fn sync_state_directory(path: &Path) -> Result<(), IdentityError> {
    #[cfg(unix)]
    {
        #[cfg(test)]
        {
            let mut failures = STATE_DIRECTORY_SYNC_FAILURES
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(index) = failures.iter().position(|(expected, _)| expected == path) {
                if failures[index].1 == 0 {
                    failures.swap_remove(index);
                    return Err(IdentityError::Io(std::io::Error::other(
                        "injected state-directory sync failure",
                    )));
                }
                failures[index].1 -= 1;
            }
        }
        fs::File::open(path).and_then(|directory| directory.sync_all()).map_err(IdentityError::Io)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

pub fn load_runtime_info(
    session: &str,
    state_override: Option<&Path>,
) -> anyhow::Result<DaemonRuntimeInfo> {
    let (state, _, _) = daemon_paths(session, state_override)?;
    let path = state.join("runtime.json");
    serde_json::from_slice(&fs::read(&path).with_context(|| {
        format!("remote daemon is not running for session {session:?} ({})", path.display())
    })?)
    .context("remote daemon runtime metadata is invalid")
}

pub(super) fn read_runtime_info(
    state_dir: &Path,
) -> Result<Option<DaemonRuntimeInfo>, IdentityError> {
    let encoded = match fs::read(state_dir.join("runtime.json")) {
        Ok(encoded) => encoded,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(IdentityError::Io(error)),
    };
    serde_json::from_slice(&encoded).map(Some).map_err(IdentityError::Json)
}

pub(super) fn read_optional_file(path: &Path) -> Result<Option<Vec<u8>>, IdentityError> {
    match fs::read(path) {
        Ok(encoded) => Ok(Some(encoded)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(IdentityError::Io(error)),
    }
}

fn decode_shutdown_outcome(encoded: &[u8]) -> Result<DaemonShutdownOutcome, IdentityError> {
    let outcome: DaemonShutdownOutcome =
        serde_json::from_slice(encoded).map_err(IdentityError::Json)?;
    if outcome.version != DAEMON_SHUTDOWN_OUTCOME_VERSION {
        return Err(IdentityError::Invalid(format!(
            "remote daemon shutdown outcome version {} is unsupported",
            outcome.version
        )));
    }
    if outcome.lifecycle_id.is_empty() {
        return Err(IdentityError::Invalid(
            "remote daemon shutdown outcome has an empty lifecycle id".into(),
        ));
    }
    Ok(outcome)
}

pub(super) fn read_daemon_lifecycle_fence(state_dir: &Path) -> Result<bool, IdentityError> {
    let Some(encoded) = read_optional_file(&state_dir.join("lifecycle-fence.json"))? else {
        return Ok(false);
    };
    let fence: DaemonLifecycleFence =
        serde_json::from_slice(&encoded).map_err(IdentityError::Json)?;
    if fence.version != DAEMON_LIFECYCLE_FENCE_VERSION {
        return Err(IdentityError::Invalid(
            catalog().remote.lifecycle_fence_version_unsupported(fence.version),
        ));
    }
    Ok(true)
}

pub(crate) fn inactive_daemon_needs_legacy_acknowledgement(
    state_dir: &Path,
) -> anyhow::Result<bool> {
    let auth_state_dir = state_dir.join("auth");
    let lifecycle_fenced =
        read_daemon_lifecycle_fence(state_dir).context(catalog().remote.verify_lifecycle_fence)?;
    if !auth_state_dir.try_exists().context(catalog().remote.inspect_authorization_state)? {
        return Ok(lifecycle_fenced);
    }
    let auth_schema = persisted_auth_state_schema(&auth_state_dir)
        .context(catalog().remote.inspect_authorization_schema)?;
    Ok(auth_schema != PersistedAuthStateSchema::Current || !lifecycle_fenced)
}

fn read_shutdown_outcome(state_dir: &Path) -> Result<Option<DaemonShutdownOutcome>, IdentityError> {
    let path = state_dir.join("shutdown.json");
    read_optional_file(&path)?.map(|encoded| decode_shutdown_outcome(&encoded)).transpose()
}

pub(crate) fn load_shutdown_outcome(state_dir: &Path) -> anyhow::Result<DaemonShutdownOutcome> {
    read_shutdown_outcome(state_dir)?
        .ok_or_else(|| {
            anyhow!(
                "remote daemon shutdown outcome is unavailable ({})",
                state_dir.join("shutdown.json").display()
            )
        })
        .context("remote daemon shutdown outcome is invalid")
}

#[cfg(unix)]
pub(crate) async fn complete_verified_daemon_stop(
    state_dir: &Path,
    daemon_name: &str,
) -> anyhow::Result<()> {
    let auth_state_dir = state_dir.join("auth");
    auth_state_dir.try_exists().context(catalog().remote.inspect_stopped_authorization_state)?;

    let auth = AuthDatabase::load_or_migrate_legacy(&auth_state_dir, daemon_name, true)
        .context(catalog().remote.acquire_stopped_authorization_lease)?;
    let cleanup_state_dir = state_dir.to_path_buf();
    auth.shutdown_with_cleanup(move |finalization| {
        if finalization.is_err() {
            return Ok(());
        }
        persist_daemon_lifecycle_fence(&cleanup_state_dir)
    })
    .await
    .context(catalog().remote.finalize_stopped_authorization_migration)
}

#[cfg(unix)]
pub(crate) async fn acknowledge_failed_shutdown_outcome(
    state_dir: &Path,
    daemon_name: &str,
    link_socket: &Path,
    admin_socket: &Path,
) -> anyhow::Result<()> {
    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    let initial_runtime = read_optional_file(&runtime_path)
        .context(catalog().remote.snapshot_runtime_for_recovery)?;
    let initial_outcome = read_optional_file(&outcome_path)
        .context(catalog().remote.snapshot_finalization_for_recovery)?;
    let runtime = validate_failed_shutdown_recovery_evidence(&initial_runtime, &initial_outcome)?;
    verify_recovery_sockets_inactive(
        runtime.as_ref(),
        link_socket,
        admin_socket,
        catalog().remote.failed_finalization_label,
    )
    .await?;

    let auth = AuthDatabase::load_or_migrate_legacy(state_dir.join("auth"), daemon_name, true)
        .context(catalog().remote.acquire_recovery_authorization_lease)?;

    let runtime_snapshot = read_optional_file(&runtime_path)
        .context(catalog().remote.resnapshot_runtime_for_recovery)?;
    let outcome_snapshot = read_optional_file(&outcome_path)
        .context(catalog().remote.resnapshot_finalization_for_recovery)?;
    if runtime_snapshot != initial_runtime || outcome_snapshot != initial_outcome {
        return Err(anyhow!(catalog().remote.lifecycle_evidence_changed_before_recovery));
    }
    let runtime = validate_failed_shutdown_recovery_evidence(&runtime_snapshot, &outcome_snapshot)?;
    verify_recovery_sockets_inactive(
        runtime.as_ref(),
        link_socket,
        admin_socket,
        catalog().remote.failed_finalization_label,
    )
    .await?;

    let cleanup_state_dir = state_dir.to_path_buf();
    auth.shutdown_with_cleanup(move |finalization| {
        if finalization.is_err() {
            return Ok(());
        }
        remove_shutdown_recovery_evidence(&cleanup_state_dir, runtime_snapshot, outcome_snapshot)
    })
    .await
    .context(catalog().remote.complete_authorization_recovery)
}

fn validate_failed_shutdown_recovery_evidence(
    runtime_snapshot: &Option<Vec<u8>>,
    outcome_snapshot: &Option<Vec<u8>>,
) -> anyhow::Result<Option<DaemonRuntimeInfo>> {
    let runtime = runtime_snapshot
        .as_deref()
        .map(serde_json::from_slice::<DaemonRuntimeInfo>)
        .transpose()
        .context(catalog().remote.verify_runtime_for_recovery)?;

    if let Some(runtime) = &runtime {
        match runtime.lifecycle_id.as_deref() {
            Some(lifecycle_id) if !lifecycle_id.is_empty() => {}
            _ => {
                return Err(anyhow!(catalog().remote.refuse_failed_ack_with_legacy_runtime));
            }
        }
    } else {
        let encoded = outcome_snapshot
            .as_deref()
            .ok_or_else(|| anyhow!(catalog().remote.no_failed_finalization_recorded))?;
        if matches!(
            decode_shutdown_outcome(encoded),
            Ok(DaemonShutdownOutcome { status: DaemonShutdownStatus::Succeeded, .. })
        ) {
            return Err(anyhow!(catalog().remote.finalization_succeeded_no_ack));
        }
    }
    Ok(runtime)
}

#[cfg(unix)]
pub(crate) async fn acknowledge_legacy_shutdown_state(
    state_dir: &Path,
    daemon_name: &str,
    link_socket: &Path,
    admin_socket: &Path,
) -> anyhow::Result<()> {
    let auth_state_dir = state_dir.join("auth");
    let auth_state_preexisting =
        auth_state_dir.try_exists().context(catalog().remote.inspect_legacy_authorization_state)?;
    let lifecycle_fenced =
        read_daemon_lifecycle_fence(state_dir).context(catalog().remote.verify_lifecycle_fence)?;
    if !auth_state_preexisting && !lifecycle_fenced {
        return Err(anyhow!(catalog().remote.no_legacy_authorization_state));
    }

    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    let initial_runtime =
        read_optional_file(&runtime_path).context(catalog().remote.snapshot_legacy_runtime)?;
    let initial_outcome =
        read_optional_file(&outcome_path).context(catalog().remote.snapshot_legacy_shutdown)?;
    let runtime = validate_legacy_shutdown_evidence(&initial_runtime, &initial_outcome)?;
    verify_recovery_sockets_inactive(
        runtime.as_ref(),
        link_socket,
        admin_socket,
        catalog().remote.legacy_finalization_label,
    )
    .await?;

    let auth = AuthDatabase::load_or_migrate_legacy(&auth_state_dir, daemon_name, true)
        .context(catalog().remote.acquire_legacy_recovery_authorization_lease)?;
    let runtime_snapshot =
        read_optional_file(&runtime_path).context(catalog().remote.resnapshot_legacy_runtime)?;
    let outcome_snapshot =
        read_optional_file(&outcome_path).context(catalog().remote.resnapshot_legacy_shutdown)?;
    if runtime_snapshot != initial_runtime || outcome_snapshot != initial_outcome {
        return Err(anyhow!(catalog().remote.lifecycle_evidence_changed_before_legacy_recovery));
    }
    let runtime = validate_legacy_shutdown_evidence(&runtime_snapshot, &outcome_snapshot)?;
    verify_recovery_sockets_inactive(
        runtime.as_ref(),
        link_socket,
        admin_socket,
        catalog().remote.legacy_finalization_label,
    )
    .await?;

    let cleanup_state_dir = state_dir.to_path_buf();
    auth.shutdown_with_cleanup(move |finalization| {
        if finalization.is_err() {
            return Ok(());
        }
        finish_legacy_shutdown_recovery(&cleanup_state_dir, runtime_snapshot, outcome_snapshot)
    })
    .await
    .context(catalog().remote.complete_legacy_authorization_recovery)
}

#[cfg(unix)]
async fn verify_recovery_sockets_inactive(
    runtime: Option<&DaemonRuntimeInfo>,
    link_socket: &Path,
    admin_socket: &Path,
    finalization: &str,
) -> anyhow::Result<()> {
    let mut sockets = Vec::with_capacity(4);
    if let Some(runtime) = runtime {
        sockets.push(runtime.link_socket.as_path());
        sockets.push(runtime.admin_socket.as_path());
    }
    for socket in [link_socket, admin_socket] {
        if !sockets.contains(&socket) {
            sockets.push(socket);
        }
    }
    for socket in sockets {
        match bounded_unix_socket_connect(tokio::net::UnixStream::connect(socket)).await {
            Ok(_) => {
                return Err(anyhow!(
                    catalog()
                        .remote
                        .refuse_active_socket(finalization, &socket.display().to_string())
                ));
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

#[cfg(unix)]
pub(super) async fn bounded_unix_socket_connect<F, T>(connect: F) -> std::io::Result<T>
where
    F: Future<Output = std::io::Result<T>>,
{
    tokio::time::timeout(UNIX_SOCKET_PROBE_TIMEOUT, connect).await.map_err(|_| {
        std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "daemon Unix socket probe exceeded its deadline",
        )
    })?
}

fn validate_legacy_shutdown_evidence(
    runtime_snapshot: &Option<Vec<u8>>,
    outcome_snapshot: &Option<Vec<u8>>,
) -> anyhow::Result<Option<DaemonRuntimeInfo>> {
    // Explicit operator acknowledgement is the only recovery path for raw
    // metadata that cannot reveal its recorded sockets. The caller still
    // holds the authorization lease and probes the session's default sockets
    // before removing the unchanged byte snapshot.
    let runtime = runtime_snapshot
        .as_deref()
        .and_then(|encoded| serde_json::from_slice::<DaemonRuntimeInfo>(encoded).ok());
    let runtime_is_malformed = runtime_snapshot.is_some() && runtime.is_none();
    if runtime.as_ref().is_some_and(|runtime| runtime.lifecycle_id.is_some()) {
        return Err(anyhow!(catalog().remote.lifecycle_runtime_requires_failed_ack));
    }
    if !runtime_is_malformed && let Some(encoded) = outcome_snapshot {
        match decode_shutdown_outcome(encoded) {
            Ok(DaemonShutdownOutcome { status: DaemonShutdownStatus::Succeeded, .. }) => {}
            Ok(DaemonShutdownOutcome { status: DaemonShutdownStatus::Failed, .. }) | Err(_) => {
                return Err(anyhow!(catalog().remote.shutdown_evidence_requires_failed_ack));
            }
        }
    }
    Ok(runtime)
}

fn finish_legacy_shutdown_recovery(
    state_dir: &Path,
    expected_runtime: Option<Vec<u8>>,
    expected_outcome: Option<Vec<u8>>,
) -> Result<(), IdentityError> {
    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    if read_optional_file(&runtime_path)? != expected_runtime
        || read_optional_file(&outcome_path)? != expected_outcome
    {
        return Err(IdentityError::Invalid(
            catalog().remote.lifecycle_evidence_changed_during_legacy_recovery.into(),
        ));
    }
    persist_daemon_lifecycle_fence(state_dir)?;
    if expected_runtime.is_some() {
        fs::remove_file(runtime_path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)?;
    }
    Ok(())
}

pub(super) fn remove_shutdown_recovery_evidence(
    state_dir: &Path,
    expected_runtime: Option<Vec<u8>>,
    expected_outcome: Option<Vec<u8>>,
) -> Result<(), IdentityError> {
    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    if read_optional_file(&runtime_path)? != expected_runtime
        || read_optional_file(&outcome_path)? != expected_outcome
    {
        return Err(IdentityError::Invalid(
            catalog().remote.lifecycle_evidence_changed_during_recovery.into(),
        ));
    }

    persist_daemon_lifecycle_fence(state_dir)?;
    if expected_runtime.is_some() {
        fs::remove_file(runtime_path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)?;
    }
    if expected_outcome.is_some() {
        fs::remove_file(outcome_path).map_err(IdentityError::Io)?;
        sync_state_directory(state_dir)?;
    }
    Ok(())
}
