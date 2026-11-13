//! `git.fingerprint`: 64 hex digits that are equal while one scope's diff is
//! equal, for a view that asks every few seconds if its diff is still current.
//!
//! The answer is made from what the diff is made from, never from the diff:
//! HEAD, the base (the branch scope), the diff settings, and each changed or
//! untracked file's modes, blob ids and content hash. One `git status` run
//! lists them; no run makes a patch. A file's content hash is kept by its stat
//! entry (`content`), so a read of an unchanged work tree reads no file, and a
//! file whose time stamp alone moved gives the same digits.
//!
//! The work tree is HEAD's tree plus the listed entries, so a file that
//! `git status` does not list is covered by HEAD's id.
//!
//! A listed path is looked at and read only through the real folders of the
//! work tree (`entry`): a link in a folder's place leads nowhere, in a work
//! tree that was made so and when the link comes after git's listing.

use std::path::{Path, PathBuf};

use cmux_git::diff::ScopeError;
use cmux_git::run::{self, GitFailure};
use serde_json::{Map, Value, json};
use sha2::{Digest as _, Sha256};

use super::{MAX_SMALL_OUTPUT_BYTES, Repository, clamp, git_failed, open_failed};
use crate::resource::ResourceError;

mod content;
#[cfg(unix)]
mod entry;
#[cfg(not(unix))]
#[path = "fingerprint/entry_by_path.rs"]
mod entry;

const OPERATION: &str = "git.fingerprint";
/// git output read from the listing run. Entries past it are not seen, as
/// `git.diff` sees no file past its own listing bound.
const MAX_LISTING_BYTES: usize = 8 * 1024 * 1024;
/// Submodules whose HEAD one read asks for; each is one git run.
const MAX_SUBMODULE_READS: usize = 8;

/// The scopes of `git.diff` that compare a work tree or an index. The others
/// compare commits, which the caller knows by their ids.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Scope {
    Uncommitted,
    Unstaged,
    Staged,
    Branch,
}

impl Scope {
    fn named(name: &str) -> Result<Self, ResourceError> {
        match name {
            "uncommitted" => Ok(Self::Uncommitted),
            "unstaged" => Ok(Self::Unstaged),
            "staged" => Ok(Self::Staged),
            "branch" => Ok(Self::Branch),
            other => Err(ResourceError::validation_invalid(
                Some("scope"),
                format!("no fingerprint for scope {other:?}"),
            )),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Uncommitted => "uncommitted",
            Self::Unstaged => "unstaged",
            Self::Staged => "staged",
            Self::Branch => "branch",
        }
    }

    /// Whether the scope's diff shows work tree files.
    fn reads_work_tree(self) -> bool {
        self != Self::Staged
    }
}

pub(super) fn read(directory: &Path, fields: &Map<String, Value>) -> Result<Value, ResourceError> {
    let scope = Scope::named(fields.get("scope").and_then(Value::as_str).unwrap_or("uncommitted"))?;
    // The settings that can change a patch of the same files (the `core`,
    // `diff` and `filter` sections of every config file) come from the run
    // that the open makes for the filter drivers.
    let (repository, settings) = Repository::open_with_diff_settings(directory)
        .map_err(|error| open_failed(OPERATION, directory, error))?;
    let repository = &repository;
    let mut digest = Digest::new();
    digest.put(b"cmux git.fingerprint 1");
    digest.put(scope.name().as_bytes());
    if scope == Scope::Branch {
        digest.put(merge_base(repository)?.as_bytes());
    }
    match &settings {
        Some(settings) => digest.put(&Sha256::digest(settings)),
        None => digest.put(b"settings past the bound"),
    }
    let listing = listing(repository, scope)?;
    let mut records: Vec<&[u8]> = listing.stdout.split(|byte| *byte == 0).collect();
    // Each record ends with a NUL: the last piece is empty, or the part of a
    // record that a cut listing lost.
    records.pop();
    digest.put(if listing.truncated { b"cut".as_slice() } else { b"whole".as_slice() });
    let tree = entry::Tree::open(&repository.root).ok_or_else(|| {
        ResourceError::operation_failed(
            OPERATION,
            "the work tree's folder cannot be opened",
            json!({"code":"work_tree_unreadable"}),
        )
    })?;
    let mut work_tree = WorkTree { repository, tree, files: content::Reader::new(), submodules: 0 };
    let mut records = records.into_iter();
    while let Some(record) = records.next() {
        let original = if record.starts_with(b"2 ") { records.next() } else { None };
        entry(&mut digest, &mut work_tree, scope, record, original)?;
    }
    Ok(json!({
        "fingerprint": digest.hex(),
        "files_read": clamp(work_tree.files.files_read),
        "bytes_read": clamp(work_tree.files.bytes_read),
    }))
}

/// One record of `git status --porcelain=v2 -z`, as the part of it that the
/// scope's diff shows.
fn entry(
    digest: &mut Digest,
    work_tree: &mut WorkTree<'_>,
    scope: Scope,
    record: &[u8],
    original: Option<&[u8]>,
) -> Result<(), ResourceError> {
    let kind = record.first().copied();
    match kind {
        // `# branch.oid <commit>`: HEAD. The other headers name the branch
        // and its upstream, which no diff shows.
        Some(b'#') => {
            if let Some(head) = record.strip_prefix(b"# branch.oid ") {
                digest.put(b"head");
                digest.put(head);
            }
        }
        // `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`, and for a rename
        // `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <score> <path>` with the
        // original path in the next record.
        Some(b'1' | b'2') => {
            let fields: Vec<&[u8]> = record
                .splitn(if kind == Some(b'2') { 10 } else { 9 }, |byte| *byte == b' ')
                .collect();
            let field = |index: usize| fields.get(index).copied().unwrap_or_default();
            let (staged, unstaged) =
                (field(1).first() != Some(&b'.'), field(1).get(1) != Some(&b'.'));
            let (head, index, tree) = ((field(3), field(6)), (field(4), field(7)), field(5));
            let path = fields.last().copied().unwrap_or_default();
            let (from, to) = match scope {
                Scope::Uncommitted | Scope::Branch => (head, None),
                Scope::Unstaged if unstaged => (index, None),
                Scope::Staged if staged => (head, Some(index)),
                Scope::Unstaged | Scope::Staged => return Ok(()),
            };
            digest.put(b"tracked");
            digest.put(path);
            digest.put(original.unwrap_or_default());
            digest.put(from.0);
            digest.put(from.1);
            match to {
                Some(index) => {
                    digest.put(index.0);
                    digest.put(index.1);
                }
                None => {
                    digest.put(tree);
                    // No file in the work tree, by the mode or by the letter:
                    // the index deleted it, or the work tree did. git says
                    // so too when a folder above the path is now a link.
                    let deleted = tree == b"000000" || field(1).get(1) == Some(&b'D');
                    digest.put(&work_tree.token(path, tree == b"160000", deleted)?);
                }
            }
        }
        // `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`: a
        // conflict, which every scope shows.
        Some(b'u') => {
            digest.put(b"unmerged");
            digest.put(record);
            if scope.reads_work_tree() {
                let path = record.splitn(11, |byte| *byte == b' ').last().unwrap_or_default();
                digest.put(&work_tree.token(path, false, false)?);
            }
        }
        // `? <path>`: an untracked file. The listing run of the staged scope
        // prints none.
        Some(b'?') => {
            if let Some(path) = record.strip_prefix(b"? ") {
                digest.put(b"untracked");
                digest.put(path);
                digest.put(&work_tree.token(path, false, false)?);
            }
        }
        _ => {
            digest.put(b"record");
            digest.put(record);
        }
    }
    Ok(())
}

/// The work tree side of the entries of one read.
struct WorkTree<'a> {
    repository: &'a Repository,
    tree: entry::Tree,
    files: content::Reader,
    submodules: usize,
}

impl WorkTree<'_> {
    /// What stands for the content at `path`, a path of the listing. An
    /// error is a read that gave no answer: the caller asks again.
    fn token(
        &mut self,
        path: &[u8],
        submodule: bool,
        deleted: bool,
    ) -> Result<Vec<u8>, ResourceError> {
        if deleted {
            return Ok(b"none".to_vec());
        }
        let relative = path_from_bytes(path);
        // A path with a link, a file or nothing in a folder's place is not
        // in the work tree.
        let Some(entry) = self.tree.entry(&relative) else { return Ok(b"none".to_vec()) };
        let path = self.repository.root.join(&relative);
        if !submodule {
            return Ok(self.files.token(&path, &entry));
        }
        if content::kind_of(&entry) != Some(content::Kind::Folder) {
            return Ok(b"submodule none".to_vec());
        }
        self.submodule_head(&path)
    }

    /// The commit a checked-out submodule is on: the listing says only that
    /// it is not the recorded one. `checkout` is a real folder of the work
    /// tree; git runs there by its path.
    fn submodule_head(&mut self, checkout: &Path) -> Result<Vec<u8>, ResourceError> {
        // With no `.git` there, git would answer for the repository above.
        if !checkout.join(".git").exists() {
            return Ok(b"submodule none".to_vec());
        }
        if self.submodules >= MAX_SUBMODULE_READS {
            return Ok(b"submodule past the bound".to_vec());
        }
        self.submodules = self.submodules.saturating_add(1);
        let arguments = ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"];
        let overrides = &self.repository.overrides;
        let mut token = b"submodule ".to_vec();
        match run::run_git_within(
            checkout,
            overrides,
            &arguments,
            MAX_SMALL_OUTPUT_BYTES,
            run::DEADLINE,
        ) {
            Ok(output) => token.extend_from_slice(&output.stdout),
            // No commit there: a state of the checkout, which stays until
            // the checkout changes.
            Err(GitFailure::Exit(_)) => token.extend_from_slice(b"no commit"),
            // git did not run or did not end. Digits made of that would
            // move now and move back at the next good read.
            Err(failure) => return Err(git_failed(OPERATION, &failure)),
        }
        Ok(token)
    }
}

/// The changed and untracked files, with HEAD: one run reads the index once
/// for all of them. Renames stay a delete and an add, which names the same
/// work tree; a submodule counts by its commit only, as in `git.diff`.
fn listing(repository: &Repository, scope: Scope) -> Result<run::GitOutput, ResourceError> {
    let untracked =
        if scope.reads_work_tree() { "--untracked-files=all" } else { "--untracked-files=no" };
    let arguments = [
        "status",
        "--porcelain=v2",
        "--branch",
        "-z",
        "--no-renames",
        "--no-ahead-behind",
        "--ignore-submodules=dirty",
        untracked,
    ];
    repository.run(&arguments, MAX_LISTING_BYTES).map_err(|failure| git_failed(OPERATION, &failure))
}

/// The commit the branch scope compares the work tree with, with the errors
/// `git.diff` gives for that scope.
fn merge_base(repository: &Repository) -> Result<String, ResourceError> {
    cmux_git::diff::merge_base(repository).map_err(|error| match error {
        ScopeError::NoBaseBranch => ResourceError::operation_failed(
            OPERATION,
            "no base branch: origin's default branch, main and master are all missing",
            json!({"code":"no_base_branch"}),
        ),
        ScopeError::NoMergeBase { base } => ResourceError::operation_failed(
            OPERATION,
            format!("HEAD and {base} have no common commit"),
            json!({"code":"no_merge_base","base":base}),
        ),
        ScopeError::Git(failure) => git_failed(OPERATION, &failure),
        other => ResourceError::validation_invalid(Some("scope"), other.to_string()),
    })
}

/// SHA-256 over length-prefixed parts, so that two lists of parts never give
/// the same bytes.
struct Digest(Sha256);

impl Digest {
    fn new() -> Self {
        Self(Sha256::new())
    }

    fn put(&mut self, part: &[u8]) {
        let length = u64::try_from(part.len()).unwrap_or(u64::MAX);
        self.0.update(length.to_le_bytes());
        self.0.update(part);
    }

    fn hex(self) -> String {
        self.0.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
    }
}

/// A path git printed, byte for byte where the platform allows.
fn path_from_bytes(bytes: &[u8]) -> PathBuf {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        PathBuf::from(std::ffi::OsStr::from_bytes(bytes))
    }
    #[cfg(not(unix))]
    {
        PathBuf::from(String::from_utf8_lossy(bytes).into_owned())
    }
}
