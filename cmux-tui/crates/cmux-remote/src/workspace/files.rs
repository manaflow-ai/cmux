use std::collections::{HashSet, VecDeque};
use std::mem::size_of;
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::ffi::{CStr, CString, OsString};
#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::os::fd::{FromRawFd, IntoRawFd, RawFd};
#[cfg(unix)]
use std::os::unix::ffi::{OsStrExt as _, OsStringExt as _};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

use cmux_remote_protocol::{
    ByteString, DirectoryEntry, FileKind, FilePrecondition, FileStat, PageCursor, RpcError,
    SearchMatch, WorkspaceResponse,
};
use sha2::{Digest, Sha256};
#[cfg(not(unix))]
use tokio::io::AsyncWriteExt;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

use super::PreparedWorkspaceResponse;
#[cfg(unix)]
use super::path::{UnixWorkspaceDirectory, UnixWorkspaceRoot, UnixWorkspaceTarget};
use super::path::{
    WorkspaceRoot, io_error, join_protocol_path, normalize_protocol_path, validate_relative,
};
use super::query::{FileHashKey, WorkspaceQueryContext};

#[cfg(unix)]
mod commit;
mod search;

#[cfg(unix)]
use commit::{commit_unix_remove, commit_unix_write, prepare_unix_remove, prepare_unix_write};
pub(super) use search::SearchContinuation;
pub(crate) use search::search;

pub(crate) const MAX_READ_BYTES: u32 = 4 * 1024 * 1024;
pub(crate) const MAX_WRITE_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const MAX_HASH_BYTES: u64 = 128 * 1024 * 1024;
const MAX_DIRECTORY_LIMIT: u32 = 4_096;
const MAX_DIRECTORY_SCAN: usize = 16_384;
const MAX_DIRECTORY_SNAPSHOT_BYTES: usize = 16 * 1024 * 1024;
const MAX_DIRECTORY_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const MAX_SEARCH_RESULTS: u32 = 10_000;
const MAX_SEARCH_DIRECTORIES: usize = 10_000;
const MAX_SEARCH_ENTRIES: usize = 50_000;
const MAX_SEARCH_FILE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_SEARCH_TOTAL_BYTES: u64 = 64 * 1024 * 1024;
const MAX_SEARCH_PATH_STATE_BYTES: usize = 12 * 1024 * 1024;
const MAX_SEARCH_STATE_BYTES: usize = 16 * 1024 * 1024;
const MAX_SEARCH_QUERY_BYTES: usize = 64 * 1024;
const MAX_SEARCH_PATHS: usize = 256;
const MAX_SEARCH_GLOBS: usize = 256;
const MAX_SEARCH_ARGUMENT_BYTES: usize = 1024 * 1024;
const MAX_SEARCH_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
#[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
const GUARDED_CONTENT_MUTATIONS_SUPPORTED: bool = true;
#[cfg(all(unix, not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))))]
const GUARDED_CONTENT_MUTATIONS_SUPPORTED: bool = false;

#[derive(Clone)]
struct SortedDirectoryEntry {
    entry: DirectoryEntry,
    folded_name: String,
    directory: bool,
}

impl SortedDirectoryEntry {
    fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            .saturating_add(self.entry.name.capacity())
            .saturating_add(self.entry.path.capacity())
            .saturating_add(self.folded_name.capacity())
            .saturating_add(64)
    }
}

#[derive(Clone)]
pub(super) struct DirectoryContinuation {
    entries: Vec<SortedDirectoryEntry>,
    next_index: usize,
    scan_truncated: bool,
}

impl DirectoryContinuation {
    pub(super) fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            .saturating_add(
                self.entries.capacity().saturating_mul(size_of::<SortedDirectoryEntry>()),
            )
            .saturating_add(
                self.entries
                    .iter()
                    .map(SortedDirectoryEntry::retained_bytes)
                    .fold(0usize, usize::saturating_add),
            )
    }
}

pub(crate) async fn stat(
    root: &WorkspaceRoot,
    path: &str,
    follow_symlinks: bool,
) -> Result<WorkspaceResponse, RpcError> {
    let normalized = normalize_protocol_path(path)?;
    let resolved = if follow_symlinks {
        root.resolve_existing(path).await?
    } else {
        root.resolve_entry(path).await?
    };
    #[cfg(unix)]
    let prepared = {
        let unix_root = root.unix_root();
        let resolved = resolved.clone();
        let is_root = resolved == root.canonical_root();
        tokio::task::spawn_blocking(move || {
            prepare_unix_stat(unix_root, resolved, is_root, follow_symlinks)
        })
        .await
        .map_err(blocking_task_error)??
    };
    #[cfg(unix)]
    {
        let (state, content_hash) = match prepared {
            PreparedUnixStat::Root { directory, before } => {
                let after = directory.metadata()?;
                if !metadata_stable(&before, &after) {
                    return Err(RpcError::new(
                        "file-changed",
                        "workspace root changed while it was being inspected",
                    ));
                }
                directory.verify_identity("stat")?;
                (RawEntryState::from_metadata(&before), None)
            }
            PreparedUnixStat::Entry { target, before, file } => {
                let content_hash = if let Some(file) = file {
                    let mut file = tokio::fs::File::from_std(file);
                    let digest = if before.size <= MAX_HASH_BYTES {
                        Some(hash_file(&mut file, before.size).await?)
                    } else {
                        None
                    };
                    let after = file
                        .metadata()
                        .await
                        .map_err(|error| io_error("stat", target.display(), error))?;
                    if before != RawEntryState::from_metadata(&after) {
                        return Err(RpcError::new(
                            "file-changed",
                            "file changed while it was being inspected",
                        ));
                    }
                    digest
                } else {
                    None
                };
                let checked = tokio::task::spawn_blocking(move || {
                    let after = stat_entry(&target, "stat")?.ok_or_else(|| {
                        RpcError::new(
                            "file-changed",
                            "file disappeared while it was being inspected",
                        )
                    })?;
                    if before != after {
                        return Err(RpcError::new(
                            "file-changed",
                            "file changed while it was being inspected",
                        ));
                    }
                    target.verify_parent_identity()?;
                    Ok::<_, RpcError>(before)
                })
                .await
                .map_err(blocking_task_error)??;
                (checked, content_hash)
            }
        };
        Ok(WorkspaceResponse::Stat {
            stat: FileStat {
                path: normalized,
                kind: state.file_kind(),
                size: state.size,
                modified_unix_ms: state.modified_unix_ms(),
                executable: state.is_executable(),
                content_hash,
            },
        })
    }
    #[cfg(not(unix))]
    {
        let metadata = if follow_symlinks {
            tokio::fs::metadata(&resolved).await
        } else {
            tokio::fs::symlink_metadata(&resolved).await
        }
        .map_err(|error| io_error("stat", &resolved, error))?;
        let kind = file_kind(&metadata);
        let content_hash = if kind == FileKind::File && metadata.len() <= MAX_HASH_BYTES {
            Some(hash_path(&resolved, MAX_HASH_BYTES).await?)
        } else {
            None
        };
        let metadata_after = if follow_symlinks {
            tokio::fs::metadata(&resolved).await
        } else {
            tokio::fs::symlink_metadata(&resolved).await
        }
        .map_err(|error| io_error("stat", &resolved, error))?;
        if !metadata_stable(&metadata, &metadata_after) {
            return Err(RpcError::new("file-changed", "file changed while it was being inspected"));
        }
        let modified_unix_ms = metadata
            .modified()
            .ok()
            .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
            .and_then(|duration| u64::try_from(duration.as_millis()).ok());

        Ok(WorkspaceResponse::Stat {
            stat: FileStat {
                path: normalized,
                kind,
                size: metadata.len(),
                modified_unix_ms,
                executable: is_executable(&metadata),
                content_hash,
            },
        })
    }
}

pub(crate) async fn read_file(
    context: &WorkspaceQueryContext<'_>,
    path: &str,
    offset: u64,
    limit: u32,
) -> Result<WorkspaceResponse, RpcError> {
    if limit > MAX_READ_BYTES {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("read limit exceeds {MAX_READ_BYTES} bytes"),
        ));
    }
    let root = context.root;
    let resolved = root.resolve_existing(path).await?;
    #[cfg(unix)]
    let (mut file, target) = {
        let unix_root = root.unix_root();
        let resolved = resolved.clone();
        let (file, target) = tokio::task::spawn_blocking(move || {
            let target = unix_root.target_for_canonical_path(&resolved)?;
            let file = open_regular_entry(&target, "read")?;
            Ok::<_, RpcError>((file, target))
        })
        .await
        .map_err(blocking_task_error)??;
        (tokio::fs::File::from_std(file), target)
    };
    #[cfg(not(unix))]
    let mut file = tokio::fs::File::open(&resolved)
        .await
        .map_err(|error| io_error("read", &resolved, error))?;
    let metadata = file.metadata().await.map_err(|error| io_error("read", &resolved, error))?;
    if !metadata.is_file() {
        return Err(RpcError::new("not-a-file", format!("not a file: {}", resolved.display())));
    }
    if metadata.len() > MAX_HASH_BYTES {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("file exceeds the {MAX_HASH_BYTES}-byte integrity limit"),
        ));
    }

    let hash_key = FileHashKey::new(root.id.clone(), resolved.clone(), &metadata);
    let hash_cell = context.service.hash_cell(hash_key.clone());
    let content_hash = hash_cell
        .get_or_try_init(|| async {
            let content_hash = hash_file(&mut file, metadata.len()).await?;
            let metadata_after_hash =
                file.metadata().await.map_err(|error| io_error("read", &resolved, error))?;
            if !hash_key.matches(&resolved, &metadata_after_hash) {
                return Err(RpcError::new(
                    "file-changed",
                    "file changed while it was being hashed",
                ));
            }
            Ok::<String, RpcError>(content_hash)
        })
        .await?
        .clone();
    file.seek(std::io::SeekFrom::Start(offset))
        .await
        .map_err(|error| io_error("seek", &resolved, error))?;
    let mut data = Vec::with_capacity(limit as usize);
    (&mut file)
        .take(u64::from(limit))
        .read_to_end(&mut data)
        .await
        .map_err(|error| io_error("read", &resolved, error))?;
    let consumed = u64::try_from(data.len()).unwrap_or(u64::MAX);
    let eof = offset.saturating_add(consumed) >= metadata.len();
    let metadata_after =
        file.metadata().await.map_err(|error| io_error("read", &resolved, error))?;
    if !hash_key.matches(&resolved, &metadata_after) {
        return Err(RpcError::new("file-changed", "file changed while it was being read"));
    }
    #[cfg(unix)]
    tokio::task::spawn_blocking(move || target.verify_parent_identity())
        .await
        .map_err(blocking_task_error)??;

    Ok(WorkspaceResponse::File { data: ByteString::from_bytes(&data), offset, eof, content_hash })
}

pub(crate) async fn write_file(
    root: &WorkspaceRoot,
    path: &str,
    data: &ByteString,
    precondition: &FilePrecondition,
    create_parents: bool,
) -> Result<WorkspaceResponse, RpcError> {
    let bytes = data
        .decode()
        .map_err(|error| RpcError::new("invalid-data", format!("invalid file bytes: {error}")))?;
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("write exceeds {MAX_WRITE_BYTES} bytes"),
        ));
    }
    let _guard = root.mutation.lock().await;
    let content_hash = write_bytes_locked(root, path, &bytes, precondition, create_parents).await?;
    Ok(WorkspaceResponse::Written {
        bytes: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
        content_hash,
    })
}

pub(crate) async fn list_directory(
    context: &WorkspaceQueryContext<'_>,
    path: &str,
    include_hidden: bool,
    limit: u32,
    cursor: Option<&PageCursor>,
) -> Result<PreparedWorkspaceResponse, RpcError> {
    if limit > MAX_DIRECTORY_LIMIT {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("directory limit exceeds {MAX_DIRECTORY_LIMIT} entries"),
        ));
    }
    if limit == 0 {
        return Ok(PreparedWorkspaceResponse::plain(WorkspaceResponse::Directory {
            entries: Vec::new(),
            truncated: false,
            next_cursor: None,
        }));
    }
    let normalized = normalize_protocol_path(path)?;
    let cursor_scope =
        page_scope(&["directory", &normalized, if include_hidden { "1" } else { "0" }]);
    let (mut continuation, mut delivery) = if let Some(cursor) = cursor {
        let (continuation, delivery) = context.service.lease_directory(
            context.owner,
            &context.root.id,
            &cursor_scope,
            cursor,
        )?;
        (continuation, Some(delivery))
    } else {
        (snapshot_directory(context.root, path, &normalized, include_hidden).await?, None)
    };

    let requested = limit as usize;
    let mut page = Vec::with_capacity(
        requested.min(continuation.entries.len().saturating_sub(continuation.next_index)),
    );
    let mut response_bytes = 0usize;
    while continuation.next_index < continuation.entries.len() && page.len() < requested {
        let entry = &continuation.entries[continuation.next_index].entry;
        let entry_bytes =
            entry.name.len().saturating_add(entry.path.len()).saturating_mul(6).saturating_add(64);
        if response_bytes.saturating_add(entry_bytes) > MAX_DIRECTORY_RESPONSE_BYTES {
            break;
        }
        response_bytes = response_bytes.saturating_add(entry_bytes);
        page.push(entry.clone());
        continuation.next_index += 1;
    }
    let has_more = continuation.next_index < continuation.entries.len();
    let scan_truncated = continuation.scan_truncated;
    let next_cursor = if has_more {
        let (next, next_delivery) = context.service.put_directory(
            context.owner,
            &context.root.id,
            &cursor_scope,
            continuation,
            delivery.take(),
        )?;
        delivery = Some(next_delivery);
        Some(next)
    } else {
        None
    };
    if let Some(delivery) = delivery.as_mut() {
        delivery.finish_preparation();
    }
    Ok(PreparedWorkspaceResponse::paginated(
        WorkspaceResponse::Directory {
            entries: page,
            truncated: scan_truncated || next_cursor.is_some(),
            next_cursor,
        },
        delivery,
    ))
}

async fn snapshot_directory(
    root: &WorkspaceRoot,
    path: &str,
    normalized: &str,
    include_hidden: bool,
) -> Result<DirectoryContinuation, RpcError> {
    let resolved = root.resolve_existing(path).await?;
    #[cfg(unix)]
    let directory = {
        let unix_root = root.unix_root();
        let resolved = resolved.clone();
        tokio::task::spawn_blocking(move || {
            unix_root.pinned_directory_for_canonical_path(&resolved)
        })
        .await
        .map_err(blocking_task_error)??
    };
    #[cfg(not(unix))]
    {
        let metadata = tokio::fs::metadata(&resolved)
            .await
            .map_err(|error| io_error("list-directory", &resolved, error))?;
        if !metadata.is_dir() {
            return Err(RpcError::new(
                "not-a-directory",
                format!("not a directory: {}", resolved.display()),
            ));
        }
    }

    #[cfg(unix)]
    {
        let normalized = normalized.to_owned();
        tokio::task::spawn_blocking(move || {
            snapshot_unix_directory(directory, &normalized, include_hidden)
        })
        .await
        .map_err(blocking_task_error)?
    }
    #[cfg(not(unix))]
    {
        let mut reader = tokio::fs::read_dir(&resolved)
            .await
            .map_err(|error| io_error("list-directory", &resolved, error))?;
        let mut entries = Vec::new();
        let mut scanned = 0usize;
        let mut scan_truncated = false;
        let mut snapshot_bytes = 0usize;
        while let Some(entry) = reader
            .next_entry()
            .await
            .map_err(|error| io_error("list-directory", &resolved, error))?
        {
            scanned += 1;
            if scanned > MAX_DIRECTORY_SCAN {
                scan_truncated = true;
                break;
            }
            let Ok(name) = entry.file_name().into_string() else { continue };
            if !include_hidden && name.starts_with('.') {
                continue;
            }
            let metadata = tokio::fs::symlink_metadata(entry.path())
                .await
                .map_err(|error| io_error("list-directory", &entry.path(), error))?;
            let Ok(entry_path) = join_protocol_path(normalized, &name) else { continue };
            let kind = file_kind(&metadata);
            let candidate = SortedDirectoryEntry {
                folded_name: name.to_lowercase(),
                directory: kind == FileKind::Directory,
                entry: DirectoryEntry { path: entry_path, name, kind, size: metadata.len() },
            };
            let candidate_bytes = candidate.retained_bytes();
            if snapshot_bytes.saturating_add(candidate_bytes) > MAX_DIRECTORY_SNAPSHOT_BYTES {
                scan_truncated = true;
                break;
            }
            snapshot_bytes = snapshot_bytes.saturating_add(candidate_bytes);
            entries.push(candidate);
        }
        entries.sort_unstable_by(|left, right| {
            right
                .directory
                .cmp(&left.directory)
                .then_with(|| left.folded_name.cmp(&right.folded_name))
                .then_with(|| left.entry.name.cmp(&right.entry.name))
        });
        entries.shrink_to_fit();
        Ok(DirectoryContinuation { entries, next_index: 0, scan_truncated })
    }
}

#[derive(Clone, Debug)]
pub(crate) struct WorkspaceFileSnapshot {
    pub(crate) contents: Vec<u8>,
    pub(crate) mode: Option<u32>,
}

pub(crate) async fn read_file_snapshot(
    root: &WorkspaceRoot,
    path: &str,
    maximum: usize,
) -> Result<WorkspaceFileSnapshot, RpcError> {
    validate_relative(path)?;
    #[cfg(unix)]
    {
        let root = root.unix_root();
        let path = path.to_owned();
        tokio::task::spawn_blocking(move || {
            let target = root.resolve_target(&path, false)?;
            let mut file = open_regular_entry(&target, "read")?;
            let (contents, metadata) =
                read_file_bounded_sync(&mut file, target.display(), maximum)?;
            target.verify_parent_identity()?;
            Ok(WorkspaceFileSnapshot {
                contents,
                mode: Some(metadata.permissions().mode() & 0o7777),
            })
        })
        .await
        .map_err(blocking_task_error)?
    }
    #[cfg(not(unix))]
    {
        let resolved = root.resolve_existing(path).await?;
        let contents = read_path_bounded(&resolved, maximum).await?;
        Ok(WorkspaceFileSnapshot { contents, mode: None })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum MutationOutcome {
    Unchanged,
    Applied,
    Restored,
    Unknown,
}

#[derive(Debug)]
pub(crate) struct MutationFailure {
    pub(crate) error: RpcError,
    pub(crate) outcome: MutationOutcome,
    pub(crate) recovery_path: Option<PathBuf>,
}

impl MutationFailure {
    fn unchanged(error: RpcError) -> Self {
        Self { error, outcome: MutationOutcome::Unchanged, recovery_path: None }
    }

    fn unknown(error: RpcError) -> Self {
        Self { error, outcome: MutationOutcome::Unknown, recovery_path: None }
    }
}

#[derive(Debug)]
struct MutationProgress {
    outcome: MutationOutcome,
    recovery_path: Option<PathBuf>,
}

impl MutationProgress {
    fn unchanged() -> Self {
        Self { outcome: MutationOutcome::Unchanged, recovery_path: None }
    }

    #[cfg(unix)]
    fn retain(&mut self, target: &UnixWorkspaceTarget, name: &CStr) {
        self.recovery_path = Some(temporary_display(target, name));
    }

    fn cleaned(&mut self) {
        self.recovery_path = None;
    }

    fn fail(self, error: RpcError) -> MutationFailure {
        MutationFailure { error, outcome: self.outcome, recovery_path: self.recovery_path }
    }
}

pub(crate) async fn write_bytes_locked(
    root: &WorkspaceRoot,
    path: &str,
    bytes: &[u8],
    precondition: &FilePrecondition,
    create_parents: bool,
) -> Result<String, RpcError> {
    write_bytes_locked_with_outcome(root, path, bytes, precondition, create_parents)
        .await
        .map_err(|failure| failure.error)
}

pub(crate) async fn write_bytes_locked_with_outcome(
    root: &WorkspaceRoot,
    path: &str,
    bytes: &[u8],
    precondition: &FilePrecondition,
    create_parents: bool,
) -> Result<String, MutationFailure> {
    write_bytes_locked_with_mode_and_outcome(root, path, bytes, precondition, create_parents, None)
        .await
}

pub(crate) async fn write_bytes_locked_with_mode_and_outcome(
    root: &WorkspaceRoot,
    path: &str,
    bytes: &[u8],
    precondition: &FilePrecondition,
    create_parents: bool,
    mode: Option<u32>,
) -> Result<String, MutationFailure> {
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(MutationFailure::unchanged(RpcError::new(
            "resource-exhausted",
            format!("write exceeds {MAX_WRITE_BYTES} bytes"),
        )));
    }
    #[cfg(unix)]
    {
        let root_handle = root.unix_root();
        let prepared_path = path.to_owned();
        let prepared_precondition = precondition.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            prepare_unix_write(
                root_handle,
                prepared_path,
                prepared_precondition,
                create_parents,
                mode,
            )
        })
        .await
        .map_err(|error| MutationFailure::unchanged(blocking_task_error(error)))?
        .map_err(MutationFailure::unchanged)?;
        let bytes = bytes.to_vec();
        let (result, progress) = tokio::task::spawn_blocking(move || {
            let mut progress = MutationProgress::unchanged();
            let result = commit_unix_write(prepared, &bytes, &mut progress);
            (result, progress)
        })
        .await
        .map_err(|error| MutationFailure::unknown(blocking_task_error(error)))?;
        result.map_err(|error| progress.fail(error))
    }
    #[cfg(not(unix))]
    {
        if mode.is_some() {
            return Err(MutationFailure::unchanged(RpcError::new(
                "unsupported-platform",
                "workspace file modes require Unix descriptor-relative file operations",
            )));
        }
        if !matches!(precondition, FilePrecondition::Any) {
            return Err(MutationFailure::unchanged(RpcError::new(
                "unsupported-platform",
                "guarded workspace writes require Unix descriptor-relative file operations",
            )));
        }
        write_bytes_locked_path(root, path, bytes, precondition, create_parents)
            .await
            .map_err(MutationFailure::unknown)
    }
}

#[cfg(not(unix))]
async fn write_bytes_locked_path(
    root: &WorkspaceRoot,
    path: &str,
    bytes: &[u8],
    precondition: &FilePrecondition,
    create_parents: bool,
) -> Result<String, RpcError> {
    let target = root.resolve_write_target(path, create_parents).await?;
    let existing = match tokio::fs::symlink_metadata(&target).await {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(io_error("stat-before-write", &target, error)),
    };
    if existing.as_ref().is_some_and(|metadata| metadata.is_dir()) {
        return Err(RpcError::new(
            "not-a-file",
            format!("cannot replace directory: {}", target.display()),
        ));
    }
    if existing.as_ref().is_some_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(RpcError::new(
            "symlink-not-supported",
            format!("refusing to replace symlink: {}", target.display()),
        ));
    }
    if existing.as_ref().is_some_and(|metadata| !metadata.is_file()) {
        return Err(RpcError::new(
            "not-a-file",
            format!("cannot replace non-regular file: {}", target.display()),
        ));
    }
    match precondition {
        FilePrecondition::Any => {}
        FilePrecondition::Missing if existing.is_some() => {
            return Err(RpcError::new("conflict", "file already exists"));
        }
        FilePrecondition::Missing => {}
        FilePrecondition::ContentHash(expected) => {
            validate_content_hash(expected)?;
            if existing.is_none() {
                return Err(RpcError::new("conflict", "file does not exist"));
            }
            let actual = hash_path(&target, MAX_HASH_BYTES).await?;
            if !actual.eq_ignore_ascii_case(expected) {
                return Err(RpcError::new(
                    "conflict",
                    format!("content hash changed: expected {expected}, found {actual}"),
                ));
            }
        }
    }

    let parent = target
        .parent()
        .ok_or_else(|| RpcError::new("invalid-path", "write target has no parent"))?;
    let temporary = parent.join(format!(".cmux-write-{}", uuid::Uuid::new_v4()));
    let result = async {
        let mut options = tokio::fs::OpenOptions::new();
        options.write(true).create_new(true);
        let mut file = options
            .open(&temporary)
            .await
            .map_err(|error| io_error("create-temporary", &temporary, error))?;
        file.write_all(bytes)
            .await
            .map_err(|error| io_error("write-temporary", &temporary, error))?;
        file.flush().await.map_err(|error| io_error("flush-temporary", &temporary, error))?;
        if let Some(metadata) = &existing {
            tokio::fs::set_permissions(&temporary, metadata.permissions())
                .await
                .map_err(|error| io_error("set-permissions", &temporary, error))?;
        }
        file.sync_all().await.map_err(|error| io_error("sync-temporary", &temporary, error))?;
        drop(file);
        replace_file(&temporary, &target).await?;
        sync_parent(parent).await?;
        Ok::<(), RpcError>(())
    }
    .await;
    if let Err(error) = result {
        let _ = tokio::fs::remove_file(&temporary).await;
        return Err(error);
    }
    Ok(hash_bytes(bytes))
}

pub(crate) async fn remove_file_precondition_locked_with_outcome(
    root: &WorkspaceRoot,
    path: &str,
    precondition: &FilePrecondition,
) -> Result<(), MutationFailure> {
    #[cfg(unix)]
    {
        let root_handle = root.unix_root();
        let prepared_path = path.to_owned();
        let prepared_precondition = precondition.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            prepare_unix_remove(root_handle, prepared_path, prepared_precondition)
        })
        .await
        .map_err(|error| MutationFailure::unchanged(blocking_task_error(error)))?
        .map_err(MutationFailure::unchanged)?;
        let (result, progress) = tokio::task::spawn_blocking(move || {
            let mut progress = MutationProgress::unchanged();
            let result = commit_unix_remove(prepared, &mut progress);
            (result, progress)
        })
        .await
        .map_err(|error| MutationFailure::unknown(blocking_task_error(error)))?;
        result.map_err(|error| progress.fail(error))
    }
    #[cfg(not(unix))]
    {
        if !matches!(precondition, FilePrecondition::Any) {
            return Err(MutationFailure::unchanged(RpcError::new(
                "unsupported-platform",
                "guarded workspace removals require Unix descriptor-relative file operations",
            )));
        }
        remove_file_precondition_locked_path(root, path, precondition)
            .await
            .map_err(MutationFailure::unknown)
    }
}

#[cfg(not(unix))]
async fn remove_file_precondition_locked_path(
    root: &WorkspaceRoot,
    path: &str,
    precondition: &FilePrecondition,
) -> Result<(), RpcError> {
    let target = root.resolve_entry(path).await?;
    let metadata = tokio::fs::symlink_metadata(&target)
        .await
        .map_err(|error| io_error("remove", &target, error))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(RpcError::new("not-a-file", format!("not a regular file: {path}")));
    }
    match precondition {
        FilePrecondition::Any => {}
        FilePrecondition::Missing => {
            return Err(RpcError::new("conflict", "file exists"));
        }
        FilePrecondition::ContentHash(expected) => {
            validate_content_hash(expected)?;
            let actual = hash_path(&target, MAX_HASH_BYTES).await?;
            if !actual.eq_ignore_ascii_case(expected) {
                return Err(RpcError::new(
                    "conflict",
                    format!("content hash changed: expected {expected}, found {actual}"),
                ));
            }
        }
    }
    tokio::fs::remove_file(&target).await.map_err(|error| io_error("remove", &target, error))?;
    if let Some(parent) = target.parent() {
        sync_parent(parent).await?;
    }
    Ok(())
}

#[cfg(unix)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RawEntryState {
    dev: u64,
    ino: u64,
    mode: u32,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}

#[cfg(unix)]
impl RawEntryState {
    fn from_metadata(metadata: &std::fs::Metadata) -> Self {
        Self {
            dev: metadata.dev(),
            ino: metadata.ino(),
            mode: metadata.mode(),
            size: metadata.len(),
            modified: (metadata.mtime(), metadata.mtime_nsec()),
            changed: (metadata.ctime(), metadata.ctime_nsec()),
        }
    }

    fn from_stat(status: &libc::stat) -> Self {
        let (modified, changed) = raw_stat_timestamps(status);
        Self {
            dev: normalize_stat_value(status.st_dev),
            ino: normalize_stat_value(status.st_ino),
            mode: normalize_stat_value(status.st_mode),
            size: normalize_stat_value(status.st_size),
            modified,
            changed,
        }
    }

    fn is_regular(&self) -> bool {
        file_type_bits(self.mode) == normalize_stat_value::<_, u32>(libc::S_IFREG)
    }

    fn is_directory(&self) -> bool {
        file_type_bits(self.mode) == normalize_stat_value::<_, u32>(libc::S_IFDIR)
    }

    fn is_symlink(&self) -> bool {
        file_type_bits(self.mode) == normalize_stat_value::<_, u32>(libc::S_IFLNK)
    }

    fn file_kind(&self) -> FileKind {
        if self.is_symlink() {
            FileKind::Symlink
        } else if self.is_regular() {
            FileKind::File
        } else if self.is_directory() {
            FileKind::Directory
        } else {
            FileKind::Other
        }
    }

    fn is_executable(&self) -> bool {
        self.mode & 0o111 != 0
    }

    fn modified_unix_ms(&self) -> Option<u64> {
        let seconds = u64::try_from(self.modified.0).ok()?;
        let nanoseconds = u64::try_from(self.modified.1).ok()?;
        if nanoseconds >= 1_000_000_000 {
            return None;
        }
        seconds.checked_mul(1_000)?.checked_add(nanoseconds / 1_000_000)
    }

    fn same_object(&self, other: &Self) -> bool {
        self.dev == other.dev
            && self.ino == other.ino
            && file_type_bits(self.mode) == file_type_bits(other.mode)
    }

    fn matches_snapshot(&self, other: &Self) -> bool {
        self.same_object(other)
            && self.mode == other.mode
            && self.size == other.size
            && self.modified == other.modified
    }
}

#[cfg(unix)]
enum PreparedUnixStat {
    Root { directory: UnixWorkspaceDirectory, before: std::fs::Metadata },
    Entry { target: UnixWorkspaceTarget, before: RawEntryState, file: Option<File> },
}

#[cfg(unix)]
fn prepare_unix_stat(
    root: UnixWorkspaceRoot,
    resolved: PathBuf,
    is_root: bool,
    follow_symlinks: bool,
) -> Result<PreparedUnixStat, RpcError> {
    if is_root {
        let directory = root.pinned_directory_for_canonical_path(&resolved)?;
        let before = directory.metadata()?;
        return Ok(PreparedUnixStat::Root { directory, before });
    }

    let target = root.target_for_canonical_path(&resolved)?;
    let observed = stat_entry(&target, "stat")?.ok_or_else(|| {
        RpcError::new("not-found", format!("path not found: {}", resolved.display()))
    })?;
    if follow_symlinks && observed.is_symlink() {
        return Err(RpcError::new(
            "file-changed",
            "resolved path changed to a symlink while it was being inspected",
        ));
    }
    let file = if observed.is_regular() {
        let file = open_regular_entry(&target, "stat")?;
        let pinned = file
            .metadata()
            .map(|metadata| RawEntryState::from_metadata(&metadata))
            .map_err(|error| io_error("stat", target.display(), error))?;
        if observed != pinned {
            return Err(RpcError::new(
                "file-changed",
                "file changed while it was being opened for inspection",
            ));
        }
        Some(file)
    } else {
        None
    };
    Ok(PreparedUnixStat::Entry { target, before: observed, file })
}

#[cfg(unix)]
struct UnixDirectoryRecord {
    name: OsString,
    state: RawEntryState,
}

#[cfg(unix)]
struct UnixDirectoryStream(*mut libc::DIR);

#[cfg(unix)]
impl Drop for UnixDirectoryStream {
    fn drop(&mut self) {
        // SAFETY: this wrapper uniquely owns the stream returned by `fdopendir`.
        unsafe { libc::closedir(self.0) };
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn set_readdir_errno(value: libc::c_int) {
    // SAFETY: libc returns this thread's writable errno location.
    unsafe { *libc::__errno_location() = value };
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn readdir_errno() -> libc::c_int {
    // SAFETY: libc returns this thread's readable errno location.
    unsafe { *libc::__errno_location() }
}

#[cfg(any(target_vendor = "apple", target_os = "freebsd", target_os = "dragonfly"))]
fn set_readdir_errno(value: libc::c_int) {
    // SAFETY: libc returns this thread's writable errno location.
    unsafe { *libc::__error() = value };
}

#[cfg(any(target_vendor = "apple", target_os = "freebsd", target_os = "dragonfly"))]
fn readdir_errno() -> libc::c_int {
    // SAFETY: libc returns this thread's readable errno location.
    unsafe { *libc::__error() }
}

#[cfg(any(target_os = "netbsd", target_os = "openbsd"))]
fn set_readdir_errno(value: libc::c_int) {
    // SAFETY: libc returns this thread's writable errno location.
    unsafe { *libc::__errno() = value };
}

#[cfg(any(target_os = "netbsd", target_os = "openbsd"))]
fn readdir_errno() -> libc::c_int {
    // SAFETY: libc returns this thread's readable errno location.
    unsafe { *libc::__errno() }
}

#[cfg(any(target_os = "solaris", target_os = "illumos"))]
fn set_readdir_errno(value: libc::c_int) {
    // SAFETY: libc returns this thread's writable errno location.
    unsafe { *libc::___errno() = value };
}

#[cfg(any(target_os = "solaris", target_os = "illumos"))]
fn readdir_errno() -> libc::c_int {
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
fn set_readdir_errno(_value: libc::c_int) {}

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
fn readdir_errno() -> libc::c_int {
    0
}

#[cfg(unix)]
fn read_directory_records(
    directory: &UnixWorkspaceDirectory,
    maximum: usize,
) -> Result<(Vec<UnixDirectoryRecord>, bool), RpcError> {
    let (names, truncated) = read_directory_names(directory, maximum)?;
    let mut records = Vec::with_capacity(names.len());
    for owned_name in names {
        let name = CString::new(owned_name.as_os_str().as_bytes())
            .map_err(|_| invalid_directory_entry(directory.display()))?;
        let display = directory.display().join(&owned_name);
        let Some(state) = stat_named(directory.fd(), &name, &display, "read-directory")? else {
            continue;
        };
        records.push(UnixDirectoryRecord { name: owned_name, state });
    }
    Ok((records, truncated))
}

#[cfg(unix)]
fn read_directory_names(
    directory: &UnixWorkspaceDirectory,
    maximum: usize,
) -> Result<(Vec<OsString>, bool), RpcError> {
    // A duplicated directory descriptor shares its directory-stream offset
    // with the pinned root. Reopen `.` so concurrent and repeated snapshots
    // each receive an independent stream position.
    let descriptor = directory.open_independent_file()?.into_raw_fd();
    // SAFETY: `descriptor` is a newly owned directory descriptor. On success,
    // `fdopendir` takes ownership; on failure, this function closes it below.
    let stream = unsafe { libc::fdopendir(descriptor) };
    if stream.is_null() {
        let error = std::io::Error::last_os_error();
        // SAFETY: failed `fdopendir` did not consume the descriptor.
        unsafe { libc::close(descriptor) };
        return Err(io_error("read-directory", directory.display(), error));
    }
    let stream = UnixDirectoryStream(stream);
    let mut names = Vec::with_capacity(maximum.min(1_024));
    let mut scanned = 0usize;
    loop {
        set_readdir_errno(0);
        // SAFETY: `stream` owns a valid DIR pointer and calls are serialized.
        let entry = unsafe { libc::readdir(stream.0) };
        if entry.is_null() {
            let errno = readdir_errno();
            if errno == 0 {
                break;
            }
            return Err(io_error(
                "read-directory",
                directory.display(),
                std::io::Error::from_raw_os_error(errno),
            ));
        }
        // SAFETY: POSIX requires `d_name` to contain a NUL-terminated name for
        // the current entry, valid until the next call on this stream.
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if matches!(name.to_bytes(), b"." | b"..") {
            continue;
        }
        scanned = scanned.saturating_add(1);
        if scanned > maximum {
            return Ok((names, true));
        }
        names.push(OsString::from_vec(name.to_bytes().to_vec()));
    }
    Ok((names, false))
}

#[cfg(unix)]
fn invalid_directory_entry(directory: &Path) -> RpcError {
    RpcError::new(
        "invalid-path",
        format!("directory entry contains a NUL byte: {}", directory.display()),
    )
}

#[cfg(unix)]
fn snapshot_unix_directory(
    directory: UnixWorkspaceDirectory,
    normalized: &str,
    include_hidden: bool,
) -> Result<DirectoryContinuation, RpcError> {
    let (records, mut scan_truncated) = read_directory_records(&directory, MAX_DIRECTORY_SCAN)?;
    directory.verify_identity("list directory")?;
    let mut entries = Vec::new();
    let mut snapshot_bytes = 0usize;
    for record in records {
        let Ok(name) = record.name.into_string() else { continue };
        if !include_hidden && name.starts_with('.') {
            continue;
        }
        let Ok(entry_path) = join_protocol_path(normalized, &name) else { continue };
        let kind = record.state.file_kind();
        let candidate = SortedDirectoryEntry {
            folded_name: name.to_lowercase(),
            directory: kind == FileKind::Directory,
            entry: DirectoryEntry { path: entry_path, name, kind, size: record.state.size },
        };
        let candidate_bytes = candidate.retained_bytes();
        if snapshot_bytes.saturating_add(candidate_bytes) > MAX_DIRECTORY_SNAPSHOT_BYTES {
            scan_truncated = true;
            break;
        }
        snapshot_bytes = snapshot_bytes.saturating_add(candidate_bytes);
        entries.push(candidate);
    }
    entries.sort_unstable_by(|left, right| {
        right
            .directory
            .cmp(&left.directory)
            .then_with(|| left.folded_name.cmp(&right.folded_name))
            .then_with(|| left.entry.name.cmp(&right.entry.name))
    });
    entries.shrink_to_fit();
    Ok(DirectoryContinuation { entries, next_index: 0, scan_truncated })
}

#[cfg(unix)]
fn file_type_bits(mode: u32) -> u32 {
    mode & normalize_stat_value::<_, u32>(libc::S_IFMT)
}

#[cfg(unix)]
fn normalize_stat_value<T, U>(value: T) -> U
where
    T: TryInto<U>,
    U: Default,
{
    value.try_into().unwrap_or_default()
}

#[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
fn raw_stat_timestamps(status: &libc::stat) -> ((i64, i64), (i64, i64)) {
    (
        (normalize_stat_value(status.st_mtime), normalize_stat_value(status.st_mtime_nsec)),
        (normalize_stat_value(status.st_ctime), normalize_stat_value(status.st_ctime_nsec)),
    )
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))))]
fn raw_stat_timestamps(_status: &libc::stat) -> ((i64, i64), (i64, i64)) {
    // The libc timestamp field names vary across less common Unix targets.
    // Guarded content mutations are rejected there, so unconditional and
    // missing-only operations do not compare these placeholder values.
    ((0, 0), (0, 0))
}

#[cfg(unix)]
fn stat_entry(
    target: &UnixWorkspaceTarget,
    operation: &str,
) -> Result<Option<RawEntryState>, RpcError> {
    stat_named(target.parent_fd(), target.name(), target.display(), operation)
}

#[cfg(unix)]
fn stat_named(
    parent: RawFd,
    name: &CStr,
    display: &Path,
    operation: &str,
) -> Result<Option<RawEntryState>, RpcError> {
    let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: `status` points to writable storage, `name` is NUL-terminated,
    // and `fstatat` initializes `status` on success.
    let result = unsafe {
        libc::fstatat(parent, name.as_ptr(), status.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW)
    };
    if result == 0 {
        // SAFETY: successful `fstatat` initialized `status`.
        let status = unsafe { status.assume_init() };
        return Ok(Some(RawEntryState::from_stat(&status)));
    }
    let error = std::io::Error::last_os_error();
    if error.kind() == std::io::ErrorKind::NotFound {
        Ok(None)
    } else {
        Err(io_error(operation, display, error))
    }
}

#[cfg(unix)]
fn non_regular_entry_error(
    target: &UnixWorkspaceTarget,
    entry: Option<&RawEntryState>,
) -> RpcError {
    if entry.is_some_and(RawEntryState::is_symlink) {
        RpcError::new(
            "symlink-not-supported",
            format!("refusing to mutate symlink: {}", target.display().display()),
        )
    } else {
        RpcError::new("not-a-file", format!("not a regular file: {}", target.display().display()))
    }
}

#[cfg(unix)]
fn partial_write_with_recovery(
    target: &UnixWorkspaceTarget,
    recovery_name: &CStr,
    reason: &str,
) -> RpcError {
    RpcError::new(
        "partial-write",
        format!(
            "{reason}; recovery entry retained at {}",
            temporary_display(target, recovery_name).display()
        ),
    )
}

#[cfg(unix)]
fn open_regular_entry(target: &UnixWorkspaceTarget, operation: &str) -> Result<File, RpcError> {
    open_regular_entry_if_present(target, operation)?.ok_or_else(|| {
        RpcError::new("not-found", format!("file not found: {}", target.display().display()))
    })
}

#[cfg(unix)]
fn open_regular_entry_if_present(
    target: &UnixWorkspaceTarget,
    operation: &str,
) -> Result<Option<File>, RpcError> {
    let Some(metadata) =
        entry_metadata_named(target.parent_fd(), target.name(), target.display(), operation)?
    else {
        return Ok(None);
    };
    if metadata.file_type().is_symlink() {
        return Err(RpcError::new(
            "symlink-not-supported",
            format!("refusing to mutate symlink: {}", target.display().display()),
        ));
    }
    if !metadata.is_file() {
        return Err(RpcError::new(
            "not-a-file",
            format!("not a regular file: {}", target.display().display()),
        ));
    }
    open_named_regular(target.parent_fd(), target.name(), target.display(), operation).map(Some)
}

#[cfg(unix)]
fn open_named_regular(
    parent: RawFd,
    name: &CStr,
    display: &Path,
    operation: &str,
) -> Result<File, RpcError> {
    // SAFETY: `parent` is a live directory descriptor, `name` is
    // NUL-terminated, and `openat` does not retain either.
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ELOOP) {
            return Err(RpcError::new(
                "symlink-not-supported",
                format!("refusing to mutate symlink: {}", display.display()),
            ));
        }
        return Err(io_error(operation, display, error));
    }
    // SAFETY: `openat` returned a new owned descriptor.
    let file = unsafe { File::from_raw_fd(fd) };
    let metadata = file.metadata().map_err(|error| io_error(operation, display, error))?;
    if !metadata.is_file() {
        return Err(RpcError::new(
            "not-a-file",
            format!("not a regular file: {}", display.display()),
        ));
    }
    Ok(file)
}

#[cfg(unix)]
fn entry_metadata_named(
    parent: RawFd,
    name: &CStr,
    display: &Path,
    operation: &str,
) -> Result<Option<std::fs::Metadata>, RpcError> {
    // `fstatat` cannot construct `std::fs::Metadata`, so open the entry after
    // checking its no-follow type. The second no-follow open closes the race.
    let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: `status` points to writable storage, `name` is NUL-terminated,
    // and `fstatat` initializes `status` on success.
    let result = unsafe {
        libc::fstatat(parent, name.as_ptr(), status.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW)
    };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        if error.kind() == std::io::ErrorKind::NotFound {
            return Ok(None);
        }
        return Err(io_error(operation, display, error));
    }
    // SAFETY: successful `fstatat` initialized `status`.
    let status = unsafe { status.assume_init() };
    let file_type = status.st_mode & libc::S_IFMT;
    if file_type == libc::S_IFLNK {
        return Err(RpcError::new(
            "symlink-not-supported",
            format!("refusing to mutate symlink: {}", display.display()),
        ));
    }
    if file_type != libc::S_IFREG {
        return Err(RpcError::new(
            "not-a-file",
            format!("not a regular file: {}", display.display()),
        ));
    }
    let file = open_named_regular(parent, name, display, operation)?;
    file.metadata().map(Some).map_err(|error| io_error(operation, display, error))
}

#[cfg(unix)]
fn create_temporary(
    target: &UnixWorkspaceTarget,
    prefix: &str,
) -> Result<(CString, File), RpcError> {
    for _ in 0..16 {
        let name = unique_name(&format!(".cmux-{prefix}"))?;
        // SAFETY: `target` owns the directory descriptor, `name` is
        // NUL-terminated, and `openat` does not retain either.
        let fd = unsafe {
            libc::openat(
                target.parent_fd(),
                name.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o600,
            )
        };
        if fd >= 0 {
            // SAFETY: `openat` returned a new owned descriptor.
            return Ok((name, unsafe { File::from_raw_fd(fd) }));
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::AlreadyExists {
            return Err(io_error("create-temporary", target.parent_display(), error));
        }
    }
    Err(RpcError::new("resource-exhausted", "could not allocate a unique workspace temporary file"))
}

#[cfg(unix)]
fn unique_name(prefix: &str) -> Result<CString, RpcError> {
    CString::new(format!("{prefix}-{}", uuid::Uuid::new_v4()))
        .map_err(|_| RpcError::new("internal", "temporary file name contains a NUL byte"))
}

#[cfg(unix)]
fn temporary_display(target: &UnixWorkspaceTarget, name: &CStr) -> PathBuf {
    target.parent_display().join(name.to_string_lossy().as_ref())
}

#[cfg(unix)]
fn read_file_bounded_sync(
    file: &mut File,
    display: &Path,
    maximum: usize,
) -> Result<(Vec<u8>, std::fs::Metadata), RpcError> {
    use std::io::{Read as _, Seek as _};

    let metadata = file.metadata().map_err(|error| io_error("read", display, error))?;
    if metadata.len() > maximum as u64 {
        return Err(RpcError::new("resource-exhausted", format!("file exceeds {maximum} bytes")));
    }
    file.seek(std::io::SeekFrom::Start(0)).map_err(|error| io_error("read", display, error))?;
    let capacity = usize::try_from(metadata.len()).unwrap_or(maximum).min(maximum);
    let mut bytes = Vec::with_capacity(capacity);
    (&mut *file)
        .take((maximum as u64).saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| io_error("read", display, error))?;
    if bytes.len() > maximum {
        return Err(RpcError::new("resource-exhausted", format!("file exceeds {maximum} bytes")));
    }
    let metadata_after = file.metadata().map_err(|error| io_error("read", display, error))?;
    if !metadata_stable(&metadata, &metadata_after)
        || u64::try_from(bytes.len()).unwrap_or(u64::MAX) != metadata.len()
    {
        return Err(RpcError::new("file-changed", "file changed while it was being read"));
    }
    Ok((bytes, metadata_after))
}

#[cfg(unix)]
fn hash_file_sync(
    file: &mut File,
    display: &Path,
    maximum: u64,
) -> Result<(String, std::fs::Metadata), RpcError> {
    use std::io::{Read as _, Seek as _};

    let metadata = file.metadata().map_err(|error| io_error("hash", display, error))?;
    if metadata.len() > maximum {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("file exceeds the {maximum}-byte integrity limit"),
        ));
    }
    file.seek(std::io::SeekFrom::Start(0)).map_err(|error| io_error("hash", display, error))?;
    let mut remaining = metadata.len();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut digest = Sha256::new();
    while remaining > 0 {
        let requested = usize::try_from(remaining.min(buffer.len() as u64)).unwrap_or(buffer.len());
        let read = file
            .read(&mut buffer[..requested])
            .map_err(|error| io_error("hash", display, error))?;
        if read == 0 {
            return Err(RpcError::new("file-changed", "file changed while it was being hashed"));
        }
        digest.update(&buffer[..read]);
        remaining = remaining.saturating_sub(read as u64);
    }
    let metadata_after = file.metadata().map_err(|error| io_error("hash", display, error))?;
    if !metadata_stable(&metadata, &metadata_after) {
        return Err(RpcError::new("file-changed", "file changed while it was being hashed"));
    }
    Ok((hex_digest(&digest.finalize()), metadata_after))
}

#[cfg(unix)]
fn link_name(parent: RawFd, source: &CStr, target: &CStr) -> Result<(), std::io::Error> {
    // SAFETY: both names are NUL-terminated and relative to the live
    // `parent` descriptor. `linkat` does not retain the pointers.
    if unsafe { libc::linkat(parent, source.as_ptr(), parent, target.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(unix)]
fn unlink_name(parent: RawFd, name: &CStr) -> Result<(), std::io::Error> {
    // SAFETY: `name` is NUL-terminated and relative to the live `parent`
    // descriptor. `unlinkat` does not retain the pointer.
    if unsafe { libc::unlinkat(parent, name.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(unix)]
fn unlink_unpublished_name(
    target: &UnixWorkspaceTarget,
    name: &CStr,
) -> Result<(), std::io::Error> {
    unlink_name(target.parent_fd(), name)
}

#[cfg(unix)]
fn unlink_published_name(target: &UnixWorkspaceTarget, name: &CStr) -> Result<(), std::io::Error> {
    unlink_name(target.parent_fd(), name)
}

#[cfg(unix)]
fn sync_committed_parent(target: &UnixWorkspaceTarget) -> Result<(), RpcError> {
    target.sync_parent().map_err(|error| {
        RpcError::new(
            "committed-not-durable",
            format!(
                "workspace mutation committed but directory sync failed at {}: {}",
                target.parent_display().display(),
                error.message
            ),
        )
    })
}

#[cfg(unix)]
fn sync_rollback_parent(target: &UnixWorkspaceTarget) -> Result<(), RpcError> {
    target.sync_parent().map_err(|error| {
        RpcError::new(
            "rollback-not-durable",
            format!(
                "workspace mutation was restored but directory sync failed at {}: {}",
                target.parent_display().display(),
                error.message
            ),
        )
    })
}

#[cfg(unix)]
fn rename_name(parent: RawFd, source: &CStr, target: &CStr) -> Result<(), std::io::Error> {
    // SAFETY: both names are NUL-terminated and relative to the live
    // `parent` descriptor. `renameat` does not retain the pointers.
    if unsafe { libc::renameat(parent, source.as_ptr(), parent, target.as_ptr()) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn exchange_names(parent: RawFd, left: &CStr, right: &CStr) -> Result<(), std::io::Error> {
    // SAFETY: both names are NUL-terminated and relative to the live
    // descriptor. The syscall does not retain the pointers. Calling it
    // directly avoids a dependency on the glibc `renameat2` wrapper.
    if unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            parent,
            left.as_ptr(),
            parent,
            right.as_ptr(),
            libc::RENAME_EXCHANGE,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(unix)]
fn exchange_guarded_write(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
) -> Result<(), std::io::Error> {
    exchange_names(target.parent_fd(), temporary_name, target.name())
}

#[cfg(unix)]
fn exchange_rollback(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
) -> Result<(), std::io::Error> {
    exchange_names(target.parent_fd(), temporary_name, target.name())
}

#[cfg(target_vendor = "apple")]
fn exchange_names(parent: RawFd, left: &CStr, right: &CStr) -> Result<(), std::io::Error> {
    // SAFETY: both names are NUL-terminated and relative to the live
    // descriptor. `renameatx_np` does not retain the pointers.
    if unsafe {
        libc::renameatx_np(parent, left.as_ptr(), parent, right.as_ptr(), libc::RENAME_SWAP)
    } == 0
    {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))))]
fn exchange_names(_parent: RawFd, _left: &CStr, _right: &CStr) -> Result<(), std::io::Error> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "atomic file exchange is unavailable on this platform",
    ))
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn rename_noreplace(parent: RawFd, source: &CStr, target: &CStr) -> Result<(), std::io::Error> {
    // SAFETY: both names are NUL-terminated and relative to the live
    // descriptor. The syscall does not retain the pointers. Calling it
    // directly avoids a dependency on the glibc `renameat2` wrapper.
    if unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            parent,
            source.as_ptr(),
            parent,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    } == 0
    {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(target_vendor = "apple")]
fn rename_noreplace(parent: RawFd, source: &CStr, target: &CStr) -> Result<(), std::io::Error> {
    // SAFETY: both names are NUL-terminated and relative to the live
    // descriptor. `renameatx_np` does not retain the pointers.
    if unsafe {
        libc::renameatx_np(parent, source.as_ptr(), parent, target.as_ptr(), libc::RENAME_EXCL)
    } == 0
    {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(all(unix, not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))))]
fn rename_noreplace(_parent: RawFd, _source: &CStr, _target: &CStr) -> Result<(), std::io::Error> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "atomic no-replace rename is unavailable on this platform",
    ))
}

#[cfg(unix)]
fn exchange_error(path: &Path, error: std::io::Error) -> RpcError {
    let unsupported = matches!(
        error.raw_os_error(),
        Some(code) if code == libc::ENOTSUP || code == libc::EINVAL
    );
    if error.kind() == std::io::ErrorKind::Unsupported || unsupported {
        return RpcError::new(
            "unsupported-filesystem",
            format!("filesystem does not support atomic file exchange: {}", path.display()),
        );
    }
    io_error("replace", path, error)
}

#[cfg(unix)]
fn rename_noreplace_error(path: &Path, error: std::io::Error) -> RpcError {
    let unsupported = matches!(
        error.raw_os_error(),
        Some(code) if code == libc::ENOTSUP || code == libc::EINVAL
    );
    if error.kind() == std::io::ErrorKind::Unsupported || unsupported {
        return RpcError::new(
            "unsupported-filesystem",
            format!("filesystem does not support atomic guarded removal: {}", path.display()),
        );
    }
    io_error("remove", path, error)
}

#[cfg(unix)]
fn blocking_task_error(error: tokio::task::JoinError) -> RpcError {
    RpcError::new("internal", format!("workspace file task failed: {error}"))
}

#[cfg(not(unix))]
pub(crate) async fn hash_path(path: &Path, maximum: u64) -> Result<String, RpcError> {
    let mut file =
        tokio::fs::File::open(path).await.map_err(|error| io_error("hash", path, error))?;
    let metadata = file.metadata().await.map_err(|error| io_error("hash", path, error))?;
    if metadata.len() > maximum {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("file exceeds the {maximum}-byte integrity limit"),
        ));
    }
    let digest = hash_file(&mut file, metadata.len()).await?;
    let metadata_after = file.metadata().await.map_err(|error| io_error("hash", path, error))?;
    if !metadata_stable(&metadata, &metadata_after) {
        return Err(RpcError::new("file-changed", "file changed while it was being hashed"));
    }
    Ok(digest)
}

#[cfg(not(unix))]
async fn read_path_bounded(path: &Path, maximum: usize) -> Result<Vec<u8>, RpcError> {
    let mut file =
        tokio::fs::File::open(path).await.map_err(|error| io_error("read", path, error))?;
    read_open_file_bounded(&mut file, path, maximum).await
}

async fn read_open_file_bounded(
    file: &mut tokio::fs::File,
    path: &Path,
    maximum: usize,
) -> Result<Vec<u8>, RpcError> {
    let metadata = file.metadata().await.map_err(|error| io_error("read", path, error))?;
    if !metadata.is_file() {
        return Err(RpcError::new("not-a-file", format!("not a file: {}", path.display())));
    }
    if metadata.len() > maximum as u64 {
        return Err(RpcError::new("resource-exhausted", format!("file exceeds {maximum} bytes")));
    }
    let capacity = usize::try_from(metadata.len()).unwrap_or(maximum).min(maximum);
    let mut bytes = Vec::with_capacity(capacity);
    (&mut *file)
        .take((maximum as u64).saturating_add(1))
        .read_to_end(&mut bytes)
        .await
        .map_err(|error| io_error("read", path, error))?;
    if bytes.len() > maximum {
        return Err(RpcError::new("resource-exhausted", format!("file exceeds {maximum} bytes")));
    }
    let metadata_after = file.metadata().await.map_err(|error| io_error("read", path, error))?;
    if !metadata_stable(&metadata, &metadata_after)
        || u64::try_from(bytes.len()).unwrap_or(u64::MAX) != metadata.len()
    {
        return Err(RpcError::new("file-changed", "file changed while it was being read"));
    }
    Ok(bytes)
}

fn validate_content_hash(hash: &str) -> Result<(), RpcError> {
    if hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(RpcError::new(
            "invalid-precondition",
            "content hash must be a 64-character SHA-256 digest",
        ))
    }
}

async fn hash_file(file: &mut tokio::fs::File, length: u64) -> Result<String, RpcError> {
    file.seek(std::io::SeekFrom::Start(0))
        .await
        .map_err(|error| RpcError::new("io-error", format!("seek before hashing: {error}")))?;
    let mut remaining = length;
    let mut buffer = vec![0u8; 64 * 1024];
    let mut digest = Sha256::new();
    while remaining > 0 {
        let requested = usize::try_from(remaining.min(buffer.len() as u64)).unwrap_or(buffer.len());
        let read = file
            .read(&mut buffer[..requested])
            .await
            .map_err(|error| RpcError::new("io-error", format!("read while hashing: {error}")))?;
        if read == 0 {
            return Err(RpcError::new("file-changed", "file changed while it was being hashed"));
        }
        digest.update(&buffer[..read]);
        remaining = remaining.saturating_sub(read as u64);
    }
    Ok(hex_digest(&digest.finalize()))
}

pub(crate) fn hash_bytes(bytes: &[u8]) -> String {
    hex_digest(&Sha256::digest(bytes))
}

fn hex_digest(bytes: &[u8]) -> String {
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[cfg(not(unix))]
fn file_kind(metadata: &std::fs::Metadata) -> FileKind {
    let kind = metadata.file_type();
    if kind.is_symlink() {
        FileKind::Symlink
    } else if kind.is_file() {
        FileKind::File
    } else if kind.is_dir() {
        FileKind::Directory
    } else {
        FileKind::Other
    }
}

#[cfg(unix)]
fn metadata_stable(before: &std::fs::Metadata, after: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt as _;
    before.dev() == after.dev()
        && before.ino() == after.ino()
        && before.mode() == after.mode()
        && before.len() == after.len()
        && before.mtime() == after.mtime()
        && before.mtime_nsec() == after.mtime_nsec()
        && before.ctime() == after.ctime()
        && before.ctime_nsec() == after.ctime_nsec()
}

#[cfg(not(unix))]
fn metadata_stable(before: &std::fs::Metadata, after: &std::fs::Metadata) -> bool {
    before.len() == after.len() && before.modified().ok() == after.modified().ok()
}

#[cfg(not(unix))]
fn is_executable(_metadata: &std::fs::Metadata) -> bool {
    false
}

#[cfg(not(unix))]
async fn sync_parent(_parent: &Path) -> Result<(), RpcError> {
    Ok(())
}

#[cfg(windows)]
async fn replace_file(temporary: &Path, target: &Path) -> Result<(), RpcError> {
    if tokio::fs::try_exists(target).await.map_err(|error| io_error("replace", target, error))? {
        tokio::fs::remove_file(target).await.map_err(|error| io_error("replace", target, error))?;
    }
    tokio::fs::rename(temporary, target).await.map_err(|error| io_error("replace", target, error))
}

fn page_scope(parts: &[&str]) -> String {
    let mut digest = Sha256::new();
    for part in parts {
        digest.update(u64::try_from(part.len()).unwrap_or(u64::MAX).to_be_bytes());
        digest.update(part.as_bytes());
    }
    hex_digest(&digest.finalize())
}
