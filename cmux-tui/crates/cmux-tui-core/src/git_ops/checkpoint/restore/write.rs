//! The writes of an applied restore: under the worktree's `index.lock`,
//! check that HEAD, the index and every path to touch are still what the
//! safety capture saw, remove, write, then install the rebuilt index.

use std::ffi::OsStr;
use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::json;

use super::super::capture::{hash_blob, hash_files};
use super::super::scan::{self, Kind, failed, refused};
use super::super::store::{Store, io_failed, mint};
use super::{Entry, Plan};
use crate::git_ops::Repository;
use crate::git_ops::write_run::{Bound, WriteGit};
use crate::resource::ResourceError;

/// Reading one blob back.
const READ_DEADLINE: Duration = Duration::from_secs(120);
const MAX_BLOB_BYTES: usize = 1024 * 1024 * 1024;

pub(super) struct Apply<'a> {
    pub git: &'a WriteGit<'a>,
    pub root: &'a Path,
    pub git_dir: &'a Path,
    pub repository: &'a Repository,
    /// The observation of HEAD and the index the safety capture verified.
    pub observed: &'a str,
    /// The all-zero object id that drops an index entry.
    pub zero: &'a str,
    pub safety: &'a str,
    pub operation: &'static str,
}

/// `index.lock`, held from the checks to the index install; removed on drop
/// unless it was renamed over the index.
struct IndexLock {
    path: PathBuf,
    file: Option<fs::File>,
}

impl IndexLock {
    fn take(git_dir: &Path, operation: &'static str) -> Result<Self, ResourceError> {
        let path = git_dir.join("index.lock");
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        match options.open(&path) {
            Ok(file) => Ok(Self { path, file: Some(file) }),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                let message =
                    "another git process holds the index lock; try again when it finishes";
                Err(failed(operation, "repository_busy", message))
            }
            Err(error) => Err(io_failed(operation, &error)),
        }
    }

    /// Writes `bytes` as the new index and renames the lock over `index`.
    fn install(mut self, index: &Path, bytes: &[u8]) -> io::Result<()> {
        let mut file = self.file.take().ok_or_else(|| io::Error::other("the lock is closed"))?;
        file.write_all(bytes)?;
        file.sync_data()?;
        drop(file);
        fs::rename(&self.path, index)?;
        self.path = PathBuf::new();
        Ok(())
    }
}

impl Drop for IndexLock {
    fn drop(&mut self) {
        self.file.take();
        if !self.path.as_os_str().is_empty() {
            let _ = fs::remove_file(&self.path);
        }
    }
}

pub(super) fn apply(apply: &Apply<'_>, store: &Store, plan: &Plan) -> Result<(), ResourceError> {
    let operation = apply.operation;
    if plan.steps.is_empty() {
        return Ok(());
    }
    let lock = IndexLock::take(apply.git_dir, operation)?;
    if scan::observe(apply.repository, operation)?.fingerprint != apply.observed {
        let message = "HEAD or the index changed since the safety checkpoint; nothing was written";
        return Err(failed(operation, "repository_changed", message));
    }
    unchanged(apply, plan)?;
    let incomplete = |message: String| {
        let message = format!(
            "{message}; the restore stopped part way. Restore {} to undo what it wrote",
            apply.safety
        );
        refused(
            operation,
            "restore_incomplete",
            message,
            json!({"safety_checkpoint_id":apply.safety}),
        )
    };
    for (path, step) in &plan.steps {
        if step.remove {
            remove(apply.root, path).map_err(|error| {
                incomplete(format!("{} could not be removed: {error}", lossy(path)))
            })?;
        }
    }
    for (path, step) in &plan.steps {
        if let Some(entry) = &step.write {
            let bytes = blob(apply.git, &entry.oid, operation).map_err(|error| {
                incomplete(format!("{} could not be read back: {}", lossy(path), error.message))
            })?;
            place(apply.root, path, entry, &bytes).map_err(|error| {
                incomplete(format!("{} could not be written: {error}", lossy(path)))
            })?;
        }
    }
    let lines = index_lines(plan, apply.zero);
    if lines.is_empty() {
        return Ok(());
    }
    let index = apply.git_dir.join("index");
    let scratch = store.scratch().map_err(|error| io_failed(operation, &error))?;
    let staged = scratch.path.join("restore.index");
    match fs::copy(&index, &staged) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(incomplete(format!("the index could not be read: {error}"))),
    }
    let arguments = [OsStr::new("update-index"), OsStr::new("-z"), OsStr::new("--index-info")];
    apply
        .git
        .run(Some(staged.as_path()), &arguments, &lines, Bound::Unbounded, 64 * 1024)
        .map_err(|failure| {
            incomplete(format!(
                "the index could not be rebuilt: {}",
                scan::git(operation, &failure).message
            ))
        })?;
    let bytes = fs::read(&staged)
        .map_err(|error| incomplete(format!("the index could not be read: {error}")))?;
    lock.install(&index, &bytes)
        .map_err(|error| incomplete(format!("the index could not be installed: {error}")))
}

/// Refuses with `repository_changed` when a path the restore writes or
/// removes no longer holds what the safety capture stored.
fn unchanged(apply: &Apply<'_>, plan: &Plan) -> Result<(), ResourceError> {
    let operation = apply.operation;
    let touched = plan
        .steps
        .iter()
        .filter(|(_, step)| step.write.is_some() || step.remove)
        .collect::<Vec<_>>();
    let mut files = Vec::new();
    for (path, step) in &touched {
        let now = scan::inspect(apply.root, path).ok().flatten();
        let same = match (&now, &step.expected) {
            (None, None) => true,
            (Some(Kind::File { executable, .. }), Some(expected)) => {
                files.push((path.as_slice(), &expected.oid));
                expected.mode == if *executable { "100755" } else { "100644" }
            }
            (Some(Kind::Symlink { target }), Some(expected)) => {
                expected.mode == "120000"
                    && hash_blob(apply.git, target, operation)? == expected.oid
            }
            _ => false,
        };
        if !same || parent_not_a_folder(apply.root, path) {
            return Err(changed(operation, path));
        }
    }
    let paths = files.iter().map(|(path, _)| *path).collect::<Vec<_>>();
    let hashed = hash_files(apply.git, &paths, false, operation)?;
    for ((path, expected), oid) in files.iter().zip(hashed) {
        if **expected != oid {
            return Err(changed(operation, path));
        }
    }
    Ok(())
}

/// Whether a parent of `path` exists as something other than a folder (a link, a file). A
/// missing parent is fine: nothing past it exists, and `place` makes it a folder (an Undo that
/// brings back a file in a folder the restore emptied and removed).
fn parent_not_a_folder(root: &Path, path: &[u8]) -> bool {
    let mut end = 0;
    while let Some(offset) = path[end..].iter().position(|byte| *byte == b'/') {
        end += offset;
        match fs::symlink_metadata(scan::join(root, &path[..end])) {
            Ok(metadata) if metadata.is_dir() => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => return false,
            _ => return true,
        }
        end += 1;
    }
    false
}

fn changed(operation: &'static str, path: &[u8]) -> ResourceError {
    let path = lossy(path);
    let message = format!("{path} changed since the safety checkpoint; nothing was written");
    refused(operation, "repository_changed", message, json!({"path":path}))
}

/// `update-index --index-info` records: set or drop each changed entry.
fn index_lines(plan: &Plan, zero: &str) -> Vec<u8> {
    let mut lines = Vec::new();
    for (path, step) in &plan.steps {
        let record = match &step.index {
            Some(Some(Entry { mode, oid })) => format!("{mode} {oid}\t"),
            Some(None) => format!("0 {zero}\t"),
            None => continue,
        };
        lines.extend_from_slice(record.as_bytes());
        lines.extend_from_slice(path);
        lines.push(0);
    }
    lines
}

/// A blob's raw bytes.
fn blob(git: &WriteGit<'_>, oid: &str, operation: &'static str) -> Result<Vec<u8>, ResourceError> {
    let arguments = [OsStr::new("cat-file"), OsStr::new("blob"), OsStr::new(oid)];
    let output = git
        .run(None, &arguments, &[], Bound::Deadline(READ_DEADLINE), MAX_BLOB_BYTES)
        .map_err(|failure| scan::git(operation, &failure))?;
    if output.truncated {
        return Err(failed(operation, "budget_exceeded", format!("{oid} is too large to restore")));
    }
    Ok(output.stdout)
}

/// Deletes the file or link at `path`, then its parent folders while they
/// are empty. A folder with anything left in it stays.
fn remove(root: &Path, path: &[u8]) -> io::Result<()> {
    match fs::remove_file(scan::join(root, path)) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
        _ => {}
    }
    let mut parent = path;
    while let Some(slash) = parent.iter().rposition(|byte| *byte == b'/') {
        parent = &parent[..slash];
        if fs::remove_dir(scan::join(root, parent)).is_err() {
            break;
        }
    }
    Ok(())
}

/// Writes `entry` at `path`: a temporary file or link beside it, renamed
/// over it. Parent folders are made, never followed through a link.
fn place(root: &Path, path: &[u8], entry: &Entry, bytes: &[u8]) -> io::Result<()> {
    let mut end = 0;
    while let Some(offset) = path[end..].iter().position(|byte| *byte == b'/') {
        end += offset;
        let folder = scan::join(root, &path[..end]);
        match fs::symlink_metadata(&folder) {
            Ok(metadata) if metadata.is_dir() => {}
            Ok(_) => return Err(io::Error::other("a parent is not a folder")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                match fs::create_dir(&folder) {
                    Err(error) if error.kind() != io::ErrorKind::AlreadyExists => {
                        return Err(error);
                    }
                    _ => {}
                }
                if !fs::symlink_metadata(&folder)?.is_dir() {
                    return Err(io::Error::other("a parent is not a folder"));
                }
            }
            Err(error) => return Err(error),
        }
        end += 1;
    }
    let target = scan::join(root, path);
    let directory = target.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
    let temporary = directory.join(format!(".{}.cmux-restore", mint("tmp")));
    let written = if entry.mode == "120000" {
        link(bytes, &temporary)
    } else {
        file(bytes, entry.mode == "100755", &temporary)
    };
    let result = written.and_then(|()| fs::rename(&temporary, &target));
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn file(bytes: &[u8], executable: bool, path: &Path) -> io::Result<()> {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // The umask applies, as it does for git's own checkout.
        options.mode(if executable { 0o777 } else { 0o666 });
    }
    #[cfg(not(unix))]
    let _ = executable;
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_data()
}

#[cfg(unix)]
fn link(target: &[u8], path: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    std::os::unix::fs::symlink(OsStr::from_bytes(target), path)
}

/// Without symbolic links, a link is checked out as a file holding its
/// target, as git does with `core.symlinks=false`.
#[cfg(not(unix))]
fn link(target: &[u8], path: &Path) -> io::Result<()> {
    file(target, false, path)
}

fn lossy(path: &[u8]) -> String {
    String::from_utf8_lossy(path).into_owned()
}
