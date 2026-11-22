//! The built-in [`GitBackend`]: runs git with a deadline and bounded output.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::AsyncReadExt;
use tokio::process::Command;

use super::{
    BAD_REF, GitBackend, GitDiff, GitDiffFile, GitDiffParams, GitFileStatus, GitStatus,
    GitStatusParams, NOT_A_REPO,
};
use crate::error::{self, ErrorBody};

const DEADLINE: Duration = Duration::from_secs(20);
/// Status and numstat output limit.
const MAX_LISTING: usize = 8 * 1024 * 1024;
/// Patch output limit; above it patches are omitted, counts stay.
const MAX_PATCH: usize = 12 * 1024 * 1024;

/// Runs the `git` on `PATH`.
#[derive(Debug, Clone, Default)]
pub struct CommandGit;

struct Output {
    stdout: Vec<u8>,
    truncated: bool,
}

enum Failure {
    Exit(String),
    Other(String),
}

async fn run_git(cwd: &Path, arguments: &[&str], limit: usize) -> Result<Output, Failure> {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    command
        .args(["-c", "core.fsmonitor=false", "-c", "core.quotePath=false", "--no-optional-locks"])
        .args(arguments)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child =
        command.spawn().map_err(|error| Failure::Other(format!("git could not run: {error}")))?;
    let mut stdout = child.stdout.take().ok_or_else(|| Failure::Other("no stdout".into()))?;
    let mut stderr = child.stderr.take().ok_or_else(|| Failure::Other("no stderr".into()))?;
    let work = async {
        let mut out = Vec::new();
        let mut truncated = false;
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            let read =
                stdout.read(&mut chunk).await.map_err(|error| Failure::Other(error.to_string()))?;
            if read == 0 {
                break;
            }
            if out.len() + read > limit {
                truncated = true;
                continue;
            }
            out.extend_from_slice(&chunk[..read]);
        }
        let mut err = Vec::new();
        let _ = (&mut stderr).take(16 * 1024).read_to_end(&mut err).await;
        let status = child.wait().await.map_err(|error| Failure::Other(error.to_string()))?;
        if !status.success() {
            return Err(Failure::Exit(String::from_utf8_lossy(&err).trim().to_owned()));
        }
        Ok(Output { stdout: out, truncated })
    };
    tokio::time::timeout(DEADLINE, work).await.unwrap_or_else(|_| {
        Err(Failure::Other(format!("git did not finish within {} s", DEADLINE.as_secs())))
    })
}

fn checked_cwd(cwd: &str) -> Result<&Path, ErrorBody> {
    let path = Path::new(cwd);
    if !path.is_absolute() {
        return Err(ErrorBody::new(error::INVALID_PARAMS, "cwd must be an absolute path"));
    }
    if !path.is_dir() {
        return Err(ErrorBody::new(NOT_A_REPO, "cwd is not a directory"));
    }
    Ok(path)
}

fn failure(failure: Failure) -> ErrorBody {
    match failure {
        Failure::Exit(stderr) if stderr.contains("not a git repository") => {
            ErrorBody::new(NOT_A_REPO, stderr)
        }
        Failure::Exit(stderr) => ErrorBody::new(error::INTERNAL, stderr),
        Failure::Other(reason) => ErrorBody::new(error::INTERNAL, reason).retryable(),
    }
}

impl GitBackend for CommandGit {
    async fn status(&self, params: GitStatusParams) -> Result<GitStatus, ErrorBody> {
        let cwd = checked_cwd(&params.cwd)?;
        let output = run_git(
            cwd,
            &["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
            MAX_LISTING,
        )
        .await
        .map_err(failure)?;
        if output.truncated {
            return Err(ErrorBody::new(error::TOO_LARGE, "git status output exceeds 8 MiB"));
        }
        Ok(parse_status_v2(&output.stdout))
    }

    async fn diff(&self, params: GitDiffParams) -> Result<GitDiff, ErrorBody> {
        let cwd = checked_cwd(&params.cwd)?;
        let base = match params.base.as_deref() {
            Some(base) => resolve_commit(cwd, base).await?,
            None => match resolve_commit(cwd, "HEAD").await {
                Ok(head) => head,
                Err(error) if error.code == NOT_A_REPO => return Err(error),
                Err(_) => empty_tree(cwd).await?,
            },
        };
        let common = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--find-renames"];
        let mut numstat_args = common.to_vec();
        numstat_args.extend(["--numstat", "-z", base.as_str(), "--"]);
        let numstat = run_git(cwd, &numstat_args, MAX_LISTING).await.map_err(failure)?;
        if numstat.truncated {
            return Err(ErrorBody::new(error::TOO_LARGE, "git diff listing exceeds 8 MiB"));
        }
        let mut files = parse_numstat(&numstat.stdout);
        if params.include_patch {
            let mut patch_args = common.to_vec();
            patch_args.extend(["--patch", base.as_str(), "--"]);
            let patch = run_git(cwd, &patch_args, MAX_PATCH).await.map_err(failure)?;
            if !patch.truncated {
                let patches = split_patches(&String::from_utf8_lossy(&patch.stdout));
                // git emits files in the same order for both formats; a count
                // mismatch means the pairing is unsafe, so omit the patches.
                if patches.len() == files.len() {
                    for (file, patch) in files.iter_mut().zip(patches) {
                        file.patch = Some(patch);
                    }
                }
            }
        }
        Ok(GitDiff { files })
    }
}

async fn resolve_commit(cwd: &Path, reference: &str) -> Result<String, ErrorBody> {
    if reference.is_empty() || reference.starts_with('-') || reference.contains('\0') {
        return Err(ErrorBody::new(BAD_REF, "base is not a valid revision"));
    }
    let spec = format!("{reference}^{{commit}}");
    match run_git(cwd, &["rev-parse", "--verify", "--quiet", "--end-of-options", &spec], 4096).await
    {
        Ok(output) => Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned()),
        Err(Failure::Exit(stderr)) if stderr.contains("not a git repository") => {
            Err(ErrorBody::new(NOT_A_REPO, stderr))
        }
        Err(Failure::Exit(_)) => {
            Err(ErrorBody::new(BAD_REF, format!("{reference} does not name a commit")))
        }
        Err(other) => Err(failure(other)),
    }
}

async fn empty_tree(cwd: &Path) -> Result<String, ErrorBody> {
    let output =
        run_git(cwd, &["hash-object", "-t", "tree", "--stdin"], 4096).await.map_err(failure)?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn tokens(bytes: &[u8]) -> impl Iterator<Item = String> + '_ {
    bytes.split(|byte| *byte == 0).map(|token| String::from_utf8_lossy(token).into_owned())
}

/// v2 status letter to the porcelain v1 letter (`.` is unmodified).
fn letter(code: u8) -> String {
    if code == b'.' { " ".into() } else { char::from(code).to_string() }
}

/// Parse `git status --porcelain=v2 --branch -z`.
pub(super) fn parse_status_v2(bytes: &[u8]) -> GitStatus {
    let mut branch = None;
    let mut files = Vec::new();
    let mut tokens = tokens(bytes);
    while let Some(entry) = tokens.next() {
        if let Some(head) = entry.strip_prefix("# branch.head ") {
            branch = (head != "(detached)").then(|| head.to_owned());
            continue;
        }
        let codes = |xy: &str| {
            let bytes = xy.as_bytes();
            (letter(*bytes.first().unwrap_or(&b'.')), letter(*bytes.get(1).unwrap_or(&b'.')))
        };
        let (fields, path_field) = match entry.as_bytes().first() {
            Some(b'1') => (entry.splitn(9, ' ').collect::<Vec<_>>(), 8),
            Some(b'2') => (entry.splitn(10, ' ').collect::<Vec<_>>(), 9),
            Some(b'u') => (entry.splitn(11, ' ').collect::<Vec<_>>(), 10),
            Some(b'?') => {
                let path = entry.get(2..).unwrap_or_default().to_owned();
                files.push(GitFileStatus { path, index: "?".into(), worktree: "?".into() });
                continue;
            }
            _ => continue,
        };
        let (Some(xy), Some(path)) = (fields.get(1), fields.get(path_field)) else { continue };
        let (index, worktree) = codes(xy);
        files.push(GitFileStatus { path: (*path).to_owned(), index, worktree });
        if entry.starts_with('2') {
            // A rename or copy names its original path next.
            let _original = tokens.next();
        }
    }
    GitStatus { branch, files }
}

/// Parse `git diff --numstat -z`, renames included (new path).
pub(super) fn parse_numstat(bytes: &[u8]) -> Vec<GitDiffFile> {
    let mut files = Vec::new();
    let mut tokens = tokens(bytes);
    while let Some(token) = tokens.next() {
        if token.is_empty() {
            continue;
        }
        let mut fields = token.splitn(3, '\t');
        let (Some(additions), Some(deletions), Some(path)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        let path = if path.is_empty() {
            let _old = tokens.next();
            match tokens.next() {
                Some(new) => new,
                None => break,
            }
        } else {
            path.to_owned()
        };
        files.push(GitDiffFile {
            path,
            additions: additions.parse().unwrap_or(0),
            deletions: deletions.parse().unwrap_or(0),
            patch: None,
        });
    }
    files
}

/// Split a unified diff into one patch per `diff --git` section.
pub(super) fn split_patches(patch: &str) -> Vec<String> {
    let mut sections = Vec::new();
    let mut current = String::new();
    for line in patch.split_inclusive('\n') {
        if line.starts_with("diff --git ") && !current.is_empty() {
            sections.push(std::mem::take(&mut current));
        }
        current.push_str(line);
    }
    if !current.is_empty() {
        sections.push(current);
    }
    sections
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_status_v2_entries() {
        let raw = b"# branch.oid abc\0# branch.head main\0\
1 .M N... 100644 100644 100644 a a src/a b.rs\0\
2 R. N... 100644 100644 100644 a a R100 new.rs\0old.rs\0\
? notes.txt\0";
        let status = parse_status_v2(raw);
        assert_eq!(status.branch.as_deref(), Some("main"));
        let files: Vec<_> = status
            .files
            .iter()
            .map(|f| (f.path.as_str(), f.index.as_str(), f.worktree.as_str()))
            .collect();
        assert_eq!(
            files,
            [("src/a b.rs", " ", "M"), ("new.rs", "R", " "), ("notes.txt", "?", "?")]
        );
        assert_eq!(parse_status_v2(b"# branch.head (detached)\0").branch, None);
    }

    #[test]
    fn parses_numstat_with_renames_and_binaries() {
        let raw = b"3\t1\tsrc/a.rs\0-\t-\timg.png\x002\t0\t\0old.rs\0new.rs\0";
        let files = parse_numstat(raw);
        let got: Vec<_> =
            files.iter().map(|f| (f.path.as_str(), f.additions, f.deletions)).collect();
        assert_eq!(got, [("src/a.rs", 3, 1), ("img.png", 0, 0), ("new.rs", 2, 0)]);
    }

    #[test]
    fn splits_patches_per_file() {
        let patch = "diff --git a/x b/x\n+1\ndiff --git a/y b/y\n-2\n";
        assert_eq!(split_patches(patch), ["diff --git a/x b/x\n+1\n", "diff --git a/y b/y\n-2\n"]);
    }
}
