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
        // Scope output to the opened folder and print paths relative to it.
        "--relative".to_string(),
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
        // Client paths are file names, never pathspec magic such as `:(top)`,
        // which would reach files outside the opened folder.
        .env("GIT_LITERAL_PATHSPECS", "1")
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
        "--relative".to_string(),
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
mod tests;
