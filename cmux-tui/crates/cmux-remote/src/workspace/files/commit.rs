//! Publish a prepared write or remove on unix: link, exchange or quarantine the entry, verify it, roll back on a mismatch.

use super::*;

#[cfg(unix)]
pub(super) struct PreparedUnixWrite {
    target: UnixWorkspaceTarget,
    precondition: FilePrecondition,
    staged_mode: u32,
    mode_override: Option<u32>,
    pinned: Option<File>,
}

#[cfg(unix)]
pub(super) fn prepare_unix_write(
    root: UnixWorkspaceRoot,
    path: String,
    precondition: FilePrecondition,
    create_parents: bool,
    mode_override: Option<u32>,
) -> Result<PreparedUnixWrite, RpcError> {
    let target = root.resolve_target(&path, create_parents)?;
    let existing = stat_entry(&target, "stat-before-write")?;
    if existing.as_ref().is_some_and(|entry| !entry.is_regular()) {
        return Err(non_regular_entry_error(&target, existing.as_ref()));
    }
    let mut pinned = None;
    match &precondition {
        FilePrecondition::Any => {}
        FilePrecondition::Missing if existing.is_some() => {
            return Err(RpcError::new("conflict", "file already exists"));
        }
        FilePrecondition::Missing => {}
        FilePrecondition::ContentHash(expected) => {
            if !GUARDED_CONTENT_MUTATIONS_SUPPORTED {
                return Err(RpcError::new(
                    "unsupported-platform",
                    "content-guarded workspace writes require Linux, Android, or Apple atomic file exchange",
                ));
            }
            validate_content_hash(expected)?;
            if existing.is_none() {
                return Err(RpcError::new("conflict", "file does not exist"));
            }
            let mut file = open_regular_entry(&target, "hash-before-write")?;
            let (actual, _) = hash_file_sync(&mut file, target.display(), MAX_HASH_BYTES)?;
            if !actual.eq_ignore_ascii_case(expected) {
                return Err(RpcError::new(
                    "conflict",
                    format!("content hash changed: expected {expected}, found {actual}"),
                ));
            }
            pinned = Some(file);
        }
    }
    Ok(PreparedUnixWrite {
        target,
        precondition,
        staged_mode: mode_override
            .or_else(|| existing.map(|entry| entry.mode & 0o7777))
            .unwrap_or(0o600)
            & 0o7777,
        mode_override: mode_override.map(|mode| mode & 0o7777),
        pinned,
    })
}

#[cfg(unix)]
pub(super) fn commit_unix_write(
    prepared: PreparedUnixWrite,
    bytes: &[u8],
    progress: &mut MutationProgress,
) -> Result<String, RpcError> {
    use std::io::Write as _;

    let PreparedUnixWrite { target, precondition, staged_mode, mode_override, mut pinned } =
        prepared;
    target.verify_parent_identity()?;
    let (temporary_name, mut temporary) = create_temporary(&target, "write")?;
    progress.retain(&target, &temporary_name);
    let temporary_path = temporary_display(&target, &temporary_name);
    let stage_result = (|| {
        temporary
            .write_all(bytes)
            .map_err(|error| io_error("write-temporary", &temporary_path, error))?;
        temporary.flush().map_err(|error| io_error("flush-temporary", &temporary_path, error))?;
        temporary.sync_all().map_err(|error| io_error("sync-temporary", &temporary_path, error))?;
        temporary
            .set_permissions(std::fs::Permissions::from_mode(staged_mode))
            .map_err(|error| io_error("set-permissions", &temporary_path, error))?;
        temporary.sync_all().map_err(|error| io_error("sync-temporary", &temporary_path, error))?;
        let temporary_metadata = temporary
            .metadata()
            .map_err(|error| io_error("stat-temporary", &temporary_path, error))?;
        target.verify_parent_identity()?;
        Ok(temporary_metadata)
    })();
    let mut temporary_metadata = match stage_result {
        Ok(metadata) => metadata,
        Err(error) => {
            return Err(cleanup_unpublished_temporary(&target, &temporary_name, error, progress));
        }
    };
    let content_hash = hash_bytes(bytes);
    match &precondition {
        FilePrecondition::Missing => {
            if let Err(error) = link_name(target.parent_fd(), &temporary_name, target.name()) {
                let error = if error.kind() == std::io::ErrorKind::AlreadyExists {
                    progress.outcome = MutationOutcome::Unchanged;
                    RpcError::new("conflict", "file appeared before commit")
                } else {
                    progress.outcome = MutationOutcome::Unknown;
                    io_error("create", target.display(), error)
                };
                return Err(cleanup_unpublished_temporary(
                    &target,
                    &temporary_name,
                    error,
                    progress,
                ));
            }
            progress.outcome = MutationOutcome::Applied;
            if let Err(error) = unlink_published_name(&target, &temporary_name) {
                return Err(partial_write_with_recovery(
                    &target,
                    &temporary_name,
                    &format!("file was created but temporary link cleanup failed: {error}"),
                ));
            }
            progress.cleaned();
        }
        FilePrecondition::Any => {
            commit_any_write(&target, &temporary_name, progress)?;
        }
        FilePrecondition::ContentHash(expected) => {
            let pinned = match pinned.as_mut() {
                Some(pinned) => pinned,
                None => {
                    let error =
                        RpcError::new("internal", "content-hash write lost its pinned target");
                    return Err(cleanup_unpublished_temporary(
                        &target,
                        &temporary_name,
                        error,
                        progress,
                    ));
                }
            };
            commit_content_hash_write(
                &target,
                &temporary_name,
                ContentHashWrite {
                    staged_file: &mut temporary,
                    staged_metadata: &mut temporary_metadata,
                    pinned_file: pinned,
                    expected_hash: expected,
                    requested_hash: &content_hash,
                    mode_override,
                },
                progress,
            )?;
        }
    }
    sync_committed_parent(&target)?;
    Ok(content_hash)
}

#[cfg(unix)]
fn cleanup_unpublished_temporary(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
    error: RpcError,
    progress: &mut MutationProgress,
) -> RpcError {
    match unlink_unpublished_name(target, temporary_name) {
        Ok(()) => {
            progress.cleaned();
            error
        }
        Err(cleanup) if cleanup.kind() == std::io::ErrorKind::NotFound => {
            progress.cleaned();
            error
        }
        Err(cleanup) => partial_write_with_recovery(
            target,
            temporary_name,
            &format!("{}; temporary cleanup also failed: {}", error.message, cleanup),
        ),
    }
}

#[cfg(unix)]
fn stat_before_publish(target: &UnixWorkspaceTarget) -> Result<Option<RawEntryState>, RpcError> {
    stat_entry(target, "stat-before-replace")
}

#[cfg(unix)]
fn hash_before_publish(
    pinned: &mut File,
    target: &UnixWorkspaceTarget,
) -> Result<(String, std::fs::Metadata), RpcError> {
    hash_file_sync(pinned, target.display(), MAX_HASH_BYTES)
}

#[cfg(unix)]
fn commit_any_write(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
    progress: &mut MutationProgress,
) -> Result<(), RpcError> {
    let existing = match stat_before_publish(target) {
        Ok(existing) => existing,
        Err(error) => {
            return Err(cleanup_unpublished_temporary(target, temporary_name, error, progress));
        }
    };
    if existing.as_ref().is_some_and(|entry| !entry.is_regular()) {
        let error = non_regular_entry_error(target, existing.as_ref());
        return Err(cleanup_unpublished_temporary(target, temporary_name, error, progress));
    }
    if let Err(error) = rename_name(target.parent_fd(), temporary_name, target.name()) {
        progress.outcome = MutationOutcome::Unknown;
        let error = io_error("replace", target.display(), error);
        return Err(cleanup_unpublished_temporary(target, temporary_name, error, progress));
    }
    progress.outcome = MutationOutcome::Applied;
    progress.cleaned();
    Ok(())
}

#[cfg(unix)]
struct ContentHashWrite<'a> {
    staged_file: &'a mut File,
    staged_metadata: &'a mut std::fs::Metadata,
    pinned_file: &'a mut File,
    expected_hash: &'a str,
    requested_hash: &'a str,
    mode_override: Option<u32>,
}

#[cfg(unix)]
fn commit_content_hash_write(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
    mut write: ContentHashWrite<'_>,
    progress: &mut MutationProgress,
) -> Result<(), RpcError> {
    let (actual, pinned_metadata) = match hash_before_publish(write.pinned_file, target) {
        Ok(result) => result,
        Err(error) => {
            return Err(cleanup_unpublished_temporary(target, temporary_name, error, progress));
        }
    };
    if !actual.eq_ignore_ascii_case(write.expected_hash) {
        return Err(cleanup_unpublished_temporary(
            target,
            temporary_name,
            RpcError::new(
                "conflict",
                format!(
                    "content hash changed before commit: expected {}, found {actual}",
                    write.expected_hash
                ),
            ),
            progress,
        ));
    }
    let pinned_identity = RawEntryState::from_metadata(&pinned_metadata);
    let current = match stat_before_publish(target) {
        Ok(current) => current,
        Err(error) => {
            return Err(cleanup_unpublished_temporary(target, temporary_name, error, progress));
        }
    };
    if current.as_ref().is_none_or(|entry| !entry.matches_snapshot(&pinned_identity)) {
        return Err(cleanup_unpublished_temporary(
            target,
            temporary_name,
            RpcError::new("conflict", "file identity changed before commit"),
            progress,
        ));
    }
    let temporary_path = temporary_display(target, temporary_name);
    let final_mode = write.mode_override.unwrap_or(pinned_identity.mode & 0o7777);
    let refreshed_temporary = (|| {
        write
            .staged_file
            .set_permissions(std::fs::Permissions::from_mode(final_mode))
            .map_err(|error| io_error("set-permissions", &temporary_path, error))?;
        write
            .staged_file
            .sync_all()
            .map_err(|error| io_error("sync-temporary", &temporary_path, error))?;
        write
            .staged_file
            .metadata()
            .map_err(|error| io_error("stat-temporary", &temporary_path, error))
    })();
    *write.staged_metadata = match refreshed_temporary {
        Ok(metadata) => metadata,
        Err(error) => {
            return Err(cleanup_unpublished_temporary(target, temporary_name, error, progress));
        }
    };
    if let Err(error) = exchange_guarded_write(target, temporary_name) {
        let unsupported = error.kind() == std::io::ErrorKind::Unsupported
            || matches!(
                error.raw_os_error(),
                Some(code) if code == libc::ENOTSUP || code == libc::EINVAL
            );
        progress.outcome =
            if unsupported { MutationOutcome::Unchanged } else { MutationOutcome::Unknown };
        let error = if error.kind() == std::io::ErrorKind::NotFound {
            RpcError::new("conflict", "file disappeared before commit")
        } else {
            exchange_error(target.display(), error)
        };
        return Err(cleanup_unpublished_temporary(target, temporary_name, error, progress));
    }
    progress.outcome = MutationOutcome::Applied;
    let published = match stat_entry(target, "stat-published") {
        Ok(Some(published)) => published,
        Ok(None) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(
                target,
                temporary_name,
                "published entry disappeared",
            ));
        }
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(target, temporary_name, &error.message));
        }
    };
    let recovery = match stat_named(
        target.parent_fd(),
        temporary_name,
        &temporary_display(target, temporary_name),
        "stat-recovery",
    ) {
        Ok(Some(recovery)) => recovery,
        Ok(None) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(
                target,
                temporary_name,
                "recovery entry disappeared",
            ));
        }
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(target, temporary_name, &error.message));
        }
    };
    if let Err(error) = validate_exchanged_write(
        target,
        temporary_name,
        &mut write,
        &pinned_identity,
        &published,
        &recovery,
    ) {
        rollback_exchange(target, temporary_name, &published, &recovery, progress)?;
        return Err(error);
    }
    // These final identity checks are the commit's linearization point. A
    // non-cooperating process can write after them; that is a later mutation
    // and cannot be excluded without a shared lock or kernel transaction.
    unlink_published_name(target, temporary_name).map_err(|error| {
        partial_write_with_recovery(
            target,
            temporary_name,
            &format!("replacement committed but recovery cleanup failed: {error}"),
        )
    })?;
    progress.cleaned();
    Ok(())
}

#[cfg(unix)]
fn validate_exchanged_write(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
    write: &mut ContentHashWrite<'_>,
    pinned_identity: &RawEntryState,
    published: &RawEntryState,
    recovery: &RawEntryState,
) -> Result<(), RpcError> {
    let staged_identity = RawEntryState::from_metadata(write.staged_metadata);
    if !published.matches_snapshot(&staged_identity) || !recovery.matches_snapshot(pinned_identity)
    {
        return Err(RpcError::new("conflict", "file identity changed during commit"));
    }

    let (published_hash, published_metadata) =
        hash_file_sync(write.staged_file, target.display(), MAX_HASH_BYTES)?;
    if !published_hash.eq_ignore_ascii_case(write.requested_hash) {
        return Err(RpcError::new("conflict", "staged file content changed during commit"));
    }

    let recovery_display = temporary_display(target, temporary_name);
    let (recovery_hash, recovery_metadata) =
        hash_file_sync(write.pinned_file, &recovery_display, MAX_HASH_BYTES)?;
    if !recovery_hash.eq_ignore_ascii_case(write.expected_hash) {
        return Err(RpcError::new("conflict", "file content changed during commit"));
    }

    let published_identity = RawEntryState::from_metadata(&published_metadata);
    let recovery_identity = RawEntryState::from_metadata(&recovery_metadata);
    if !published.matches_snapshot(&published_identity)
        || published.changed != published_identity.changed
        || !recovery.matches_snapshot(&recovery_identity)
        || recovery.changed != recovery_identity.changed
    {
        return Err(RpcError::new(
            "conflict",
            "exchanged file identity changed while content was validated",
        ));
    }
    let current_published = stat_entry(target, "validate-published")?.ok_or_else(|| {
        RpcError::new("conflict", "published entry disappeared during validation")
    })?;
    let current_recovery =
        stat_named(target.parent_fd(), temporary_name, &recovery_display, "validate-recovery")?
            .ok_or_else(|| {
                RpcError::new("conflict", "recovery entry disappeared during validation")
            })?;
    if !current_published.matches_snapshot(&published_identity)
        || current_published.changed != published_identity.changed
        || !current_recovery.matches_snapshot(&recovery_identity)
        || current_recovery.changed != recovery_identity.changed
    {
        return Err(RpcError::new("conflict", "file identity changed during commit validation"));
    }
    Ok(())
}

#[cfg(unix)]
fn rollback_exchange(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
    published: &RawEntryState,
    recovery: &RawEntryState,
    progress: &mut MutationProgress,
) -> Result<(), RpcError> {
    let current_target = match stat_entry(target, "rollback") {
        Ok(current) => current,
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(target, temporary_name, &error.message));
        }
    };
    let current_recovery = match stat_named(
        target.parent_fd(),
        temporary_name,
        &temporary_display(target, temporary_name),
        "rollback",
    ) {
        Ok(current) => current,
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(target, temporary_name, &error.message));
        }
    };
    if current_target.as_ref() != Some(published) || current_recovery.as_ref() != Some(recovery) {
        progress.outcome = MutationOutcome::Unknown;
        return Err(partial_write_with_recovery(
            target,
            temporary_name,
            "replacement validation failed and an exchanged entry changed before restoration",
        ));
    }
    if let Err(error) = exchange_rollback(target, temporary_name) {
        progress.outcome = MutationOutcome::Unknown;
        return Err(partial_write_with_recovery(
            target,
            temporary_name,
            &format!("restoring exchanged entries failed: {error}"),
        ));
    }
    progress.outcome = MutationOutcome::Restored;
    unlink_published_name(target, temporary_name).map_err(|error| {
        partial_write_with_recovery(
            target,
            temporary_name,
            &format!("original restored but staged-entry cleanup failed: {error}"),
        )
    })?;
    progress.cleaned();
    sync_rollback_parent(target)
}

#[cfg(unix)]
pub(super) struct PreparedUnixRemove {
    target: UnixWorkspaceTarget,
    precondition: FilePrecondition,
    pinned: Option<File>,
}

#[cfg(unix)]
pub(super) fn prepare_unix_remove(
    root: UnixWorkspaceRoot,
    path: String,
    precondition: FilePrecondition,
) -> Result<PreparedUnixRemove, RpcError> {
    let target = root.resolve_target(&path, false)?;
    let existing = stat_entry(&target, "remove")?
        .ok_or_else(|| RpcError::new("not-found", format!("file not found: {path}")))?;
    if !existing.is_regular() {
        return Err(non_regular_entry_error(&target, Some(&existing)));
    }
    let mut pinned = None;
    match &precondition {
        FilePrecondition::Any => {}
        FilePrecondition::Missing => {
            return Err(RpcError::new("conflict", "file exists"));
        }
        FilePrecondition::ContentHash(expected) => {
            if !GUARDED_CONTENT_MUTATIONS_SUPPORTED {
                return Err(RpcError::new(
                    "unsupported-platform",
                    "content-guarded workspace removals require Linux, Android, or Apple atomic no-replace rename",
                ));
            }
            validate_content_hash(expected)?;
            let mut file = open_regular_entry(&target, "hash-before-remove")?;
            let (actual, _) = hash_file_sync(&mut file, target.display(), MAX_HASH_BYTES)?;
            if !actual.eq_ignore_ascii_case(expected) {
                return Err(RpcError::new(
                    "conflict",
                    format!("content hash changed: expected {expected}, found {actual}"),
                ));
            }
            pinned = Some(file);
        }
    }
    Ok(PreparedUnixRemove { target, precondition, pinned })
}

#[cfg(unix)]
pub(super) fn commit_unix_remove(
    prepared: PreparedUnixRemove,
    progress: &mut MutationProgress,
) -> Result<(), RpcError> {
    let PreparedUnixRemove { target, precondition, mut pinned } = prepared;
    target.verify_parent_identity()?;
    if matches!(precondition, FilePrecondition::Any) {
        if let Err(error) = unlink_name(target.parent_fd(), target.name()) {
            progress.outcome = MutationOutcome::Unknown;
            return Err(io_error("remove", target.display(), error));
        }
        progress.outcome = MutationOutcome::Applied;
        return sync_committed_parent(&target);
    }
    let FilePrecondition::ContentHash(expected) = &precondition else {
        return Err(RpcError::new("conflict", "file exists"));
    };
    let pinned = pinned
        .as_mut()
        .ok_or_else(|| RpcError::new("internal", "content-hash removal lost its pinned target"))?;
    let (actual, pinned_metadata) = hash_file_sync(pinned, target.display(), MAX_HASH_BYTES)?;
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(RpcError::new(
            "conflict",
            format!("content hash changed before removal: expected {expected}, found {actual}"),
        ));
    }
    let pinned_identity = RawEntryState::from_metadata(&pinned_metadata);
    let current = stat_entry(&target, "stat-before-remove")?;
    if current.as_ref().is_none_or(|entry| !entry.matches_snapshot(&pinned_identity)) {
        return Err(RpcError::new("conflict", "file identity changed before removal"));
    }
    let quarantine = unique_name(".cmux-remove")?;
    progress.retain(&target, &quarantine);
    if let Err(error) = rename_noreplace(target.parent_fd(), target.name(), &quarantine) {
        let unsupported = error.kind() == std::io::ErrorKind::Unsupported
            || matches!(
                error.raw_os_error(),
                Some(code) if code == libc::ENOTSUP || code == libc::EINVAL
            );
        progress.cleaned();
        if unsupported {
            progress.outcome = MutationOutcome::Unchanged;
        } else {
            progress.outcome = MutationOutcome::Unknown;
        }
        return Err(if error.kind() == std::io::ErrorKind::NotFound {
            RpcError::new("conflict", "file disappeared before commit")
        } else {
            rename_noreplace_error(target.display(), error)
        });
    }
    progress.outcome = MutationOutcome::Applied;
    let quarantine_display = temporary_display(&target, &quarantine);
    if let Err(error) =
        validate_quarantined_remove(&target, &quarantine, &quarantine_display, pinned, expected)
    {
        restore_quarantined_remove(&target, &quarantine, pinned, progress)?;
        return Err(error);
    }
    // The final quarantine stat is the removal's validation point. A
    // non-cooperating process can mutate the inode after that check and before
    // unlink; compare-and-unlink is not available through portable Unix APIs.
    unlink_published_name(&target, &quarantine).map_err(|error| {
        partial_write_with_recovery(
            &target,
            &quarantine,
            &format!("file removed but recovery cleanup failed: {error}"),
        )
    })?;
    progress.cleaned();
    sync_committed_parent(&target)
}

#[cfg(unix)]
fn validate_quarantined_remove(
    target: &UnixWorkspaceTarget,
    quarantine: &CStr,
    quarantine_display: &Path,
    pinned: &mut File,
    expected: &str,
) -> Result<(), RpcError> {
    let (actual, pinned_metadata) = hash_file_sync(pinned, quarantine_display, MAX_HASH_BYTES)?;
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(RpcError::new("conflict", "file content changed during removal"));
    }
    let pinned_after_rename = RawEntryState::from_metadata(&pinned_metadata);
    let current =
        stat_named(target.parent_fd(), quarantine, quarantine_display, "validate-remove-recovery")?
            .ok_or_else(|| {
                RpcError::new("conflict", "remove recovery disappeared during validation")
            })?;
    if !current.matches_snapshot(&pinned_after_rename)
        || current.changed != pinned_after_rename.changed
    {
        return Err(RpcError::new(
            "conflict",
            "remove recovery identity changed during validation",
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn restore_quarantined_remove(
    target: &UnixWorkspaceTarget,
    quarantine: &CStr,
    pinned: &File,
    progress: &mut MutationProgress,
) -> Result<(), RpcError> {
    let pinned_identity = match pinned.metadata() {
        Ok(metadata) => RawEntryState::from_metadata(&metadata),
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(
                target,
                quarantine,
                &format!("could not inspect pinned remove recovery before restoration: {error}"),
            ));
        }
    };
    let current_target = match stat_entry(target, "restore-remove") {
        Ok(current) => current,
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(target, quarantine, &error.message));
        }
    };
    let current_recovery = match stat_named(
        target.parent_fd(),
        quarantine,
        &temporary_display(target, quarantine),
        "restore-remove",
    ) {
        Ok(current) => current,
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(partial_write_with_recovery(target, quarantine, &error.message));
        }
    };
    if current_target.is_some()
        || current_recovery.as_ref().is_none_or(|recovery| {
            !recovery.matches_snapshot(&pinned_identity)
                || recovery.changed != pinned_identity.changed
        })
    {
        progress.outcome = MutationOutcome::Unknown;
        return Err(partial_write_with_recovery(
            target,
            quarantine,
            "remove recovery changed before restoration",
        ));
    }
    if let Err(error) = rename_noreplace(target.parent_fd(), quarantine, target.name()) {
        progress.outcome = MutationOutcome::Unknown;
        return Err(partial_write_with_recovery(
            target,
            quarantine,
            &format!("remove restoration failed: {error}"),
        ));
    }
    progress.cleaned();
    let restored = match stat_entry(target, "verify-remove-restoration") {
        Ok(Some(restored)) => restored,
        Ok(None) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(RpcError::new(
                "partial-write",
                "remove restoration completed but the restored entry disappeared",
            ));
        }
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(RpcError::new(
                "partial-write",
                format!(
                    "remove restoration completed but could not be verified: {}",
                    error.message
                ),
            ));
        }
    };
    let pinned_after_restore = match pinned.metadata() {
        Ok(metadata) => RawEntryState::from_metadata(&metadata),
        Err(error) => {
            progress.outcome = MutationOutcome::Unknown;
            return Err(RpcError::new(
                "partial-write",
                format!(
                    "remove restoration completed but pinned identity could not be verified: {error}"
                ),
            ));
        }
    };
    if !restored.matches_snapshot(&pinned_after_restore)
        || restored.changed != pinned_after_restore.changed
    {
        progress.outcome = MutationOutcome::Unknown;
        return Err(RpcError::new(
            "partial-write",
            "remove restoration completed but restored the wrong entry",
        ));
    }
    progress.outcome = MutationOutcome::Restored;
    sync_rollback_parent(target)
}
