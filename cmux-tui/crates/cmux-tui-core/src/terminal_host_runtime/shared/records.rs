//! Terminal-host discovery and exit records (cx-ko2e table B): validation,
//! the liveness probe, loading, stale-record removal, exit sidecars and the
//! exit-persistence diagnostic. The OS edges (owner and mode checks, the
//! canonical endpoint, the lease probe, private opens, the no-replace
//! rename, durable syncs) go through the `sys` seams.

use std::collections::HashSet;
use std::fs;
use std::io as std_io;
use std::io::Write;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use anyhow::Context;

use super::super::sys::{self, HostLivenessLease, LeaseProbe, PrivateOpen};
use super::super::*;
use super::codec::decode_lower_hex_array;
use super::host_shared::HostShared;
use super::host_state::HOST_EXIT_PERSIST_RETRY_MAX;

pub(crate) static RECORD_TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(1);

/// Validate a discovery record without trusting paths or alternate
/// identity spellings supplied by its JSON payload.
pub fn validate_terminal_host_record(
    record_path: &Path,
    record: &TerminalHostRecord,
) -> anyhow::Result<TerminalHostIdentity> {
    if !matches!(record.record_version, 1 | 2 | 3 | HOST_RECORD_VERSION) {
        anyhow::bail!("unsupported terminal-host record version {}", record.record_version);
    }
    let terminal_id = TerminalId::from_hex(&record.terminal_id)
        .ok_or_else(|| anyhow::anyhow!("terminal-host id is not a canonical UUIDv4"))?;
    let incarnation = HostIncarnation::from_hex(&record.incarnation)
        .ok_or_else(|| anyhow::anyhow!("terminal-host incarnation is not a canonical UUIDv4"))?;
    let owner = decode_lower_hex_array::<{ crate::terminal_host::CAPABILITY_TOKEN_LEN }>(
        &record.owner_token,
        "owner token",
    )?;
    if owner.iter().all(|byte| *byte == 0) {
        anyhow::bail!("terminal-host owner token is zero");
    }
    if record.record_version == 1 {
        if record.host_pid != 0
            || !record.host_start_nonce.is_empty()
            || record.supports_set_defaults
            || record.supports_clear_history
            || record.supports_terminate_ack
            || record.supports_input_ack
            || record.supports_terminal_metadata
            || record.supports_clipboard_read
            || record.supports_viewer_size_priority
            || record.supports_pty_custody
        {
            anyhow::bail!("legacy terminal-host record has unexpected liveness fields");
        }
    } else {
        if record.record_version < HOST_RECORD_VERSION && record.supports_terminal_metadata {
            anyhow::bail!(
                "legacy terminal-host record advertises terminal metadata without support"
            );
        }
        if record.record_version < HOST_RECORD_VERSION && record.supports_viewer_size_priority {
            anyhow::bail!("pre-v4 terminal-host record advertises viewer-size priority");
        }
        if record.record_version == 2 && record.supports_terminate_ack {
            anyhow::bail!("version 2 terminal-host record advertises terminate receipts");
        }
        if record.record_version < HOST_RECORD_VERSION && record.supports_input_ack {
            anyhow::bail!("pre-v4 terminal-host record advertises input receipts");
        }
        if record.record_version < HOST_RECORD_VERSION
            && (record.supports_clipboard_read || record.supports_pty_custody)
        {
            anyhow::bail!("pre-v4 terminal-host record advertises clipboard reads or custody");
        }
        let nonce = decode_lower_hex_array::<HOST_START_NONCE_LEN>(
            &record.host_start_nonce,
            "process-start nonce",
        )?;
        if nonce.iter().all(|byte| *byte == 0) {
            anyhow::bail!("terminal-host process-start nonce is zero");
        }
        if record.host_pid == 0 {
            anyhow::bail!("terminal-host PID is zero");
        }
    }
    if record.workspace_key.len() > MAX_STRING || record.workspace_key.contains('\0') {
        anyhow::bail!("terminal-host workspace hint is invalid");
    }

    let parent = record_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("terminal-host record has no parent directory"))?;
    let expected_record = parent.join(format!("{}.json", record.terminal_id));
    if record_path != expected_record {
        anyhow::bail!("terminal-host record filename is not canonical");
    }
    let uid = sys::file_owner(parent)?;
    let expected_endpoint = sys::canonical_endpoint(uid, &record.terminal_id);
    if Path::new(&record.endpoint) != expected_endpoint {
        anyhow::bail!("terminal-host endpoint is not canonical");
    }
    if let Ok(metadata) = fs::symlink_metadata(record_path)
        && !sys::is_private_file(&metadata, uid)
    {
        anyhow::bail!("terminal-host record permissions or ownership are unsafe");
    }
    let _ = (terminal_id, incarnation);
    Ok(TerminalHostIdentity {
        terminal_id: record.terminal_id.clone(),
        incarnation: record.incarnation.clone(),
    })
}

pub(crate) fn liveness_path(record_path: &Path, record: &TerminalHostRecord) -> PathBuf {
    record_path.with_extension(format!("{}-{}.live", record.incarnation, record.host_start_nonce))
}

/// Probe the process-lifetime nonce lock. `Dead` is positive evidence
/// tied to this exact incarnation even if `host_pid` has since been
/// assigned to another process.
pub fn terminal_host_record_liveness(
    record_path: &Path,
    record: &TerminalHostRecord,
) -> anyhow::Result<TerminalHostLiveness> {
    validate_terminal_host_record(record_path, record)?;
    if record.record_version == 1 {
        // v1 predates process-bound liveness proof. Preserve and adopt a
        // reachable legacy host, but never infer death from PID/socket
        // observations that are vulnerable to reuse and startup races.
        // A normal legacy Exit remains authoritative and removes its own
        // record; an unclean v1 crash intentionally requires manual or
        // version-aware migration rather than unsafe reaping.
        return Ok(if !record_path.exists() && !Path::new(&record.endpoint).exists() {
            TerminalHostLiveness::Dead
        } else {
            TerminalHostLiveness::Indeterminate
        });
    }
    let path = liveness_path(record_path, record);
    let file = match sys::open_private(&path, PrivateOpen::ExistingNoFollow) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let host_cleanup_complete =
                !record_path.exists() && !Path::new(&record.endpoint).exists() && !path.exists();
            return Ok(if host_cleanup_complete || sys::process_definitely_gone(record.host_pid) {
                TerminalHostLiveness::Dead
            } else {
                TerminalHostLiveness::Indeterminate
            });
        }
        Err(_) => return Ok(TerminalHostLiveness::Indeterminate),
    };
    let metadata = file.metadata()?;
    let expected_uid = sys::file_owner(record_path.parent().unwrap())?;
    if !sys::is_private_file(&metadata, expected_uid) || !sys::has_single_link(&metadata) {
        return Ok(TerminalHostLiveness::Indeterminate);
    }
    Ok(match sys::probe_lease(&file) {
        LeaseProbe::Free => TerminalHostLiveness::Dead,
        LeaseProbe::Held => TerminalHostLiveness::Live,
        LeaseProbe::Unknown => TerminalHostLiveness::Indeterminate,
    })
}

/// Remove a discovery record only after the process-lifetime proof says
/// the exact recorded host is dead. A live or ambiguous record is always
/// retained for a later adoption attempt.
pub fn remove_stale_terminal_host_record(
    record_path: &Path,
    expected: &TerminalHostRecord,
) -> anyhow::Result<bool> {
    if terminal_host_record_liveness(record_path, expected)? != TerminalHostLiveness::Dead {
        return Ok(false);
    }
    let current: TerminalHostRecord = serde_json::from_slice(&fs::read(record_path)?)?;
    validate_terminal_host_record(record_path, &current)?;
    if current.terminal_id != expected.terminal_id
        || current.incarnation != expected.incarnation
        || current.host_start_nonce != expected.host_start_nonce
    {
        return Ok(false);
    }
    let proof = liveness_path(record_path, &current);
    let endpoint = PathBuf::from(&current.endpoint);
    fs::remove_file(record_path)?;
    let _ = fs::remove_file(proof);
    sys::remove_terminal_loss_signals(record_path);
    sys::remove_released_pty_lock(record_path, &current.terminal_id, &current.incarnation);
    if fs::symlink_metadata(&endpoint).is_ok_and(|metadata| sys::is_endpoint_file(&metadata)) {
        let _ = fs::remove_file(endpoint);
    }
    Ok(true)
}

pub fn load_terminal_host_records(
    root: &Path,
) -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
    load_terminal_host_records_with_policy(root, false)
}

pub(crate) fn load_terminal_host_records_for_reset(
    root: &Path,
) -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
    load_terminal_host_records_with_policy(root, true)
}

pub(crate) fn load_terminal_host_records_with_policy(
    root: &Path,
    fail_closed: bool,
) -> anyhow::Result<Vec<(PathBuf, TerminalHostRecord)>> {
    let mut records = Vec::new();
    let mut identities = HashSet::new();
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(records),
        Err(error) => return Err(error.into()),
    };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(_) if !fail_closed => continue,
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("read terminal-host record {}", path.display()));
            }
        };
        let record = match serde_json::from_slice::<TerminalHostRecord>(&bytes) {
            Ok(record) => record,
            Err(_) if !fail_closed => continue,
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("decode terminal-host record {}", path.display()));
            }
        };
        if let Err(error) = validate_terminal_host_record(&path, &record) {
            if fail_closed {
                return Err(error)
                    .with_context(|| format!("validate terminal-host record {}", path.display()));
            }
            continue;
        }
        if !identities.insert((record.terminal_id.clone(), record.incarnation.clone())) {
            if fail_closed {
                anyhow::bail!("duplicate terminal-host identity in {}", path.display());
            }
            continue;
        }
        records.push((path, record));
    }
    // Reset uses records only for marker membership and liveness checks, so
    // keep its fail-closed scan linear.
    if !fail_closed {
        records.sort_by(|left, right| left.0.cmp(&right.0));
    }
    Ok(records)
}

pub fn validate_terminal_host_exit_record(
    record_path: &Path,
    record: &TerminalHostExitRecord,
) -> anyhow::Result<()> {
    if record.record_version != HOST_EXIT_RECORD_VERSION {
        anyhow::bail!("unsupported terminal-host exit record version {}", record.record_version);
    }
    TerminalId::from_hex(&record.terminal_id)
        .ok_or_else(|| anyhow::anyhow!("terminal-host exit id is not a canonical UUIDv4"))?;
    HostIncarnation::from_hex(&record.incarnation).ok_or_else(|| {
        anyhow::anyhow!("terminal-host exit incarnation is not a canonical UUIDv4")
    })?;
    anyhow::ensure!(record.exit.is_valid(), "terminal-host exit outcome is invalid");
    let parent = record_path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("terminal-host exit record has no parent directory"))?;
    if record_path != parent.join(format!("{}.exit", record.terminal_id)) {
        anyhow::bail!("terminal-host exit record filename is not canonical");
    }
    let metadata = fs::symlink_metadata(record_path)?;
    let expected_uid = sys::file_owner(parent)?;
    if !sys::is_private_file(&metadata, expected_uid) || !sys::has_single_link(&metadata) {
        anyhow::bail!("terminal-host exit record permissions or ownership are unsafe");
    }
    Ok(())
}

pub fn load_terminal_host_exit_records(
    root: &Path,
) -> anyhow::Result<Vec<(PathBuf, TerminalHostExitRecord)>> {
    let mut records = Vec::new();
    let mut identities = HashSet::new();
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(records),
        Err(error) => return Err(error.into()),
    };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("exit") {
            continue;
        }
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(_) => continue,
        };
        let Ok(record) = serde_json::from_slice::<TerminalHostExitRecord>(&bytes) else {
            continue;
        };
        if validate_terminal_host_exit_record(&path, &record).is_err()
            || !identities.insert((record.terminal_id.clone(), record.incarnation.clone()))
        {
            continue;
        }
        records.push((path, record));
    }
    records.sort_by(|left, right| left.0.cmp(&right.0));
    Ok(records)
}

pub fn terminal_host_exit_record(
    host_record_path: &Path,
) -> anyhow::Result<Option<(PathBuf, TerminalHostExitRecord)>> {
    let path = host_record_path.with_extension("exit");
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let record = serde_json::from_slice::<TerminalHostExitRecord>(&bytes)?;
    validate_terminal_host_exit_record(&path, &record)?;
    Ok(Some((path, record)))
}

/// Acknowledge only the exact sidecar already committed to the registry.
/// A mismatched replacement is retained for reconciliation rather than
/// deleting evidence from another incarnation.
pub fn acknowledge_terminal_host_exit_record(
    record_path: &Path,
    expected: &TerminalHostExitRecord,
) -> anyhow::Result<bool> {
    let bytes = match fs::read(record_path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    let current: TerminalHostExitRecord = serde_json::from_slice(&bytes)?;
    validate_terminal_host_exit_record(record_path, &current)?;
    if &current != expected {
        return Ok(false);
    }
    fs::remove_file(record_path)?;
    // The terminal ended with a recorded exit: its signal breadcrumbs
    // (`<id>.signals`, same stem as `<id>.exit`) are no longer evidence.
    sys::remove_terminal_loss_signals(record_path);
    sys::remove_released_pty_lock(record_path, &current.terminal_id, &current.incarnation);
    if let Some(parent) = record_path.parent() {
        sys::sync_dir(parent)?;
    }
    Ok(true)
}

pub(crate) fn write_record(path: &Path, record: &TerminalHostRecord) -> anyhow::Result<()> {
    write_json_record(path, record)
}

pub(crate) fn write_exit_record(
    path: &Path,
    record: &TerminalHostExitRecord,
) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        sys::prepare_private_dir(parent)?;
    }
    let temporary = path.with_extension(format!(
        "tmp-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let bytes = serde_json::to_vec(record)?;
    let result = (|| -> anyhow::Result<bool> {
        let mut file = sys::open_private(&temporary, PrivateOpen::CreateNewNoFollow)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        match sys::rename_no_replace(&temporary, path) {
            Ok(()) => {
                if let Some(parent) = path.parent() {
                    sys::sync_dir(parent)?;
                }
                Ok(true)
            }
            Err(error) if error.kind() == std_io::ErrorKind::AlreadyExists => Ok(false),
            Err(error) => Err(error.into()),
        }
    })();
    if temporary.exists() {
        let _ = fs::remove_file(&temporary);
    }
    if result? {
        return validate_terminal_host_exit_record(path, record);
    }
    let current: TerminalHostExitRecord = serde_json::from_slice(&fs::read(path)?)?;
    validate_terminal_host_exit_record(path, &current)?;
    anyhow::ensure!(
        current == *record,
        "terminal-host exit sidecar already contains a different outcome"
    );
    Ok(())
}

pub(crate) fn exit_persistence_diagnostic_path(exit_record_path: &Path) -> PathBuf {
    exit_record_path.with_extension("exit-error")
}

pub(crate) fn write_exit_persistence_diagnostic(
    exit_record_path: &Path,
    attempt: u64,
    error: &anyhow::Error,
) -> std_io::Result<()> {
    let path = exit_persistence_diagnostic_path(exit_record_path);
    if let Some(parent) = path.parent() {
        sys::prepare_private_dir(parent).map_err(std_io::Error::other)?;
    }
    let message = format!(
        "terminal-host exit persistence failed on attempt {attempt}; retrying: {error:#}\n"
    );
    let mut file = sys::open_private(&path, PrivateOpen::TruncateNoFollow)?;
    file.write_all(message.as_bytes())?;
    file.sync_all()
}

pub(crate) fn clear_exit_persistence_diagnostic(exit_record_path: &Path) {
    match fs::remove_file(exit_persistence_diagnostic_path(exit_record_path)) {
        Ok(()) => {}
        Err(error) if error.kind() == std_io::ErrorKind::NotFound => {}
        Err(_) => {}
    }
}

pub(crate) fn next_exit_persistence_retry_delay(delay: Duration) -> Duration {
    delay.saturating_mul(2).min(HOST_EXIT_PERSIST_RETRY_MAX)
}

pub(crate) fn write_json_record(path: &Path, record: &impl Serialize) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        sys::prepare_private_dir(parent)?;
    }
    let temporary = path.with_extension(format!(
        "tmp-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let bytes = serde_json::to_vec(record)?;
    let result = (|| -> anyhow::Result<()> {
        let mut file = sys::open_private(&temporary, PrivateOpen::CreateNew)?;
        file.write_all(&bytes)?;
        sys::barrier_sync(&file)?;
        fs::rename(&temporary, path)?;
        if let Some(parent) = path.parent() {
            sys::barrier_sync_dir(parent)?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub(crate) struct HostServiceGuard {
    pub(crate) shared: Arc<HostShared>,
    pub(crate) endpoint: PathBuf,
    pub(crate) record_path: PathBuf,
    pub(crate) record: TerminalHostRecord,
    pub(crate) lease: Option<HostLivenessLease>,
    pub(crate) published: bool,
}

pub(crate) struct UnpublishedHostGuard {
    pub(crate) shared: Arc<HostShared>,
    pub(crate) endpoint: PathBuf,
    pub(crate) armed: bool,
}

impl Drop for UnpublishedHostGuard {
    fn drop(&mut self) {
        if self.armed {
            // An adopted session is not this host's to end: its owner keeps it.
            if self.shared.adopted_session.is_none() {
                self.shared.terminate_and_wait();
            }
            let _ = fs::remove_file(&self.endpoint);
        }
    }
}

impl Drop for HostServiceGuard {
    fn drop(&mut self) {
        // All normal and early-error paths confirm the PTY child exited
        // before removing its discoverability record. If this host is
        // SIGKILLed, Drop cannot run; the locked nonce file remains on
        // disk but unlocks automatically, giving the next mux positive
        // stale-record proof.
        self.shared.terminate_and_wait();
        if !self.shared.child_exited() {
            return;
        }
        let owns_record = !self.published
            || fs::read(&self.record_path)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<TerminalHostRecord>(&bytes).ok())
                .is_some_and(|current| {
                    current.terminal_id == self.record.terminal_id
                        && current.incarnation == self.record.incarnation
                        && current.host_start_nonce == self.record.host_start_nonce
                });
        let released_lease_path = if owns_record {
            self.lease.take().map(|lease| {
                let _ = lease.file.sync_all();
                let path = lease.path.clone();
                // Unlock the process-incarnation proof before removing its
                // discovery record. Observers can never see an absent
                // record whose captured liveness proof still says Live.
                drop(lease);
                path
            })
        } else {
            None
        };
        let removed_record =
            !self.published || (owns_record && fs::remove_file(&self.record_path).is_ok());
        let _ = fs::remove_file(&self.endpoint);
        if removed_record && let Some(path) = released_lease_path {
            let _ = fs::remove_file(path);
        }
    }
}
