//! `git.diff`: one scope's changed files, with line counts and, on request,
//! each file's patch cut to a byte budget.

use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::path::{Component, Path};

use serde_json::{Map, Value, json};

use super::run::{GitFailure, GitOutput};
use super::{MAX_SMALL_OUTPUT_BYTES, Repository, clamp, git_failed, parse};
use crate::resource::ResourceError;

const OPERATION: &str = "git.diff";
const MAX_LISTING_BYTES: usize = 8 * 1024 * 1024;
/// git output read per patch run.
const MAX_PATCH_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
/// Patch bytes in one reply, across its files; past it, files are marked
/// `patch_truncated` without a patch.
const MAX_REPLY_PATCH_BYTES: usize = 8 * 1024 * 1024;
/// Paths per patch run, so a long file list never exceeds the argument limit.
const PATCH_BATCH: usize = 256;
/// Untracked files are read to count their lines; past this many the rest
/// are left out and counted in `untracked_skipped`.
const MAX_UNTRACKED_FILES: usize = 200;
const MAX_UNTRACKED_FILE_BYTES: u64 = 2 * 1024 * 1024;
/// git's own test for a binary file: a NUL in the first 8000 bytes.
const BINARY_PROBE_BYTES: usize = 8000;

/// What a scope compares.
struct Comparison {
    /// The operation errors name.
    operation: &'static str,
    /// The `git diff` revisions; `None` when there is nothing tracked to
    /// compare (committed, before the first commit).
    revisions: Option<Vec<String>>,
    cached: bool,
    untracked: bool,
    head: Option<String>,
    base: Option<String>,
}

#[derive(Debug)]
struct ChangedFile {
    path: String,
    previous_path: Option<String>,
    status: &'static str,
    additions: u64,
    deletions: u64,
    binary: bool,
    patch: Option<String>,
    patch_truncated: bool,
}

impl ChangedFile {
    fn new(path: String, status: &'static str) -> Self {
        Self {
            path,
            previous_path: None,
            status,
            additions: 0,
            deletions: 0,
            binary: false,
            patch: None,
            patch_truncated: false,
        }
    }

    fn has_patch(&self) -> bool {
        self.status != "untracked" && !self.binary
    }

    fn to_json(&self) -> Value {
        let mut value = json!({
            "path":self.path,
            "status":self.status,
            "additions":clamp(self.additions),
            "deletions":clamp(self.deletions),
        });
        if let Some(previous_path) = &self.previous_path {
            value["previous_path"] = json!(previous_path);
        }
        if self.binary {
            value["binary"] = json!(true);
        }
        if let Some(patch) = &self.patch {
            value["patch"] = json!(patch);
        }
        if self.patch_truncated {
            value["patch_truncated"] = json!(true);
        }
        value
    }
}

pub(super) fn read(
    repository: &Repository,
    fields: &Map<String, Value>,
) -> Result<Value, ResourceError> {
    let scope = fields.get("scope").and_then(Value::as_str).unwrap_or("uncommitted");
    let comparison = comparison(repository, scope)?;
    let mut value = report(repository, &comparison, fields)?;
    value["scope"] = json!(scope);
    Ok(value)
}

/// The tree in `from` against the working tree as `index` lists it (or the
/// repository's own index): one checkpoint against now, read the way a
/// scope is, with the caller's operation in errors.
pub(in crate::git_ops) fn against_worktree(
    repository: &Repository,
    from: String,
    fields: &Map<String, Value>,
    operation: &'static str,
) -> Result<Value, ResourceError> {
    let comparison = Comparison {
        operation,
        revisions: Some(vec![from]),
        cached: false,
        untracked: false,
        head: repository.commit("HEAD"),
        base: None,
    };
    report(repository, &comparison, fields)
}

/// One tree against another.
pub(in crate::git_ops) fn between(
    repository: &Repository,
    from: String,
    to: String,
    fields: &Map<String, Value>,
    operation: &'static str,
) -> Result<Value, ResourceError> {
    let comparison = Comparison {
        operation,
        revisions: Some(vec![from, to]),
        cached: false,
        untracked: false,
        head: repository.commit("HEAD"),
        base: None,
    };
    report(repository, &comparison, fields)
}

/// The changed files a comparison finds, with counts and bounded patches.
fn report(
    repository: &Repository,
    comparison: &Comparison,
    fields: &Map<String, Value>,
) -> Result<Value, ResourceError> {
    let include_patch = fields.get("include_patch").and_then(Value::as_bool).unwrap_or(false);
    let max_patch_bytes = limit(fields, "max_patch_bytes", 262_144);
    let max_files = limit(fields, "max_files", 500);
    let paths = pathspecs(fields)?;

    let mut files = tracked(repository, comparison, &paths)?;
    let mut untracked_skipped = 0;
    if comparison.untracked {
        let listing = git(repository, comparison.operation, &untracked_args(&paths), MAX_LISTING_BYTES)?;
        let mut names = parse::file_list(&listing.stdout);
        if listing.truncated {
            // The last name may be cut short.
            names.pop();
        }
        untracked_skipped = names.len().saturating_sub(MAX_UNTRACKED_FILES);
        let counted = names.into_iter().take(MAX_UNTRACKED_FILES);
        files.extend(counted.map(|name| untracked(&repository.root, name)));
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    let additions = files.iter().map(|file| file.additions).sum::<u64>();
    let deletions = files.iter().map(|file| file.deletions).sum::<u64>();
    let total_files = files.len();
    files.truncate(max_files);
    let files_omitted = total_files - files.len();
    let wants_patch = include_patch && comparison.revisions.is_some();
    if wants_patch && files.iter().any(ChangedFile::has_patch) {
        let batches = if files_omitted == 0 {
            // Every file is returned: the request's own paths select them.
            vec![paths]
        } else {
            returned_paths(&files).chunks(PATCH_BATCH).map(<[String]>::to_vec).collect()
        };
        attach_patches(repository, comparison, &batches, &mut files, max_patch_bytes)?;
    }

    let mut value = json!({
        "root":repository.root.to_string_lossy(),
        "files":files.iter().map(ChangedFile::to_json).collect::<Vec<_>>(),
        "additions":clamp(additions),
        "deletions":clamp(deletions),
        "total_files":clamp(total_files as u64),
        "files_omitted":clamp(files_omitted as u64),
    });
    if let Some(head) = &comparison.head {
        value["head"] = json!(head);
    }
    if let Some(base) = &comparison.base {
        value["base"] = json!(base);
    }
    if untracked_skipped > 0 {
        value["untracked_skipped"] = json!(clamp(untracked_skipped as u64));
    }
    Ok(value)
}

fn comparison(repository: &Repository, scope: &str) -> Result<Comparison, ResourceError> {
    let head = repository.commit("HEAD");
    let empty_tree = || repository.empty_tree().map_err(|failure| git_failed(OPERATION, &failure));
    let compare = |revisions: Vec<String>, cached: bool, untracked: bool, base: Option<String>| {
        Comparison {
            operation: OPERATION,
            revisions: Some(revisions),
            cached,
            untracked,
            head: head.clone(),
            base,
        }
    };
    Ok(match scope {
        "uncommitted" => {
            let tree = match &head {
                Some(head) => head.clone(),
                None => empty_tree()?,
            };
            compare(vec![tree], false, true, None)
        }
        "unstaged" => compare(Vec::new(), false, true, None),
        "staged" => compare(Vec::new(), true, false, None),
        "committed" => match &head {
            None => Comparison {
                operation: OPERATION,
                revisions: None,
                cached: false,
                untracked: false,
                head: None,
                base: None,
            },
            Some(commit) => {
                let parent = repository.commit(&format!("{commit}^1"));
                let from = match &parent {
                    Some(parent) => parent.clone(),
                    None => empty_tree()?,
                };
                compare(vec![from, commit.clone()], false, false, parent)
            }
        },
        "branch" => {
            let merge_base = merge_base(repository)?;
            compare(vec![merge_base.clone()], false, true, Some(merge_base))
        }
        other => {
            return Err(ResourceError::validation_invalid(
                Some("scope"),
                format!("unknown scope {other:?}"),
            ));
        }
    })
}

fn merge_base(repository: &Repository) -> Result<String, ResourceError> {
    let Some((reference, short)) = repository.base_branch() else {
        return Err(ResourceError::operation_failed(
            OPERATION,
            "no base branch: origin's default branch, main and master are all missing",
            json!({"code":"no_base_branch"}),
        ));
    };
    let arguments = ["merge-base", "HEAD", reference.as_str()];
    match repository.run(&arguments, MAX_SMALL_OUTPUT_BYTES) {
        Ok(output) => Ok(String::from_utf8_lossy(&output.stdout).trim().to_string()),
        Err(GitFailure::Exit(_)) => Err(ResourceError::operation_failed(
            OPERATION,
            format!("HEAD and {short} have no common commit"),
            json!({"code":"no_merge_base","base":short}),
        )),
        Err(failure) => Err(git_failed(OPERATION, &failure)),
    }
}

/// The tracked files the comparison changes, with their counts.
fn tracked(
    repository: &Repository,
    comparison: &Comparison,
    paths: &[String],
) -> Result<Vec<ChangedFile>, ResourceError> {
    if comparison.revisions.is_none() {
        return Ok(Vec::new());
    }
    let operation = comparison.operation;
    let statuses =
        listing(repository, operation, &diff_args(comparison, &["--name-status", "-z"], paths))?;
    let counts = listing(repository, operation, &diff_args(comparison, &["--numstat", "-z"], paths))?;
    let counts = parse::numstat(&counts.stdout);
    // An unmerged path is listed once per side; keep its first entry.
    let mut seen = HashSet::new();
    Ok(parse::name_status(&statuses.stdout)
        .into_iter()
        .filter(|entry| seen.insert(entry.path.clone()))
        .map(|entry| {
            let mut file = ChangedFile::new(entry.path, entry.status);
            file.previous_path = entry.previous_path;
            match counts.get(&file.path) {
                Some(Some(lines)) => {
                    file.additions = lines.additions;
                    file.deletions = lines.deletions;
                }
                Some(None) => file.binary = true,
                None => {}
            }
            file
        })
        .collect())
}

/// A file listing, which must be complete to pair its entries.
fn listing(
    repository: &Repository,
    operation: &'static str,
    arguments: &[&str],
) -> Result<GitOutput, ResourceError> {
    let output = git(repository, operation, arguments, MAX_LISTING_BYTES)?;
    if output.truncated {
        return Err(ResourceError::operation_failed(
            operation,
            "too many changed files to list; narrow the read with paths",
            json!({"code":"too_many_changes"}),
        ));
    }
    Ok(output)
}

fn attach_patches(
    repository: &Repository,
    comparison: &Comparison,
    batches: &[Vec<String>],
    files: &mut [ChangedFile],
    max_patch_bytes: usize,
) -> Result<(), ResourceError> {
    let mut patches = HashMap::new();
    // Files whose patch may be incomplete: the last one of a cut run.
    let mut cut = HashSet::new();
    // Some run was cut or skipped, so a missing patch may exist.
    let mut incomplete = false;
    let mut collected = 0;
    for batch in batches {
        if collected >= MAX_REPLY_PATCH_BYTES {
            incomplete = true;
            break;
        }
        let arguments = diff_args(comparison, &["--patch"], batch);
        let output = git(repository, comparison.operation, &arguments, MAX_PATCH_OUTPUT_BYTES)?;
        let sections = parse::patches(&output.stdout);
        if output.truncated {
            incomplete = true;
            cut.extend(sections.last().map(|(path, _)| path.clone()));
        }
        collected += sections.iter().map(|(_, patch)| patch.len()).sum::<usize>();
        patches.extend(sections);
    }
    let mut budget = MAX_REPLY_PATCH_BYTES;
    for file in files.iter_mut().filter(|file| file.has_patch()) {
        let Some(mut patch) = patches.remove(&file.path) else {
            file.patch_truncated = incomplete && file.additions + file.deletions > 0;
            continue;
        };
        let cut_here = parse::truncate_patch(&mut patch, max_patch_bytes.min(budget));
        file.patch_truncated = cut_here || cut.contains(&file.path);
        budget -= patch.len();
        if !patch.is_empty() {
            file.patch = Some(patch);
        }
    }
    Ok(())
}

fn diff_args<'a>(
    comparison: &'a Comparison,
    mode: &[&'a str],
    paths: &'a [String],
) -> Vec<&'a str> {
    let mut args = vec![
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--no-relative",
        "--ignore-submodules=dirty",
        "-M",
        "--src-prefix=a/",
        "--dst-prefix=b/",
    ];
    args.extend_from_slice(mode);
    if comparison.cached {
        args.push("--cached");
    }
    if let Some(revisions) = &comparison.revisions {
        args.extend(revisions.iter().map(String::as_str));
    }
    args.push("--");
    args.extend(paths.iter().map(String::as_str));
    args
}

fn untracked_args(paths: &[String]) -> Vec<&str> {
    let mut args = vec!["ls-files", "--others", "--exclude-standard", "-z", "--"];
    args.extend(paths.iter().map(String::as_str));
    args
}

/// The returned files' paths, with a rename's old path so git still pairs it.
fn returned_paths(files: &[ChangedFile]) -> Vec<String> {
    files
        .iter()
        .filter(|file| file.has_patch())
        .flat_map(|file| std::iter::once(file.path.clone()).chain(file.previous_path.clone()))
        .collect()
}

/// An untracked file counts its lines as additions; a binary, special or
/// large one counts none.
fn untracked(root: &Path, path: String) -> ChangedFile {
    let mut file = ChangedFile::new(path, "untracked");
    let Some(handle) = open_regular(&root.join(&file.path)) else { return file };
    let mut bytes = Vec::new();
    if handle.take(MAX_UNTRACKED_FILE_BYTES).read_to_end(&mut bytes).is_err() {
        return file;
    }
    if bytes[..bytes.len().min(BINARY_PROBE_BYTES)].contains(&0) {
        file.binary = true;
        return file;
    }
    let newlines = bytes.iter().filter(|byte| **byte == b'\n').count() as u64;
    file.additions = newlines + u64::from(!bytes.is_empty() && !bytes.ends_with(b"\n"));
    file
}

/// Opens a regular file without following a link or waiting on a FIFO.
fn open_regular(path: &Path) -> Option<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW);
    }
    let handle = options.open(path).ok()?;
    let metadata = handle.metadata().ok()?;
    (metadata.is_file() && metadata.len() <= MAX_UNTRACKED_FILE_BYTES).then_some(handle)
}

/// The request's paths, which must stay inside the repository.
fn pathspecs(fields: &Map<String, Value>) -> Result<Vec<String>, ResourceError> {
    let Some(paths) = fields.get("paths").and_then(Value::as_array) else {
        return Ok(Vec::new());
    };
    paths
        .iter()
        .map(|path| {
            let raw = path.as_str().unwrap_or_default();
            let inside = Path::new(raw)
                .components()
                .all(|component| matches!(component, Component::Normal(_) | Component::CurDir));
            if inside {
                Ok(raw.to_string())
            } else {
                Err(ResourceError::validation_invalid(
                    Some("paths"),
                    format!("{raw:?} must be relative to the repository root and stay inside it"),
                ))
            }
        })
        .collect()
}

fn limit(fields: &Map<String, Value>, name: &str, default: u64) -> usize {
    let value = fields.get(name).and_then(Value::as_u64).unwrap_or(default);
    usize::try_from(value).unwrap_or(usize::MAX)
}

fn git(
    repository: &Repository,
    operation: &'static str,
    arguments: &[&str],
    max_stdout: usize,
) -> Result<GitOutput, ResourceError> {
    repository.run(arguments, max_stdout).map_err(|failure| git_failed(operation, &failure))
}
