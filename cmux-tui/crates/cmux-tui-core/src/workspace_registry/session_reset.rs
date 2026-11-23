// Persistent workspace-state reset, fingerprint, and checked-delete helpers.
use super::*;

pub(super) fn persistent_session_state_dir(root: &Path, session_name: &str) -> PathBuf {
    platform::normalize_filesystem_path(root.join(session_storage_component(session_name)))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PendingSessionResetKind {
    Session,
    TerminalHosts,
}

pub(super) fn pending_session_reset_kind(rest: &str) -> Option<PendingSessionResetKind> {
    let (kind, reset_id) = if let Some(reset_id) = rest.strip_prefix("session-") {
        (PendingSessionResetKind::Session, reset_id)
    } else {
        let reset_id = rest.strip_prefix("terminal-hosts-")?;
        (PendingSessionResetKind::TerminalHosts, reset_id)
    };
    is_canonical_reset_uuid_v4(reset_id).then_some(kind)
}

pub(super) fn is_canonical_reset_uuid_v4(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes[8] == b'-'
        && bytes[13] == b'-'
        && bytes[18] == b'-'
        && bytes[23] == b'-'
        && bytes[14] == b'4'
        && matches!(bytes[19], b'8' | b'9' | b'a' | b'b')
        && bytes.iter().enumerate().all(|(index, byte)| {
            matches!(index, 8 | 13 | 18 | 23) || matches!(*byte, b'0'..=b'9' | b'a'..=b'f')
        })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct PendingSessionResetDir {
    pub(super) path: PathBuf,
    pub(super) kind: PendingSessionResetKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ResetConfirmationSnapshot {
    pub(super) confirm_reset: String,
    pub(super) session_fingerprint: String,
    pub(super) terminal_host_fingerprint: String,
    pub(super) pending_reset_dir_fingerprints: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ResetDirectoryManifest {
    fingerprint: String,
    entries: HashSet<String>,
}

pub(super) fn pending_session_reset_dirs(
    root: &Path,
    session_name: &str,
) -> anyhow::Result<Vec<PendingSessionResetDir>> {
    if !workspace_state_root_exists(root)? {
        return Ok(Vec::new());
    }

    let root_device = reset_root_device(root)?;
    let storage_component = session_storage_component(session_name);
    let prefix = format!("{RESET_DIR_HEAD}{storage_component}-");
    let mut reset_dirs = Vec::new();
    for entry in fs::read_dir(root)
        .with_context(|| format!("read workspace state root {}", root.display()))?
    {
        let entry = entry?;
        let file_name = entry.file_name();
        let Some(file_name) = file_name.to_str() else {
            continue;
        };
        if !file_name.starts_with(&prefix) || !file_name.ends_with(RESET_DIR_TAIL) {
            continue;
        }
        let rest = &file_name[prefix.len()..file_name.len() - RESET_DIR_TAIL.len()];
        let Some(kind) = pending_session_reset_kind(rest) else {
            continue;
        };
        let path = platform::normalize_filesystem_path(entry.path());
        let metadata = fs::symlink_metadata(&path)
            .with_context(|| format!("inspect private reset path {}", path.display()))?;
        if !metadata.file_type().is_dir() {
            anyhow::bail!("private reset path is not a directory: {}", path.display());
        }
        ensure_reset_device_boundary(&path, root_device, reset_metadata_device(&metadata))?;
        reset_dirs.push(PendingSessionResetDir { path, kind });
    }
    reset_dirs.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(reset_dirs)
}

pub(super) fn workspace_state_root_exists(root: &Path) -> anyhow::Result<bool> {
    let metadata = match fs::symlink_metadata(root) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("inspect workspace state root {}", root.display()));
        }
    };
    if metadata.file_type().is_symlink() {
        anyhow::bail!("workspace state root must not be a symbolic link: {}", root.display());
    }
    if !metadata.file_type().is_dir() {
        anyhow::bail!("workspace state root is not a directory: {}", root.display());
    }
    Ok(true)
}

pub(super) fn validate_session_reset_dir(path: &Path) -> anyhow::Result<bool> {
    validate_reset_child_dir(path, "workspace session state path")
}

pub(super) fn validate_terminal_host_reset_dir(path: &Path) -> anyhow::Result<bool> {
    validate_reset_child_dir(path, "terminal host state path")
}

pub(super) fn validate_reset_child_dir(path: &Path, label: &str) -> anyhow::Result<bool> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => {
            return Err(error).with_context(|| format!("inspect {label} {}", path.display()));
        }
    };
    if !metadata.file_type().is_dir() {
        anyhow::bail!("{label} is not a directory: {}", path.display());
    }
    Ok(true)
}

pub(super) fn rename_session_dir_for_reset(
    root: &Path,
    session_name: &str,
    session_dir: &Path,
    expected_fingerprint: &str,
) -> anyhow::Result<PathBuf> {
    rename_reset_dir_for_deletion(
        root,
        session_name,
        "session",
        "workspace session state",
        session_dir,
        expected_fingerprint,
    )
}

pub(super) fn rename_terminal_host_dir_for_reset(
    root: &Path,
    session_name: &str,
    terminal_host_root: &Path,
    expected_fingerprint: &str,
) -> anyhow::Result<PathBuf> {
    rename_reset_dir_for_deletion(
        root,
        session_name,
        "terminal-hosts",
        "terminal host state",
        terminal_host_root,
        expected_fingerprint,
    )
}

pub(super) fn rename_reset_dir_for_deletion(
    root: &Path,
    session_name: &str,
    kind: &str,
    label: &str,
    source: &Path,
    expected_fingerprint: &str,
) -> anyhow::Result<PathBuf> {
    let storage_component = session_storage_component(session_name);
    for _ in 0..16 {
        let candidate = platform::normalize_filesystem_path(root.join(format!(
            "{RESET_DIR_HEAD}{storage_component}-{kind}-{}{RESET_DIR_TAIL}",
            try_new_uuid_v4()?
        )));
        ensure_reset_dir_fingerprint(source, kind, expected_fingerprint)?;
        match fs::rename(source, &candidate) {
            Ok(()) => {
                if let Err(error) =
                    ensure_reset_dir_fingerprint(&candidate, kind, expected_fingerprint)
                {
                    let _ = fs::rename(&candidate, source);
                    return Err(error);
                }
                sync_private_reset_rename(root, &candidate, label)?;
                return Ok(candidate);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "move {label} {} to private reset path {}",
                        source.display(),
                        candidate.display()
                    )
                });
            }
        }
    }
    anyhow::bail!("could not allocate private reset path for {label} {}", source.display())
}

pub(super) fn sync_private_reset_rename(
    root: &Path,
    candidate: &Path,
    label: &str,
) -> anyhow::Result<()> {
    #[cfg(test)]
    {
        let mut failure_root = RESET_RENAME_SYNC_FAILURE_ROOT.lock().unwrap();
        if failure_root.as_deref() == Some(root) {
            *failure_root = None;
            anyhow::bail!("injected private reset rename sync failure");
        }
    }
    platform::sync_directory(root)
        .with_context(|| format!("sync private reset path for {label} {}", candidate.display()))
}

pub(super) fn ensure_reset_dir_fingerprint(
    path: &Path,
    fingerprint_label: &str,
    expected_fingerprint: &str,
) -> anyhow::Result<()> {
    let mut budget = ResetFingerprintBudget::default();
    let current = reset_dir_fingerprint(fingerprint_label, path, &mut budget)?;
    if current == expected_fingerprint {
        return Ok(());
    }
    anyhow::bail!("reset path changed during reset: {}", path.display());
}

pub(super) fn require_reset_confirmation(
    state_root: &Path,
    session_name: &str,
    session_dir: &Path,
    terminal_host_root: &Path,
    pending_reset_dirs: &[PendingSessionResetDir],
    confirm_reset: Option<&str>,
) -> anyhow::Result<ResetConfirmationSnapshot> {
    let confirmation = reset_confirmation_snapshot(
        state_root,
        session_name,
        session_dir,
        terminal_host_root,
        pending_reset_dirs,
    )?;
    if confirm_reset == Some(confirmation.confirm_reset.as_str()) {
        return Ok(confirmation);
    }
    anyhow::bail!("reset confirmation is required");
}

pub(super) fn reset_confirmation_snapshot(
    state_root: &Path,
    session_name: &str,
    session_dir: &Path,
    terminal_host_root: &Path,
    pending_reset_dirs: &[PendingSessionResetDir],
) -> anyhow::Result<ResetConfirmationSnapshot> {
    let mut hash = Sha256::new();
    let mut budget = ResetFingerprintBudget::default();
    update_reset_confirmation_part(&mut hash, "cmux-session-reset-v1");
    update_reset_confirmation_part(&mut hash, session_name);
    update_reset_confirmation_part(&mut hash, &canonical_reset_path_token(state_root));
    update_reset_confirmation_part(&mut hash, &canonical_reset_path_token(session_dir));
    update_reset_confirmation_part(&mut hash, &canonical_reset_path_token(terminal_host_root));
    let session_fingerprint = session_reset_target_fingerprint(session_dir, &mut budget)?;
    update_reset_confirmation_part(&mut hash, &session_fingerprint);
    let terminal_host_fingerprint =
        reset_dir_fingerprint("terminal-hosts", terminal_host_root, &mut budget)?;
    update_reset_confirmation_part(&mut hash, &terminal_host_fingerprint);
    let mut pending_reset_dir_fingerprints = Vec::with_capacity(pending_reset_dirs.len());
    for reset_dir in pending_reset_dirs {
        update_reset_confirmation_part(&mut hash, &canonical_reset_path_token(&reset_dir.path));
        let fingerprint = reset_dir_fingerprint("pending", &reset_dir.path, &mut budget)?;
        update_reset_confirmation_part(&mut hash, &fingerprint);
        pending_reset_dir_fingerprints.push(fingerprint);
    }
    let digest = hash.finalize();
    Ok(ResetConfirmationSnapshot {
        confirm_reset: digest[..12].iter().map(|byte| format!("{byte:02x}")).collect(),
        session_fingerprint,
        terminal_host_fingerprint,
        pending_reset_dir_fingerprints,
    })
}

pub(super) fn update_reset_confirmation_part(hash: &mut Sha256, value: &str) {
    hash.update(value.len().to_le_bytes());
    hash.update(value.as_bytes());
}

pub(super) fn canonical_reset_path_token(path: &Path) -> String {
    let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    reset_path_token(&path)
}

#[cfg(unix)]
pub(super) fn reset_path_token(path: &Path) -> String {
    use std::os::unix::ffi::OsStrExt;

    format!("unix-hex:{}", hex_bytes(path.as_os_str().as_bytes()))
}

#[cfg(windows)]
pub(super) fn reset_path_token(path: &Path) -> String {
    use std::os::windows::ffi::OsStrExt;

    let mut bytes = Vec::new();
    for unit in path.as_os_str().encode_wide() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    format!("windows-utf16le-hex:{}", hex_bytes(&bytes))
}

#[cfg(all(not(unix), not(windows)))]
pub(super) fn reset_path_token(path: &Path) -> String {
    format!("display:{}", path.display())
}

pub(super) fn hex_bytes(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

pub(super) fn reset_manifest_path_key(relative_path: &Path) -> String {
    reset_path_token(relative_path)
}

pub(super) fn session_reset_target_fingerprint(
    session_dir: &Path,
    budget: &mut ResetFingerprintBudget,
) -> anyhow::Result<String> {
    reset_dir_fingerprint("session", session_dir, budget)
}

pub(super) fn reset_dir_fingerprint(
    label: &str,
    path: &Path,
    budget: &mut ResetFingerprintBudget,
) -> anyhow::Result<String> {
    Ok(reset_dir_manifest(label, path, budget)?.fingerprint)
}

pub(super) fn reset_dir_manifest(
    label: &str,
    path: &Path,
    budget: &mut ResetFingerprintBudget,
) -> anyhow::Result<ResetDirectoryManifest> {
    let mut entries = Vec::new();
    collect_reset_path_fingerprints(
        path,
        Path::new("."),
        reset_ignored_root_child(label),
        reset_stable_root_identity(label),
        None,
        budget,
        &mut entries,
    )?;
    entries.sort();
    let fingerprint = format!("{label}:{}", entries.join(","));
    Ok(ResetDirectoryManifest { fingerprint, entries: entries.into_iter().collect() })
}

pub(super) fn reset_ignored_root_child(label: &str) -> Option<&'static str> {
    match label {
        "session" => Some(SESSION_WRITER_LOCK_FILE),
        "terminal-hosts" => Some(TERMINAL_HOST_PUBLICATION_LOCK_FILE),
        _ => None,
    }
}

pub(super) fn reset_stable_root_identity(label: &str) -> bool {
    matches!(label, "session" | "terminal-hosts")
}

#[derive(Default)]
pub(super) struct ResetFingerprintBudget {
    entries: usize,
    bytes: u64,
    manifest_bytes: usize,
}

impl ResetFingerprintBudget {
    fn add_entry(&mut self, path: &Path) -> anyhow::Result<()> {
        self.entries = self.entries.saturating_add(1);
        if self.entries > MAX_RESET_CONFIRMATION_FINGERPRINT_ENTRIES {
            return Err(reset_confirmation_scan_limit_error("paths", path));
        }
        Ok(())
    }

    fn add_manifest_bytes(&mut self, path: &Path, bytes: usize) -> anyhow::Result<()> {
        self.manifest_bytes = self.manifest_bytes.saturating_add(bytes);
        if self.manifest_bytes > MAX_RESET_CONFIRMATION_FINGERPRINT_MANIFEST_BYTES {
            return Err(reset_confirmation_scan_limit_error("manifest bytes", path));
        }
        Ok(())
    }

    fn check_queued_child(&self, queued_children: usize, path: &Path) -> anyhow::Result<()> {
        if self.entries.saturating_add(queued_children).saturating_add(1)
            > MAX_RESET_CONFIRMATION_FINGERPRINT_ENTRIES
        {
            return Err(reset_confirmation_scan_limit_error("paths", path));
        }
        Ok(())
    }

    fn add_file_bytes(&mut self, path: &Path, bytes: u64) -> anyhow::Result<()> {
        self.bytes = self.bytes.saturating_add(bytes);
        if self.bytes > MAX_RESET_CONFIRMATION_FINGERPRINT_BYTES {
            return Err(reset_confirmation_scan_limit_error("bytes", path));
        }
        Ok(())
    }
}

pub(super) fn reset_confirmation_scan_limit_error(unit: &str, path: &Path) -> anyhow::Error {
    let limit = match unit {
        "paths" => MAX_RESET_CONFIRMATION_FINGERPRINT_ENTRIES.to_string(),
        "bytes" => MAX_RESET_CONFIRMATION_FINGERPRINT_BYTES.to_string(),
        "manifest bytes" => MAX_RESET_CONFIRMATION_FINGERPRINT_MANIFEST_BYTES.to_string(),
        _ => "configured".to_string(),
    };
    anyhow::anyhow!(
        "reset confirmation scan exceeds {limit} {unit}; scoped state is too large to reset safely: {}",
        path.display()
    )
}

pub(super) fn collect_reset_path_fingerprints(
    path: &Path,
    relative_path: &Path,
    ignored_root_child: Option<&str>,
    stable_root_identity: bool,
    root_device: Option<u64>,
    budget: &mut ResetFingerprintBudget,
    entries: &mut Vec<String>,
) -> anyhow::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            push_reset_manifest_entry(
                entries,
                format!("{}=missing", reset_manifest_path_key(relative_path)),
                budget,
                path,
            )?;
            return Ok(());
        }
        Err(error) => {
            return Err(error).with_context(|| format!("inspect reset path {}", path.display()));
        }
    };
    let current_device = reset_metadata_device(&metadata);
    let root_device = root_device.or(current_device);
    ensure_reset_device_boundary(path, root_device, current_device)?;
    budget.add_entry(path)?;
    let entry = format!(
        "{}={}",
        reset_manifest_path_key(relative_path),
        reset_path_fingerprint(
            path,
            &metadata,
            budget,
            stable_root_identity && relative_path == Path::new("."),
        )?
    );
    push_reset_manifest_entry(entries, entry, budget, path)?;
    if !metadata.file_type().is_dir() {
        return Ok(());
    }
    let mut child_paths = Vec::new();
    for entry in
        fs::read_dir(path).with_context(|| format!("read reset path {}", path.display()))?
    {
        let child_path = entry?.path();
        let child_name = child_path.file_name().ok_or_else(|| {
            anyhow::anyhow!("reset path has no file name: {}", child_path.display())
        })?;
        if relative_path == Path::new(".")
            && ignored_root_child.is_some_and(|ignored| child_name == std::ffi::OsStr::new(ignored))
        {
            continue;
        }
        budget.check_queued_child(child_paths.len(), &child_path)?;
        child_paths.push(child_path);
    }
    child_paths.sort();
    for child_path in child_paths {
        let child_name = child_path.file_name().ok_or_else(|| {
            anyhow::anyhow!("reset path has no file name: {}", child_path.display())
        })?;
        collect_reset_path_fingerprints(
            &child_path,
            &relative_path.join(Path::new(child_name)),
            ignored_root_child,
            stable_root_identity,
            root_device,
            budget,
            entries,
        )?;
    }
    Ok(())
}

pub(super) fn push_reset_manifest_entry(
    entries: &mut Vec<String>,
    entry: String,
    budget: &mut ResetFingerprintBudget,
    path: &Path,
) -> anyhow::Result<()> {
    budget.add_manifest_bytes(path, entry.len())?;
    entries.push(entry);
    Ok(())
}

pub(super) fn ensure_reset_device_boundary(
    path: &Path,
    root_device: Option<u64>,
    current_device: Option<u64>,
) -> anyhow::Result<()> {
    if let (Some(root_device), Some(current_device)) = (root_device, current_device)
        && current_device != root_device
    {
        anyhow::bail!("reset path crosses filesystem boundary: {}", path.display());
    }
    Ok(())
}

#[cfg(unix)]
pub(super) fn reset_metadata_device(metadata: &fs::Metadata) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;

    Some(metadata.dev())
}

pub(super) fn reset_root_device(root: &Path) -> anyhow::Result<Option<u64>> {
    let metadata = fs::metadata(root)
        .with_context(|| format!("inspect workspace state root {}", root.display()))?;
    Ok(reset_metadata_device(&metadata))
}

#[cfg(not(unix))]
pub(super) fn reset_metadata_device(_metadata: &fs::Metadata) -> Option<u64> {
    None
}

#[cfg(unix)]
pub(super) fn remove_reset_dir_all(
    path: &Path,
    label: &str,
    fingerprint_label: &str,
    expected_fingerprint: &str,
) -> anyhow::Result<()> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

    let mut budget = ResetFingerprintBudget::default();
    let manifest = reset_dir_manifest(fingerprint_label, path, &mut budget)?;
    if manifest.fingerprint != expected_fingerprint {
        anyhow::bail!("reset path changed during reset: {}", path.display());
    }
    #[cfg(test)]
    {
        let mut injected_file = RESET_DELETE_AFTER_MANIFEST_FILE.lock().unwrap();
        if injected_file.as_ref().is_some_and(|(target, _)| target == path) {
            let (_, file_path) = injected_file.take().unwrap();
            fs::write(&file_path, b"late")
                .with_context(|| format!("write injected reset file {}", file_path.display()))?;
        }
    }
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)
        .with_context(|| format!("open {label} {}", path.display()))?;
    let metadata =
        directory.metadata().with_context(|| format!("inspect {label} {}", path.display()))?;
    if !metadata.file_type().is_dir() {
        anyhow::bail!("{label} is not a directory: {}", path.display());
    }
    let root_device = metadata.dev();
    let root_inode = metadata.ino();
    remove_reset_dir_children_from_handle(
        &directory,
        path,
        Path::new("."),
        label,
        root_device,
        &manifest.entries,
        reset_ignored_root_child(fingerprint_label),
    )?;
    let current = fs::symlink_metadata(path)
        .with_context(|| format!("inspect {label} {}", path.display()))?;
    if !current.file_type().is_dir() || current.dev() != root_device || current.ino() != root_inode
    {
        anyhow::bail!("reset path changed during reset: {}", path.display());
    }
    fs::remove_dir(path).with_context(|| format!("remove {label} {}", path.display()))
}

#[cfg(unix)]
pub(super) fn remove_reset_dir_children_from_handle(
    directory: &File,
    display_path: &Path,
    relative_path: &Path,
    label: &str,
    root_device: u64,
    expected_entries: &HashSet<String>,
    ignored_root_child: Option<&str>,
) -> anyhow::Result<()> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::MetadataExt;

    let mut children = reset_dir_child_names(directory, display_path, label)?;
    children.sort();

    for child_name in children {
        let child_display = display_path.join(&child_name);
        let child_relative = relative_path.join(&child_name);
        let child_stat = match reset_child_stat(directory.as_raw_fd(), &child_name, &child_display)
        {
            Ok(child_stat) => child_stat,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
            {
                continue;
            }
            Err(error) => return Err(error),
        };
        let child_device = reset_stat_device(&child_stat);
        ensure_reset_device_boundary(&child_display, Some(root_device), Some(child_device))?;
        ensure_reset_manifest_entry(
            directory.as_raw_fd(),
            &child_name,
            &child_relative,
            &child_display,
            &child_stat,
            expected_entries,
            ignored_root_child,
        )?;
        #[cfg(test)]
        inject_reset_delete_child_replacement(&child_display)?;
        let staged_child = stage_reset_child_for_deletion(
            directory.as_raw_fd(),
            &child_name,
            &child_display,
            &child_stat,
        )?;
        if let Err(error) = ensure_reset_manifest_entry(
            directory.as_raw_fd(),
            &staged_child.name,
            &child_relative,
            &staged_child.display_path,
            &staged_child.stat,
            expected_entries,
            ignored_root_child,
        ) {
            return Err(restore_changed_reset_child(
                directory.as_raw_fd(),
                &staged_child.name,
                &child_name,
                &staged_child.display_path,
                &child_display,
                error,
            ));
        }
        if reset_stat_is_dir(&staged_child.stat) {
            let child_directory = open_reset_child_dir(
                directory.as_raw_fd(),
                &staged_child.name,
                &staged_child.display_path,
            )?;
            let opened = child_directory.metadata().with_context(|| {
                format!("inspect {label} {}", staged_child.display_path.display())
            })?;
            if !opened.file_type().is_dir()
                || opened.dev() != reset_stat_device(&staged_child.stat)
                || opened.ino() != reset_stat_inode(&staged_child.stat)
            {
                anyhow::bail!(
                    "reset path changed during reset: {}",
                    staged_child.display_path.display()
                );
            }
            remove_reset_dir_children_from_handle(
                &child_directory,
                &staged_child.display_path,
                &child_relative,
                label,
                root_device,
                expected_entries,
                ignored_root_child,
            )?;
            let current = reset_child_stat(
                directory.as_raw_fd(),
                &staged_child.name,
                &staged_child.display_path,
            )?;
            if !reset_stat_is_dir(&current)
                || reset_stat_device(&current) != reset_stat_device(&staged_child.stat)
                || reset_stat_inode(&current) != reset_stat_inode(&staged_child.stat)
            {
                anyhow::bail!(
                    "reset path changed during reset: {}",
                    staged_child.display_path.display()
                );
            }
            reset_unlink_child(
                directory.as_raw_fd(),
                &staged_child.name,
                &staged_child.display_path,
                libc::AT_REMOVEDIR,
            )?;
        } else {
            reset_unlink_child(
                directory.as_raw_fd(),
                &staged_child.name,
                &staged_child.display_path,
                0,
            )?;
        }
    }
    let remaining = reset_dir_child_names(directory, display_path, label)?;
    if !remaining.is_empty() {
        anyhow::bail!("reset path changed during reset: {}", display_path.display());
    }
    Ok(())
}

#[cfg(all(unix, test))]
pub(super) fn inject_reset_delete_child_replacement(path: &Path) -> anyhow::Result<()> {
    let mut replacement = RESET_DELETE_AFTER_CHILD_VERIFY_FILE.lock().unwrap();
    if replacement.as_ref() != Some(&path.to_path_buf()) {
        return Ok(());
    }
    *replacement = None;
    fs::remove_file(path)
        .with_context(|| format!("remove injected reset file {}", path.display()))?;
    fs::write(path, b"replacement")
        .with_context(|| format!("write injected reset file {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
pub(super) fn inject_reset_recreated_session_dir_after_staging(path: &Path) -> anyhow::Result<()> {
    let mut injected = RESET_RECREATE_SESSION_DIR_AFTER_STAGING.lock().unwrap();
    let Some(session_dir) = injected.take() else {
        return Ok(());
    };
    if session_dir != path {
        *injected = Some(session_dir);
        return Ok(());
    }
    fs::create_dir_all(&session_dir)
        .with_context(|| format!("recreate injected session dir {}", session_dir.display()))?;
    fs::write(session_dir.join(SESSION_WRITER_LOCK_FILE), b"recreated")
        .with_context(|| format!("write injected session lock {}", session_dir.display()))?;
    fs::write(session_dir.join("recreated-sidecar"), b"new")
        .with_context(|| format!("write injected session sidecar {}", session_dir.display()))?;
    Ok(())
}

#[cfg(unix)]
pub(super) struct ResetStagedChild {
    name: std::ffi::OsString,
    display_path: PathBuf,
    stat: libc::stat,
}

#[cfg(unix)]
pub(super) fn stage_reset_child_for_deletion(
    parent_fd: std::os::fd::RawFd,
    name: &std::ffi::OsStr,
    display_path: &Path,
    expected: &libc::stat,
) -> anyhow::Result<ResetStagedChild> {
    for _ in 0..16 {
        let private_name =
            std::ffi::OsString::from(format!(".reset-delete-{}.entry", try_new_uuid_v4()?));
        let private_display = display_path.with_file_name(&private_name);
        match reset_rename_child_exclusive(
            parent_fd,
            name,
            &private_name,
            display_path,
            &private_display,
        ) {
            Ok(()) => {
                let stat = reset_child_stat(parent_fd, &private_name, &private_display)?;
                if reset_stat_device(&stat) != reset_stat_device(expected)
                    || reset_stat_inode(&stat) != reset_stat_inode(expected)
                    || reset_stat_kind(&stat) != reset_stat_kind(expected)
                {
                    let error = anyhow::anyhow!(
                        "reset path changed during reset: {}",
                        display_path.display()
                    );
                    return Err(restore_changed_reset_child(
                        parent_fd,
                        &private_name,
                        name,
                        &private_display,
                        display_path,
                        error,
                    ));
                }
                return Ok(ResetStagedChild {
                    name: private_name,
                    display_path: private_display,
                    stat,
                });
            }
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::AlreadyExists) =>
            {
                continue;
            }
            Err(error) => return Err(error),
        }
    }
    anyhow::bail!("could not allocate private reset path for {}", display_path.display())
}

#[cfg(unix)]
pub(super) fn restore_changed_reset_child(
    parent_fd: std::os::fd::RawFd,
    private_name: &std::ffi::OsStr,
    original_name: &std::ffi::OsStr,
    private_display: &Path,
    original_display: &Path,
    verification_error: anyhow::Error,
) -> anyhow::Error {
    match reset_rename_child_exclusive(
        parent_fd,
        private_name,
        original_name,
        private_display,
        original_display,
    ) {
        Ok(()) => verification_error,
        Err(restore_error) => anyhow::anyhow!(
            "{verification_error:#}; failed to restore changed reset path {}: {restore_error:#}",
            original_display.display()
        ),
    }
}

#[cfg(unix)]
pub(super) fn ensure_reset_manifest_entry(
    parent_fd: std::os::fd::RawFd,
    name: &std::ffi::OsStr,
    relative_path: &Path,
    display_path: &Path,
    stat: &libc::stat,
    expected_entries: &HashSet<String>,
    ignored_root_child: Option<&str>,
) -> anyhow::Result<()> {
    if let Some(ignored) = ignored_root_child
        && relative_path == Path::new(".").join(ignored)
    {
        return Ok(());
    }
    let mut budget = ResetFingerprintBudget::default();
    let entry = reset_child_fingerprint_entry(
        parent_fd,
        name,
        relative_path,
        display_path,
        stat,
        &mut budget,
    )?;
    if expected_entries.contains(&entry) {
        return Ok(());
    }
    anyhow::bail!("reset path changed during reset: {}", display_path.display());
}

#[cfg(unix)]
pub(super) fn reset_child_fingerprint_entry(
    parent_fd: std::os::fd::RawFd,
    name: &std::ffi::OsStr,
    relative_path: &Path,
    display_path: &Path,
    stat: &libc::stat,
    budget: &mut ResetFingerprintBudget,
) -> anyhow::Result<String> {
    let mut fingerprint = reset_stat_metadata_fingerprint(stat);
    if reset_stat_is_file(stat) {
        fingerprint.push_str(";sha256=");
        fingerprint.push_str(&reset_child_file_content_sha256(
            parent_fd,
            name,
            display_path,
            stat,
            budget,
        )?);
    }
    Ok(format!("{}={fingerprint}", reset_manifest_path_key(relative_path)))
}

#[cfg(unix)]
pub(super) fn reset_child_file_content_sha256(
    parent_fd: std::os::fd::RawFd,
    name: &std::ffi::OsStr,
    display_path: &Path,
    expected: &libc::stat,
    budget: &mut ResetFingerprintBudget,
) -> anyhow::Result<String> {
    let mut file = open_reset_child_file(parent_fd, name, display_path)?;
    let opened = file
        .metadata()
        .with_context(|| format!("inspect reset file {}", display_path.display()))?;
    if reset_metadata_fingerprint(&opened) != reset_stat_metadata_fingerprint(expected) {
        anyhow::bail!("reset path changed during fingerprint: {}", display_path.display());
    }
    let mut hash = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file.read(&mut buffer).with_context(|| {
            format!("read reset file for fingerprint {}", display_path.display())
        })?;
        if read == 0 {
            break;
        }
        budget.add_file_bytes(display_path, read as u64)?;
        hash.update(&buffer[..read]);
    }
    let current = reset_child_stat(parent_fd, name, display_path)?;
    if reset_stat_metadata_fingerprint(&current) != reset_stat_metadata_fingerprint(expected) {
        anyhow::bail!("reset path changed during fingerprint: {}", display_path.display());
    }
    Ok(hex_sha256(hash.finalize().into()))
}

#[cfg(unix)]
pub(super) struct ResetDirStream(*mut libc::DIR);

#[cfg(unix)]
impl Drop for ResetDirStream {
    fn drop(&mut self) {
        // SAFETY: fdopendir returned this DIR pointer and ownership belongs to this guard.
        unsafe {
            libc::closedir(self.0);
        }
    }
}

#[cfg(unix)]
pub(super) fn reset_dir_child_names(
    directory: &File,
    display_path: &Path,
    label: &str,
) -> anyhow::Result<Vec<std::ffi::OsString>> {
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;

    // SAFETY: dup only duplicates this valid directory file descriptor.
    let duplicate = unsafe { libc::dup(directory.as_raw_fd()) };
    if duplicate < 0 {
        return Err(std::io::Error::last_os_error())
            .with_context(|| format!("read {label} {}", display_path.display()));
    }
    // SAFETY: fdopendir takes ownership of the duplicated descriptor on success.
    let raw_stream = unsafe { libc::fdopendir(duplicate) };
    if raw_stream.is_null() {
        let error = std::io::Error::last_os_error();
        // SAFETY: fdopendir did not take ownership when it failed.
        unsafe {
            libc::close(duplicate);
        }
        return Err(error).with_context(|| format!("read {label} {}", display_path.display()));
    }
    let stream = ResetDirStream(raw_stream);
    // fdopendir takes a duplicated descriptor, but dup shares the directory
    // cursor with the original file description. Rewind every scan so repeated
    // safety passes cannot inherit an end-of-directory cursor.
    // SAFETY: stream owns a valid DIR pointer.
    unsafe {
        libc::rewinddir(stream.0);
    }
    let mut names = Vec::new();
    loop {
        set_reset_readdir_errno(0);
        // SAFETY: stream owns a valid DIR pointer for the duration of this loop.
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            let errno = reset_readdir_errno();
            if errno == 0 {
                break;
            }
            return Err(std::io::Error::from_raw_os_error(errno))
                .with_context(|| format!("read {label} {}", display_path.display()));
        }
        // SAFETY: d_name is a nul-terminated C string for a live dirent.
        let name = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) };
        let name = name.to_bytes();
        if name == b"." || name == b".." {
            continue;
        }
        names.push(std::ffi::OsStr::from_bytes(name).to_os_string());
    }
    Ok(names)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(super) fn set_reset_readdir_errno(value: libc::c_int) {
    // SAFETY: libc returns this thread's writable errno location.
    unsafe { *libc::__errno_location() = value };
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(super) fn reset_readdir_errno() -> libc::c_int {
    // SAFETY: libc returns this thread's readable errno location.
    unsafe { *libc::__errno_location() }
}

#[cfg(any(target_vendor = "apple", target_os = "freebsd", target_os = "dragonfly"))]
pub(super) fn set_reset_readdir_errno(value: libc::c_int) {
    // SAFETY: libc returns this thread's writable errno location.
    unsafe { *libc::__error() = value };
}

#[cfg(any(target_vendor = "apple", target_os = "freebsd", target_os = "dragonfly"))]
pub(super) fn reset_readdir_errno() -> libc::c_int {
    // SAFETY: libc returns this thread's readable errno location.
    unsafe { *libc::__error() }
}

#[cfg(any(target_os = "netbsd", target_os = "openbsd"))]
pub(super) fn set_reset_readdir_errno(value: libc::c_int) {
    // SAFETY: libc returns this thread's writable errno location.
    unsafe { *libc::__errno() = value };
}

#[cfg(any(target_os = "netbsd", target_os = "openbsd"))]
pub(super) fn reset_readdir_errno() -> libc::c_int {
    // SAFETY: libc returns this thread's readable errno location.
    unsafe { *libc::__errno() }
}

#[cfg(any(target_os = "solaris", target_os = "illumos"))]
pub(super) fn set_reset_readdir_errno(value: libc::c_int) {
    // SAFETY: libc returns this thread's writable errno location.
    unsafe { *libc::___errno() = value };
}

#[cfg(any(target_os = "solaris", target_os = "illumos"))]
pub(super) fn reset_readdir_errno() -> libc::c_int {
    // SAFETY: libc returns this thread's readable errno location.
    unsafe { *libc::___errno() }
}

#[cfg(all(
    unix,
    not(any(
        target_os = "linux",
        target_os = "android",
        target_vendor = "apple",
        target_os = "freebsd",
        target_os = "dragonfly",
        target_os = "netbsd",
        target_os = "openbsd",
        target_os = "solaris",
        target_os = "illumos"
    ))
))]
pub(super) fn set_reset_readdir_errno(_value: libc::c_int) {}

#[cfg(all(
    unix,
    not(any(
        target_os = "linux",
        target_os = "android",
        target_vendor = "apple",
        target_os = "freebsd",
        target_os = "dragonfly",
        target_os = "netbsd",
        target_os = "openbsd",
        target_os = "solaris",
        target_os = "illumos"
    ))
))]
pub(super) fn reset_readdir_errno() -> libc::c_int {
    0
}

#[cfg(unix)]
pub(super) fn open_reset_child_file(
    parent_fd: std::os::fd::RawFd,
    name: &std::ffi::OsStr,
    display_path: &Path,
) -> anyhow::Result<File> {
    use std::os::fd::FromRawFd;

    let name = reset_child_c_string(name, display_path)?;
    loop {
        // SAFETY: openat reads a nul-terminated child name relative to a valid parent directory fd.
        let fd = unsafe {
            libc::openat(
                parent_fd,
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
            )
        };
        if fd >= 0 {
            // SAFETY: openat returned a new owned file descriptor.
            return Ok(unsafe { File::from_raw_fd(fd) });
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(error).with_context(|| format!("open reset file {}", display_path.display()));
    }
}

#[cfg(unix)]
pub(super) fn open_reset_child_dir(
    parent_fd: std::os::fd::RawFd,
    name: &std::ffi::OsStr,
    display_path: &Path,
) -> anyhow::Result<File> {
    use std::os::fd::FromRawFd;

    let name = reset_child_c_string(name, display_path)?;
    loop {
        // SAFETY: openat reads a nul-terminated child name relative to a valid parent directory fd.
        let fd = unsafe {
            libc::openat(
                parent_fd,
                name.as_ptr(),
                libc::O_RDONLY | libc::O_CLOEXEC | libc::O_DIRECTORY | libc::O_NOFOLLOW,
            )
        };
        if fd >= 0 {
            // SAFETY: openat returned a new owned file descriptor.
            return Ok(unsafe { File::from_raw_fd(fd) });
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(error).with_context(|| format!("open reset dir {}", display_path.display()));
    }
}

#[cfg(unix)]
pub(super) fn reset_child_stat(
    parent_fd: std::os::fd::RawFd,
    name: &std::ffi::OsStr,
    display_path: &Path,
) -> anyhow::Result<libc::stat> {
    let name = reset_child_c_string(name, display_path)?;
    loop {
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        // SAFETY: fstatat writes to stat and reads a nul-terminated child name relative to parent_fd.
        let result = unsafe {
            libc::fstatat(parent_fd, name.as_ptr(), stat.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW)
        };
        if result == 0 {
            // SAFETY: fstatat initialized stat on success.
            return Ok(unsafe { stat.assume_init() });
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(error)
            .with_context(|| format!("inspect reset path {}", display_path.display()));
    }
}

#[cfg(unix)]
pub(super) fn reset_unlink_child(
    parent_fd: std::os::fd::RawFd,
    name: &std::ffi::OsStr,
    display_path: &Path,
    flags: i32,
) -> anyhow::Result<()> {
    let name = reset_child_c_string(name, display_path)?;
    loop {
        // SAFETY: unlinkat reads a nul-terminated child name relative to a valid parent directory fd.
        let result = unsafe { libc::unlinkat(parent_fd, name.as_ptr(), flags) };
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(error).with_context(|| format!("remove reset path {}", display_path.display()));
    }
}

#[cfg(any(target_os = "ios", target_os = "macos"))]
pub(super) fn reset_rename_child_exclusive(
    parent_fd: std::os::fd::RawFd,
    from: &std::ffi::OsStr,
    to: &std::ffi::OsStr,
    from_display: &Path,
    to_display: &Path,
) -> anyhow::Result<()> {
    let from = reset_child_c_string(from, from_display)?;
    let to = reset_child_c_string(to, to_display)?;
    loop {
        // SAFETY: renameatx_np reads nul-terminated names relative to a valid parent directory fd.
        let result = unsafe {
            libc::renameatx_np(parent_fd, from.as_ptr(), parent_fd, to.as_ptr(), libc::RENAME_EXCL)
        };
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(error).with_context(|| {
            format!(
                "move reset path {} to private path {}",
                from_display.display(),
                to_display.display()
            )
        });
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(super) fn reset_rename_child_exclusive(
    parent_fd: std::os::fd::RawFd,
    from: &std::ffi::OsStr,
    to: &std::ffi::OsStr,
    from_display: &Path,
    to_display: &Path,
) -> anyhow::Result<()> {
    let from = reset_child_c_string(from, from_display)?;
    let to = reset_child_c_string(to, to_display)?;
    loop {
        // SAFETY: renameat2 reads nul-terminated names relative to a valid parent directory fd.
        let result = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                parent_fd,
                from.as_ptr(),
                parent_fd,
                to.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(error).with_context(|| {
            format!(
                "move reset path {} to private path {}",
                from_display.display(),
                to_display.display()
            )
        });
    }
}

#[cfg(all(
    unix,
    not(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))
))]
pub(super) fn reset_rename_child_exclusive(
    _parent_fd: std::os::fd::RawFd,
    _from: &std::ffi::OsStr,
    _to: &std::ffi::OsStr,
    from_display: &Path,
    _to_display: &Path,
) -> anyhow::Result<()> {
    unsupported_checked_reset_deletion(from_display, "saved state")
}

#[cfg(unix)]
pub(super) fn reset_child_c_string(
    name: &std::ffi::OsStr,
    display_path: &Path,
) -> anyhow::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;

    std::ffi::CString::new(name.as_bytes())
        .with_context(|| format!("reset path has an invalid file name: {}", display_path.display()))
}

#[cfg(unix)]
pub(super) fn reset_stat_is_dir(stat: &libc::stat) -> bool {
    stat.st_mode & libc::S_IFMT == libc::S_IFDIR
}

#[cfg(unix)]
pub(super) fn reset_stat_is_file(stat: &libc::stat) -> bool {
    stat.st_mode & libc::S_IFMT == libc::S_IFREG
}

#[cfg(unix)]
pub(super) fn reset_stat_kind(stat: &libc::stat) -> libc::mode_t {
    stat.st_mode & libc::S_IFMT
}

#[cfg(unix)]
pub(super) fn reset_stat_metadata_fingerprint(stat: &libc::stat) -> String {
    let kind = if reset_stat_is_dir(stat) {
        "dir"
    } else if reset_stat_is_file(stat) {
        "file"
    } else if stat.st_mode & libc::S_IFMT == libc::S_IFLNK {
        "symlink"
    } else {
        "other"
    };
    format!(
        "{kind}:dev={},ino={},mode={},len={},mtime={}.{}",
        reset_stat_device(stat),
        reset_stat_inode(stat),
        stat.st_mode,
        stat.st_size,
        reset_stat_mtime_seconds(stat),
        reset_stat_mtime_nanoseconds(stat)
    )
}

#[cfg(all(unix, not(any(target_vendor = "apple", target_os = "aix", target_os = "hurd"))))]
pub(super) fn reset_stat_mtime_seconds(stat: &libc::stat) -> i64 {
    stat.st_mtime
}

#[cfg(any(target_os = "aix", target_os = "hurd"))]
pub(super) fn reset_stat_mtime_seconds(stat: &libc::stat) -> i64 {
    stat.st_mtim.tv_sec
}

#[cfg(all(unix, target_vendor = "apple"))]
pub(super) fn reset_stat_mtime_seconds(stat: &libc::stat) -> i64 {
    // Rust libc exposes Darwin's st_mtimespec through these stable aliases.
    stat.st_mtime
}

#[cfg(all(unix, not(any(target_vendor = "apple", target_os = "aix", target_os = "hurd"))))]
pub(super) fn reset_stat_mtime_nanoseconds(stat: &libc::stat) -> i64 {
    stat.st_mtime_nsec
}

#[cfg(any(target_os = "aix", target_os = "hurd"))]
pub(super) fn reset_stat_mtime_nanoseconds(stat: &libc::stat) -> i64 {
    stat.st_mtim.tv_nsec
}

#[cfg(all(unix, target_vendor = "apple"))]
pub(super) fn reset_stat_mtime_nanoseconds(stat: &libc::stat) -> i64 {
    // Rust libc exposes Darwin's st_mtimespec through these stable aliases.
    stat.st_mtime_nsec
}

#[cfg(unix)]
pub(super) fn reset_stat_device(stat: &libc::stat) -> u64 {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        stat.st_dev
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        stat.st_dev as u64
    }
}

#[cfg(unix)]
pub(super) fn reset_stat_inode(stat: &libc::stat) -> u64 {
    stat.st_ino
}

#[cfg(not(unix))]
pub(super) fn remove_reset_dir_all(
    path: &Path,
    label: &str,
    _fingerprint_label: &str,
    _expected_fingerprint: &str,
) -> anyhow::Result<()> {
    unsupported_checked_reset_deletion(path, label)
}

pub(super) fn ensure_checked_reset_deletion_supported(root: &Path) -> anyhow::Result<()> {
    #[cfg(test)]
    {
        let mut unsupported_root = RESET_UNSUPPORTED_CHECKED_DELETION_ROOT.lock().unwrap();
        if unsupported_root.as_deref() == Some(root) {
            *unsupported_root = None;
            return unsupported_checked_reset_deletion(root, "saved state");
        }
    }
    #[cfg(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))]
    {
        let _ = root;
        Ok(())
    }
    #[cfg(not(any(
        target_os = "ios",
        target_os = "macos",
        target_os = "linux",
        target_os = "android"
    )))]
    {
        unsupported_checked_reset_deletion(root, "saved state")
    }
}

#[cfg(any(
    test,
    not(any(target_os = "ios", target_os = "macos", target_os = "linux", target_os = "android"))
))]
pub(super) fn unsupported_checked_reset_deletion(path: &Path, label: &str) -> anyhow::Result<()> {
    anyhow::bail!(
        "safe saved-state reset is not supported on this platform because cmux cannot verify {label} during deletion: {}",
        path.display()
    )
}

pub(super) fn reset_path_fingerprint(
    path: &Path,
    metadata: &fs::Metadata,
    budget: &mut ResetFingerprintBudget,
    stable_directory_identity: bool,
) -> anyhow::Result<String> {
    let mut fingerprint = if stable_directory_identity && metadata.file_type().is_dir() {
        reset_stable_directory_identity_fingerprint(metadata)
    } else {
        reset_metadata_fingerprint(metadata)
    };
    if metadata.file_type().is_file() {
        fingerprint.push_str(";sha256=");
        fingerprint.push_str(&reset_file_content_sha256(path, metadata, budget)?);
    }
    Ok(fingerprint)
}

#[cfg(unix)]
pub(super) fn reset_stable_directory_identity_fingerprint(metadata: &fs::Metadata) -> String {
    use std::os::unix::fs::MetadataExt;

    format!("dir:dev={},ino={},uid={}", metadata.dev(), metadata.ino(), metadata.uid())
}

#[cfg(not(unix))]
pub(super) fn reset_stable_directory_identity_fingerprint(metadata: &fs::Metadata) -> String {
    reset_metadata_fingerprint(metadata)
}

pub(super) fn reset_metadata_fingerprint(metadata: &fs::Metadata) -> String {
    let kind = if metadata.file_type().is_dir() {
        "dir"
    } else if metadata.file_type().is_file() {
        "file"
    } else if metadata.file_type().is_symlink() {
        "symlink"
    } else {
        "other"
    };
    format!("{kind}:{}", metadata_identity(metadata))
}

pub(super) fn reset_file_content_sha256(
    path: &Path,
    expected: &fs::Metadata,
    budget: &mut ResetFingerprintBudget,
) -> anyhow::Result<String> {
    let mut file = open_reset_fingerprint_file(path)
        .with_context(|| format!("open reset file {}", path.display()))?;
    let opened =
        file.metadata().with_context(|| format!("inspect reset file {}", path.display()))?;
    if reset_metadata_fingerprint(&opened) != reset_metadata_fingerprint(expected) {
        anyhow::bail!("reset path changed during fingerprint: {}", path.display());
    }
    let mut hash = Sha256::new();
    let mut buffer = [0_u8; 8192];
    loop {
        let read = file
            .read(&mut buffer)
            .with_context(|| format!("read reset file for fingerprint {}", path.display()))?;
        if read == 0 {
            break;
        }
        budget.add_file_bytes(path, read as u64)?;
        hash.update(&buffer[..read]);
    }
    let current = fs::symlink_metadata(path)
        .with_context(|| format!("inspect reset file {}", path.display()))?;
    if reset_metadata_fingerprint(&current) != reset_metadata_fingerprint(expected) {
        anyhow::bail!("reset path changed during fingerprint: {}", path.display());
    }
    Ok(hex_sha256(hash.finalize().into()))
}

#[cfg(unix)]
pub(super) fn open_reset_fingerprint_file(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;

    OpenOptions::new().read(true).custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW).open(path)
}

#[cfg(not(unix))]
pub(super) fn open_reset_fingerprint_file(path: &Path) -> std::io::Result<File> {
    File::open(path)
}

#[cfg(unix)]
pub(super) fn metadata_identity(metadata: &fs::Metadata) -> String {
    use std::os::unix::fs::MetadataExt;

    format!(
        "dev={},ino={},mode={},len={},mtime={}.{}",
        metadata.dev(),
        metadata.ino(),
        metadata.mode(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec()
    )
}

#[cfg(not(unix))]
pub(super) fn metadata_identity(metadata: &fs::Metadata) -> String {
    let modified = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| format!("{}.{}", duration.as_secs(), duration.subsec_nanos()))
        .unwrap_or_else(|| "unknown".into());
    format!(
        "readonly={},len={},modified={modified}",
        metadata.permissions().readonly(),
        metadata.len()
    )
}

pub(super) fn sqlite_filesystem_path(path: &Path) -> anyhow::Result<Cow<'_, Path>> {
    #[cfg(windows)]
    {
        let parent =
            path.parent().ok_or_else(|| anyhow::anyhow!("workspace state path has no parent"))?;
        let file_name = path
            .file_name()
            .ok_or_else(|| anyhow::anyhow!("workspace state path has no file name"))?;
        let parent = fs::canonicalize(parent).context("resolve workspace state directory")?;
        Ok(Cow::Owned(parent.join(file_name)))
    }
    #[cfg(not(windows))]
    {
        Ok(Cow::Borrowed(path))
    }
}
