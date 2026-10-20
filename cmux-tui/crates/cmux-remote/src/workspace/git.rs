use std::mem::size_of;
use std::ops::Range;
use std::process::Stdio;
use std::time::Duration;

#[cfg(unix)]
use std::os::fd::AsRawFd as _;
#[cfg(unix)]
use std::os::unix::process::CommandExt as _;

use cmux_remote_protocol::{
    ByteString, DiffFormat, GitChange, GitStatus, PageCursor, RpcError, StructuredDiffHunkV1,
    StructuredDiffLineKind, StructuredDiffLineV1, StructuredDiffV1, StructuredFileDiffV1,
    WorkspaceResponse,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;

use super::PreparedWorkspaceResponse;
use super::path::{WorkspaceRoot, normalize_protocol_path};
use super::query::WorkspaceQueryContext;

const MAX_GIT_DIFF_BYTES: usize = 8 * 1024 * 1024;
const MAX_GIT_DIFF_SOURCE_BYTES: usize = 32 * 1024 * 1024;
const MAX_GIT_DIFF_METADATA_BYTES: usize = 8 * 1024 * 1024;
const MAX_GIT_STATUS_BYTES: usize = 4 * 1024 * 1024;
const MAX_GIT_STDERR_BYTES: usize = 256 * 1024;
const GIT_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_DIFF_CONTEXT: u16 = 1_000;
const MAX_DIFF_PATHS: usize = 256;
const MAX_DIFF_PATH_BYTES: usize = 1024 * 1024;
const MAX_GIT_CHANGES: usize = 10_000;
const MAX_GIT_DIFF_FILES: usize = 10_000;
const MAX_GIT_STATUS_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone)]
pub(super) struct DiffContinuation {
    unified: Vec<u8>,
    sections: Vec<Range<usize>>,
    path_metadata: Option<Vec<DiffPathPair>>,
    next_index: usize,
}

impl DiffContinuation {
    pub(super) fn retained_bytes(&self) -> usize {
        let metadata_bytes = self.path_metadata.as_ref().map_or(0, |metadata| {
            metadata.capacity().saturating_mul(size_of::<DiffPathPair>()).saturating_add(
                metadata
                    .iter()
                    .map(DiffPathPair::retained_bytes)
                    .fold(0usize, usize::saturating_add),
            )
        });
        size_of::<Self>()
            .saturating_add(self.unified.capacity())
            .saturating_add(self.sections.capacity().saturating_mul(size_of::<Range<usize>>()))
            .saturating_add(metadata_bytes)
    }
}

pub(crate) async fn status(root: &WorkspaceRoot) -> Result<WorkspaceResponse, RpcError> {
    let output = run_git(
        root,
        &["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"],
        MAX_GIT_STATUS_BYTES,
    )
    .await?;
    let (branch, changes) = parse_status(&output)?;
    let head = match run_git(root, &["rev-parse", "--verify", "HEAD"], 1024).await {
        Ok(output) => Some(String::from_utf8_lossy(&output).trim().to_string()),
        Err(error) if error.code == "git-command-failed" => None,
        Err(error) => return Err(error),
    };
    Ok(WorkspaceResponse::GitStatus { status: GitStatus { branch, head, changes } })
}

pub(crate) async fn diff(
    query_context: &WorkspaceQueryContext<'_>,
    paths: &[String],
    staged: bool,
    diff_context: u16,
    format: DiffFormat,
    cursor: Option<&PageCursor>,
    max_bytes: Option<u32>,
) -> Result<PreparedWorkspaceResponse, RpcError> {
    if diff_context > MAX_DIFF_CONTEXT {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("diff context exceeds {MAX_DIFF_CONTEXT} lines"),
        ));
    }
    if paths.len() > MAX_DIFF_PATHS
        || paths.iter().fold(0usize, |total, path| total.saturating_add(path.len()))
            > MAX_DIFF_PATH_BYTES
    {
        return Err(RpcError::new(
            "resource-exhausted",
            format!(
                "diff accepts at most {MAX_DIFF_PATHS} paths and {MAX_DIFF_PATH_BYTES} path bytes"
            ),
        ));
    }
    let normalized =
        paths.iter().map(|path| normalize_protocol_path(path)).collect::<Result<Vec<_>, _>>()?;
    if normalized.iter().any(String::is_empty) {
        return Err(RpcError::new("invalid-path", "diff paths cannot be empty"));
    }
    let default_maximum = u32::try_from(MAX_GIT_DIFF_BYTES).unwrap_or(u32::MAX);
    let maximum =
        usize::try_from(max_bytes.unwrap_or(default_maximum)).unwrap_or(MAX_GIT_DIFF_BYTES);
    if maximum == 0 || maximum > MAX_GIT_DIFF_BYTES {
        return Err(RpcError::new(
            "invalid-argument",
            format!("diff max_bytes must be between 1 and {MAX_GIT_DIFF_BYTES}"),
        ));
    }
    let root = query_context.root;
    let scope = diff_page_scope(&normalized, staged, diff_context, format);
    let mut arguments = vec![
        "diff".to_string(),
        "--no-ext-diff".to_string(),
        "--no-textconv".to_string(),
        "--no-color".to_string(),
        format!("--unified={diff_context}"),
    ];
    if staged {
        arguments.push("--cached".into());
    }
    if !normalized.is_empty() {
        arguments.push("--".into());
        arguments.extend(normalized.iter().cloned());
    }
    let references = arguments.iter().map(String::as_str).collect::<Vec<_>>();
    let (mut continuation, mut delivery) = if let Some(cursor) = cursor {
        let (continuation, delivery) =
            query_context.service.lease_diff(query_context.owner, &root.id, &scope, cursor)?;
        (continuation, Some(delivery))
    } else {
        let (mut unified, mut path_metadata) =
            if matches!(format, DiffFormat::Structured | DiffFormat::StructuredV1) {
                let (unified, metadata) = tokio::try_join!(
                    run_git(root, &references, MAX_GIT_DIFF_SOURCE_BYTES),
                    read_diff_path_metadata(root, &normalized, staged),
                )?;
                (unified, Some(parse_diff_path_metadata(&metadata)?))
            } else {
                (run_git(root, &references, MAX_GIT_DIFF_SOURCE_BYTES).await?, None)
            };
        let mut sections = split_diff_section_ranges(&unified);
        if sections.len() > MAX_GIT_DIFF_FILES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("git diff exceeds {MAX_GIT_DIFF_FILES} files"),
            ));
        }
        if path_metadata.as_ref().is_some_and(|metadata| metadata.len() != sections.len()) {
            return Err(RpcError::new(
                "git-parse-error",
                "git path metadata does not match the diff sections",
            ));
        }
        unified.shrink_to_fit();
        sections.shrink_to_fit();
        if let Some(metadata) = &mut path_metadata {
            metadata.shrink_to_fit();
        }
        (DiffContinuation { unified, sections, path_metadata, next_index: 0 }, None)
    };

    let start = continuation.next_index;
    let mut page = Vec::new();
    let mut index = start;
    while let Some(section) = continuation.sections.get(index) {
        let section_length = section.end.saturating_sub(section.start);
        if section_length > maximum {
            if page.is_empty() {
                return Err(RpcError::new(
                    "resource-exhausted",
                    format!("one file diff exceeds the {maximum}-byte page limit"),
                ));
            }
            break;
        }
        if page.len().saturating_add(section_length) > maximum {
            break;
        }
        page.extend_from_slice(&continuation.unified[section.clone()]);
        index += 1;
    }
    let mut response = match format {
        DiffFormat::Unified => WorkspaceResponse::Diff {
            data: ByteString::from_bytes(&page),
            format,
            next_cursor: None,
        },
        DiffFormat::Structured | DiffFormat::StructuredV1 => {
            let text = std::str::from_utf8(&page)
                .map_err(|_| RpcError::new("invalid-text", "git diff is not UTF-8"))?;
            let path_metadata = continuation.path_metadata.as_ref().ok_or_else(|| {
                RpcError::new("internal", "structured diff path metadata was not collected")
            })?;
            let metadata = &path_metadata[start..index];
            let mut structured = parse_structured_diff(text);
            if metadata.len() != structured.files.len() {
                return Err(RpcError::new(
                    "git-parse-error",
                    "git path metadata does not match the structured diff files",
                ));
            }
            for (file, paths) in structured.files.iter_mut().zip(metadata) {
                file.old_path.clone_from(&paths.old_path);
                file.new_path.clone_from(&paths.new_path);
            }
            if format == DiffFormat::StructuredV1 {
                WorkspaceResponse::StructuredDiff { diff: structured, next_cursor: None }
            } else {
                let legacy = LegacyStructuredDiff {
                    files: structured
                        .files
                        .iter()
                        .map(|file| LegacyStructuredFileDiff {
                            old_path: file.old_path.as_deref(),
                            new_path: file.new_path.as_deref(),
                            hunks: &file.hunks,
                        })
                        .collect(),
                };
                let data = serde_json::to_vec(&legacy)
                    .map_err(|error| RpcError::new("internal", format!("encode diff: {error}")))?;
                if data.len() > MAX_GIT_DIFF_BYTES {
                    return Err(RpcError::new(
                        "resource-exhausted",
                        format!("encoded diff exceeds {MAX_GIT_DIFF_BYTES} bytes"),
                    ));
                }
                WorkspaceResponse::Diff {
                    data: ByteString::from_bytes(&data),
                    format,
                    next_cursor: None,
                }
            }
        }
    };
    continuation.next_index = index;
    let next_cursor = if index < continuation.sections.len() {
        let (next, next_delivery) = query_context.service.put_diff(
            query_context.owner,
            &root.id,
            &scope,
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
    match &mut response {
        WorkspaceResponse::Diff { next_cursor: response_cursor, .. }
        | WorkspaceResponse::StructuredDiff { next_cursor: response_cursor, .. } => {
            *response_cursor = next_cursor;
        }
        _ => unreachable!("diff request constructed a diff response"),
    }
    Ok(PreparedWorkspaceResponse::paginated(response, delivery))
}

async fn run_git(
    root: &WorkspaceRoot,
    arguments: &[&str],
    maximum_stdout: usize,
) -> Result<Vec<u8>, RpcError> {
    let mut command = tokio::process::Command::new("git");
    // The daemon's launch environment must not redirect an RPC away from its pinned workspace.
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    command
        .args(["-c", "core.fsmonitor=false"])
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_PAGER", "cat")
        .env("LC_ALL", "C")
        .kill_on_drop(true);
    #[cfg(not(unix))]
    command.current_dir(root.canonical_root());
    #[cfg(unix)]
    {
        // Keep Git on the same pinned directory as file and process RPCs even
        // if the registered pathname is moved and replaced.
        let directory = root
            .unix_root()
            .pinned_directory_for_canonical_path(root.canonical_root())?
            .try_clone_file()?;
        // SAFETY: `fchdir` is async-signal-safe, the descriptor remains open
        // through `spawn`, and the closure performs no allocation.
        unsafe {
            command.as_std_mut().pre_exec(move || {
                if libc::fchdir(directory.as_raw_fd()) == 0 {
                    Ok(())
                } else {
                    Err(std::io::Error::last_os_error())
                }
            });
        }
    }
    let mut child = command
        .spawn()
        .map_err(|error| RpcError::new("git-unavailable", format!("start git: {error}")))?;
    let mut stdout =
        child.stdout.take().ok_or_else(|| RpcError::new("internal", "git stdout was not piped"))?;
    let mut stderr =
        child.stderr.take().ok_or_else(|| RpcError::new("internal", "git stderr was not piped"))?;
    let execution = async {
        let stdout_read = read_bounded(&mut stdout, maximum_stdout, "git stdout");
        let stderr_read = read_bounded(&mut stderr, MAX_GIT_STDERR_BYTES, "git stderr");
        let wait = async {
            child
                .wait()
                .await
                .map_err(|error| RpcError::new("git-error", format!("wait for git: {error}")))
        };
        let (stdout, stderr, status) = tokio::try_join!(stdout_read, stderr_read, wait)?;
        if !status.success() {
            return Err(RpcError::new(
                "git-command-failed",
                String::from_utf8_lossy(&stderr).trim().to_string(),
            ));
        }
        Ok(stdout)
    };
    tokio::time::timeout(GIT_TIMEOUT, execution)
        .await
        .map_err(|_| RpcError::new("deadline-exceeded", "git command timed out"))?
}

async fn read_diff_path_metadata(
    root: &WorkspaceRoot,
    paths: &[String],
    staged: bool,
) -> Result<Vec<u8>, RpcError> {
    let mut arguments = vec![
        "diff".to_string(),
        "--name-status".to_string(),
        "-z".to_string(),
        "--no-ext-diff".to_string(),
        "--no-textconv".to_string(),
    ];
    if staged {
        arguments.push("--cached".into());
    }
    if !paths.is_empty() {
        arguments.push("--".into());
        arguments.extend(paths.iter().cloned());
    }
    let references = arguments.iter().map(String::as_str).collect::<Vec<_>>();
    run_git(root, &references, MAX_GIT_DIFF_METADATA_BYTES).await
}

async fn read_bounded(
    reader: &mut (impl tokio::io::AsyncRead + Unpin),
    maximum: usize,
    label: &str,
) -> Result<Vec<u8>, RpcError> {
    let mut bytes = Vec::new();
    reader
        .take((maximum as u64).saturating_add(1))
        .read_to_end(&mut bytes)
        .await
        .map_err(|error| RpcError::new("git-error", format!("read {label}: {error}")))?;
    if bytes.len() > maximum {
        return Err(RpcError::new(
            "resource-exhausted",
            format!("{label} exceeds {maximum} bytes"),
        ));
    }
    Ok(bytes)
}

#[derive(Clone)]
struct DiffPathPair {
    old_path: Option<String>,
    new_path: Option<String>,
}

impl DiffPathPair {
    fn retained_bytes(&self) -> usize {
        size_of::<Self>()
            .saturating_add(self.old_path.as_ref().map_or(0, String::capacity))
            .saturating_add(self.new_path.as_ref().map_or(0, String::capacity))
            .saturating_add(64)
    }
}

fn parse_diff_path_metadata(output: &[u8]) -> Result<Vec<DiffPathPair>, RpcError> {
    let mut offset = 0usize;
    let mut paths = Vec::new();
    while offset < output.len() {
        if paths.len() >= MAX_GIT_DIFF_FILES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("git diff metadata exceeds {MAX_GIT_DIFF_FILES} files"),
            ));
        }
        let status = take_nul_field(output, &mut offset)?;
        let kind = status[0];
        if !matches!(kind, b'A' | b'B' | b'C' | b'D' | b'M' | b'R' | b'T' | b'U' | b'X')
            || !status[1..].iter().all(u8::is_ascii_digit)
        {
            return Err(RpcError::new("git-parse-error", "malformed Git name-status entry"));
        }
        let first = take_nul_field(output, &mut offset)?;
        let second = if matches!(kind, b'C' | b'R') {
            Some(take_nul_field(output, &mut offset)?)
        } else {
            None
        };
        let first = diff_metadata_path(first)?;
        let pair = match kind {
            b'A' => DiffPathPair { old_path: None, new_path: Some(first) },
            b'D' => DiffPathPair { old_path: Some(first), new_path: None },
            b'C' | b'R' => {
                let second = second.ok_or_else(|| {
                    RpcError::new("git-parse-error", "rename is missing its destination")
                })?;
                DiffPathPair { old_path: Some(first), new_path: Some(diff_metadata_path(second)?) }
            }
            _ => DiffPathPair { old_path: Some(first.clone()), new_path: Some(first) },
        };
        paths.push(pair);
    }
    Ok(paths)
}

fn take_nul_field<'a>(output: &'a [u8], offset: &mut usize) -> Result<&'a [u8], RpcError> {
    let remaining = &output[*offset..];
    let end = remaining
        .iter()
        .position(|byte| *byte == 0)
        .ok_or_else(|| RpcError::new("git-parse-error", "unterminated Git name-status entry"))?;
    let field = &remaining[..end];
    if field.is_empty() {
        return Err(RpcError::new("git-parse-error", "empty Git name-status field"));
    }
    *offset += end + 1;
    Ok(field)
}

fn diff_metadata_path(path: &[u8]) -> Result<String, RpcError> {
    std::str::from_utf8(path)
        .map(str::to_string)
        .map_err(|_| RpcError::new("invalid-path", "git path is not UTF-8"))
}

fn parse_status(output: &[u8]) -> Result<(Option<String>, Vec<GitChange>), RpcError> {
    let fields =
        output.split(|byte| *byte == 0).filter(|field| !field.is_empty()).collect::<Vec<_>>();
    let mut branch = None;
    let mut changes = Vec::new();
    let mut response_bytes = 0usize;
    let mut index = 0usize;
    if let Some(first) = fields.first()
        && first.starts_with(b"## ")
    {
        let header = String::from_utf8_lossy(&first[3..]);
        branch = parse_branch(&header);
        index = 1;
    }
    while index < fields.len() {
        if changes.len() >= MAX_GIT_CHANGES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("git status exceeds {MAX_GIT_CHANGES} changes"),
            ));
        }
        let field = fields[index];
        if field.len() < 3 || field[2] != b' ' {
            return Err(RpcError::new("git-parse-error", "malformed git status entry"));
        }
        let index_status = char::from(field[0]);
        let worktree_status = char::from(field[1]);
        let path = std::str::from_utf8(&field[3..])
            .map_err(|_| RpcError::new("invalid-path", "git path is not UTF-8"))?
            .to_string();
        index += 1;
        let renamed = index_status == 'R'
            || index_status == 'C'
            || worktree_status == 'R'
            || worktree_status == 'C';
        let original_path = if renamed {
            let original = fields
                .get(index)
                .ok_or_else(|| RpcError::new("git-parse-error", "rename is missing its source"))?;
            index += 1;
            Some(
                std::str::from_utf8(original)
                    .map_err(|_| RpcError::new("invalid-path", "git path is not UTF-8"))?
                    .to_string(),
            )
        } else {
            None
        };
        let change_bytes = path
            .len()
            .saturating_add(original_path.as_ref().map_or(0, String::len))
            .saturating_mul(6)
            .saturating_add(128);
        if response_bytes.saturating_add(change_bytes) > MAX_GIT_STATUS_RESPONSE_BYTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("encoded git status exceeds {MAX_GIT_STATUS_RESPONSE_BYTES} bytes"),
            ));
        }
        response_bytes = response_bytes.saturating_add(change_bytes);
        changes.push(GitChange { path, original_path, index_status, worktree_status });
    }
    Ok((branch, changes))
}

fn parse_branch(header: &str) -> Option<String> {
    if header.starts_with("HEAD ") || header.starts_with("No commits yet on ") {
        return header.strip_prefix("No commits yet on ").map(str::to_string);
    }
    let name = header.split("...").next().unwrap_or(header).split_whitespace().next()?;
    (!name.is_empty()).then(|| name.to_string())
}

fn split_diff_section_ranges(source: &[u8]) -> Vec<Range<usize>> {
    if source.is_empty() {
        return Vec::new();
    }
    const HEADER: &[u8] = b"diff --git ";
    let mut starts = Vec::new();
    let mut line_start = 0usize;
    while line_start < source.len() {
        if source[line_start..].starts_with(HEADER) {
            starts.push(line_start);
        }
        let Some(newline) = source[line_start..].iter().position(|byte| *byte == b'\n') else {
            break;
        };
        line_start = line_start.saturating_add(newline).saturating_add(1);
    }
    if starts.is_empty() {
        return std::iter::once(0..source.len()).collect();
    }
    if starts[0] != 0 {
        starts[0] = 0;
    }
    starts
        .iter()
        .enumerate()
        .map(|(position, start)| {
            let end = starts.get(position + 1).copied().unwrap_or(source.len());
            *start..end
        })
        .collect()
}

#[cfg(test)]
fn split_diff_sections(source: &[u8]) -> Vec<&[u8]> {
    split_diff_section_ranges(source).into_iter().map(|range| &source[range]).collect()
}

fn diff_page_scope(paths: &[String], staged: bool, context: u16, format: DiffFormat) -> String {
    let mut digest = Sha256::new();
    digest.update([u8::from(staged)]);
    digest.update(context.to_be_bytes());
    digest.update([match format {
        DiffFormat::Unified => 0,
        DiffFormat::Structured => 1,
        DiffFormat::StructuredV1 => 2,
    }]);
    for path in paths {
        digest.update(u64::try_from(path.len()).unwrap_or(u64::MAX).to_be_bytes());
        digest.update(path.as_bytes());
    }
    let bytes = digest.finalize();
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

#[derive(Serialize)]
struct LegacyStructuredDiff<'a> {
    files: Vec<LegacyStructuredFileDiff<'a>>,
}

#[derive(Serialize)]
struct LegacyStructuredFileDiff<'a> {
    old_path: Option<&'a str>,
    new_path: Option<&'a str>,
    hunks: &'a [StructuredDiffHunkV1],
}

fn parse_structured_diff(source: &str) -> StructuredDiffV1 {
    let mut files = Vec::<StructuredFileDiffV1>::new();
    let mut current_file: Option<StructuredFileDiffV1> = None;
    let mut current_hunk: Option<StructuredDiffHunkV1> = None;

    for line in source.lines() {
        if line.starts_with("diff --git ") {
            if let Some(hunk) = current_hunk.take()
                && let Some(file) = current_file.as_mut()
            {
                file.hunks.push(hunk);
            }
            if let Some(file) = current_file.take() {
                files.push(file);
            }
            let (old_path, new_path) = diff_git_paths(line);
            current_file = Some(StructuredFileDiffV1 {
                old_path,
                new_path,
                metadata: Vec::new(),
                hunks: Vec::new(),
            });
        } else if current_hunk.is_none()
            && let Some(path) = line.strip_prefix("--- ")
        {
            current_file.get_or_insert_with(empty_structured_file).old_path = structured_path(path);
        } else if current_hunk.is_none()
            && let Some(path) = line.strip_prefix("+++ ")
        {
            current_file.get_or_insert_with(empty_structured_file).new_path = structured_path(path);
        } else if line.starts_with("@@ ") || line == "@@" {
            if let Some(hunk) = current_hunk.take()
                && let Some(file) = current_file.as_mut()
            {
                file.hunks.push(hunk);
            }
            current_hunk =
                Some(StructuredDiffHunkV1 { header: line.to_string(), lines: Vec::new() });
        } else if let Some(hunk) = current_hunk.as_mut() {
            let (kind, text) = if let Some(text) = line.strip_prefix('+') {
                (StructuredDiffLineKind::Added, text)
            } else if let Some(text) = line.strip_prefix('-') {
                (StructuredDiffLineKind::Deleted, text)
            } else if let Some(text) = line.strip_prefix(' ') {
                (StructuredDiffLineKind::Context, text)
            } else {
                (StructuredDiffLineKind::Metadata, line)
            };
            hunk.lines.push(StructuredDiffLineV1 { kind, text: text.to_string() });
        } else if let Some(file) = current_file.as_mut() {
            if let Some(path) = line.strip_prefix("rename from ") {
                file.old_path = structured_path(path);
            } else if let Some(path) = line.strip_prefix("rename to ") {
                file.new_path = structured_path(path);
            } else if let Some(path) = line.strip_prefix("copy from ") {
                file.old_path = structured_path(path);
            } else if let Some(path) = line.strip_prefix("copy to ") {
                file.new_path = structured_path(path);
            } else if line.starts_with("new file mode ") {
                file.old_path = None;
            } else if line.starts_with("deleted file mode ") {
                file.new_path = None;
            }
            file.metadata.push(line.to_string());
        }
    }
    if let Some(hunk) = current_hunk
        && let Some(file) = current_file.as_mut()
    {
        file.hunks.push(hunk);
    }
    if let Some(file) = current_file {
        files.push(file);
    }
    StructuredDiffV1 { version: 1, files }
}

fn empty_structured_file() -> StructuredFileDiffV1 {
    StructuredFileDiffV1 { old_path: None, new_path: None, metadata: Vec::new(), hunks: Vec::new() }
}

fn diff_git_paths(line: &str) -> (Option<String>, Option<String>) {
    let Some(paths) = line.strip_prefix("diff --git ") else {
        return (None, None);
    };
    let Some((old, new)) = paths.rsplit_once(" b/") else {
        return (None, None);
    };
    (structured_path(old), structured_path(&format!("b/{new}")))
}

fn structured_path(path: &str) -> Option<String> {
    let path = path.trim();
    if path == "/dev/null" {
        None
    } else {
        Some(
            path.strip_prefix("a/").or_else(|| path.strip_prefix("b/")).unwrap_or(path).to_string(),
        )
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::process::Command;
    use std::sync::Arc;

    use cmux_remote_protocol::WorkspaceId;
    use tempfile::tempdir;

    use super::super::{ClientScope, query::WorkspaceQueryService};
    use super::*;

    fn git(root: &Path, arguments: &[&str]) {
        let status = Command::new("git").arg("-C").arg(root).args(arguments).status().unwrap();
        assert!(status.success(), "git {arguments:?} failed with {status}");
    }

    fn write_test_file(root: &Path, path: &str, contents: &[u8]) {
        let path = root.join(path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(path, contents).unwrap();
    }

    async fn structured_diff(root: &WorkspaceRoot, staged: bool) -> StructuredDiffV1 {
        let queries = WorkspaceQueryService::default();
        let owner = ClientScope::new("test", cmux_remote_protocol::SessionId([1; 16]));
        let context = WorkspaceQueryContext::new(&queries, &owner, root);
        let response = diff(&context, &[], staged, 3, DiffFormat::StructuredV1, None, None)
            .await
            .unwrap()
            .commit();
        let WorkspaceResponse::StructuredDiff { diff, .. } = response else { panic!() };
        diff
    }

    async fn git_root() -> (tempfile::TempDir, Arc<WorkspaceRoot>) {
        let directory = tempdir().unwrap();
        git(directory.path(), &["init", "-q"]);
        git(directory.path(), &["config", "user.email", "test@example.com"]);
        git(directory.path(), &["config", "user.name", "Test"]);
        git(directory.path(), &["config", "core.quotePath", "true"]);
        std::fs::write(directory.path().join("tracked.txt"), "before\n").unwrap();
        git(directory.path(), &["add", "tracked.txt"]);
        git(directory.path(), &["commit", "-qm", "initial"]);
        let root =
            WorkspaceRoot::open(WorkspaceId("git".into()), directory.path().to_str().unwrap())
                .await
                .unwrap();
        (directory, root)
    }

    #[tokio::test]
    async fn status_and_structured_diff_are_bounded_and_typed() {
        let (_directory, root) = git_root().await;
        let queries = WorkspaceQueryService::default();
        let owner = ClientScope::new("test", cmux_remote_protocol::SessionId([1; 16]));
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        tokio::fs::write(root.canonical_root().join("tracked.txt"), b"after\n").await.unwrap();
        let response = status(&root).await.unwrap();
        let WorkspaceResponse::GitStatus { status } = response else { panic!() };
        assert_eq!(status.changes[0].path, "tracked.txt");
        assert_eq!(status.changes[0].worktree_status, 'M');

        let response = diff(&context, &[], false, 3, DiffFormat::Structured, None, None)
            .await
            .unwrap()
            .commit();
        let WorkspaceResponse::Diff { data, .. } = response else { panic!() };
        let decoded = data.decode().unwrap();
        let json: serde_json::Value = serde_json::from_slice(&decoded).unwrap();
        assert_eq!(json["files"][0]["new_path"], "tracked.txt");
        assert!(json["files"][0]["hunks"][0]["lines"].is_array());
        assert!(json["files"][0].get("metadata").is_none());

        let typed = diff(&context, &[], false, 3, DiffFormat::StructuredV1, None, None)
            .await
            .unwrap()
            .commit();
        let WorkspaceResponse::StructuredDiff { diff, .. } = typed else { panic!() };
        assert_eq!(diff.version, 1);
        assert_eq!(diff.files[0].new_path.as_deref(), Some("tracked.txt"));
        assert!(!diff.files[0].metadata.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn status_uses_the_pinned_root_after_its_path_is_replaced() {
        let parent = tempdir().unwrap();
        let root_path = parent.path().join("workspace");
        let pinned_path = parent.path().join("pinned-workspace");
        std::fs::create_dir(&root_path).unwrap();
        git(&root_path, &["init", "-q"]);
        git(&root_path, &["config", "user.email", "test@example.com"]);
        git(&root_path, &["config", "user.name", "Test"]);
        std::fs::write(root_path.join("tracked.txt"), "before\n").unwrap();
        git(&root_path, &["add", "tracked.txt"]);
        git(&root_path, &["commit", "-qm", "initial"]);
        let root =
            WorkspaceRoot::open(WorkspaceId("pinned-git".into()), root_path.to_str().unwrap())
                .await
                .unwrap();

        std::fs::rename(&root_path, &pinned_path).unwrap();
        std::fs::create_dir(&root_path).unwrap();
        git(&root_path, &["init", "-q"]);
        std::fs::write(root_path.join("replacement.txt"), "replacement\n").unwrap();
        std::fs::write(pinned_path.join("tracked.txt"), "after\n").unwrap();

        let response = status(&root).await.unwrap();
        let WorkspaceResponse::GitStatus { status } = response else { panic!() };
        let paths = status.changes.iter().map(|change| change.path.as_str()).collect::<Vec<_>>();
        assert_eq!(paths, vec!["tracked.txt"]);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn status_disables_repository_fsmonitor() {
        use std::os::unix::fs::PermissionsExt;

        let (_directory, root) = git_root().await;
        let hook = root.canonical_root().join("fsmonitor-hook");
        let marker = root.canonical_root().join("fsmonitor-hook.invoked");
        std::fs::write(&hook, "#!/bin/sh\n: > \"$0.invoked\"\nprintf 'cmux-token\\n'\n").unwrap();
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o700)).unwrap();
        git(root.canonical_root(), &["config", "core.fsmonitor", hook.to_str().unwrap()]);

        assert!(Command::new(&hook).status().unwrap().success());
        assert!(marker.exists(), "positive control did not execute fsmonitor hook");
        std::fs::remove_file(&marker).unwrap();

        status(&root).await.unwrap();
        assert!(!marker.exists(), "workspace Git status executed repository fsmonitor hook");
    }

    #[tokio::test]
    async fn status_ignores_repository_selecting_environment() {
        const CHILD: &str = "CMUX_GIT_ENVIRONMENT_TEST_CHILD";
        const ROOT: &str = "CMUX_GIT_ENVIRONMENT_TEST_ROOT";
        if std::env::var_os(CHILD).is_some() {
            let root_path = std::env::var_os(ROOT).expect("isolated Git test root is present");
            let root = WorkspaceRoot::open(
                WorkspaceId("git-environment".into()),
                Path::new(&root_path).to_str().unwrap(),
            )
            .await
            .unwrap();
            let response = status(&root).await.unwrap();
            let WorkspaceResponse::GitStatus { status } = response else { panic!() };
            let paths =
                status.changes.iter().map(|change| change.path.as_str()).collect::<Vec<_>>();
            assert!(paths.contains(&"target-only.txt"), "target status missing: {paths:?}");
            assert!(!paths.contains(&"decoy-only.txt"), "decoy status escaped its workspace");
            return;
        }

        let (target, _target_root) = git_root().await;
        let (decoy, _decoy_root) = git_root().await;
        std::fs::write(target.path().join("target-only.txt"), "target\n").unwrap();
        std::fs::write(decoy.path().join("decoy-only.txt"), "decoy\n").unwrap();
        let output = Command::new(std::env::current_exe().unwrap())
            .arg("--exact")
            .arg("workspace::git::tests::status_ignores_repository_selecting_environment")
            .arg("--nocapture")
            .env(CHILD, "1")
            .env(ROOT, target.path())
            .env("GIT_DIR", decoy.path().join(".git"))
            .env("GIT_WORK_TREE", decoy.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "isolated Git environment test failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[tokio::test]
    async fn structured_diff_decodes_modified_git_paths() {
        let (_directory, root) = git_root().await;
        let paths = [
            "quote\"name.bin",
            "tab\tname.bin",
            "\u{65e5}\u{672c}\u{8a9e}.bin",
            "folder b/name.bin",
        ];
        for (index, path) in paths.iter().enumerate() {
            write_test_file(root.canonical_root(), path, format!("before {index}\0").as_bytes());
        }
        git(root.canonical_root(), &["add", "."]);
        git(root.canonical_root(), &["commit", "-qm", "special paths"]);
        for (index, path) in paths.iter().enumerate() {
            write_test_file(root.canonical_root(), path, format!("after {index}\0").as_bytes());
        }

        let parsed = structured_diff(&root, false).await;
        assert_eq!(parsed.files.len(), paths.len());
        for path in paths {
            let file = parsed
                .files
                .iter()
                .find(|file| file.new_path.as_deref() == Some(path))
                .unwrap_or_else(|| panic!("missing modified path {path:?}"));
            assert_eq!(file.old_path.as_deref(), Some(path));
            assert!(file.hunks.is_empty());
        }
    }

    #[tokio::test]
    async fn structured_diff_decodes_renamed_git_paths() {
        let (_directory, root) = git_root().await;
        let paths = [
            ("old\"quote.txt", "new\"quote.txt"),
            ("old\ttab.txt", "new\ttab.txt"),
            ("\u{53e4}\u{3044}.txt", "\u{65b0}\u{3057}\u{3044}.txt"),
            ("old b/path.txt", "new b/path.txt"),
        ];
        for (index, (old, _new)) in paths.iter().enumerate() {
            write_test_file(
                root.canonical_root(),
                old,
                format!("unique contents {index}\n").as_bytes(),
            );
        }
        git(root.canonical_root(), &["add", "."]);
        git(root.canonical_root(), &["commit", "-qm", "rename sources"]);
        for (old, new) in paths {
            let new_path = root.canonical_root().join(new);
            if let Some(parent) = new_path.parent() {
                std::fs::create_dir_all(parent).unwrap();
            }
            std::fs::rename(root.canonical_root().join(old), new_path).unwrap();
        }
        git(root.canonical_root(), &["add", "-A"]);

        let parsed = structured_diff(&root, true).await;
        assert_eq!(parsed.files.len(), paths.len());
        for (old, new) in paths {
            let file = parsed
                .files
                .iter()
                .find(|file| {
                    file.old_path.as_deref() == Some(old) && file.new_path.as_deref() == Some(new)
                })
                .unwrap_or_else(|| panic!("missing rename {old:?} -> {new:?}"));
            assert!(file.hunks.is_empty());
        }
    }

    #[tokio::test]
    async fn unified_diff_cursor_pages_on_file_boundaries() {
        let (_directory, root) = git_root().await;
        let queries = WorkspaceQueryService::default();
        let owner = ClientScope::new("test", cmux_remote_protocol::SessionId([1; 16]));
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        std::fs::write(root.canonical_root().join("second.txt"), "before\n").unwrap();
        for args in [["add", "second.txt"].as_slice(), ["commit", "-qm", "second"].as_slice()] {
            assert!(
                Command::new("git")
                    .arg("-C")
                    .arg(root.canonical_root())
                    .args(args)
                    .status()
                    .unwrap()
                    .success()
            );
        }
        std::fs::write(root.canonical_root().join("tracked.txt"), "after one\n").unwrap();
        std::fs::write(root.canonical_root().join("second.txt"), "after two\n").unwrap();

        let full =
            diff(&context, &[], false, 3, DiffFormat::Unified, None, None).await.unwrap().commit();
        let WorkspaceResponse::Diff { data, .. } = full else { panic!() };
        let full = data.decode().unwrap();
        let maximum = split_diff_sections(&full).iter().map(|section| section.len()).max().unwrap();
        let maximum = u32::try_from(maximum).unwrap();

        let first = diff(&context, &[], false, 3, DiffFormat::Unified, None, Some(maximum))
            .await
            .unwrap()
            .commit();
        let WorkspaceResponse::Diff { data, next_cursor: Some(cursor), .. } = first else {
            panic!()
        };
        let mut combined = data.decode().unwrap();
        let second =
            diff(&context, &[], false, 3, DiffFormat::Unified, Some(&cursor), Some(maximum))
                .await
                .unwrap()
                .commit();
        let WorkspaceResponse::Diff { data, next_cursor, .. } = second else { panic!() };
        assert_eq!(next_cursor, None);
        combined.extend(data.decode().unwrap());
        assert_eq!(combined, full);
    }

    #[tokio::test]
    async fn unified_diff_cursor_continues_the_original_snapshot() {
        let (_directory, root) = git_root().await;
        let queries = WorkspaceQueryService::default();
        let owner = ClientScope::new("test", cmux_remote_protocol::SessionId([1; 16]));
        let context = WorkspaceQueryContext::new(&queries, &owner, &root);
        std::fs::write(root.canonical_root().join("second.txt"), "before\n").unwrap();
        git(root.canonical_root(), &["add", "second.txt"]);
        git(root.canonical_root(), &["commit", "-qm", "second"]);
        std::fs::write(root.canonical_root().join("tracked.txt"), "after one\n").unwrap();
        std::fs::write(root.canonical_root().join("second.txt"), "after two\n").unwrap();

        let full =
            diff(&context, &[], false, 3, DiffFormat::Unified, None, None).await.unwrap().commit();
        let WorkspaceResponse::Diff { data, .. } = full else { panic!() };
        let full = data.decode().unwrap();
        let maximum = split_diff_sections(&full).iter().map(|section| section.len()).max().unwrap();
        let maximum = u32::try_from(maximum).unwrap();
        let first = diff(&context, &[], false, 3, DiffFormat::Unified, None, Some(maximum))
            .await
            .unwrap()
            .commit();
        let WorkspaceResponse::Diff { data, next_cursor: Some(cursor), .. } = first else {
            panic!()
        };
        let first = String::from_utf8(data.decode().unwrap()).unwrap();
        let (returned, remaining) = if first.contains("second.txt") {
            ("second.txt", "tracked.txt")
        } else {
            ("tracked.txt", "second.txt")
        };
        git(root.canonical_root(), &["checkout", "--", returned]);

        let second =
            diff(&context, &[], false, 3, DiffFormat::Unified, Some(&cursor), Some(maximum))
                .await
                .unwrap()
                .commit();
        let WorkspaceResponse::Diff { data, .. } = second else { panic!() };
        let second = String::from_utf8(data.decode().unwrap()).unwrap();
        assert!(second.contains(remaining), "missing retained diff for {remaining}: {second}");
    }

    #[test]
    fn parses_porcelain_rename_records() {
        let input = b"## main\0R  new.txt\0old.txt\0";
        let (branch, changes) = parse_status(input).unwrap();
        assert_eq!(branch.as_deref(), Some("main"));
        assert_eq!(changes[0].path, "new.txt");
        assert_eq!(changes[0].original_path.as_deref(), Some("old.txt"));
    }

    #[test]
    fn parses_nul_delimited_diff_path_page() {
        let input = concat!(
            "M\0skip.txt\0",
            "A\0tab\tname.txt\0",
            "R100\0old b/path.txt\0new\"path.txt\0",
            "D\0gone.txt\0",
        );
        let parsed = parse_diff_path_metadata(input.as_bytes()).unwrap();
        assert_eq!(parsed.len(), 4);
        assert_eq!(parsed[1].old_path, None);
        assert_eq!(parsed[1].new_path.as_deref(), Some("tab\tname.txt"));
        assert_eq!(parsed[2].old_path.as_deref(), Some("old b/path.txt"));
        assert_eq!(parsed[2].new_path.as_deref(), Some("new\"path.txt"));
        assert_eq!(parsed[3].old_path.as_deref(), Some("gone.txt"));
        assert_eq!(parsed[3].new_path, None);
    }

    #[test]
    fn structured_diff_does_not_confuse_hunk_content_for_file_headers() {
        let source = concat!(
            "diff --git a/value.txt b/value.txt\n",
            "--- a/value.txt\n",
            "+++ b/value.txt\n",
            "@@ -1 +1 @@\n",
            "--- deleted content\n",
            "++++ added content\n",
        );
        let parsed = parse_structured_diff(source);
        assert_eq!(parsed.files.len(), 1);
        assert_eq!(parsed.files[0].old_path.as_deref(), Some("value.txt"));
        assert_eq!(parsed.files[0].new_path.as_deref(), Some("value.txt"));
        assert_eq!(parsed.files[0].hunks[0].lines[0].kind, StructuredDiffLineKind::Deleted);
        assert_eq!(parsed.files[0].hunks[0].lines[0].text, "-- deleted content");
        assert_eq!(parsed.files[0].hunks[0].lines[1].kind, StructuredDiffLineKind::Added);
        assert_eq!(parsed.files[0].hunks[0].lines[1].text, "+++ added content");
    }

    #[test]
    fn structured_diff_keeps_binary_file_metadata_without_hunks() {
        let parsed = parse_structured_diff(concat!(
            "diff --git a/image.bin b/image.bin\n",
            "index 1111111..2222222 100644\n",
            "Binary files a/image.bin and b/image.bin differ\n",
        ));
        assert_eq!(parsed.files.len(), 1);
        assert_eq!(parsed.files[0].old_path.as_deref(), Some("image.bin"));
        assert_eq!(parsed.files[0].new_path.as_deref(), Some("image.bin"));
        assert!(parsed.files[0].hunks.is_empty());
        assert_eq!(parsed.files[0].metadata.len(), 2);
    }
}
