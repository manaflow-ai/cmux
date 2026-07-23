use std::collections::{HashSet, VecDeque};
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::ffi::{CStr, CString};
#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::os::fd::{FromRawFd, RawFd};
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

#[cfg(unix)]
use super::path::{UnixWorkspaceRoot, UnixWorkspaceTarget};
use super::path::{
    WorkspaceRoot, io_error, join_protocol_path, normalize_protocol_path, validate_relative,
};

pub(crate) const MAX_READ_BYTES: u32 = 4 * 1024 * 1024;
pub(crate) const MAX_WRITE_BYTES: usize = 8 * 1024 * 1024;
pub(crate) const MAX_HASH_BYTES: u64 = 128 * 1024 * 1024;
const MAX_DIRECTORY_LIMIT: u32 = 4_096;
const MAX_DIRECTORY_SCAN: usize = 100_000;
const MAX_DIRECTORY_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const MAX_SEARCH_RESULTS: u32 = 10_000;
const MAX_SEARCH_DIRECTORIES: usize = 10_000;
const MAX_SEARCH_ENTRIES: usize = 50_000;
const MAX_SEARCH_FILE_BYTES: u64 = 2 * 1024 * 1024;
const MAX_SEARCH_TOTAL_BYTES: u64 = 64 * 1024 * 1024;
const MAX_SEARCH_QUERY_BYTES: usize = 64 * 1024;
const MAX_SEARCH_PATHS: usize = 256;
const MAX_SEARCH_GLOBS: usize = 256;
const MAX_SEARCH_ARGUMENT_BYTES: usize = 1024 * 1024;
const MAX_SEARCH_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

#[cfg(test)]
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub(crate) enum MutationTestPoint {
    AfterPrecondition,
    BeforeContentHashValidation,
    BeforeContentHashExchange,
    AfterContentHashExchange,
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
async fn pause_at_mutation_test_barrier(
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

pub(crate) async fn read_file(
    root: &WorkspaceRoot,
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
    let resolved = root.resolve_existing(path).await?;
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

    let content_hash = hash_file(&mut file, metadata.len()).await?;
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
    if !metadata_stable(&metadata, &metadata_after) {
        return Err(RpcError::new("file-changed", "file changed while it was being read"));
    }

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
    root: &WorkspaceRoot,
    path: &str,
    include_hidden: bool,
    limit: u32,
    cursor: Option<&PageCursor>,
) -> Result<WorkspaceResponse, RpcError> {
    if limit > MAX_DIRECTORY_LIMIT {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("directory limit exceeds {MAX_DIRECTORY_LIMIT} entries"),
        ));
    }
    let normalized = normalize_protocol_path(path)?;
    let cursor_scope =
        page_scope(&["directory", &normalized, if include_hidden { "1" } else { "0" }]);
    let start = parse_page_cursor(cursor, "directory", &cursor_scope)?;
    let resolved = root.resolve_existing(path).await?;
    let metadata = tokio::fs::metadata(&resolved)
        .await
        .map_err(|error| io_error("list-directory", &resolved, error))?;
    if !metadata.is_dir() {
        return Err(RpcError::new(
            "not-a-directory",
            format!("not a directory: {}", resolved.display()),
        ));
    }

    let mut reader = tokio::fs::read_dir(&resolved)
        .await
        .map_err(|error| io_error("list-directory", &resolved, error))?;
    let mut entries = Vec::new();
    let mut scanned = 0usize;
    let mut scan_truncated = false;
    while let Some(entry) =
        reader.next_entry().await.map_err(|error| io_error("list-directory", &resolved, error))?
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
        let Ok(entry_path) = join_protocol_path(&normalized, &name) else { continue };
        entries.push(DirectoryEntry {
            path: entry_path,
            name,
            kind: file_kind(&metadata),
            size: metadata.len(),
        });
    }
    entries.sort_by(|left, right| {
        let left_directory = left.kind == FileKind::Directory;
        let right_directory = right.kind == FileKind::Directory;
        right_directory
            .cmp(&left_directory)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
            .then_with(|| left.name.cmp(&right.name))
    });
    if start > entries.len() {
        return Err(RpcError::new(
            "invalid-cursor",
            "directory cursor is beyond the available entries",
        ));
    }
    let requested = limit as usize;
    let mut page = Vec::with_capacity(requested.min(entries.len().saturating_sub(start)));
    let mut response_bytes = 0usize;
    let mut index = start;
    while index < entries.len() && page.len() < requested {
        let entry = &entries[index];
        let entry_bytes =
            entry.name.len().saturating_add(entry.path.len()).saturating_mul(6).saturating_add(64);
        if response_bytes.saturating_add(entry_bytes) > MAX_DIRECTORY_RESPONSE_BYTES {
            break;
        }
        response_bytes = response_bytes.saturating_add(entry_bytes);
        page.push(entry.clone());
        index += 1;
    }
    let next_cursor = (requested > 0 && index < entries.len())
        .then(|| make_page_cursor("directory", &cursor_scope, index));
    let truncated = scan_truncated || next_cursor.is_some();
    Ok(WorkspaceResponse::Directory { entries: page, truncated, next_cursor })
}

pub(crate) async fn search(
    root: &WorkspaceRoot,
    query: &str,
    paths: &[String],
    globs: &[String],
    include_hidden: bool,
    max_results: u32,
    cursor: Option<&PageCursor>,
) -> Result<WorkspaceResponse, RpcError> {
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
        return Ok(WorkspaceResponse::Search {
            matches: Vec::new(),
            truncated: false,
            next_cursor: None,
        });
    }
    for glob in globs {
        if glob.contains('\0') {
            return Err(RpcError::new("invalid-argument", "search glob contains a NUL byte"));
        }
    }

    let requested_paths = if paths.is_empty() { vec![String::new()] } else { paths.to_vec() };
    let mut queue = VecDeque::<(PathBuf, String)>::new();
    let mut requested_paths = requested_paths
        .into_iter()
        .map(|path| normalize_protocol_path(&path).map(|normalized| (path, normalized)))
        .collect::<Result<Vec<_>, _>>()?;
    requested_paths.sort_by(|left, right| left.1.cmp(&right.1));
    requested_paths.dedup_by(|left, right| left.1 == right.1);
    let cursor_scope = search_page_scope(query, &requested_paths, globs, include_hidden);
    let skip_matches = parse_page_cursor(cursor, "search", &cursor_scope)?;
    for (path, normalized) in requested_paths {
        let resolved = root.resolve_existing(&path).await?;
        let metadata = tokio::fs::metadata(&resolved)
            .await
            .map_err(|error| io_error("search", &resolved, error))?;
        if metadata.is_dir() || metadata.is_file() {
            queue.push_back((resolved, normalized));
        } else {
            return Err(RpcError::new(
                "invalid-search-path",
                "search paths must be files or directories",
            ));
        }
    }

    let mut matches = Vec::new();
    let mut directory_count = 0usize;
    let mut entry_count = 0usize;
    let mut total_bytes = 0u64;
    let mut response_bytes = 0usize;
    let mut visited = HashSet::new();
    let mut truncated = false;
    let mut seen_matches = 0usize;
    let mut next_offset = None;

    while let Some((path, protocol_path)) = queue.pop_front() {
        if !visited.insert(path.clone()) {
            continue;
        }
        let metadata = tokio::fs::symlink_metadata(&path)
            .await
            .map_err(|error| io_error("search", &path, error))?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        if metadata.is_dir() {
            directory_count += 1;
            if directory_count > MAX_SEARCH_DIRECTORIES {
                truncated = true;
                break;
            }
            let mut reader = tokio::fs::read_dir(&path)
                .await
                .map_err(|error| io_error("search", &path, error))?;
            let mut children = Vec::new();
            while let Some(entry) =
                reader.next_entry().await.map_err(|error| io_error("search", &path, error))?
            {
                entry_count += 1;
                if entry_count > MAX_SEARCH_ENTRIES {
                    truncated = true;
                    break;
                }
                let Ok(name) = entry.file_name().into_string() else { continue };
                if !include_hidden && name.starts_with('.') {
                    continue;
                }
                let Ok(child_protocol) = join_protocol_path(&protocol_path, &name) else {
                    continue;
                };
                children.push((entry.path(), child_protocol));
            }
            if truncated {
                break;
            }
            children.sort_by(|left, right| left.1.cmp(&right.1));
            queue.extend(children);
            continue;
        }
        if !metadata.is_file()
            || metadata.len() > MAX_SEARCH_FILE_BYTES
            || !matches_globs(&protocol_path, globs)
        {
            continue;
        }
        if total_bytes.saturating_add(metadata.len()) > MAX_SEARCH_TOTAL_BYTES {
            truncated = true;
            break;
        }
        total_bytes += metadata.len();
        let bytes = read_path_bounded(&path, MAX_SEARCH_FILE_BYTES as usize).await?;
        if bytes.contains(&0) {
            continue;
        }
        let Ok(text) = String::from_utf8(bytes) else { continue };
        let lines = text.lines().collect::<Vec<_>>();
        for (line_index, line) in lines.iter().enumerate() {
            let mut start = 0usize;
            while let Some(found) = line[start..].find(query) {
                let column = start + found;
                let occurrence = seen_matches;
                seen_matches = seen_matches.saturating_add(1);
                if occurrence < skip_matches {
                    start = column.saturating_add(query.len());
                    continue;
                }
                if matches.len() >= max_results as usize {
                    next_offset = Some(skip_matches.saturating_add(matches.len()));
                    truncated = true;
                    break;
                }
                let before = line_index.checked_sub(1).and_then(|index| lines.get(index)).copied();
                let after = lines.get(line_index + 1).copied();
                let match_bytes = protocol_path
                    .len()
                    .saturating_add(line.len())
                    .saturating_add(before.map_or(0, str::len))
                    .saturating_add(after.map_or(0, str::len))
                    .saturating_add(128);
                if response_bytes.saturating_add(match_bytes) > MAX_SEARCH_RESPONSE_BYTES {
                    next_offset = Some(skip_matches.saturating_add(matches.len()));
                    truncated = true;
                    break;
                }
                response_bytes = response_bytes.saturating_add(match_bytes);
                matches.push(SearchMatch {
                    path: protocol_path.clone(),
                    line: u64::try_from(line_index + 1).unwrap_or(u64::MAX),
                    column: u64::try_from(column + 1).unwrap_or(u64::MAX),
                    text: (*line).to_string(),
                    before: before.map(|line| vec![line.to_string()]).unwrap_or_default(),
                    after: after.map(|line| vec![line.to_string()]).unwrap_or_default(),
                });
                start = column.saturating_add(query.len());
            }
            if truncated {
                break;
            }
        }
        if truncated {
            break;
        }
    }

    if !truncated && skip_matches > seen_matches {
        return Err(RpcError::new(
            "invalid-cursor",
            "search cursor is beyond the available matches",
        ));
    }
    let next_cursor = next_offset.map(|offset| make_page_cursor("search", &cursor_scope, offset));
    Ok(WorkspaceResponse::Search { matches, truncated, next_cursor })
}

pub(crate) async fn read_full_file(
    root: &WorkspaceRoot,
    path: &str,
    maximum: usize,
) -> Result<Vec<u8>, RpcError> {
    validate_relative(path)?;
    #[cfg(unix)]
    {
        let root = root.unix_root();
        let path = path.to_owned();
        return tokio::task::spawn_blocking(move || {
            let target = root.resolve_target(&path, false)?;
            let mut file = open_regular_entry(&target, "read")?;
            let bytes = read_file_bounded_sync(&mut file, target.display(), maximum)?;
            target.verify_parent_identity()?;
            Ok(bytes)
        })
        .await
        .map_err(blocking_task_error)?;
    }
    #[cfg(not(unix))]
    {
        let resolved = root.resolve_existing(path).await?;
        read_path_bounded(&resolved, maximum).await
    }
}

pub(crate) async fn write_bytes_locked(
    root: &WorkspaceRoot,
    path: &str,
    bytes: &[u8],
    precondition: &FilePrecondition,
    create_parents: bool,
) -> Result<String, RpcError> {
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("write exceeds {MAX_WRITE_BYTES} bytes"),
        ));
    }
    #[cfg(unix)]
    {
        let root_handle = root.unix_root();
        let prepared_path = path.to_owned();
        let prepared_precondition = precondition.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            prepare_unix_write(root_handle, prepared_path, prepared_precondition, create_parents)
        })
        .await
        .map_err(blocking_task_error)??;
        #[cfg(test)]
        pause_at_mutation_test_barrier(root, path, MutationTestPoint::AfterPrecondition).await;
        let bytes = bytes.to_vec();
        return tokio::task::spawn_blocking(move || commit_unix_write(prepared, &bytes))
            .await
            .map_err(blocking_task_error)?;
    }
    #[cfg(not(unix))]
    {
        if !matches!(precondition, FilePrecondition::Any) {
            return Err(RpcError::new(
                "unsupported-platform",
                "guarded workspace writes require Unix descriptor-relative file operations",
            ));
        }
        write_bytes_locked_path(root, path, bytes, precondition, create_parents).await
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

pub(crate) async fn remove_file_precondition_locked(
    root: &WorkspaceRoot,
    path: &str,
    precondition: &FilePrecondition,
) -> Result<(), RpcError> {
    #[cfg(unix)]
    {
        let root_handle = root.unix_root();
        let prepared_path = path.to_owned();
        let prepared_precondition = precondition.clone();
        let prepared = tokio::task::spawn_blocking(move || {
            prepare_unix_remove(root_handle, prepared_path, prepared_precondition)
        })
        .await
        .map_err(blocking_task_error)??;
        #[cfg(test)]
        pause_at_mutation_test_barrier(root, path, MutationTestPoint::AfterPrecondition).await;
        return tokio::task::spawn_blocking(move || commit_unix_remove(prepared))
            .await
            .map_err(blocking_task_error)?;
    }
    #[cfg(not(unix))]
    {
        if !matches!(precondition, FilePrecondition::Any) {
            return Err(RpcError::new(
                "unsupported-platform",
                "guarded workspace removals require Unix descriptor-relative file operations",
            ));
        }
        remove_file_precondition_locked_path(root, path, precondition).await
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
        Self {
            dev: status.st_dev as u64,
            ino: status.st_ino as u64,
            mode: status.st_mode as u32,
            size: u64::try_from(status.st_size).unwrap_or(0),
            modified: (status.st_mtime, status.st_mtime_nsec),
            changed: (status.st_ctime, status.st_ctime_nsec),
        }
    }

    fn is_regular(&self) -> bool {
        self.mode & libc::S_IFMT as u32 == libc::S_IFREG as u32
    }

    fn is_symlink(&self) -> bool {
        self.mode & libc::S_IFMT as u32 == libc::S_IFLNK as u32
    }

    fn same_object(&self, other: &Self) -> bool {
        self.dev == other.dev
            && self.ino == other.ino
            && self.mode & libc::S_IFMT as u32 == other.mode & libc::S_IFMT as u32
    }
}

#[cfg(unix)]
struct PreparedUnixWrite {
    target: UnixWorkspaceTarget,
    precondition: FilePrecondition,
    initial_mode: Option<u32>,
    pinned: Option<File>,
}

#[cfg(unix)]
fn prepare_unix_write(
    root: UnixWorkspaceRoot,
    path: String,
    precondition: FilePrecondition,
    create_parents: bool,
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
        initial_mode: existing.map(|entry| entry.mode & 0o7777),
        pinned,
    })
}

#[cfg(unix)]
fn commit_unix_write(prepared: PreparedUnixWrite, bytes: &[u8]) -> Result<String, RpcError> {
    use std::io::Write as _;

    let PreparedUnixWrite { target, precondition, initial_mode, mut pinned } = prepared;
    target.verify_parent_identity()?;
    let (temporary_name, mut temporary) = create_temporary(&target, "write")?;
    let temporary_display = temporary_display(&target, &temporary_name);
    let stage_result = (|| {
        temporary
            .write_all(bytes)
            .map_err(|error| io_error("write-temporary", &temporary_display, error))?;
        temporary
            .flush()
            .map_err(|error| io_error("flush-temporary", &temporary_display, error))?;
        if let Some(mode) = initial_mode {
            temporary
                .set_permissions(std::fs::Permissions::from_mode(mode))
                .map_err(|error| io_error("set-permissions", &temporary_display, error))?;
        }
        temporary
            .sync_all()
            .map_err(|error| io_error("sync-temporary", &temporary_display, error))?;
        let temporary_metadata = temporary
            .metadata()
            .map_err(|error| io_error("stat-temporary", &temporary_display, error))?;
        target.verify_parent_identity()?;
        Ok(temporary_metadata)
    })();
    let temporary_metadata = match stage_result {
        Ok(metadata) => metadata,
        Err(error) => {
            return Err(cleanup_unpublished_temporary(&target, &temporary_name, error));
        }
    };
    match &precondition {
        FilePrecondition::Missing => {
            if let Err(error) = link_name(target.parent_fd(), &temporary_name, target.name()) {
                let error = if error.kind() == std::io::ErrorKind::AlreadyExists {
                    RpcError::new("conflict", "file appeared before commit")
                } else {
                    io_error("create", target.display(), error)
                };
                return Err(cleanup_unpublished_temporary(&target, &temporary_name, error));
            }
            if let Err(error) = unlink_name(target.parent_fd(), &temporary_name) {
                return Err(partial_write_with_recovery(
                    &target,
                    &temporary_name,
                    &format!("file was created but temporary link cleanup failed: {error}"),
                ));
            }
        }
        FilePrecondition::Any => {
            commit_any_write(&target, &temporary_name)?;
        }
        FilePrecondition::ContentHash(expected) => {
            let pinned = pinned.as_mut().ok_or_else(|| {
                RpcError::new("internal", "content-hash write lost its pinned target")
            })?;
            commit_content_hash_write(
                &target,
                &temporary_name,
                &temporary_metadata,
                pinned,
                expected,
            )?;
        }
    }
    target.sync_parent()?;
    Ok(hash_bytes(bytes))
}

#[cfg(unix)]
fn cleanup_unpublished_temporary(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
    error: RpcError,
) -> RpcError {
    match unlink_name(target.parent_fd(), temporary_name) {
        Ok(()) => error,
        Err(cleanup) if cleanup.kind() == std::io::ErrorKind::NotFound => error,
        Err(cleanup) => RpcError::new(
            "partial-write",
            format!("{}; temporary cleanup also failed: {}", error.message, cleanup),
        ),
    }
}

#[cfg(unix)]
fn commit_any_write(target: &UnixWorkspaceTarget, temporary_name: &CStr) -> Result<(), RpcError> {
    let existing = stat_entry(target, "stat-before-replace")?;
    if existing.as_ref().is_some_and(|entry| !entry.is_regular()) {
        let error = non_regular_entry_error(target, existing.as_ref());
        return Err(cleanup_unpublished_temporary(target, temporary_name, error));
    }
    if let Err(error) = rename_name(target.parent_fd(), temporary_name, target.name()) {
        let error = io_error("replace", target.display(), error);
        return Err(cleanup_unpublished_temporary(target, temporary_name, error));
    }
    Ok(())
}

#[cfg(unix)]
fn commit_content_hash_write(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
    temporary_metadata: &std::fs::Metadata,
    pinned: &mut File,
    expected: &str,
) -> Result<(), RpcError> {
    #[cfg(test)]
    pause_at_mutation_test_barrier_blocking(
        target.display(),
        MutationTestPoint::BeforeContentHashValidation,
    );
    let (actual, pinned_metadata) = hash_file_sync(pinned, target.display(), MAX_HASH_BYTES)?;
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(cleanup_unpublished_temporary(
            target,
            temporary_name,
            RpcError::new(
                "conflict",
                format!("content hash changed before commit: expected {expected}, found {actual}"),
            ),
        ));
    }
    let pinned_identity = RawEntryState::from_metadata(&pinned_metadata);
    let current = stat_entry(target, "stat-before-replace")?;
    if current.as_ref().is_none_or(|entry| !entry.same_object(&pinned_identity)) {
        return Err(cleanup_unpublished_temporary(
            target,
            temporary_name,
            RpcError::new("conflict", "file identity changed before commit"),
        ));
    }
    #[cfg(test)]
    pause_at_mutation_test_barrier_blocking(
        target.display(),
        MutationTestPoint::BeforeContentHashExchange,
    );
    if let Err(error) = exchange_names(target.parent_fd(), temporary_name, target.name()) {
        let error = if error.kind() == std::io::ErrorKind::NotFound {
            RpcError::new("conflict", "file disappeared before commit")
        } else {
            exchange_error(target.display(), error)
        };
        return Err(cleanup_unpublished_temporary(target, temporary_name, error));
    }
    let published = stat_entry(target, "stat-published")
        .map_err(|error| partial_write_with_recovery(target, temporary_name, &error.message))?
        .ok_or_else(|| {
            partial_write_with_recovery(target, temporary_name, "published entry disappeared")
        })?;
    let recovery = stat_named(
        target.parent_fd(),
        temporary_name,
        &temporary_display(target, temporary_name),
        "stat-recovery",
    )
    .map_err(|error| partial_write_with_recovery(target, temporary_name, &error.message))?
    .ok_or_else(|| {
        partial_write_with_recovery(target, temporary_name, "recovery entry disappeared")
    })?;
    #[cfg(test)]
    pause_at_mutation_test_barrier_blocking(
        target.display(),
        MutationTestPoint::AfterContentHashExchange,
    );
    let staged_identity = RawEntryState::from_metadata(temporary_metadata);
    if !published.same_object(&staged_identity) || !recovery.same_object(&pinned_identity) {
        rollback_exchange(target, temporary_name, &published, &recovery)?;
        return Err(RpcError::new("conflict", "file identity changed during commit"));
    }
    unlink_name(target.parent_fd(), temporary_name).map_err(|error| {
        partial_write_with_recovery(
            target,
            temporary_name,
            &format!("replacement committed but recovery cleanup failed: {error}"),
        )
    })
}

#[cfg(unix)]
fn rollback_exchange(
    target: &UnixWorkspaceTarget,
    temporary_name: &CStr,
    published: &RawEntryState,
    recovery: &RawEntryState,
) -> Result<(), RpcError> {
    let current_target = stat_entry(target, "rollback")
        .map_err(|error| partial_write_with_recovery(target, temporary_name, &error.message))?;
    let current_recovery = stat_named(
        target.parent_fd(),
        temporary_name,
        &temporary_display(target, temporary_name),
        "rollback",
    )
    .map_err(|error| partial_write_with_recovery(target, temporary_name, &error.message))?;
    if current_target.as_ref() != Some(published) || current_recovery.as_ref() != Some(recovery) {
        return Err(partial_write_with_recovery(
            target,
            temporary_name,
            "replacement validation failed and an exchanged entry changed before restoration",
        ));
    }
    exchange_names(target.parent_fd(), temporary_name, target.name())
        .map_err(|error| exchange_error(target.display(), error))?;
    unlink_name(target.parent_fd(), temporary_name).map_err(|error| {
        partial_write_with_recovery(
            target,
            temporary_name,
            &format!("original restored but staged-entry cleanup failed: {error}"),
        )
    })?;
    target.sync_parent()
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
fn commit_unix_remove(prepared: PreparedUnixRemove) -> Result<(), RpcError> {
    let PreparedUnixRemove { target, precondition, mut pinned } = prepared;
    target.verify_parent_identity()?;
    if matches!(precondition, FilePrecondition::Any) {
        unlink_name(target.parent_fd(), target.name())
            .map_err(|error| io_error("remove", target.display(), error))?;
        return target.sync_parent();
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
    if current.as_ref().is_none_or(|entry| !entry.same_object(&pinned_identity)) {
        return Err(RpcError::new("conflict", "file identity changed before removal"));
    }
    let quarantine = unique_name(".cmux-remove")?;
    rename_noreplace(target.parent_fd(), target.name(), &quarantine).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            RpcError::new("conflict", "file disappeared before commit")
        } else {
            rename_noreplace_error(target.display(), error)
        }
    })?;
    let quarantine_display = temporary_display(&target, &quarantine);
    let recovery =
        stat_named(target.parent_fd(), &quarantine, &quarantine_display, "stat-remove-recovery")
            .map_err(|error| partial_write_with_recovery(&target, &quarantine, &error.message))?
            .ok_or_else(|| {
                partial_write_with_recovery(
                    &target,
                    &quarantine,
                    "remove recovery entry disappeared",
                )
            })?;
    if !recovery.same_object(&pinned_identity) {
        let current_target = stat_entry(&target, "restore-remove")
            .map_err(|error| partial_write_with_recovery(&target, &quarantine, &error.message))?;
        let current_recovery =
            stat_named(target.parent_fd(), &quarantine, &quarantine_display, "restore-remove")
                .map_err(|error| {
                    partial_write_with_recovery(&target, &quarantine, &error.message)
                })?;
        if current_target.is_some() || current_recovery.as_ref() != Some(&recovery) {
            return Err(partial_write_with_recovery(
                &target,
                &quarantine,
                "remove recovery changed before restoration",
            ));
        }
        rename_noreplace(target.parent_fd(), &quarantine, target.name()).map_err(|error| {
            partial_write_with_recovery(
                &target,
                &quarantine,
                &format!("remove restoration failed: {error}"),
            )
        })?;
        target.sync_parent()?;
        return Err(RpcError::new("conflict", "file identity changed during removal"));
    }
    unlink_name(target.parent_fd(), &quarantine).map_err(|error| {
        partial_write_with_recovery(
            &target,
            &quarantine,
            &format!("file removed but recovery cleanup failed: {error}"),
        )
    })?;
    target.sync_parent()
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
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW,
                0o666,
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
) -> Result<Vec<u8>, RpcError> {
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
    Ok(bytes)
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

async fn read_path_bounded(path: &Path, maximum: usize) -> Result<Vec<u8>, RpcError> {
    let mut file =
        tokio::fs::File::open(path).await.map_err(|error| io_error("read", path, error))?;
    let metadata = file.metadata().await.map_err(|error| io_error("read", path, error))?;
    if !metadata.is_file() {
        return Err(RpcError::new("not-a-file", format!("not a file: {}", path.display())));
    }
    if metadata.len() > maximum as u64 {
        return Err(RpcError::new("resource-exhausted", format!("file exceeds {maximum} bytes")));
    }
    let capacity = usize::try_from(metadata.len()).unwrap_or(maximum).min(maximum);
    let mut bytes = Vec::with_capacity(capacity);
    (&mut file)
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

#[cfg(unix)]
fn is_executable(metadata: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    metadata.permissions().mode() & 0o111 != 0
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

fn parse_page_cursor(
    cursor: Option<&PageCursor>,
    kind: &str,
    scope: &str,
) -> Result<usize, RpcError> {
    let Some(PageCursor(cursor)) = cursor else {
        return Ok(0);
    };
    let mut parts = cursor.split(':');
    let valid_kind = parts.next() == Some(kind);
    let valid_scope = parts.next() == Some(scope);
    let offset = parts.next().and_then(|offset| offset.parse::<usize>().ok());
    if !valid_kind || !valid_scope || parts.next().is_some() || offset.is_none() {
        return Err(RpcError::new(
            "invalid-cursor",
            format!("cursor does not belong to this {kind} request"),
        ));
    }
    Ok(offset.unwrap_or_default())
}

fn make_page_cursor(kind: &str, scope: &str, offset: usize) -> PageCursor {
    PageCursor(format!("{kind}:{scope}:{offset}"))
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

    use super::*;

    async fn root() -> (tempfile::TempDir, Arc<WorkspaceRoot>) {
        let directory = tempdir().unwrap();
        let root =
            WorkspaceRoot::open(WorkspaceId("test".into()), directory.path().to_str().unwrap())
                .await
                .unwrap();
        (directory, root)
    }

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

    #[cfg(unix)]
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

    #[cfg(unix)]
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
        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0)).await.unwrap();

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

        tokio::fs::set_permissions(&target, std::fs::Permissions::from_mode(0)).await.unwrap();
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

    #[tokio::test]
    async fn directory_listing_is_sorted_bounded_and_hidden_aware() {
        let (_directory, root) = root().await;
        tokio::fs::create_dir(root.canonical_root().join("z-dir")).await.unwrap();
        tokio::fs::write(root.canonical_root().join("A.txt"), b"a").await.unwrap();
        tokio::fs::write(root.canonical_root().join(".hidden"), b"h").await.unwrap();
        let response = list_directory(&root, "", false, 1, None).await.unwrap();
        let WorkspaceResponse::Directory { entries, truncated, .. } = response else { panic!() };
        assert!(truncated);
        assert_eq!(entries[0].name, "z-dir");
    }

    #[tokio::test]
    async fn directory_cursor_returns_the_next_sorted_page() {
        let (_directory, root) = root().await;
        for name in ["c.txt", "a.txt", "b.txt"] {
            tokio::fs::write(root.canonical_root().join(name), name).await.unwrap();
        }
        let first = list_directory(&root, "", false, 2, None).await.unwrap();
        let WorkspaceResponse::Directory { entries, next_cursor: Some(cursor), .. } = first else {
            panic!()
        };
        assert_eq!(
            entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(),
            ["a.txt", "b.txt"]
        );

        let second = list_directory(&root, "", false, 2, Some(&cursor)).await.unwrap();
        let WorkspaceResponse::Directory { entries, next_cursor, truncated } = second else {
            panic!()
        };
        assert_eq!(entries.iter().map(|entry| entry.name.as_str()).collect::<Vec<_>>(), ["c.txt"]);
        assert_eq!(next_cursor, None);
        assert!(!truncated);

        let error = list_directory(&root, "", true, 2, Some(&cursor)).await.unwrap_err();
        assert_eq!(error.code, "invalid-cursor");
    }

    #[tokio::test]
    async fn search_is_literal_structured_and_bounded() {
        let (_directory, root) = root().await;
        tokio::fs::create_dir(root.canonical_root().join("src")).await.unwrap();
        tokio::fs::write(
            root.canonical_root().join("src/lib.rs"),
            b"before\nneedle here\nafter\nneedle twice\n",
        )
        .await
        .unwrap();
        let response = search(&root, "needle", &["src".into()], &["*.rs".into()], false, 1, None)
            .await
            .unwrap();
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
        tokio::fs::write(root.canonical_root().join("matches.txt"), b"needle one\nneedle two\n")
            .await
            .unwrap();
        let first = search(&root, "needle", &[], &[], false, 1, None).await.unwrap();
        let WorkspaceResponse::Search { matches, next_cursor: Some(cursor), .. } = first else {
            panic!()
        };
        assert_eq!(matches[0].line, 1);

        let second = search(&root, "needle", &[], &[], false, 1, Some(&cursor)).await.unwrap();
        let WorkspaceResponse::Search { matches, next_cursor, truncated } = second else {
            panic!()
        };
        assert_eq!(matches[0].line, 2);
        assert_eq!(next_cursor, None);
        assert!(!truncated);
    }

    #[test]
    fn wildcard_matching_handles_common_patterns() {
        assert!(wildcard_match("*.rs", "src/lib.rs"));
        assert!(wildcard_match("src/?ib.rs", "src/lib.rs"));
        assert!(!wildcard_match("*.md", "src/lib.rs"));
    }
}
