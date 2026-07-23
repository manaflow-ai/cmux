use std::collections::{HashSet, VecDeque};
use std::path::{Path, PathBuf};

use cmux_remote_protocol::{
    ByteString, DirectoryEntry, FileKind, FilePrecondition, FileStat, PageCursor, RpcError,
    SearchMatch, WorkspaceResponse,
};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};

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
    let resolved = root.resolve_existing(path).await?;
    read_path_bounded(&resolved, maximum).await
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

pub(crate) async fn remove_file_precondition_locked(
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

#[cfg(unix)]
async fn sync_parent(parent: &Path) -> Result<(), RpcError> {
    let parent = parent.to_owned();
    tokio::task::spawn_blocking(move || {
        std::fs::File::open(&parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| io_error("sync-directory", &parent, error))
    })
    .await
    .map_err(|error| RpcError::new("internal", format!("directory sync task failed: {error}")))?
}

#[cfg(not(unix))]
async fn sync_parent(_parent: &Path) -> Result<(), RpcError> {
    Ok(())
}

#[cfg(unix)]
async fn replace_file(temporary: &Path, target: &Path) -> Result<(), RpcError> {
    tokio::fs::rename(temporary, target).await.map_err(|error| io_error("replace", target, error))
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
