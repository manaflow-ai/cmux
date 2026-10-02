//! Capture: an immutable synthetic commit whose tree holds the index tree
//! (staged entries), the worktree tree (raw bytes, file type and executable
//! bit of every tracked path; a deleted path is absent), the untracked tree
//! (the approved untracked files) and `metadata.json`. Trees are built in
//! temporary index files; HEAD, the user's index and the worktree are only
//! read. The observation is taken again before returning, and a change is
//! `repository_changed`, never a mixed checkpoint.

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::time::Duration;

use serde_json::json;

use super::record::{Base, Bytes, Coverage, Included, Limits, Skip, SkipCode, saturate};
use super::scan::{self, Kind, Layout, failed, refused};
use super::store::Scratch;
use crate::git_ops::Repository;
use crate::git_ops::run::GitFailure;
use crate::git_ops::write_run::{Bound, WriteGit};
use crate::resource::ResourceError;

/// Reading and hashing a repository's files.
const HASH_DEADLINE: Duration = Duration::from_secs(120);
const MAX_OUTPUT_BYTES: usize = 64 * 1024 * 1024;
/// Path bytes per `hash-object` run, well inside argument limits.
const MAX_ARGUMENT_BYTES: usize = 96 * 1024;

pub(super) enum Include {
    Paths(Vec<String>),
    Eligible,
}

pub(super) struct Request {
    pub include: Include,
    /// Normalized: relative, no trailing `/`.
    pub exclude: Vec<String>,
    pub limits: Limits,
}

/// What a capture stamps into its metadata.
pub(super) struct Stamp<'a> {
    pub checkpoint_id: &'a str,
    pub repository_id: &'a str,
    pub worktree_id: &'a str,
    pub created_at: &'a str,
    pub reason: &'a str,
}

pub(super) struct Captured {
    pub object_id: String,
    pub base: Base,
    pub complete: bool,
    /// At most `limits.max_files`.
    pub skipped: Vec<Skip>,
    pub skipped_total: u32,
    pub coverage: Coverage,
    pub included: Included,
    pub bytes: Bytes,
}

/// One worktree file or link to store.
struct Item {
    path: Vec<u8>,
    kind: Kind,
    /// The staged object, for a tracked path.
    staged: Option<String>,
    oid: Option<String>,
    /// The device and inode an untracked file was read from.
    identity: Option<(u64, u64)>,
}

impl Item {
    fn mode(&self) -> &'static str {
        match self.kind {
            Kind::Symlink { .. } => "120000",
            Kind::File { executable: true, .. } => "100755",
            _ => "100644",
        }
    }

    fn size(&self) -> u64 {
        match &self.kind {
            Kind::File { size, .. } => *size,
            Kind::Symlink { target } => target.len() as u64,
            Kind::Folder | Kind::Other => 0,
        }
    }

    fn is_file(&self) -> bool {
        matches!(self.kind, Kind::File { .. })
    }

    /// Whether its content differs from the staged object (always, for an
    /// untracked file).
    fn changed(&self) -> bool {
        self.staged.is_none() || self.staged != self.oid
    }
}

/// The skips and tree entries a capture collects.
#[derive(Default)]
struct Plan {
    skips: Vec<Skip>,
    index_lines: Vec<u8>,
    gitlink_lines: Vec<u8>,
    staged_entries: u32,
    deleted: u32,
    tracked: Vec<Item>,
    untracked: Vec<Item>,
}

impl Plan {
    fn skip(&mut self, path: &[u8], code: SkipCode, bytes: Option<u64>) {
        let path = String::from_utf8_lossy(path).into_owned();
        self.skips.push(Skip { path, code, bytes: bytes.map(saturate) });
    }
}

pub(super) fn capture(
    git: &WriteGit<'_>,
    repository: &Repository,
    layout: &Layout,
    scratch: &Scratch,
    request: &Request,
    stamp: &Stamp<'_>,
    operation: &'static str,
) -> Result<Captured, ResourceError> {
    let before = scan::observe(repository, operation)?;
    if layout.git_dir.join("index.lock").exists() {
        let message = "another git process holds the index lock; try again when it finishes";
        return Err(failed(operation, "repository_busy", message));
    }
    let mut plan = Plan::default();
    plan_tracked(repository, &before.entries, request, &mut plan);
    plan_untracked(repository, request, &mut plan, operation)?;
    for path in scan::ignored(repository, operation)? {
        plan.skip(&path, SkipCode::Ignored, None);
    }
    store_content(git, request, &mut plan, operation)?;
    #[cfg(test)]
    super::seams::AFTER_HASHING.with(|hook| {
        if let Some(hook) = hook.borrow().as_ref() {
            hook();
        }
    });
    let base = Base {
        head: before.head.clone(),
        detached: before.branch.is_none(),
        branch: before.branch.clone(),
    };
    let summary = Summary::of(&plan, request.limits);
    let index_tree = write_tree(git, scratch, "index", &plan.index_lines, operation)?;
    let worktree_tree = write_tree(git, scratch, "worktree", &worktree_lines(&plan), operation)?;
    let untracked_lines = lines(&plan.untracked);
    let untracked_tree = write_tree(git, scratch, "untracked", &untracked_lines, operation)?;
    let metadata = json!({
        "schema": "cmux.git-checkpoint/1",
        "checkpoint_id": stamp.checkpoint_id,
        "repository_id": stamp.repository_id,
        "worktree_id": stamp.worktree_id,
        "created_at": stamp.created_at,
        "reason": stamp.reason,
        "base": base,
        "complete": summary.complete,
        "skipped": summary.skipped,
        "skipped_total": summary.skipped_total,
        "coverage": summary.coverage,
        "included": summary.included,
        "bytes": summary.bytes,
        "limits": request.limits,
    });
    let metadata = serde_json::to_vec_pretty(&metadata).unwrap_or_default();
    let metadata = hash_blob(git, &metadata, operation)?;
    let root = format!(
        "040000 tree {index_tree}\tindex\0040000 tree {worktree_tree}\tworktree\0\
         040000 tree {untracked_tree}\tuntracked\0100644 blob {metadata}\tmetadata.json\0"
    );
    let root = single(git, None, &["mktree", "-z"], root.as_bytes(), Bound::Unbounded, operation)?;
    let message = format!("cmux checkpoint {}", stamp.checkpoint_id);
    let arguments = ["commit-tree", root.as_str(), "-m", message.as_str()];
    let object_id = single(git, None, &arguments, &[], Bound::Unbounded, operation)?;
    verify_unchanged(repository, &plan, &before.fingerprint, operation)?;
    Ok(Captured {
        object_id,
        base,
        complete: summary.complete,
        skipped: summary.skipped,
        skipped_total: summary.skipped_total,
        coverage: summary.coverage,
        included: summary.included,
        bytes: summary.bytes,
    })
}

fn plan_tracked(
    repository: &Repository,
    entries: &[scan::IndexEntry],
    request: &Request,
    plan: &mut Plan,
) {
    let mut folders = HashSet::new();
    for entry in entries {
        if excluded(&request.exclude, &entry.path) {
            plan.skip(&entry.path, SkipCode::Excluded, None);
            continue;
        }
        plan.index_lines.extend(line(&entry.mode, &entry.oid, &entry.path));
        plan.staged_entries += 1;
        if entry.mode == "160000" {
            // A submodule is its gitlink; its contents are not captured.
            plan.gitlink_lines.extend(line(&entry.mode, &entry.oid, &entry.path));
            plan.skip(&entry.path, SkipCode::Submodule, None);
            continue;
        }
        if scan::behind_a_link(&repository.root, &entry.path, &mut folders) {
            plan.deleted += 1;
            continue;
        }
        match scan::inspect(&repository.root, &entry.path) {
            Ok(None | Some(Kind::Folder)) => plan.deleted += 1,
            Ok(Some(Kind::Other)) => plan.skip(&entry.path, SkipCode::UnsupportedType, None),
            Ok(Some(kind)) => plan.tracked.push(Item {
                path: entry.path.clone(),
                kind,
                staged: Some(entry.oid.clone()),
                oid: None,
                identity: None,
            }),
            Err(_) => plan.skip(&entry.path, SkipCode::Unreadable, None),
        }
    }
}

fn plan_untracked(
    repository: &Repository,
    request: &Request,
    plan: &mut Plan,
    operation: &'static str,
) -> Result<(), ResourceError> {
    let candidates = scan::untracked(repository, operation)?;
    let selected = match &request.include {
        Include::Eligible => None,
        Include::Paths(paths) => {
            for path in paths {
                if !candidates.iter().any(|candidate| candidate.path == path.as_bytes()) {
                    return Err(ResourceError::validation_invalid(
                        Some("include_untracked"),
                        format!("{path} is not an untracked, nonignored file"),
                    ));
                }
            }
            Some(paths.iter().map(|path| path.as_bytes().to_vec()).collect::<HashSet<_>>())
        }
    };
    let limits = request.limits;
    for candidate in candidates {
        let size = candidate.size();
        if excluded(&request.exclude, &candidate.path) {
            plan.skip(&candidate.path, SkipCode::Excluded, Some(size));
        } else if let Some(code) = candidate.ineligible(limits.max_untracked_file_bytes) {
            let bytes = matches!(code, SkipCode::OverLimit).then_some(size);
            plan.skip(&candidate.path, code, bytes);
        } else if selected.as_ref().is_some_and(|selected| !selected.contains(&candidate.path)) {
            plan.skip(&candidate.path, SkipCode::NotSelected, Some(size));
        } else {
            let (path, kind) = (candidate.path, candidate.kind);
            let item = Item { path, kind, staged: None, oid: None, identity: None };
            plan.untracked.push(item);
        }
    }
    let selected = plan.untracked.len();
    if selected > limits.max_files as usize {
        let max_files = limits.max_files;
        let message = format!(
            "{selected} untracked files are selected; at most {max_files} fit one checkpoint"
        );
        let extra = json!({"selected":selected,"max_files":max_files});
        return Err(refused(operation, "budget_exceeded", message, extra));
    }
    Ok(())
}

/// Hashes the tracked files to find what changed, refuses past the byte
/// budget before writing anything large, then writes the changed and the
/// untracked content as blobs.
fn store_content(
    git: &WriteGit<'_>,
    request: &Request,
    plan: &mut Plan,
    operation: &'static str,
) -> Result<(), ResourceError> {
    let files = plan.tracked.iter().filter(|item| item.is_file()).collect::<Vec<_>>();
    let paths = files.iter().map(|item| item.path.as_slice()).collect::<Vec<_>>();
    let hashed = hash_files(git, &paths, false, operation)?;
    let mut hashed = hashed.into_iter();
    for item in plan.tracked.iter_mut().filter(|item| item.is_file()) {
        item.oid = hashed.next();
    }
    // Links are a few bytes: written as they are hashed.
    for item in plan.tracked.iter_mut().chain(plan.untracked.iter_mut()) {
        if let Kind::Symlink { target } = &item.kind {
            item.oid = Some(hash_blob(git, target, operation)?);
        }
    }
    let newly: u64 = plan
        .tracked
        .iter()
        .filter(|item| item.changed())
        .chain(plan.untracked.iter())
        .map(Item::size)
        .sum();
    let max_bytes = request.limits.max_bytes;
    if newly > u64::from(max_bytes) {
        let message = format!(
            "the capture would store {newly} bytes; at most {max_bytes} fit one checkpoint"
        );
        let extra = json!({"bytes":newly.to_string(),"max_bytes":max_bytes});
        return Err(refused(operation, "budget_exceeded", message, extra));
    }
    // Untracked files are read from a descriptor opened without following
    // a link, so a path swapped for a link cannot smuggle another file in.
    for item in plan.untracked.iter_mut().filter(|item| item.is_file()) {
        let (bytes, identity) = read_untracked(git.root, item, operation)?;
        item.oid = Some(hash_blob(git, &bytes, operation)?);
        item.identity = Some(identity);
    }
    let writes =
        plan.tracked.iter_mut().filter(|item| item.is_file() && item.changed()).collect::<Vec<_>>();
    let paths = writes.iter().map(|item| item.path.as_slice()).collect::<Vec<_>>();
    let written = hash_files(git, &paths, true, operation)?;
    for (item, oid) in writes.into_iter().zip(written) {
        if item.staged.is_some() && item.oid.as_deref() != Some(oid.as_str()) {
            return Err(changed(operation, &item.path));
        }
        item.oid = Some(oid);
    }
    Ok(())
}

/// What the record says about a plan.
struct Summary {
    complete: bool,
    skipped: Vec<Skip>,
    skipped_total: u32,
    coverage: Coverage,
    included: Included,
    bytes: Bytes,
}

impl Summary {
    fn of(plan: &Plan, limits: Limits) -> Self {
        let unavailable = plan.skips.iter().filter(|skip| skip.code.unavailable()).count();
        let omitted = plan.skips.len() - unavailable;
        let stored = plan.tracked.len() + plan.untracked.len();
        let logical = plan.tracked.iter().chain(plan.untracked.iter()).map(Item::size).sum();
        let newly = plan
            .tracked
            .iter()
            .filter(|item| item.changed())
            .chain(plan.untracked.iter())
            .map(Item::size)
            .sum();
        let mut skipped = plan.skips.clone();
        skipped.truncate(limits.max_files as usize);
        Self {
            complete: !plan.skips.iter().any(|skip| skip.code.breaks_completeness()),
            skipped,
            skipped_total: saturate(plan.skips.len() as u64),
            coverage: Coverage {
                included: saturate(stored as u64 + u64::from(plan.deleted)),
                omitted: saturate(omitted as u64),
                unavailable: saturate(unavailable as u64),
            },
            included: Included {
                tracked: saturate(plan.tracked.len() as u64),
                untracked: saturate(plan.untracked.len() as u64),
                staged_entries: plan.staged_entries,
            },
            bytes: Bytes { logical: saturate(logical), newly_stored: saturate(newly) },
        }
    }
}

/// Every stored file and link is still what was hashed, behind no link, and
/// HEAD and the index are what the capture started from.
fn verify_unchanged(
    repository: &Repository,
    plan: &Plan,
    fingerprint: &str,
    operation: &'static str,
) -> Result<(), ResourceError> {
    let mut folders = HashSet::new();
    for item in plan.tracked.iter().chain(plan.untracked.iter()) {
        if scan::behind_a_link(&repository.root, &item.path, &mut folders)
            || item.identity.is_some_and(|identity| {
                file_identity(&repository.root, &item.path) != Some(identity)
            })
        {
            return Err(changed(operation, &item.path));
        }
        let now = scan::inspect(&repository.root, &item.path).ok().flatten();
        let same = match (&item.kind, &now) {
            (
                Kind::File { size, executable, modified },
                Some(Kind::File {
                    size: now_size,
                    executable: now_executable,
                    modified: now_modified,
                }),
            ) => size == now_size && executable == now_executable && modified == now_modified,
            (Kind::Symlink { target }, Some(Kind::Symlink { target: now_target })) => {
                target == now_target
            }
            _ => false,
        };
        if !same {
            return Err(changed(operation, &item.path));
        }
    }
    let after = scan::observe(repository, operation)?;
    if after.fingerprint != fingerprint {
        return Err(failed(
            operation,
            "repository_changed",
            "HEAD or the index changed during the capture; nothing was published",
        ));
    }
    Ok(())
}

fn changed(operation: &'static str, path: &[u8]) -> ResourceError {
    let path = String::from_utf8_lossy(path);
    let message = format!("{path} changed during the capture; nothing was published");
    refused(operation, "repository_changed", message, json!({"path":path}))
}

/// An untracked file's bytes, read from a descriptor opened without
/// following a final link, under no linked folder, with the device and
/// inode it was read from. Anything else than the regular file of the
/// planned size changed under the capture.
fn read_untracked(
    root: &Path,
    item: &Item,
    operation: &'static str,
) -> Result<(Vec<u8>, (u64, u64)), ResourceError> {
    use std::io::Read;

    let gone = || changed(operation, &item.path);
    if scan::behind_a_link(root, &item.path, &mut HashSet::new()) {
        return Err(gone());
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(scan::join(root, &item.path)).map_err(|_| gone())?;
    let metadata = file.metadata().map_err(|_| gone())?;
    let size = item.size();
    if !metadata.is_file() || metadata.len() != size {
        return Err(gone());
    }
    let mut bytes = Vec::with_capacity(usize::try_from(size).unwrap_or(0));
    file.take(size.saturating_add(1)).read_to_end(&mut bytes).map_err(|_| gone())?;
    if bytes.len() as u64 != size {
        return Err(gone());
    }
    Ok((bytes, identity_of(&metadata)))
}

fn file_identity(root: &Path, path: &[u8]) -> Option<(u64, u64)> {
    std::fs::symlink_metadata(scan::join(root, path)).ok().map(|metadata| identity_of(&metadata))
}

fn identity_of(metadata: &std::fs::Metadata) -> (u64, u64) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (metadata.dev(), metadata.ino())
    }
    #[cfg(not(unix))]
    {
        (metadata.len(), 0)
    }
}

/// Whether `path` is an excluded path or inside an excluded folder.
fn excluded(exclude: &[String], path: &[u8]) -> bool {
    let path = path.strip_suffix(b"/").unwrap_or(path);
    exclude.iter().any(|prefix| {
        let prefix = prefix.as_bytes();
        path == prefix || (path.starts_with(prefix) && path.get(prefix.len()) == Some(&b'/'))
    })
}

/// One `update-index -z --index-info` record.
fn line(mode: &str, oid: &str, path: &[u8]) -> Vec<u8> {
    let mut line = format!("{mode} {oid}\t").into_bytes();
    line.extend_from_slice(path);
    line.push(0);
    line
}

fn lines(items: &[Item]) -> Vec<u8> {
    items
        .iter()
        .filter_map(|item| item.oid.as_deref().map(|oid| line(item.mode(), oid, &item.path)))
        .flatten()
        .collect()
}

fn worktree_lines(plan: &Plan) -> Vec<u8> {
    let mut lines = lines(&plan.tracked);
    lines.extend_from_slice(&plan.gitlink_lines);
    lines
}

/// A tree from index records, built in a temporary index file.
fn write_tree(
    git: &WriteGit<'_>,
    scratch: &Scratch,
    name: &str,
    records: &[u8],
    operation: &'static str,
) -> Result<String, ResourceError> {
    let index = scratch.path.join(format!("{name}.index"));
    if !records.is_empty() {
        let arguments = [OsStr::new("update-index"), OsStr::new("-z"), OsStr::new("--index-info")];
        git.run(Some(index.as_path()), &arguments, records, Bound::Unbounded, 64 * 1024)
            .map_err(|failure| scan::git(operation, &failure))?;
    }
    single(git, Some(index.as_path()), &["write-tree"], &[], Bound::Unbounded, operation)
}

/// Writes `bytes` as a blob, with no filter.
fn hash_blob(
    git: &WriteGit<'_>,
    bytes: &[u8],
    operation: &'static str,
) -> Result<String, ResourceError> {
    let arguments = ["hash-object", "-w", "--stdin", "--no-filters"];
    single(git, None, &arguments, bytes, Bound::Deadline(HASH_DEADLINE), operation)
}

/// The object ids of files' raw bytes, in order; written with `write`.
fn hash_files(
    git: &WriteGit<'_>,
    paths: &[&[u8]],
    write: bool,
    operation: &'static str,
) -> Result<Vec<String>, ResourceError> {
    let mut oids = Vec::with_capacity(paths.len());
    let mut start = 0;
    while start < paths.len() {
        let mut end = start;
        let mut bytes = 0;
        while end < paths.len() && (end == start || bytes + paths[end].len() < MAX_ARGUMENT_BYTES) {
            bytes += paths[end].len() + 1;
            end += 1;
        }
        let names = paths[start..end].iter().map(|path| os(path)).collect::<Vec<_>>();
        let mut arguments = vec![OsStr::new("hash-object"), OsStr::new("--no-filters")];
        if write {
            arguments.push(OsStr::new("-w"));
        }
        arguments.push(OsStr::new("--"));
        arguments.extend(names.iter().map(OsString::as_os_str));
        let output = git
            .run(None, &arguments, &[], Bound::Deadline(HASH_DEADLINE), MAX_OUTPUT_BYTES)
            .map_err(|failure| hash_failed(git, operation, &failure, &paths[start..end]))?;
        let text = String::from_utf8_lossy(&output.stdout);
        let batch = text.lines().map(str::to_string).collect::<Vec<_>>();
        if batch.len() != end - start {
            return Err(failed(operation, "git_failed", "git hashed a different number of files"));
        }
        oids.extend(batch);
        start = end;
    }
    Ok(oids)
}

/// A file that vanished or stopped being a file while it was hashed
/// changed under the capture; anything else is a git failure.
fn hash_failed(
    git: &WriteGit<'_>,
    operation: &'static str,
    failure: &GitFailure,
    paths: &[&[u8]],
) -> ResourceError {
    let gone =
        |path: &&&[u8]| !matches!(scan::inspect(git.root, path), Ok(Some(Kind::File { .. })));
    match (failure, paths.iter().find(gone)) {
        (GitFailure::Exit(_), Some(path)) => changed(operation, path),
        _ => scan::git(operation, failure),
    }
}

/// The one line a run prints, such as an object id.
fn single(
    git: &WriteGit<'_>,
    index: Option<&std::path::Path>,
    arguments: &[&str],
    stdin: &[u8],
    bound: Bound,
    operation: &'static str,
) -> Result<String, ResourceError> {
    let arguments = arguments.iter().map(OsStr::new).collect::<Vec<_>>();
    let output = git
        .run(index, &arguments, stdin, bound, 64 * 1024)
        .map_err(|failure| scan::git(operation, &failure))?;
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        return Err(failed(operation, "git_failed", "git printed no object id"));
    }
    Ok(value)
}

fn os(path: &[u8]) -> OsString {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        OsStr::from_bytes(path).to_os_string()
    }
    #[cfg(not(unix))]
    {
        OsString::from(String::from_utf8_lossy(path).into_owned())
    }
}
