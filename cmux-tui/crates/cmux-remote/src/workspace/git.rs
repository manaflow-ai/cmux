use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use cmux_remote_protocol::{
    ByteString, DiffFormat, GitChange, GitStatus, PageCursor, RpcError, StructuredDiffHunkV1,
    StructuredDiffLineKind, StructuredDiffLineV1, StructuredDiffV1, StructuredFileDiffV1,
    WorkspaceResponse,
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;

use super::path::{WorkspaceRoot, normalize_protocol_path};

const MAX_GIT_DIFF_BYTES: usize = 8 * 1024 * 1024;
const MAX_GIT_DIFF_SOURCE_BYTES: usize = 32 * 1024 * 1024;
const MAX_GIT_STATUS_BYTES: usize = 4 * 1024 * 1024;
const MAX_GIT_STDERR_BYTES: usize = 256 * 1024;
const GIT_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_DIFF_CONTEXT: u16 = 1_000;
const MAX_DIFF_PATHS: usize = 256;
const MAX_DIFF_PATH_BYTES: usize = 1024 * 1024;
const MAX_GIT_CHANGES: usize = 10_000;
const MAX_GIT_STATUS_RESPONSE_BYTES: usize = 8 * 1024 * 1024;

pub(crate) async fn status(root: &WorkspaceRoot) -> Result<WorkspaceResponse, RpcError> {
    let output = run_git(
        root.canonical_root(),
        &["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"],
        MAX_GIT_STATUS_BYTES,
    )
    .await?;
    let (branch, changes) = parse_status(&output)?;
    let head = match run_git(root.canonical_root(), &["rev-parse", "--verify", "HEAD"], 1024).await
    {
        Ok(output) => Some(String::from_utf8_lossy(&output).trim().to_string()),
        Err(error) if error.code == "git-command-failed" => None,
        Err(error) => return Err(error),
    };
    Ok(WorkspaceResponse::GitStatus { status: GitStatus { branch, head, changes } })
}

pub(crate) async fn diff(
    root: &WorkspaceRoot,
    paths: &[String],
    staged: bool,
    context: u16,
    format: DiffFormat,
    cursor: Option<&PageCursor>,
    max_bytes: Option<u32>,
) -> Result<WorkspaceResponse, RpcError> {
    if context > MAX_DIFF_CONTEXT {
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
    let scope = diff_page_scope(&normalized, staged, context);
    let mut arguments = vec![
        "diff".to_string(),
        "--no-ext-diff".to_string(),
        "--no-textconv".to_string(),
        "--no-color".to_string(),
        format!("--unified={context}"),
    ];
    if staged {
        arguments.push("--cached".into());
    }
    if !normalized.is_empty() {
        arguments.push("--".into());
        arguments.extend(normalized);
    }
    let references = arguments.iter().map(String::as_str).collect::<Vec<_>>();
    let unified = run_git(root.canonical_root(), &references, MAX_GIT_DIFF_SOURCE_BYTES).await?;
    let start = parse_diff_cursor(cursor, &scope)?;
    let sections = split_diff_sections(&unified);
    if start > sections.len() {
        return Err(RpcError::new(
            "invalid-cursor",
            "diff cursor is beyond the available file changes",
        ));
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
    let mut page = Vec::new();
    let mut index = start;
    while let Some(section) = sections.get(index) {
        if section.len() > maximum {
            if page.is_empty() {
                return Err(RpcError::new(
                    "resource-exhausted",
                    format!("one file diff exceeds the {maximum}-byte page limit"),
                ));
            }
            break;
        }
        if page.len().saturating_add(section.len()) > maximum {
            break;
        }
        page.extend_from_slice(section);
        index += 1;
    }
    let next_cursor = (index < sections.len()).then(|| make_diff_cursor(&scope, index));
    match format {
        DiffFormat::Unified => {
            Ok(WorkspaceResponse::Diff { data: ByteString::from_bytes(&page), format, next_cursor })
        }
        DiffFormat::Structured | DiffFormat::StructuredV1 => {
            let text = std::str::from_utf8(&page)
                .map_err(|_| RpcError::new("invalid-text", "git diff is not UTF-8"))?;
            let structured = parse_structured_diff(text);
            if format == DiffFormat::StructuredV1 {
                return Ok(WorkspaceResponse::StructuredDiff { diff: structured, next_cursor });
            }
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
            Ok(WorkspaceResponse::Diff { data: ByteString::from_bytes(&data), format, next_cursor })
        }
    }
}

async fn run_git(
    root: &Path,
    arguments: &[&str],
    maximum_stdout: usize,
) -> Result<Vec<u8>, RpcError> {
    let mut command = tokio::process::Command::new("git");
    command
        .arg("-C")
        .arg(root)
        .args(arguments)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_PAGER", "cat")
        .env("LC_ALL", "C")
        .kill_on_drop(true);
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

fn split_diff_sections(source: &[u8]) -> Vec<&[u8]> {
    if source.is_empty() {
        return Vec::new();
    }
    const HEADER: &[u8] = b"diff --git ";
    let mut starts = (0..source.len())
        .filter(|index| {
            (*index == 0 || source[*index - 1] == b'\n') && source[*index..].starts_with(HEADER)
        })
        .collect::<Vec<_>>();
    if starts.is_empty() {
        return vec![source];
    }
    if starts[0] != 0 {
        starts[0] = 0;
    }
    starts
        .iter()
        .enumerate()
        .map(|(position, start)| {
            let end = starts.get(position + 1).copied().unwrap_or(source.len());
            &source[*start..end]
        })
        .collect()
}

fn diff_page_scope(paths: &[String], staged: bool, context: u16) -> String {
    let mut digest = Sha256::new();
    digest.update([u8::from(staged)]);
    digest.update(context.to_be_bytes());
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

fn parse_diff_cursor(cursor: Option<&PageCursor>, scope: &str) -> Result<usize, RpcError> {
    let Some(PageCursor(cursor)) = cursor else {
        return Ok(0);
    };
    let mut parts = cursor.split(':');
    let valid = parts.next() == Some("diff") && parts.next() == Some(scope);
    let index = parts.next().and_then(|index| index.parse::<usize>().ok());
    if !valid || parts.next().is_some() || index.is_none() {
        return Err(RpcError::new("invalid-cursor", "cursor does not belong to this diff request"));
    }
    Ok(index.unwrap_or_default())
}

fn make_diff_cursor(scope: &str, index: usize) -> PageCursor {
    PageCursor(format!("diff:{scope}:{index}"))
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
    use std::process::Command;
    use std::sync::Arc;

    use cmux_remote_protocol::WorkspaceId;
    use tempfile::tempdir;

    use super::*;

    async fn git_root() -> (tempfile::TempDir, Arc<WorkspaceRoot>) {
        let directory = tempdir().unwrap();
        let git = |args: &[&str]| {
            let status =
                Command::new("git").arg("-C").arg(directory.path()).args(args).status().unwrap();
            assert!(status.success());
        };
        git(&["init", "-q"]);
        git(&["config", "user.email", "test@example.com"]);
        git(&["config", "user.name", "Test"]);
        std::fs::write(directory.path().join("tracked.txt"), "before\n").unwrap();
        git(&["add", "tracked.txt"]);
        git(&["commit", "-qm", "initial"]);
        let root =
            WorkspaceRoot::open(WorkspaceId("git".into()), directory.path().to_str().unwrap())
                .await
                .unwrap();
        (directory, root)
    }

    #[tokio::test]
    async fn status_and_structured_diff_are_bounded_and_typed() {
        let (_directory, root) = git_root().await;
        tokio::fs::write(root.canonical_root().join("tracked.txt"), b"after\n").await.unwrap();
        let response = status(&root).await.unwrap();
        let WorkspaceResponse::GitStatus { status } = response else { panic!() };
        assert_eq!(status.changes[0].path, "tracked.txt");
        assert_eq!(status.changes[0].worktree_status, 'M');

        let response =
            diff(&root, &[], false, 3, DiffFormat::Structured, None, None).await.unwrap();
        let WorkspaceResponse::Diff { data, .. } = response else { panic!() };
        let decoded = data.decode().unwrap();
        let json: serde_json::Value = serde_json::from_slice(&decoded).unwrap();
        assert_eq!(json["files"][0]["new_path"], "tracked.txt");
        assert!(json["files"][0]["hunks"][0]["lines"].is_array());
        assert!(json["files"][0].get("metadata").is_none());

        let typed = diff(&root, &[], false, 3, DiffFormat::StructuredV1, None, None).await.unwrap();
        let WorkspaceResponse::StructuredDiff { diff, .. } = typed else { panic!() };
        assert_eq!(diff.version, 1);
        assert_eq!(diff.files[0].new_path.as_deref(), Some("tracked.txt"));
        assert!(!diff.files[0].metadata.is_empty());
    }

    #[tokio::test]
    async fn unified_diff_cursor_pages_on_file_boundaries() {
        let (_directory, root) = git_root().await;
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

        let full = diff(&root, &[], false, 3, DiffFormat::Unified, None, None).await.unwrap();
        let WorkspaceResponse::Diff { data, .. } = full else { panic!() };
        let full = data.decode().unwrap();
        let maximum = split_diff_sections(&full).iter().map(|section| section.len()).max().unwrap();
        let maximum = u32::try_from(maximum).unwrap();

        let first =
            diff(&root, &[], false, 3, DiffFormat::Unified, None, Some(maximum)).await.unwrap();
        let WorkspaceResponse::Diff { data, next_cursor: Some(cursor), .. } = first else {
            panic!()
        };
        let mut combined = data.decode().unwrap();
        let second = diff(&root, &[], false, 3, DiffFormat::Unified, Some(&cursor), Some(maximum))
            .await
            .unwrap();
        let WorkspaceResponse::Diff { data, next_cursor, .. } = second else { panic!() };
        assert_eq!(next_cursor, None);
        combined.extend(data.decode().unwrap());
        assert_eq!(combined, full);
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
