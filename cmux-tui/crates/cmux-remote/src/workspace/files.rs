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

    #[cfg(test)]
    pub(super) fn for_test() -> Self {
        Self { entries: Vec::new(), next_index: 0, scan_truncated: false }
    }
}

#[derive(Clone)]
struct SearchQueueEntry {
    path: PathBuf,
    protocol_path: String,
}

impl SearchQueueEntry {
    fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            .saturating_add(self.path.as_os_str().len())
            .saturating_add(self.protocol_path.capacity())
            .saturating_add(64)
    }
}

#[derive(Clone, Copy)]
struct SearchFilePosition {
    line_start: usize,
    line_number: u64,
    match_offset: usize,
    previous_line: Option<(usize, usize)>,
}

#[derive(Clone)]
struct SearchFileContinuation {
    protocol_path: String,
    text: String,
    position: SearchFilePosition,
}

impl SearchFileContinuation {
    fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            .saturating_add(self.protocol_path.capacity())
            .saturating_add(self.text.capacity())
            .saturating_add(64)
    }

    fn next_match(&mut self, query: &str) -> Option<SearchMatch> {
        loop {
            let (line_end, next_line_start) =
                search_line_bounds(&self.text, self.position.line_start)?;
            let line = &self.text[self.position.line_start..line_end];
            if let Some(found) = line[self.position.match_offset..].find(query) {
                let column = self.position.match_offset.saturating_add(found);
                self.position.match_offset = column.saturating_add(query.len());
                let before = self
                    .position
                    .previous_line
                    .map(|(start, end)| vec![self.text[start..end].to_string()])
                    .unwrap_or_default();
                let after = search_line_bounds(&self.text, next_line_start)
                    .map(|(end, _)| vec![self.text[next_line_start..end].to_string()])
                    .unwrap_or_default();
                return Some(SearchMatch {
                    path: self.protocol_path.clone(),
                    line: self.position.line_number,
                    column: u64::try_from(column.saturating_add(1)).unwrap_or(u64::MAX),
                    text: line.to_string(),
                    before,
                    after,
                });
            }
            self.position.previous_line = Some((self.position.line_start, line_end));
            self.position.line_start = next_line_start;
            self.position.line_number = self.position.line_number.saturating_add(1);
            self.position.match_offset = 0;
        }
    }
}

#[derive(Clone)]
pub(super) struct SearchContinuation {
    queue: VecDeque<SearchQueueEntry>,
    queue_bytes: usize,
    visited: HashSet<PathBuf>,
    visited_bytes: usize,
    current_file: Option<SearchFileContinuation>,
    directory_count: usize,
    entry_count: usize,
    total_bytes: u64,
    discovery_truncated: bool,
}

impl SearchContinuation {
    fn new() -> Self {
        Self {
            queue: VecDeque::new(),
            queue_bytes: 0,
            visited: HashSet::new(),
            visited_bytes: 0,
            current_file: None,
            directory_count: 0,
            entry_count: 0,
            total_bytes: 0,
            discovery_truncated: false,
        }
    }

    fn path_state_bytes(&self) -> usize {
        self.queue_bytes
            .saturating_add(self.visited_bytes)
            .saturating_add(self.visited.capacity().saturating_mul(size_of::<PathBuf>()))
    }

    pub(super) fn retained_bytes(&self) -> usize {
        size_of::<Self>().saturating_add(self.path_state_bytes()).saturating_add(
            self.current_file.as_ref().map_or(0, SearchFileContinuation::retained_bytes),
        )
    }

    fn enqueue(&mut self, entry: SearchQueueEntry) -> bool {
        let charge = entry.retained_bytes();
        if self.path_state_bytes().saturating_add(charge) > MAX_SEARCH_PATH_STATE_BYTES {
            return false;
        }
        self.queue_bytes = self.queue_bytes.saturating_add(charge);
        self.queue.push_back(entry);
        true
    }

    fn pop_front(&mut self) -> Option<SearchQueueEntry> {
        let entry = self.queue.pop_front()?;
        self.queue_bytes = self.queue_bytes.saturating_sub(entry.retained_bytes());
        Some(entry)
    }

    fn clear_queue(&mut self) {
        self.queue.clear();
        self.queue_bytes = 0;
    }

    fn remember_visited(&mut self, path: PathBuf) {
        self.visited_bytes = self
            .visited_bytes
            .saturating_add(path.as_os_str().len())
            .saturating_add(size_of::<PathBuf>())
            .saturating_add(64);
        self.visited.insert(path);
    }
}

fn search_line_bounds(text: &str, start: usize) -> Option<(usize, usize)> {
    if start >= text.len() {
        return None;
    }
    let remaining = &text.as_bytes()[start..];
    let Some(relative_newline) = remaining.iter().position(|byte| *byte == b'\n') else {
        return Some((text.len(), text.len()));
    };
    let raw_end = start.saturating_add(relative_newline);
    let content_end = if raw_end > start && text.as_bytes()[raw_end - 1] == b'\r' {
        raw_end - 1
    } else {
        raw_end
    };
    Some((content_end, raw_end.saturating_add(1)))
}

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum MutationTestPoint {
    AfterDirectoryMetadata,
    AfterProcessCwdResolve,
    AfterReadResolve,
    AfterSearchMetadata,
    AfterStatResolve,
    AfterPrecondition,
    AfterTemporaryCreate,
    BeforeContentHashValidation,
    BeforeContentHashExchange,
    AfterContentHashExchange,
    BeforeContentHashRemoveRename,
}

#[cfg(test)]
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct MutationTestKey {
    target: PathBuf,
    point: MutationTestPoint,
}

#[cfg(test)]
#[derive(Debug)]
struct MutationTestHook {
    reached: tokio::sync::Notify,
    resume: tokio::sync::Notify,
    blocking_resumed: std::sync::Mutex<bool>,
    blocking_resume: std::sync::Condvar,
}

#[cfg(test)]
fn mutation_test_hooks() -> &'static std::sync::Mutex<
    std::collections::HashMap<MutationTestKey, std::sync::Arc<MutationTestHook>>,
> {
    static HOOKS: std::sync::OnceLock<
        std::sync::Mutex<
            std::collections::HashMap<MutationTestKey, std::sync::Arc<MutationTestHook>>,
        >,
    > = std::sync::OnceLock::new();
    HOOKS.get_or_init(|| std::sync::Mutex::new(std::collections::HashMap::new()))
}

#[cfg(test)]
pub(crate) struct MutationTestBarrier {
    key: MutationTestKey,
    hook: std::sync::Arc<MutationTestHook>,
}

#[cfg(test)]
impl MutationTestBarrier {
    pub(crate) async fn wait_until_reached(&self) {
        self.hook.reached.notified().await;
    }

    pub(crate) fn resume(&self) {
        *self.hook.blocking_resumed.lock().unwrap_or_else(|error| error.into_inner()) = true;
        self.hook.blocking_resume.notify_all();
        self.hook.resume.notify_one();
    }
}

#[cfg(test)]
impl Drop for MutationTestBarrier {
    fn drop(&mut self) {
        let mut hooks = mutation_test_hooks().lock().unwrap_or_else(|error| error.into_inner());
        if hooks.get(&self.key).is_some_and(|hook| std::sync::Arc::ptr_eq(hook, &self.hook)) {
            hooks.remove(&self.key);
        }
        *self.hook.blocking_resumed.lock().unwrap_or_else(|error| error.into_inner()) = true;
        self.hook.blocking_resume.notify_all();
        self.hook.resume.notify_waiters();
    }
}

#[cfg(test)]
pub(crate) fn install_mutation_test_barrier(
    root: &WorkspaceRoot,
    path: &str,
    point: MutationTestPoint,
) -> MutationTestBarrier {
    let relative = validate_relative(path).expect("test mutation paths are valid");
    let key = MutationTestKey { target: root.canonical_root().join(relative), point };
    let hook = std::sync::Arc::new(MutationTestHook {
        reached: tokio::sync::Notify::new(),
        resume: tokio::sync::Notify::new(),
        blocking_resumed: std::sync::Mutex::new(false),
        blocking_resume: std::sync::Condvar::new(),
    });
    let previous = mutation_test_hooks()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .insert(key.clone(), std::sync::Arc::clone(&hook));
    assert!(previous.is_none(), "mutation test barrier already installed for {path}");
    MutationTestBarrier { key, hook }
}

#[cfg(test)]
pub(crate) async fn pause_at_mutation_test_barrier(
    root: &WorkspaceRoot,
    path: &str,
    point: MutationTestPoint,
) {
    let relative = validate_relative(path).expect("test mutation paths are valid");
    let key = MutationTestKey { target: root.canonical_root().join(relative), point };
    let hook =
        mutation_test_hooks().lock().unwrap_or_else(|error| error.into_inner()).get(&key).cloned();
    if let Some(hook) = hook {
        hook.reached.notify_one();
        hook.resume.notified().await;
    }
}

#[cfg(test)]
fn pause_at_mutation_test_barrier_blocking(target: &Path, point: MutationTestPoint) {
    let key = MutationTestKey { target: target.to_owned(), point };
    let hook =
        mutation_test_hooks().lock().unwrap_or_else(|error| error.into_inner()).get(&key).cloned();
    if let Some(hook) = hook {
        hook.reached.notify_one();
        let mut resumed = hook.blocking_resumed.lock().unwrap_or_else(|error| error.into_inner());
        while !*resumed {
            resumed = hook.blocking_resume.wait(resumed).unwrap_or_else(|error| error.into_inner());
        }
    }
}

#[cfg(all(test, unix))]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum MutationTestFault {
    CommitSync,
    ExchangeUnsupported,
    PrePublishHash,
    PrePublishStat,
    RollbackExchange,
    RollbackSync,
    UnpublishedCleanup,
    PublishedCleanup,
}

#[cfg(all(test, unix))]
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct MutationTestFaultKey {
    target: PathBuf,
    fault: MutationTestFault,
}

#[cfg(all(test, unix))]
type MutationTestFaults = std::sync::Mutex<HashSet<MutationTestFaultKey>>;

#[cfg(all(test, unix))]
fn mutation_test_faults() -> &'static MutationTestFaults {
    static FAULTS: std::sync::OnceLock<MutationTestFaults> = std::sync::OnceLock::new();
    FAULTS.get_or_init(|| std::sync::Mutex::new(HashSet::new()))
}

#[cfg(all(test, unix))]
pub(crate) struct MutationTestFaultGuard {
    key: MutationTestFaultKey,
}

#[cfg(all(test, unix))]
impl Drop for MutationTestFaultGuard {
    fn drop(&mut self) {
        mutation_test_faults().lock().unwrap_or_else(|error| error.into_inner()).remove(&self.key);
    }
}

#[cfg(all(test, unix))]
pub(crate) fn install_mutation_test_fault(
    root: &WorkspaceRoot,
    path: &str,
    fault: MutationTestFault,
) -> MutationTestFaultGuard {
    let relative = validate_relative(path).expect("test mutation paths are valid");
    let key = MutationTestFaultKey { target: root.canonical_root().join(relative), fault };
    assert!(
        mutation_test_faults()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .insert(key.clone()),
        "mutation test fault already installed"
    );
    MutationTestFaultGuard { key }
}

#[cfg(all(test, unix))]
fn mutation_test_fault(target: &Path, fault: MutationTestFault) -> bool {
    mutation_test_faults()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .remove(&MutationTestFaultKey { target: target.to_owned(), fault })
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
    #[cfg(test)]
    pause_at_mutation_test_barrier(root, path, MutationTestPoint::AfterStatResolve).await;
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
    #[cfg(test)]
    pause_at_mutation_test_barrier(root, path, MutationTestPoint::AfterReadResolve).await;
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
    #[cfg(test)]
    pause_at_mutation_test_barrier(root, path, MutationTestPoint::AfterDirectoryMetadata).await;

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

pub(crate) async fn search(
    context: &WorkspaceQueryContext<'_>,
    query: &str,
    paths: &[String],
    globs: &[String],
    include_hidden: bool,
    max_results: u32,
    cursor: Option<&PageCursor>,
) -> Result<PreparedWorkspaceResponse, RpcError> {
    if query.is_empty() {
        return Err(RpcError::new("invalid-argument", "search query cannot be empty"));
    }
    if query.len() > MAX_SEARCH_QUERY_BYTES {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("search query exceeds {MAX_SEARCH_QUERY_BYTES} bytes"),
        ));
    }
    if paths.len() > MAX_SEARCH_PATHS || globs.len() > MAX_SEARCH_GLOBS {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("search accepts at most {MAX_SEARCH_PATHS} paths and {MAX_SEARCH_GLOBS} globs"),
        ));
    }
    let argument_bytes = paths
        .iter()
        .chain(globs)
        .fold(query.len(), |total, value| total.saturating_add(value.len()));
    if argument_bytes > MAX_SEARCH_ARGUMENT_BYTES {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("search arguments exceed {MAX_SEARCH_ARGUMENT_BYTES} bytes"),
        ));
    }
    if max_results > MAX_SEARCH_RESULTS {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("search result limit exceeds {MAX_SEARCH_RESULTS}"),
        ));
    }
    if max_results == 0 {
        return Ok(PreparedWorkspaceResponse::plain(WorkspaceResponse::Search {
            matches: Vec::new(),
            truncated: false,
            next_cursor: None,
        }));
    }
    for glob in globs {
        if glob.contains('\0') {
            return Err(RpcError::new("invalid-argument", "search glob contains a NUL byte"));
        }
    }

    let requested_paths = if paths.is_empty() { vec![String::new()] } else { paths.to_vec() };
    let mut requested_paths = requested_paths
        .into_iter()
        .map(|path| normalize_protocol_path(&path).map(|normalized| (path, normalized)))
        .collect::<Result<Vec<_>, _>>()?;
    requested_paths.sort_by(|left, right| left.1.cmp(&right.1));
    requested_paths.dedup_by(|left, right| left.1 == right.1);
    let cursor_scope = search_page_scope(query, &requested_paths, globs, include_hidden);
    let (mut continuation, mut delivery) = if let Some(cursor) = cursor {
        let (continuation, delivery) =
            context.service.lease_search(context.owner, &context.root.id, &cursor_scope, cursor)?;
        (continuation, Some(delivery))
    } else {
        (initialize_search(context.root, requested_paths).await?, None)
    };

    let mut matches = Vec::new();
    let mut response_bytes = 0usize;
    loop {
        if matches.len() >= max_results as usize {
            let current_file_exhausted = continuation.queue.is_empty()
                && continuation.current_file.as_mut().is_some_and(|file| {
                    let checkpoint = file.position;
                    let exhausted = file.next_match(query).is_none();
                    if !exhausted {
                        file.position = checkpoint;
                    }
                    exhausted
                });
            if current_file_exhausted {
                continuation.current_file = None;
            }
            break;
        }
        if let Some(file) = continuation.current_file.as_mut() {
            let checkpoint = file.position;
            if let Some(candidate) = file.next_match(query) {
                let candidate_bytes = search_match_retained_bytes(&candidate);
                if response_bytes.saturating_add(candidate_bytes) > MAX_SEARCH_RESPONSE_BYTES {
                    file.position = checkpoint;
                    if matches.is_empty() {
                        return Err(RpcError::new(
                            "resource-exhausted",
                            format!(
                                "one search match exceeds the {MAX_SEARCH_RESPONSE_BYTES}-byte response limit"
                            ),
                        ));
                    }
                    break;
                }
                response_bytes = response_bytes.saturating_add(candidate_bytes);
                matches.push(candidate);
                continue;
            }
            continuation.current_file = None;
            continue;
        }

        let Some(entry) = continuation.pop_front() else {
            break;
        };
        if continuation.visited.contains(&entry.path) {
            continue;
        }
        #[cfg(unix)]
        {
            let unix_root = context.root.unix_root();
            let canonical = entry.path.clone();
            let is_root = canonical == context.root.canonical_root();
            let prepared = tokio::task::spawn_blocking(move || {
                prepare_unix_search_entry(unix_root, canonical, is_root)
            })
            .await
            .map_err(blocking_task_error)??;
            #[cfg(test)]
            pause_at_mutation_test_barrier(
                context.root,
                &entry.protocol_path,
                MutationTestPoint::AfterSearchMetadata,
            )
            .await;
            continuation.remember_visited(entry.path.clone());
            match prepared {
                PreparedUnixSearchEntry::Directory(directory) => {
                    scan_unix_search_directory(
                        &mut continuation,
                        &entry,
                        directory,
                        include_hidden,
                    )
                    .await?;
                    continue;
                }
                PreparedUnixSearchEntry::File { target, file, metadata } => {
                    if metadata.len() > MAX_SEARCH_FILE_BYTES
                        || !matches_globs(&entry.protocol_path, globs)
                    {
                        continue;
                    }
                    if continuation.total_bytes.saturating_add(metadata.len())
                        > MAX_SEARCH_TOTAL_BYTES
                    {
                        continuation.discovery_truncated = true;
                        continuation.clear_queue();
                        break;
                    }
                    continuation.total_bytes =
                        continuation.total_bytes.saturating_add(metadata.len());
                    let mut file = tokio::fs::File::from_std(file);
                    let bytes = read_open_file_bounded(
                        &mut file,
                        &entry.path,
                        MAX_SEARCH_FILE_BYTES as usize,
                    )
                    .await?;
                    tokio::task::spawn_blocking(move || target.verify_parent_identity())
                        .await
                        .map_err(blocking_task_error)??;
                    if bytes.contains(&0) {
                        continue;
                    }
                    let Ok(text) = String::from_utf8(bytes) else { continue };
                    continuation.current_file = Some(SearchFileContinuation {
                        protocol_path: entry.protocol_path,
                        text,
                        position: SearchFilePosition {
                            line_start: 0,
                            line_number: 1,
                            match_offset: 0,
                            previous_line: None,
                        },
                    });
                }
                PreparedUnixSearchEntry::Other => continue,
            }
        }
        #[cfg(not(unix))]
        {
            let metadata = tokio::fs::symlink_metadata(&entry.path)
                .await
                .map_err(|error| io_error("search", &entry.path, error))?;
            #[cfg(test)]
            pause_at_mutation_test_barrier(
                context.root,
                &entry.protocol_path,
                MutationTestPoint::AfterSearchMetadata,
            )
            .await;
            continuation.remember_visited(entry.path.clone());
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                continuation.directory_count = continuation.directory_count.saturating_add(1);
                if continuation.directory_count > MAX_SEARCH_DIRECTORIES {
                    continuation.discovery_truncated = true;
                    continue;
                }
                if continuation.discovery_truncated {
                    continue;
                }
                let mut reader = tokio::fs::read_dir(&entry.path)
                    .await
                    .map_err(|error| io_error("search", &entry.path, error))?;
                let mut children = Vec::new();
                let mut children_bytes = 0usize;
                while let Some(child) = reader
                    .next_entry()
                    .await
                    .map_err(|error| io_error("search", &entry.path, error))?
                {
                    continuation.entry_count = continuation.entry_count.saturating_add(1);
                    if continuation.entry_count > MAX_SEARCH_ENTRIES {
                        continuation.discovery_truncated = true;
                        break;
                    }
                    let Ok(name) = child.file_name().into_string() else { continue };
                    if !include_hidden && name.starts_with('.') {
                        continue;
                    }
                    let Ok(child_protocol) = join_protocol_path(&entry.protocol_path, &name) else {
                        continue;
                    };
                    let child =
                        SearchQueueEntry { path: child.path(), protocol_path: child_protocol };
                    let child_bytes = child.retained_bytes();
                    if continuation
                        .path_state_bytes()
                        .saturating_add(children_bytes)
                        .saturating_add(child_bytes)
                        > MAX_SEARCH_PATH_STATE_BYTES
                    {
                        continuation.discovery_truncated = true;
                        break;
                    }
                    children_bytes = children_bytes.saturating_add(child_bytes);
                    children.push(child);
                }
                children
                    .sort_unstable_by(|left, right| left.protocol_path.cmp(&right.protocol_path));
                for child in children {
                    if !continuation.enqueue(child) {
                        continuation.discovery_truncated = true;
                        break;
                    }
                }
                continue;
            }
            if !metadata.is_file()
                || metadata.len() > MAX_SEARCH_FILE_BYTES
                || !matches_globs(&entry.protocol_path, globs)
            {
                continue;
            }
            if continuation.total_bytes.saturating_add(metadata.len()) > MAX_SEARCH_TOTAL_BYTES {
                continuation.discovery_truncated = true;
                continuation.clear_queue();
                break;
            }
            continuation.total_bytes = continuation.total_bytes.saturating_add(metadata.len());
            let bytes = read_path_bounded(&entry.path, MAX_SEARCH_FILE_BYTES as usize).await?;
            if bytes.contains(&0) {
                continue;
            }
            let Ok(text) = String::from_utf8(bytes) else { continue };
            continuation.current_file = Some(SearchFileContinuation {
                protocol_path: entry.protocol_path,
                text,
                position: SearchFilePosition {
                    line_start: 0,
                    line_number: 1,
                    match_offset: 0,
                    previous_line: None,
                },
            });
        }
        if continuation.retained_bytes() > MAX_SEARCH_STATE_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("search continuation exceeds {MAX_SEARCH_STATE_BYTES} retained bytes"),
            ));
        }
    }

    let has_more = continuation.current_file.is_some() || !continuation.queue.is_empty();
    let discovery_truncated = continuation.discovery_truncated;
    let next_cursor = if has_more {
        if continuation.retained_bytes() > MAX_SEARCH_STATE_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("search continuation exceeds {MAX_SEARCH_STATE_BYTES} retained bytes"),
            ));
        }
        let (next, next_delivery) = context.service.put_search(
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
        WorkspaceResponse::Search {
            matches,
            truncated: discovery_truncated || next_cursor.is_some(),
            next_cursor,
        },
        delivery,
    ))
}

async fn initialize_search(
    root: &WorkspaceRoot,
    requested_paths: Vec<(String, String)>,
) -> Result<SearchContinuation, RpcError> {
    let mut continuation = SearchContinuation::new();
    for (path, normalized) in requested_paths {
        let resolved = root.resolve_existing(&path).await?;
        #[cfg(unix)]
        {
            let unix_root = root.unix_root();
            let canonical = resolved.clone();
            let is_root = canonical == root.canonical_root();
            let supported = tokio::task::spawn_blocking(move || {
                prepare_unix_search_entry(unix_root, canonical, is_root)
                    .map(|entry| !matches!(entry, PreparedUnixSearchEntry::Other))
            })
            .await
            .map_err(blocking_task_error)??;
            if !supported {
                return Err(RpcError::new(
                    "invalid-search-path",
                    "search paths must be files or directories",
                ));
            }
        }
        #[cfg(not(unix))]
        {
            let metadata = tokio::fs::metadata(&resolved)
                .await
                .map_err(|error| io_error("search", &resolved, error))?;
            if !metadata.is_dir() && !metadata.is_file() {
                return Err(RpcError::new(
                    "invalid-search-path",
                    "search paths must be files or directories",
                ));
            }
        }
        if !continuation.enqueue(SearchQueueEntry { path: resolved, protocol_path: normalized }) {
            continuation.discovery_truncated = true;
            break;
        }
    }
    Ok(continuation)
}

fn search_match_retained_bytes(candidate: &SearchMatch) -> usize {
    candidate
        .path
        .len()
        .saturating_add(candidate.text.len())
        .saturating_add(
            candidate.before.iter().map(String::len).fold(0usize, usize::saturating_add),
        )
        .saturating_add(candidate.after.iter().map(String::len).fold(0usize, usize::saturating_add))
        .saturating_add(128)
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
) -> Result<String, Box<MutationFailure>> {
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
) -> Result<String, Box<MutationFailure>> {
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(Box::new(MutationFailure::unchanged(RpcError::new(
            "resource-exhausted",
            format!("write exceeds {MAX_WRITE_BYTES} bytes"),
        ))));
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
        .map_err(|error| Box::new(MutationFailure::unchanged(blocking_task_error(error))))?
        .map_err(|failure| Box::new(MutationFailure::unchanged(failure)))?;
        #[cfg(test)]
        pause_at_mutation_test_barrier(root, path, MutationTestPoint::AfterPrecondition).await;
        let bytes = bytes.to_vec();
        let (result, progress) = tokio::task::spawn_blocking(move || {
            let mut progress = MutationProgress::unchanged();
            let result = commit_unix_write(prepared, &bytes, &mut progress);
            (result, progress)
        })
        .await
        .map_err(|error| Box::new(MutationFailure::unknown(blocking_task_error(error))))?;
        result.map_err(|error| Box::new(progress.fail(error)))
    }
    #[cfg(not(unix))]
    {
        if mode.is_some() {
            return Err(Box::new(MutationFailure::unchanged(RpcError::new(
                "unsupported-platform",
                "workspace file modes require Unix descriptor-relative file operations",
            ))));
        }
        if !matches!(precondition, FilePrecondition::Any) {
            return Err(Box::new(MutationFailure::unchanged(RpcError::new(
                "unsupported-platform",
                "guarded workspace writes require Unix descriptor-relative file operations",
            ))));
        }
        write_bytes_locked_path(root, path, bytes, precondition, create_parents)
            .await
            .map_err(|error| Box::new(MutationFailure::unknown(error)))
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
    #[cfg(test)]
    pause_at_mutation_test_barrier(root, path, MutationTestPoint::AfterPrecondition).await;

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

#[cfg(test)]
pub(crate) async fn remove_file_precondition_locked(
    root: &WorkspaceRoot,
    path: &str,
    precondition: &FilePrecondition,
) -> Result<(), RpcError> {
    remove_file_precondition_locked_with_outcome(root, path, precondition)
        .await
        .map_err(|failure| failure.error)
}

pub(crate) async fn remove_file_precondition_locked_with_outcome(
    root: &WorkspaceRoot,
    path: &str,
    precondition: &FilePrecondition,
) -> Result<(), Box<MutationFailure>> {
    #[cfg(unix)]
    {
        let root_handle = root.unix_root();
        let prepared_path = path.to_owned();
        let prepared_precondition = precondition.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            prepare_unix_remove(root_handle, prepared_path, prepared_precondition)
        })
        .await
        .map_err(|error| Box::new(MutationFailure::unchanged(blocking_task_error(error))))?
        .map_err(|failure| Box::new(MutationFailure::unchanged(failure)))?;
        #[cfg(test)]
        pause_at_mutation_test_barrier(root, path, MutationTestPoint::AfterPrecondition).await;
        let (result, progress) = tokio::task::spawn_blocking(move || {
            let mut progress = MutationProgress::unchanged();
            let result = commit_unix_remove(prepared, &mut progress);
            (result, progress)
        })
        .await
        .map_err(|error| Box::new(MutationFailure::unknown(blocking_task_error(error))))?;
        result.map_err(|error| Box::new(progress.fail(error)))
    }
    #[cfg(not(unix))]
    {
        if !matches!(precondition, FilePrecondition::Any) {
            return Err(Box::new(MutationFailure::unchanged(RpcError::new(
                "unsupported-platform",
                "guarded workspace removals require Unix descriptor-relative file operations",
            ))));
        }
        remove_file_precondition_locked_path(root, path, precondition)
            .await
            .map_err(|error| Box::new(MutationFailure::unknown(error)))
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
enum PreparedUnixSearchEntry {
    Directory(UnixWorkspaceDirectory),
    File { target: UnixWorkspaceTarget, file: File, metadata: Box<std::fs::Metadata> },
    Other,
}

#[cfg(unix)]
fn prepare_unix_search_entry(
    root: UnixWorkspaceRoot,
    canonical: PathBuf,
    is_root: bool,
) -> Result<PreparedUnixSearchEntry, RpcError> {
    if is_root {
        return root
            .pinned_directory_for_canonical_path(&canonical)
            .map(PreparedUnixSearchEntry::Directory);
    }
    let target = root.target_for_canonical_path(&canonical)?;
    let state = stat_entry(&target, "search")?.ok_or_else(|| {
        RpcError::new("not-found", format!("path not found: {}", canonical.display()))
    })?;
    if state.is_directory() {
        let directory = root.pinned_directory_for_canonical_path(&canonical)?;
        let pinned = RawEntryState::from_metadata(&directory.metadata()?);
        if state != pinned {
            return Err(RpcError::new(
                "file-changed",
                "directory changed while it was being opened for search",
            ));
        }
        return Ok(PreparedUnixSearchEntry::Directory(directory));
    }
    if state.is_regular() {
        let file = open_regular_entry(&target, "search")?;
        let metadata = file.metadata().map_err(|error| io_error("search", &canonical, error))?;
        if state != RawEntryState::from_metadata(&metadata) {
            return Err(RpcError::new(
                "file-changed",
                "file changed while it was being opened for search",
            ));
        }
        return Ok(PreparedUnixSearchEntry::File { target, file, metadata: Box::new(metadata) });
    }
    Ok(PreparedUnixSearchEntry::Other)
}

#[cfg(unix)]
async fn scan_unix_search_directory(
    continuation: &mut SearchContinuation,
    entry: &SearchQueueEntry,
    directory: UnixWorkspaceDirectory,
    include_hidden: bool,
) -> Result<(), RpcError> {
    continuation.directory_count = continuation.directory_count.saturating_add(1);
    if continuation.directory_count > MAX_SEARCH_DIRECTORIES {
        continuation.discovery_truncated = true;
        return Ok(());
    }
    if continuation.discovery_truncated {
        return Ok(());
    }
    let remaining = MAX_SEARCH_ENTRIES.saturating_sub(continuation.entry_count);
    let (names, truncated) = tokio::task::spawn_blocking(move || {
        let names = read_directory_names(&directory, remaining)?;
        directory.verify_identity("search")?;
        Ok::<_, RpcError>(names)
    })
    .await
    .map_err(blocking_task_error)??;
    if truncated {
        continuation.discovery_truncated = true;
    }
    let mut children = Vec::new();
    let mut children_bytes = 0usize;
    for name in names {
        continuation.entry_count = continuation.entry_count.saturating_add(1);
        let Ok(name) = name.into_string() else { continue };
        if !include_hidden && name.starts_with('.') {
            continue;
        }
        let Ok(child_protocol) = join_protocol_path(&entry.protocol_path, &name) else {
            continue;
        };
        let child =
            SearchQueueEntry { path: entry.path.join(&name), protocol_path: child_protocol };
        let child_bytes = child.retained_bytes();
        if continuation
            .path_state_bytes()
            .saturating_add(children_bytes)
            .saturating_add(child_bytes)
            > MAX_SEARCH_PATH_STATE_BYTES
        {
            continuation.discovery_truncated = true;
            break;
        }
        children_bytes = children_bytes.saturating_add(child_bytes);
        children.push(child);
    }
    children.sort_unstable_by(|left, right| left.protocol_path.cmp(&right.protocol_path));
    for child in children {
        if !continuation.enqueue(child) {
            continuation.discovery_truncated = true;
            break;
        }
    }
    Ok(())
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
struct PreparedUnixWrite {
    target: UnixWorkspaceTarget,
    precondition: FilePrecondition,
    staged_mode: u32,
    mode_override: Option<u32>,
    pinned: Option<File>,
}

#[cfg(unix)]
fn prepare_unix_write(
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
fn commit_unix_write(
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
    #[cfg(test)]
    pause_at_mutation_test_barrier_blocking(
        target.display(),
        MutationTestPoint::AfterTemporaryCreate,
    );
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
    #[cfg(test)]
    if mutation_test_fault(target.display(), MutationTestFault::PrePublishStat) {
        return Err(RpcError::new("injected-failure", "injected pre-publish stat failure"));
    }
    stat_entry(target, "stat-before-replace")
}

#[cfg(unix)]
fn hash_before_publish(
    pinned: &mut File,
    target: &UnixWorkspaceTarget,
) -> Result<(String, std::fs::Metadata), RpcError> {
    #[cfg(test)]
    if mutation_test_fault(target.display(), MutationTestFault::PrePublishHash) {
        return Err(RpcError::new("injected-failure", "injected pre-publish hash failure"));
    }
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
    #[cfg(test)]
    pause_at_mutation_test_barrier_blocking(
        target.display(),
        MutationTestPoint::BeforeContentHashValidation,
    );
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
    #[cfg(test)]
    pause_at_mutation_test_barrier_blocking(
        target.display(),
        MutationTestPoint::BeforeContentHashExchange,
    );
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
    #[cfg(test)]
    pause_at_mutation_test_barrier_blocking(
        target.display(),
        MutationTestPoint::AfterContentHashExchange,
    );
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
struct PreparedUnixRemove {
    target: UnixWorkspaceTarget,
    precondition: FilePrecondition,
    pinned: Option<File>,
}

#[cfg(unix)]
fn prepare_unix_remove(
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
fn commit_unix_remove(
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
    #[cfg(test)]
    pause_at_mutation_test_barrier_blocking(
        target.display(),
        MutationTestPoint::BeforeContentHashRemoveRename,
    );
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
    #[cfg(test)]
    if mutation_test_fault(target.display(), MutationTestFault::UnpublishedCleanup) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "injected unpublished cleanup failure",
        ));
    }
    unlink_name(target.parent_fd(), name)
}

#[cfg(unix)]
fn unlink_published_name(target: &UnixWorkspaceTarget, name: &CStr) -> Result<(), std::io::Error> {
    #[cfg(test)]
    if mutation_test_fault(target.display(), MutationTestFault::PublishedCleanup) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "injected published cleanup failure",
        ));
    }
    unlink_name(target.parent_fd(), name)
}

#[cfg(unix)]
fn sync_committed_parent(target: &UnixWorkspaceTarget) -> Result<(), RpcError> {
    #[cfg(test)]
    if mutation_test_fault(target.display(), MutationTestFault::CommitSync) {
        return Err(RpcError::new(
            "committed-not-durable",
            format!(
                "workspace mutation committed but directory sync failed at {}: injected failure",
                target.parent_display().display()
            ),
        ));
    }
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
    #[cfg(test)]
    if mutation_test_fault(target.display(), MutationTestFault::RollbackSync) {
        return Err(RpcError::new(
            "rollback-not-durable",
            format!(
                "workspace mutation was restored but directory sync failed at {}: injected failure",
                target.parent_display().display()
            ),
        ));
    }
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
    #[cfg(test)]
    if mutation_test_fault(target.display(), MutationTestFault::ExchangeUnsupported) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "injected unsupported atomic exchange",
        ));
    }
    exchange_names(target.parent_fd(), temporary_name, target.name())
}

#[cfg(unix)]
fn exchange_rollback(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
) -> Result<(), std::io::Error> {
    #[cfg(test)]
    if mutation_test_fault(target.display(), MutationTestFault::RollbackExchange) {
        return Err(std::io::Error::other("injected rollback exchange failure"));
    }
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

fn matches_globs(path: &str, globs: &[String]) -> bool {
    globs.is_empty() || globs.iter().any(|glob| wildcard_match(glob, path))
}

fn page_scope(parts: &[&str]) -> String {
    let mut digest = Sha256::new();
    for part in parts {
        digest.update(u64::try_from(part.len()).unwrap_or(u64::MAX).to_be_bytes());
        digest.update(part.as_bytes());
    }
    hex_digest(&digest.finalize())
}

fn search_page_scope(
    query: &str,
    paths: &[(String, String)],
    globs: &[String],
    include_hidden: bool,
) -> String {
    let mut digest = Sha256::new();
    for part in ["search", query, if include_hidden { "1" } else { "0" }] {
        digest.update(u64::try_from(part.len()).unwrap_or(u64::MAX).to_be_bytes());
        digest.update(part.as_bytes());
    }
    for (_, path) in paths {
        digest.update(b"path");
        digest.update(u64::try_from(path.len()).unwrap_or(u64::MAX).to_be_bytes());
        digest.update(path.as_bytes());
    }
    for glob in globs {
        digest.update(b"glob");
        digest.update(u64::try_from(glob.len()).unwrap_or(u64::MAX).to_be_bytes());
        digest.update(glob.as_bytes());
    }
    hex_digest(&digest.finalize())
}

fn wildcard_match(pattern: &str, text: &str) -> bool {
    let pattern = pattern.as_bytes();
    let text = text.as_bytes();
    let mut pattern_index = 0usize;
    let mut text_index = 0usize;
    let mut last_star = None;
    let mut star_match = 0usize;
    while text_index < text.len() {
        if pattern_index < pattern.len()
            && (pattern[pattern_index] == b'?' || pattern[pattern_index] == text[text_index])
        {
            pattern_index += 1;
            text_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
            last_star = Some(pattern_index);
            pattern_index += 1;
            star_match = text_index;
        } else if let Some(star) = last_star {
            pattern_index = star + 1;
            star_match += 1;
            text_index = star_match;
        } else {
            return false;
        }
    }
    while pattern_index < pattern.len() && pattern[pattern_index] == b'*' {
        pattern_index += 1;
    }
    pattern_index == pattern.len()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use cmux_remote_protocol::WorkspaceId;
    use tempfile::tempdir;

    use super::super::{ClientScope, query::WorkspaceQueryService};
    use super::*;

    async fn root() -> (tempfile::TempDir, Arc<WorkspaceRoot>) {
        let directory = tempdir().unwrap();
        let root =
            WorkspaceRoot::open(WorkspaceId("test".into()), directory.path().to_str().unwrap())
                .await
                .unwrap();
        (directory, root)
    }

    fn query_context() -> (WorkspaceQueryService, ClientScope) {
        (
            WorkspaceQueryService::default(),
            ClientScope::new("test", cmux_remote_protocol::SessionId([1; 16])),
        )
    }

    #[cfg(unix)]
    fn recovery_entry(root: &WorkspaceRoot, prefix: &str) -> PathBuf {
        std::fs::read_dir(root.canonical_root())
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name().is_some_and(|name| name.to_string_lossy().starts_with(prefix))
            })
            .unwrap_or_else(|| panic!("expected a retained {prefix} recovery entry"))
    }

    #[cfg(unix)]
    fn has_recovery_entry(root: &WorkspaceRoot, prefix: &str) -> bool {
        std::fs::read_dir(root.canonical_root())
            .unwrap()
            .flatten()
            .any(|entry| entry.file_name().to_string_lossy().starts_with(prefix))
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn atomic_write_enforces_content_preconditions() {
        let (_directory, root) = root().await;
        let first = ByteString::from_bytes(b"one");
        let response = write_file(&root, "src/value.txt", &first, &FilePrecondition::Missing, true)
            .await
            .unwrap();
        let WorkspaceResponse::Written { content_hash, .. } = response else { panic!() };

        let conflict = write_file(
            &root,
            "src/value.txt",
            &ByteString::from_bytes(b"two"),
            &FilePrecondition::ContentHash("0".repeat(64)),
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(conflict.code, "conflict");
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("src/value.txt")).await.unwrap(),
            b"one"
        );

        write_file(
            &root,
            "src/value.txt",
            &ByteString::from_bytes(b"two"),
            &FilePrecondition::ContentHash(content_hash),
            false,
        )
        .await
        .unwrap();
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("src/value.txt")).await.unwrap(),
            b"two"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn atomic_write_does_not_follow_a_parent_swapped_to_a_symlink() {
        use std::os::unix::fs::symlink;

        let (_directory, root) = root().await;
        let outside = tempdir().unwrap();
        let parent = root.canonical_root().join("parent");
        tokio::fs::create_dir(&parent).await.unwrap();
        let barrier = install_mutation_test_barrier(
            &root,
            "parent/value.txt",
            MutationTestPoint::AfterPrecondition,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "parent/value.txt",
                    &ByteString::from_bytes(b"cmux"),
                    &FilePrecondition::Missing,
                    false,
                )
                .await
            })
        };

        barrier.wait_until_reached().await;
        tokio::fs::rename(&parent, root.canonical_root().join("original-parent")).await.unwrap();
        symlink(outside.path(), &parent).unwrap();
        barrier.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert!(
            matches!(error.code.as_str(), "conflict" | "io-error" | "not-a-directory"),
            "unexpected error: {error:?}"
        );
        assert!(!outside.path().join("value.txt").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn read_file_does_not_follow_a_parent_swapped_to_an_outside_symlink() {
        use std::os::unix::fs::symlink;

        let (_directory, root) = root().await;
        let outside = tempdir().unwrap();
        let parent = root.canonical_root().join("parent");
        tokio::fs::create_dir(&parent).await.unwrap();
        tokio::fs::write(parent.join("value.txt"), b"inside").await.unwrap();
        tokio::fs::write(outside.path().join("value.txt"), b"outside").await.unwrap();
        let barrier = install_mutation_test_barrier(
            &root,
            "parent/value.txt",
            MutationTestPoint::AfterReadResolve,
        );
        let reader = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                let (queries, owner) = query_context();
                let context = WorkspaceQueryContext::new(&queries, &owner, &root);
                read_file(&context, "parent/value.txt", 0, MAX_READ_BYTES).await
            })
        };

        barrier.wait_until_reached().await;
        tokio::fs::rename(&parent, root.canonical_root().join("original-parent")).await.unwrap();
        symlink(outside.path(), &parent).unwrap();
        barrier.resume();

        reader.await.unwrap().unwrap_err();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn stat_does_not_follow_a_checked_parent_swapped_to_an_outside_symlink() {
        use std::os::unix::fs::symlink;

        let (_directory, root) = root().await;
        let outside = tempdir().unwrap();
        let parent = root.canonical_root().join("parent");
        tokio::fs::create_dir(&parent).await.unwrap();
        tokio::fs::write(parent.join("value.txt"), b"inside").await.unwrap();
        tokio::fs::write(outside.path().join("value.txt"), b"outside-secret").await.unwrap();
        let outside_hash = hash_bytes(b"outside-secret");
        let barrier = install_mutation_test_barrier(
            &root,
            "parent/value.txt",
            MutationTestPoint::AfterStatResolve,
        );
        let inspector = {
            let root = Arc::clone(&root);
            tokio::spawn(async move { stat(&root, "parent/value.txt", true).await })
        };

        barrier.wait_until_reached().await;
        tokio::fs::rename(&parent, root.canonical_root().join("original-parent")).await.unwrap();
        symlink(outside.path(), &parent).unwrap();
        barrier.resume();

        if let Ok(WorkspaceResponse::Stat { stat }) = inspector.await.unwrap() {
            assert_ne!(
                stat.content_hash.as_deref(),
                Some(outside_hash.as_str()),
                "stat inspected a file outside the workspace"
            );
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn list_directory_does_not_follow_a_checked_directory_swapped_to_an_outside_symlink() {
        use std::os::unix::fs::symlink;

        let (_directory, root) = root().await;
        let outside = tempdir().unwrap();
        let parent = root.canonical_root().join("parent");
        tokio::fs::create_dir(&parent).await.unwrap();
        tokio::fs::write(parent.join("inside.txt"), b"inside").await.unwrap();
        tokio::fs::write(outside.path().join("outside.txt"), b"outside").await.unwrap();
        let barrier = install_mutation_test_barrier(
            &root,
            "parent",
            MutationTestPoint::AfterDirectoryMetadata,
        );
        let inspector = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                let (queries, owner) = query_context();
                let context = WorkspaceQueryContext::new(&queries, &owner, &root);
                list_directory(&context, "parent", false, MAX_DIRECTORY_LIMIT, None).await
            })
        };

        barrier.wait_until_reached().await;
        tokio::fs::rename(&parent, root.canonical_root().join("original-parent")).await.unwrap();
        symlink(outside.path(), &parent).unwrap();
        barrier.resume();

        if let Ok(WorkspaceResponse::Directory { entries, .. }) =
            inspector.await.unwrap().map(PreparedWorkspaceResponse::commit)
        {
            assert!(
                entries.iter().all(|entry| entry.name != "outside.txt"),
                "directory listing escaped the workspace: {entries:?}"
            );
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn search_does_not_follow_a_checked_directory_swapped_to_an_outside_symlink() {
        use std::os::unix::fs::symlink;

        let (_directory, root) = root().await;
        let outside = tempdir().unwrap();
        let parent = root.canonical_root().join("parent");
        tokio::fs::create_dir(&parent).await.unwrap();
        tokio::fs::write(parent.join("inside.txt"), b"ordinary text").await.unwrap();
        tokio::fs::write(outside.path().join("outside.txt"), b"outside-needle").await.unwrap();
        let barrier =
            install_mutation_test_barrier(&root, "parent", MutationTestPoint::AfterSearchMetadata);
        let inspector = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                let (queries, owner) = query_context();
                let context = WorkspaceQueryContext::new(&queries, &owner, &root);
                search(&context, "outside-needle", &["parent".into()], &[], false, 10, None).await
            })
        };

        barrier.wait_until_reached().await;
        tokio::fs::rename(&parent, root.canonical_root().join("original-parent")).await.unwrap();
        symlink(outside.path(), &parent).unwrap();
        barrier.resume();

        if let Ok(WorkspaceResponse::Search { matches, .. }) =
            inspector.await.unwrap().map(PreparedWorkspaceResponse::commit)
        {
            assert!(matches.is_empty(), "search escaped the workspace: {matches:?}");
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn read_file_follows_a_stable_symlink_within_the_workspace() {
        use std::os::unix::fs::symlink;

        let (_directory, root) = root().await;
        tokio::fs::write(root.canonical_root().join("target.txt"), b"inside").await.unwrap();
        symlink("target.txt", root.canonical_root().join("alias.txt")).unwrap();
        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);

        let response = read_file(&context, "alias.txt", 0, MAX_READ_BYTES).await.unwrap();
        let WorkspaceResponse::File { data, .. } = response else { panic!() };
        assert_eq!(data.decode().unwrap(), b"inside");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn queries_keep_the_opened_root_after_its_path_is_replaced() {
        use std::os::unix::fs::symlink;

        let parent = tempdir().unwrap();
        let registered = parent.path().join("workspace");
        let pinned = parent.path().join("pinned-workspace");
        tokio::fs::create_dir_all(registered.join("requested-dir")).await.unwrap();
        tokio::fs::create_dir_all(registered.join("other-dir")).await.unwrap();
        tokio::fs::write(registered.join("requested.txt"), b"requested").await.unwrap();
        tokio::fs::write(registered.join("other.txt"), b"other").await.unwrap();
        tokio::fs::write(registered.join("requested-dir/requested.txt"), b"needle requested")
            .await
            .unwrap();
        tokio::fs::write(registered.join("other-dir/other.txt"), b"needle other").await.unwrap();
        let root = WorkspaceRoot::open(
            WorkspaceId("replaced-query-root".into()),
            registered.to_str().unwrap(),
        )
        .await
        .unwrap();

        tokio::fs::rename(&registered, &pinned).await.unwrap();
        tokio::fs::create_dir_all(registered.join("other-dir")).await.unwrap();
        tokio::fs::write(registered.join("other.txt"), b"replacement").await.unwrap();
        symlink("other.txt", registered.join("requested.txt")).unwrap();
        symlink("other-dir", registered.join("requested-dir")).unwrap();

        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        let response = read_file(&context, "requested.txt", 0, MAX_READ_BYTES).await.unwrap();
        let WorkspaceResponse::File { data, .. } = response else { panic!() };
        assert_eq!(data.decode().unwrap(), b"requested");

        let response =
            list_directory(&context, "requested-dir", false, 10, None).await.unwrap().commit();
        let WorkspaceResponse::Directory { entries, .. } = response else { panic!() };
        assert_eq!(
            entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(),
            ["requested.txt"]
        );

        let response = search(&context, "needle", &["requested-dir".into()], &[], false, 10, None)
            .await
            .unwrap()
            .commit();
        let WorkspaceResponse::Search { matches, .. } = response else { panic!() };
        assert_eq!(matches.len(), 1);
        assert_eq!(matches[0].path, "requested-dir/requested.txt");
        assert_eq!(matches[0].text, "needle requested");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_write_rejects_a_target_rewrite_before_commit() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let barrier =
            install_mutation_test_barrier(&root, "value.txt", MutationTestPoint::AfterPrecondition);
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"cmux"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        barrier.wait_until_reached().await;
        tokio::fs::write(&target, b"external-change").await.unwrap();
        barrier.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"external-change");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_write_rejects_same_inode_same_length_rewrite_at_exchange() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let before_exchange = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashExchange,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"newbytes"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        before_exchange.wait_until_reached().await;
        tokio::fs::write(&target, b"changed!").await.unwrap();
        before_exchange.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"changed!");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_write_preserves_a_mode_changed_after_the_precondition_check() {
        use std::os::unix::fs::PermissionsExt as _;

        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).await.unwrap();
        let after_precondition =
            install_mutation_test_barrier(&root, "value.txt", MutationTestPoint::AfterPrecondition);
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new-bytes"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        after_precondition.wait_until_reached().await;
        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o640)).await.unwrap();
        after_precondition.resume();

        writer.await.unwrap().unwrap();
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"new-bytes");
        assert_eq!(
            tokio::fs::metadata(&target).await.unwrap().permissions().mode() & 0o7777,
            0o640
        );
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn staged_write_is_owner_only_before_content_is_written() {
        use std::os::unix::fs::PermissionsExt as _;

        const CHILD: &str = "CMUX_STAGED_WRITE_MODE_TEST_CHILD";
        if std::env::var_os(CHILD).is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .arg("--exact")
                .arg(
                    "workspace::files::tests::staged_write_is_owner_only_before_content_is_written",
                )
                .arg("--nocapture")
                .env(CHILD, "1")
                .status()
                .unwrap();
            assert!(status.success(), "isolated staging-mode test failed");
            return;
        }

        struct UmaskGuard(libc::mode_t);
        impl Drop for UmaskGuard {
            fn drop(&mut self) {
                unsafe {
                    libc::umask(self.0);
                }
            }
        }

        let _umask = UmaskGuard(unsafe { libc::umask(0o022) });
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).await.unwrap();
        let after_create = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::AfterTemporaryCreate,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new-bytes"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        after_create.wait_until_reached().await;
        let staged = recovery_entry(&root, ".cmux-write-");
        let metadata = tokio::fs::metadata(&staged).await.unwrap();
        assert_eq!(metadata.len(), 0);
        assert_eq!(metadata.permissions().mode() & 0o7777, 0o600);
        after_create.resume();

        writer.await.unwrap().unwrap();
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"new-bytes");
        assert_eq!(
            tokio::fs::metadata(&target).await.unwrap().permissions().mode() & 0o7777,
            0o600
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn new_workspace_files_default_to_owner_only_mode() {
        use std::os::unix::fs::PermissionsExt as _;

        let (_directory, root) = root().await;
        write_file(
            &root,
            "new.txt",
            &ByteString::from_bytes(b"contents"),
            &FilePrecondition::Missing,
            false,
        )
        .await
        .unwrap();

        let target = root.canonical_root().join("new.txt");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"contents");
        assert_eq!(
            tokio::fs::metadata(&target).await.unwrap().permissions().mode() & 0o7777,
            0o600
        );
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_write_rejects_same_inode_rewrite_with_restored_mtime() {
        use std::io::Write as _;
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let before = std::fs::metadata(&target).unwrap();
        let before_modified = before.modified().unwrap();
        let before_exchange = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashExchange,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new-byte"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        before_exchange.wait_until_reached().await;
        let mut raced =
            std::fs::OpenOptions::new().write(true).truncate(true).open(&target).unwrap();
        raced.write_all(b"mutated!").unwrap();
        raced.sync_all().unwrap();
        raced.set_times(std::fs::FileTimes::new().set_modified(before_modified)).unwrap();
        let after = raced.metadata().unwrap();
        assert_eq!(
            (
                before.dev(),
                before.ino(),
                before.len(),
                before.permissions().mode() & 0o7777,
                before.mtime(),
                before.mtime_nsec(),
            ),
            (
                after.dev(),
                after.ino(),
                after.len(),
                after.permissions().mode() & 0o7777,
                after.mtime(),
                after.mtime_nsec(),
            ),
        );
        drop(raced);
        before_exchange.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"mutated!");
        assert!(!has_recovery_entry(&root, ".cmux-write-"));
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_write_rejects_staged_rewrite_with_restored_mtime() {
        use std::io::Write as _;
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let before_exchange = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashExchange,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new-byte"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        before_exchange.wait_until_reached().await;
        let staged = recovery_entry(&root, ".cmux-write-");
        let before = std::fs::metadata(&staged).unwrap();
        let before_modified = before.modified().unwrap();
        let mut raced =
            std::fs::OpenOptions::new().write(true).truncate(true).open(&staged).unwrap();
        raced.write_all(b"tampered").unwrap();
        raced.sync_all().unwrap();
        raced.set_times(std::fs::FileTimes::new().set_modified(before_modified)).unwrap();
        let after = raced.metadata().unwrap();
        assert_eq!(
            (
                before.dev(),
                before.ino(),
                before.len(),
                before.permissions().mode() & 0o7777,
                before.mtime(),
                before.mtime_nsec(),
            ),
            (
                after.dev(),
                after.ino(),
                after.len(),
                after.permissions().mode() & 0o7777,
                after.mtime(),
                after.mtime_nsec(),
            ),
        );
        drop(raced);
        before_exchange.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"expected");
        assert!(!has_recovery_entry(&root, ".cmux-write-"));
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_remove_rejects_same_inode_rewrite_with_restored_mtime() {
        use std::io::Write as _;
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let before = std::fs::metadata(&target).unwrap();
        let before_modified = before.modified().unwrap();
        let before_rename = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashRemoveRename,
        );
        let remover = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                remove_file_precondition_locked(
                    &root,
                    "value.txt",
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                )
                .await
            })
        };

        before_rename.wait_until_reached().await;
        let mut raced =
            std::fs::OpenOptions::new().write(true).truncate(true).open(&target).unwrap();
        raced.write_all(b"mutated!").unwrap();
        raced.sync_all().unwrap();
        raced.set_times(std::fs::FileTimes::new().set_modified(before_modified)).unwrap();
        let after = raced.metadata().unwrap();
        assert_eq!(
            (
                before.dev(),
                before.ino(),
                before.len(),
                before.permissions().mode() & 0o7777,
                before.mtime(),
                before.mtime_nsec(),
            ),
            (
                after.dev(),
                after.ino(),
                after.len(),
                after.permissions().mode() & 0o7777,
                after.mtime(),
                after.mtime_nsec(),
            ),
        );
        drop(raced);
        before_rename.resume();

        let error = remover.await.unwrap().unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"mutated!");
        assert!(!has_recovery_entry(&root, ".cmux-remove-"));
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn failed_remove_rename_does_not_report_an_uncreated_recovery_entry() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let before_rename = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashRemoveRename,
        );
        let remover = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                remove_file_precondition_locked_with_outcome(
                    &root,
                    "value.txt",
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                )
                .await
            })
        };

        before_rename.wait_until_reached().await;
        tokio::fs::remove_file(&target).await.unwrap();
        before_rename.resume();

        let failure = remover.await.unwrap().unwrap_err();
        assert_eq!(failure.error.code, "conflict");
        assert_eq!(failure.outcome, MutationOutcome::Unknown);
        assert_eq!(failure.recovery_path, None);
        assert!(!has_recovery_entry(&root, ".cmux-remove-"));
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_write_rejects_an_in_place_staged_file_mutation() {
        use std::os::unix::fs::MetadataExt as _;

        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let before_exchange = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashExchange,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new-bytes"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        before_exchange.wait_until_reached().await;
        let staged = recovery_entry(&root, ".cmux-write-");
        let before = tokio::fs::metadata(&staged).await.unwrap();
        tokio::fs::write(&staged, b"tampered").await.unwrap();
        let after = tokio::fs::metadata(&staged).await.unwrap();
        assert_eq!((before.dev(), before.ino()), (after.dev(), after.ino()));
        before_exchange.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert_eq!(error.code, "conflict");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"expected");
        assert!(!staged.exists());
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn stale_content_hash_never_publishes_new_bytes_during_validation_or_cancellation() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let after_precondition =
            install_mutation_test_barrier(&root, "value.txt", MutationTestPoint::AfterPrecondition);
        let before_validation = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashValidation,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new-bytes"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        after_precondition.wait_until_reached().await;
        tokio::fs::write(&target, b"external-change").await.unwrap();
        after_precondition.resume();
        before_validation.wait_until_reached().await;

        assert_eq!(
            tokio::fs::read(&target).await.unwrap(),
            b"external-change",
            "a stale precondition must be rejected before replacement bytes become visible"
        );
        writer.abort();
        before_validation.resume();
        for _ in 0..100 {
            let temporary_exists = std::fs::read_dir(root.canonical_root())
                .unwrap()
                .flatten()
                .any(|entry| entry.file_name().to_string_lossy().starts_with(".cmux-write-"));
            if !temporary_exists {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"external-change");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_write_rejects_same_content_recovery_name_swap() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let after_exchange = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::AfterContentHashExchange,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new-bytes"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        after_exchange.wait_until_reached().await;
        let recovery = recovery_entry(&root, ".cmux-write-");
        let saved_recovery = root.canonical_root().join("saved-recovery");
        tokio::fs::rename(&recovery, &saved_recovery).await.unwrap();
        tokio::fs::write(&recovery, b"expected").await.unwrap();
        after_exchange.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert_eq!(error.code, "partial-write");
        assert!(error.message.contains(&recovery.display().to_string()));
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"new-bytes");
        assert_eq!(tokio::fs::read(&saved_recovery).await.unwrap(), b"expected");
        assert_eq!(tokio::fs::read(&recovery).await.unwrap(), b"expected");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn content_hash_rollback_never_exchanges_an_uncertain_recovery_entry() {
        use std::os::unix::fs::symlink;

        let (_directory, root) = root().await;
        let outside = tempdir().unwrap();
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"expected").await.unwrap();
        let before_exchange = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashExchange,
        );
        let after_exchange = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::AfterContentHashExchange,
        );
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new-bytes"),
                    &FilePrecondition::ContentHash(hash_bytes(b"expected")),
                    false,
                )
                .await
            })
        };

        before_exchange.wait_until_reached().await;
        tokio::fs::rename(&target, root.canonical_root().join("pinned-original")).await.unwrap();
        tokio::fs::write(&target, b"raced-entry").await.unwrap();
        before_exchange.resume();
        after_exchange.wait_until_reached().await;

        let recovery = std::fs::read_dir(root.canonical_root())
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name()
                    .is_some_and(|name| name.to_string_lossy().starts_with(".cmux-write-"))
            })
            .expect("exchange retains the displaced entry under its recovery name");
        let saved_recovery = root.canonical_root().join("saved-raced-entry");
        tokio::fs::rename(&recovery, &saved_recovery).await.unwrap();
        symlink(outside.path().join("outside-value"), &recovery).unwrap();
        after_exchange.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert_eq!(error.code, "partial-write");
        assert!(error.message.contains(".cmux-write-"));
        assert!(!target.is_symlink());
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"new-bytes");
        assert_eq!(tokio::fs::read(&saved_recovery).await.unwrap(), b"raced-entry");
        assert!(!outside.path().join("outside-value").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn unconditional_and_missing_mutations_do_not_require_target_read_permission() {
        use std::os::unix::fs::PermissionsExt as _;

        let (_directory, root) = root().await;
        let target = root.canonical_root().join("mode-zero.txt");
        tokio::fs::write(&target, b"old").await.unwrap();
        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o000)).await.unwrap();

        let missing = write_file(
            &root,
            "mode-zero.txt",
            &ByteString::from_bytes(b"must-not-write"),
            &FilePrecondition::Missing,
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(missing.code, "conflict");

        write_file(
            &root,
            "mode-zero.txt",
            &ByteString::from_bytes(b"new"),
            &FilePrecondition::Any,
            false,
        )
        .await
        .unwrap();
        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o600)).await.unwrap();
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"new");

        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o000)).await.unwrap();
        let missing =
            remove_file_precondition_locked(&root, "mode-zero.txt", &FilePrecondition::Missing)
                .await
                .unwrap_err();
        assert_eq!(missing.code, "conflict");
        remove_file_precondition_locked(&root, "mode-zero.txt", &FilePrecondition::Any)
            .await
            .unwrap();
        assert!(!target.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn mutation_parent_symlinks_are_allowed_only_when_they_stay_in_the_workspace() {
        use std::os::unix::fs::symlink;

        let (_directory, root) = root().await;
        let outside = tempdir().unwrap();
        tokio::fs::create_dir(root.canonical_root().join("real")).await.unwrap();
        symlink("real", root.canonical_root().join("inside")).unwrap();
        symlink(outside.path(), root.canonical_root().join("outside")).unwrap();

        write_file(
            &root,
            "inside/value.txt",
            &ByteString::from_bytes(b"inside"),
            &FilePrecondition::Missing,
            false,
        )
        .await
        .unwrap();
        assert_eq!(
            tokio::fs::read(root.canonical_root().join("real/value.txt")).await.unwrap(),
            b"inside"
        );

        let error = write_file(
            &root,
            "outside/value.txt",
            &ByteString::from_bytes(b"outside"),
            &FilePrecondition::Missing,
            false,
        )
        .await
        .unwrap_err();
        assert!(matches!(error.code.as_str(), "path-outside-workspace" | "symlink-not-supported"));
        assert!(!outside.path().join("value.txt").exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn absolute_parent_symlink_through_workspace_alias_remains_contained() {
        use std::os::unix::fs::symlink;

        let parent = tempdir().unwrap();
        let canonical = parent.path().join("canonical-workspace");
        let alias = parent.path().join("workspace-alias");
        tokio::fs::create_dir_all(canonical.join("real-parent")).await.unwrap();
        symlink(&canonical, &alias).unwrap();
        symlink(alias.join("real-parent"), canonical.join("through-alias")).unwrap();
        let root = WorkspaceRoot::open(
            WorkspaceId("aliased".into()),
            alias.to_str().expect("temporary paths are UTF-8"),
        )
        .await
        .unwrap();

        write_file(
            &root,
            "through-alias/value.txt",
            &ByteString::from_bytes(b"contained"),
            &FilePrecondition::Missing,
            false,
        )
        .await
        .unwrap();

        assert_eq!(
            tokio::fs::read(canonical.join("real-parent/value.txt")).await.unwrap(),
            b"contained"
        );
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn guarded_exchange_unavailable_does_not_disable_unconditional_writes() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"old").await.unwrap();
        let fault =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::ExchangeUnsupported);

        let error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"guarded"),
            &FilePrecondition::ContentHash(hash_bytes(b"old")),
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(error.code, "unsupported-filesystem");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"old");

        write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"unconditional"),
            &FilePrecondition::Any,
            false,
        )
        .await
        .unwrap();
        drop(fault);
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"unconditional");
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn prepublish_hash_failure_cleans_the_staged_write() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"old").await.unwrap();
        let _hash =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::PrePublishHash);

        let error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"new"),
            &FilePrecondition::ContentHash(hash_bytes(b"old")),
            false,
        )
        .await
        .unwrap_err();

        assert_eq!(error.code, "injected-failure");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"old");
        assert!(!has_recovery_entry(&root, ".cmux-write-"));
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn prepublish_hash_failure_retains_the_staged_write_when_cleanup_fails() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"old").await.unwrap();
        let _hash =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::PrePublishHash);
        let _cleanup =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::UnpublishedCleanup);

        let error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"new"),
            &FilePrecondition::ContentHash(hash_bytes(b"old")),
            false,
        )
        .await
        .unwrap_err();

        let recovery = recovery_entry(&root, ".cmux-write-");
        assert_eq!(error.code, "partial-write");
        assert!(error.message.contains(&recovery.display().to_string()));
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"old");
        assert_eq!(tokio::fs::read(&recovery).await.unwrap(), b"new");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn prepublish_stat_failure_cleans_an_unconditional_staged_write() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"old").await.unwrap();
        let _stat =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::PrePublishStat);

        let error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"new"),
            &FilePrecondition::Any,
            false,
        )
        .await
        .unwrap_err();

        assert_eq!(error.code, "injected-failure");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"old");
        assert!(!has_recovery_entry(&root, ".cmux-write-"));
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn prepublish_stat_failure_cleans_a_content_guarded_staged_write() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"old").await.unwrap();
        let _stat =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::PrePublishStat);

        let error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"new"),
            &FilePrecondition::ContentHash(hash_bytes(b"old")),
            false,
        )
        .await
        .unwrap_err();

        assert_eq!(error.code, "injected-failure");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"old");
        assert!(!has_recovery_entry(&root, ".cmux-write-"));
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn failed_unpublished_cleanup_reports_the_retained_recovery_path() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"old").await.unwrap();
        let exchange =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::ExchangeUnsupported);
        let cleanup =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::UnpublishedCleanup);

        let error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"new"),
            &FilePrecondition::ContentHash(hash_bytes(b"old")),
            false,
        )
        .await
        .unwrap_err();
        let recovery = recovery_entry(&root, ".cmux-write-");
        assert_eq!(error.code, "partial-write");
        assert!(
            error.message.contains(&recovery.display().to_string()),
            "recovery path missing from error: {error:?}"
        );
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"old");
        assert_eq!(tokio::fs::read(&recovery).await.unwrap(), b"new");

        drop(cleanup);
        drop(exchange);
        tokio::fs::remove_file(recovery).await.unwrap();
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn failed_published_cleanup_reports_the_retained_recovery_path() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"old").await.unwrap();
        let cleanup =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::PublishedCleanup);

        let error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"new"),
            &FilePrecondition::ContentHash(hash_bytes(b"old")),
            false,
        )
        .await
        .unwrap_err();
        let recovery = recovery_entry(&root, ".cmux-write-");
        assert_eq!(error.code, "partial-write");
        assert!(error.message.contains(&recovery.display().to_string()));
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"new");
        assert_eq!(tokio::fs::read(&recovery).await.unwrap(), b"old");

        drop(cleanup);
        tokio::fs::remove_file(recovery).await.unwrap();

        let cleanup =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::PublishedCleanup);
        let error = remove_file_precondition_locked(
            &root,
            "value.txt",
            &FilePrecondition::ContentHash(hash_bytes(b"new")),
        )
        .await
        .unwrap_err();
        let recovery = recovery_entry(&root, ".cmux-remove-");
        assert_eq!(error.code, "partial-write");
        assert!(error.message.contains(&recovery.display().to_string()));
        assert!(!target.exists());
        assert_eq!(tokio::fs::read(&recovery).await.unwrap(), b"new");

        drop(cleanup);
        tokio::fs::remove_file(recovery).await.unwrap();
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn rollback_exchange_failure_reports_the_retained_recovery_path() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        let saved_original = root.canonical_root().join("saved-original");
        tokio::fs::write(&target, b"old").await.unwrap();
        let barrier = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashExchange,
        );
        let rollback =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::RollbackExchange);
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new"),
                    &FilePrecondition::ContentHash(hash_bytes(b"old")),
                    false,
                )
                .await
            })
        };

        barrier.wait_until_reached().await;
        tokio::fs::rename(&target, &saved_original).await.unwrap();
        tokio::fs::write(&target, b"raced").await.unwrap();
        barrier.resume();

        let error = writer.await.unwrap().unwrap_err();
        let recovery = recovery_entry(&root, ".cmux-write-");
        assert_eq!(error.code, "partial-write");
        assert!(
            error.message.contains(&recovery.display().to_string()),
            "recovery path missing from error: {error:?}"
        );
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"new");
        assert_eq!(tokio::fs::read(&recovery).await.unwrap(), b"raced");

        drop(rollback);
        tokio::fs::remove_file(recovery).await.unwrap();
    }

    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    #[tokio::test]
    async fn rollback_sync_failure_reports_restored_but_not_durable() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        let saved_original = root.canonical_root().join("saved-original");
        tokio::fs::write(&target, b"old").await.unwrap();
        let barrier = install_mutation_test_barrier(
            &root,
            "value.txt",
            MutationTestPoint::BeforeContentHashExchange,
        );
        let sync = install_mutation_test_fault(&root, "value.txt", MutationTestFault::RollbackSync);
        let writer = {
            let root = Arc::clone(&root);
            tokio::spawn(async move {
                write_file(
                    &root,
                    "value.txt",
                    &ByteString::from_bytes(b"new"),
                    &FilePrecondition::ContentHash(hash_bytes(b"old")),
                    false,
                )
                .await
            })
        };

        barrier.wait_until_reached().await;
        tokio::fs::rename(&target, &saved_original).await.unwrap();
        tokio::fs::write(&target, b"raced").await.unwrap();
        barrier.resume();

        let error = writer.await.unwrap().unwrap_err();
        assert_eq!(error.code, "rollback-not-durable");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"raced");
        assert!(
            std::fs::read_dir(root.canonical_root())
                .unwrap()
                .flatten()
                .all(|entry| !entry.file_name().to_string_lossy().starts_with(".cmux-write-"))
        );
        drop(sync);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn committed_sync_failure_reports_write_or_remove_already_committed() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        let write_sync =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::CommitSync);
        let write_error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"written"),
            &FilePrecondition::Missing,
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(write_error.code, "committed-not-durable");
        assert_eq!(tokio::fs::read(&target).await.unwrap(), b"written");
        drop(write_sync);

        let remove_sync =
            install_mutation_test_fault(&root, "value.txt", MutationTestFault::CommitSync);
        let remove_error =
            remove_file_precondition_locked(&root, "value.txt", &FilePrecondition::Any)
                .await
                .unwrap_err();
        assert_eq!(remove_error.code, "committed-not-durable");
        assert!(!target.exists());
        drop(remove_sync);
    }

    #[cfg(not(unix))]
    #[tokio::test]
    async fn guarded_mutations_report_unsupported_platform() {
        let (_directory, root) = root().await;
        let write_error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"value"),
            &FilePrecondition::Missing,
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(write_error.code, "unsupported-platform");

        tokio::fs::write(root.canonical_root().join("value.txt"), b"value").await.unwrap();
        let remove_error = remove_file_precondition_locked(
            &root,
            "value.txt",
            &FilePrecondition::ContentHash(hash_bytes(b"value")),
        )
        .await
        .unwrap_err();
        assert_eq!(remove_error.code, "unsupported-platform");
    }

    #[cfg(all(
        unix,
        not(any(target_os = "linux", target_os = "android", target_vendor = "apple"))
    ))]
    #[tokio::test]
    async fn content_guarded_mutations_report_unsupported_unix_platform() {
        let (_directory, root) = root().await;
        let target = root.canonical_root().join("value.txt");
        tokio::fs::write(&target, b"value").await.unwrap();
        let precondition = FilePrecondition::ContentHash(hash_bytes(b"value"));

        let write_error = write_file(
            &root,
            "value.txt",
            &ByteString::from_bytes(b"updated"),
            &precondition,
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(write_error.code, "unsupported-platform");

        let remove_error =
            remove_file_precondition_locked(&root, "value.txt", &precondition).await.unwrap_err();
        assert_eq!(remove_error.code, "unsupported-platform");
    }

    #[tokio::test]
    async fn directory_listing_is_sorted_bounded_and_hidden_aware() {
        let (_directory, root) = root().await;
        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        tokio::fs::create_dir(root.canonical_root().join("z-dir")).await.unwrap();
        tokio::fs::write(root.canonical_root().join("A.txt"), b"a").await.unwrap();
        tokio::fs::write(root.canonical_root().join(".hidden"), b"h").await.unwrap();
        let response = list_directory(&context, "", false, 1, None).await.unwrap().commit();
        let WorkspaceResponse::Directory { entries, truncated, .. } = response else { panic!() };
        assert!(truncated);
        assert_eq!(entries[0].name, "z-dir");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn repeated_root_directory_snapshots_have_independent_stream_offsets() {
        let (_directory, root) = root().await;
        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        tokio::fs::write(root.canonical_root().join("one.txt"), b"one").await.unwrap();

        for _ in 0..2 {
            let response = list_directory(&context, "", false, 10, None).await.unwrap().commit();
            let WorkspaceResponse::Directory { entries, .. } = response else { panic!() };
            assert!(entries.iter().any(|entry| entry.name == "one.txt"));
        }
    }

    #[tokio::test]
    async fn directory_cursor_returns_the_next_sorted_page() {
        let (_directory, root) = root().await;
        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        for name in ["c.txt", "a.txt", "b.txt"] {
            tokio::fs::write(root.canonical_root().join(name), name).await.unwrap();
        }
        let first = list_directory(&context, "", false, 2, None).await.unwrap().commit();
        let WorkspaceResponse::Directory { entries, next_cursor: Some(cursor), .. } = first else {
            panic!()
        };
        assert_eq!(
            entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(),
            ["a.txt", "b.txt"]
        );

        let second = list_directory(&context, "", false, 2, Some(&cursor)).await.unwrap().commit();
        let WorkspaceResponse::Directory { entries, next_cursor, truncated } = second else {
            panic!()
        };
        assert_eq!(entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(), ["c.txt"]);
        assert_eq!(next_cursor, None);
        assert!(!truncated);

        let error = list_directory(&context, "", true, 2, Some(&cursor))
            .await
            .err()
            .expect("cursor with a different scope should fail");
        assert_eq!(error.code, "invalid-cursor");
    }

    #[tokio::test]
    async fn directory_cursor_continues_the_original_snapshot() {
        let (_directory, root) = root().await;
        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        for name in ["a.txt", "b.txt", "c.txt"] {
            tokio::fs::write(root.canonical_root().join(name), name).await.unwrap();
        }
        let first = list_directory(&context, "", false, 1, None).await.unwrap().commit();
        let WorkspaceResponse::Directory { entries, next_cursor: Some(cursor), .. } = first else {
            panic!()
        };
        assert_eq!(entries[0].name, "a.txt");
        tokio::fs::remove_file(root.canonical_root().join("a.txt")).await.unwrap();

        let second = list_directory(&context, "", false, 1, Some(&cursor)).await.unwrap().commit();
        let WorkspaceResponse::Directory { entries, .. } = second else { panic!() };
        assert_eq!(entries[0].name, "b.txt");
    }

    #[tokio::test]
    async fn search_is_literal_structured_and_bounded() {
        let (_directory, root) = root().await;
        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        tokio::fs::create_dir(root.canonical_root().join("src")).await.unwrap();
        tokio::fs::write(
            root.canonical_root().join("src/lib.rs"),
            b"before\nneedle here\nafter\nneedle twice\n",
        )
        .await
        .unwrap();
        let response =
            search(&context, "needle", &["src".into()], &["*.rs".into()], false, 1, None)
                .await
                .unwrap()
                .commit();
        let WorkspaceResponse::Search { matches, truncated, .. } = response else { panic!() };
        assert!(truncated);
        assert_eq!(matches[0].path, "src/lib.rs");
        assert_eq!(matches[0].line, 2);
        assert_eq!(matches[0].before, ["before"]);
        assert_eq!(matches[0].after, ["after"]);
    }

    #[tokio::test]
    async fn search_cursor_resumes_after_the_last_match() {
        let (_directory, root) = root().await;
        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        tokio::fs::write(root.canonical_root().join("matches.txt"), b"needle one\nneedle two\n")
            .await
            .unwrap();
        let first = search(&context, "needle", &[], &[], false, 1, None).await.unwrap().commit();
        let WorkspaceResponse::Search { matches, next_cursor: Some(cursor), .. } = first else {
            panic!()
        };
        assert_eq!(matches[0].line, 1);

        let second =
            search(&context, "needle", &[], &[], false, 1, Some(&cursor)).await.unwrap().commit();
        let WorkspaceResponse::Search { matches, next_cursor, truncated } = second else {
            panic!()
        };
        assert_eq!(matches[0].line, 2);
        assert_eq!(next_cursor, None);
        assert!(!truncated);
    }

    #[tokio::test]
    async fn search_cursor_continues_without_replaying_changed_files() {
        let (_directory, root) = root().await;
        let (queries, owner) = query_context();
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        let path = root.canonical_root().join("matches.txt");
        tokio::fs::write(&path, b"needle one\nneedle two\n").await.unwrap();
        let first = search(&context, "needle", &[], &[], false, 1, None).await.unwrap().commit();
        let WorkspaceResponse::Search { next_cursor: Some(cursor), .. } = first else { panic!() };
        tokio::fs::write(&path, b"needle zero\nneedle one\nneedle two\n").await.unwrap();

        let second =
            search(&context, "needle", &[], &[], false, 1, Some(&cursor)).await.unwrap().commit();
        let WorkspaceResponse::Search { matches, .. } = second else { panic!() };
        assert_eq!(matches[0].text, "needle two");
        assert_eq!(matches[0].line, 2);
    }

    #[test]
    fn wildcard_matching_handles_common_patterns() {
        assert!(wildcard_match("*.rs", "src/lib.rs"));
        assert!(wildcard_match("src/?ib.rs", "src/lib.rs"));
        assert!(!wildcard_match("*.md", "src/lib.rs"));
    }
}
