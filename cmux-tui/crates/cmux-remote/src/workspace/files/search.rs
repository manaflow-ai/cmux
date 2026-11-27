//! Workspace search: walk the tree breadth first, match file contents, page the results.

use super::*;

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
pub(crate) struct SearchContinuation {
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

    pub(crate) fn retained_bytes(&self) -> usize {
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

fn matches_globs(path: &str, globs: &[String]) -> bool {
    globs.is_empty() || globs.iter().any(|glob| wildcard_match(glob, path))
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
