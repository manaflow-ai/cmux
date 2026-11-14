//! A repository's top level and the config overrides every run carries.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::MAX_SMALL_OUTPUT_BYTES;
use crate::own_work_tree::{self, is_one_folder, two_folders};
use crate::run::{
    DEADLINE, GitFailure, GitOutput, Override, run_git_records_within, run_git_within,
};

/// A repository's top level, which every run works from, and the config
/// overrides every run carries. A repository opened with
/// [`Repository::open_within`] stops every run at its deadline, so a whole
/// read stays bounded.
#[derive(Debug, Clone)]
pub struct Repository {
    pub root: PathBuf,
    pub overrides: Vec<Override>,
    deadline: Option<Instant>,
}

/// Why [`Repository::open`] found no repository.
#[derive(Debug)]
pub enum OpenError {
    /// The folder is not inside a git work tree.
    NotARepository,
    /// git failed for another reason.
    Git(GitFailure),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotARepository => formatter.write_str("not in a git repository"),
            Self::Git(failure) => formatter.write_str(&failure.reason()),
        }
    }
}

impl std::error::Error for OpenError {}

/// What [`Repository::open`] says of a work tree that it does not open
/// because its top folder's name is not UTF-8.
const TOP_FOLDER_NOT_UTF8: &str = "the work tree's top folder has a name that is not UTF-8";

/// What [`Repository::open`] says when git's answer is not one top folder
/// and one git folder that are there.
const NOT_TWO_FOLDERS: &str = "git did not name one top folder and one git folder for this folder";

impl Repository {
    /// The repository `directory` is in.
    pub fn open(directory: &Path) -> Result<Self, OpenError> {
        Self::open_until(directory, None)
    }

    /// [`Repository::open`] whose runs, the opening ones included, all stop
    /// at `deadline`.
    pub fn open_within(directory: &Path, deadline: Instant) -> Result<Self, OpenError> {
        Self::open_until(directory, Some(deadline))
    }

    fn open_until(directory: &Path, deadline: Option<Instant>) -> Result<Self, OpenError> {
        Self::open_unfiltered(directory, deadline)?.filtered().map_err(OpenError::Git)
    }

    /// [`Repository::open`], and the `core`, `diff` and `filter` settings of
    /// every config file as git prints them: the settings that can change a
    /// diff of the same files. The run that finds the filter drivers reads
    /// them, so they cost no run of their own. `None` when they are too many
    /// to keep.
    pub fn open_with_diff_settings(directory: &Path) -> Result<(Self, Option<Vec<u8>>), OpenError> {
        let unfiltered = Self::open_unfiltered(directory, None)?;
        let (overrides, settings) =
            diff_settings_within(&unfiltered.root, remaining(None)).map_err(OpenError::Git)?;
        Ok((Self { root: unfiltered.root, overrides, deadline: None }, settings))
    }

    /// The repository `directory` is in, with no filter driver blanked: for
    /// the runs that read no file content (a ref, a config value, a path of
    /// the repository). Crate-private, so that only such a run gets one
    /// ([`crate::head::Checkout`]); a run that can read content takes
    /// [`Repository::filtered`] first.
    pub(crate) fn open_unfiltered(
        directory: &Path,
        deadline: Option<Instant>,
    ) -> Result<Self, OpenError> {
        // One run gives the top folder and the git folder that git uses
        // for `directory`.
        let arguments = ["rev-parse", "--show-toplevel", "--absolute-git-dir"];
        let left = remaining(deadline);
        let output = match run_git_within(directory, &[], &arguments, MAX_SMALL_OUTPUT_BYTES, left)
        {
            Ok(output) => output,
            Err(GitFailure::Exit(stderr)) if says_no_repository(&stderr) => {
                return Err(OpenError::NotARepository);
            }
            Err(failure) => return Err(OpenError::Git(failure)),
        };
        let folders = if output.truncated { None } else { two_folders(&output.stdout) };
        let Some((root, git_dir)) = folders else {
            // An older git gives a git folder and no top folder, with no
            // error, for a folder that is in no work tree.
            return Err(if is_one_folder(&output.stdout) {
                OpenError::NotARepository
            } else {
                OpenError::Git(GitFailure::Exit(NOT_TWO_FOLDERS.to_string()))
            });
        };
        // The top folder is text for each user of it (a reply, a key). A
        // name that is not UTF-8 has no such text, and a text with other
        // characters in its place is the name of another folder: refused.
        if root.to_str().is_none() {
            return Err(OpenError::Git(GitFailure::Exit(TOP_FOLDER_NOT_UTF8.to_string())));
        }
        let setting = || core_worktree(directory, deadline);
        own_work_tree::check(directory, &root, &git_dir, setting).map_err(OpenError::Git)?;
        Ok(Self { root, overrides: Vec::new(), deadline })
    }

    /// This repository with every configured filter driver blanked, as
    /// [`Repository::open`] gives it.
    pub(crate) fn filtered(&self) -> Result<Self, GitFailure> {
        let overrides = filter_overrides_within(&self.root, remaining(self.deadline))?;
        Ok(Self { root: self.root.clone(), overrides, deadline: self.deadline })
    }

    /// This repository with its runs stopped at `deadline` too (the earlier
    /// of the two deadlines wins).
    pub fn within(&self, deadline: Instant) -> Self {
        let deadline = Some(self.deadline.map_or(deadline, |own| own.min(deadline)));
        Self { root: self.root.clone(), overrides: self.overrides.clone(), deadline }
    }

    /// Runs `git <arguments>` at the top level with this repository's
    /// overrides, stopped at its deadline.
    pub fn run(&self, arguments: &[&str], max_stdout: usize) -> Result<GitOutput, GitFailure> {
        let left = remaining(self.deadline);
        run_git_within(&self.root, &self.overrides, arguments, max_stdout, left)
    }

    /// One bounded byte window of stdout, with the complete output's digest.
    pub fn run_window(
        &self,
        arguments: &[&str],
        offset: u64,
        limit: usize,
    ) -> Result<GitOutput, GitFailure> {
        crate::run::run_git_window_within(
            &self.root,
            &self.overrides,
            arguments,
            offset,
            limit,
            remaining(self.deadline),
        )
    }

    /// The commit a revision names, or `None`.
    pub fn commit(&self, revision: &str) -> Option<String> {
        let revision = format!("{revision}^{{commit}}");
        let arguments = ["rev-parse", "--verify", "--quiet", "--end-of-options", revision.as_str()];
        let output = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
        let commit = String::from_utf8_lossy(&output.stdout).trim().to_string();
        (!commit.is_empty()).then_some(commit)
    }

    /// The branch `name` names exactly, local first: `main` but not
    /// `main~1` or `main@{1}`, which name a commit relative to one.
    pub fn branch_ref(&self, name: &str) -> Option<String> {
        ["refs/heads/", "refs/remotes/"].iter().map(|prefix| format!("{prefix}{name}")).find(
            |reference| {
                let arguments = ["show-ref", "--verify", "--quiet", reference.as_str()];
                self.run(&arguments, MAX_SMALL_OUTPUT_BYTES).is_ok()
            },
        )
    }

    /// The empty tree in this repository's hash, to compare against before
    /// the first commit.
    pub fn empty_tree(&self) -> Result<String, GitFailure> {
        let output = self.run(&["hash-object", "-t", "tree", "--stdin"], MAX_SMALL_OUTPUT_BYTES)?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    /// The branch the branch scope compares with, as (ref, short name): the
    /// base a chat's worktree branch was made from (`branch.<b>.cmuxBase`,
    /// `git.worktree.create`), else origin's default branch, else
    /// origin/main, origin/master, main or master.
    pub fn base_branch(&self) -> Option<(String, String)> {
        if let Some(recorded) = self.recorded_base() {
            return Some(recorded);
        }
        self.default_branch()
    }

    /// Origin's default branch, else origin/main, origin/master, main or
    /// master, as (ref, short name).
    pub fn default_branch(&self) -> Option<(String, String)> {
        let arguments = ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"];
        if let Ok(output) = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES) {
            let reference = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if let Some(short) = reference.strip_prefix("refs/remotes/")
                && self.commit(&reference).is_some()
            {
                return Some((reference.clone(), short.to_string()));
            }
        }
        [
            ("refs/remotes/origin/main", "origin/main"),
            ("refs/remotes/origin/master", "origin/master"),
            ("refs/heads/main", "main"),
            ("refs/heads/master", "master"),
        ]
        .into_iter()
        .find(|(reference, _)| self.commit(reference).is_some())
        .map(|(reference, short)| (reference.to_string(), short.to_string()))
    }

    /// The current branch's recorded base while it still names a commit: a
    /// local or remote branch by its ref, else the commit itself.
    pub fn recorded_base(&self) -> Option<(String, String)> {
        let arguments = ["symbolic-ref", "--quiet", "--short", "HEAD"];
        let output = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
        let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let setting = format!("branch.{branch}.cmuxBase");
        let arguments = ["config", "--get", setting.as_str()];
        let output = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
        let base = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if branch.is_empty() || base.is_empty() || base.starts_with('-') {
            return None;
        }
        self.branch_ref(&base).or_else(|| self.commit(&base)).map(|reference| (reference, base))
    }

    /// This repository with the filter drivers of every checked-out
    /// submodule blanked too, at any depth. git passes the overrides on to
    /// the `git status` it runs inside a submodule, which would otherwise run
    /// the submodule's own clean filter. Submodules are found from each
    /// index's gitlinks, since `.gitmodules` need not list them.
    pub fn with_submodule_filters(&self) -> Result<Self, GitFailure> {
        self.with_submodule_filters_limited(MAX_GITLINK_LISTING_BYTES)
    }

    /// [`Repository::with_submodule_filters`] keeping at most
    /// `max_listing_bytes` of each index's gitlink entries; the index's
    /// other files never count.
    pub fn with_submodule_filters_limited(
        &self,
        max_listing_bytes: usize,
    ) -> Result<Self, GitFailure> {
        let mut blanked = BTreeSet::new();
        let mut pending = vec![self.root.clone()];
        let mut found = 0;
        while let Some(root) = pending.pop() {
            let arguments = ["ls-files", "--stage", "-z"];
            let left = remaining(self.deadline);
            let is_gitlink: fn(&[u8]) -> bool = |entry| entry.starts_with(b"160000 ");
            let output = run_git_records_within(
                &root,
                &[],
                &arguments,
                max_listing_bytes,
                left,
                is_gitlink,
            )?;
            if output.truncated {
                return Err(GitFailure::Exit("too many submodules".to_string()));
            }
            for entry in output.stdout.split(|byte| *byte == 0) {
                // Checked out: an uninitialized one is an empty folder.
                let Some(tab) = entry.iter().position(|byte| *byte == b'\t') else { continue };
                let checkout = root.join(path_from_bytes(&entry[tab + 1..]));
                if !checkout.join(".git").exists() {
                    continue;
                }
                found += 1;
                if found > MAX_SUBMODULES {
                    return Err(GitFailure::Exit("too many submodules".to_string()));
                }
                match filter_overrides_within(&checkout, remaining(self.deadline)) {
                    Ok(drivers) => blanked.extend(drivers),
                    // A `.git` file pointing nowhere: git cannot read this
                    // submodule either, so it runs nothing there. Older git
                    // says "not a git repository", newer git (2.52+, Apple
                    // Git-157) "gitfile does not point to a valid repository".
                    Err(GitFailure::Exit(stderr)) if is_unreadable_gitfile(&stderr) => continue,
                    Err(failure) => return Err(failure),
                }
                pending.push(checkout);
            }
        }
        let mut overrides = self.overrides.clone();
        blanked.retain(|setting| !overrides.contains(setting));
        overrides.extend(blanked);
        Ok(Self { root: self.root.clone(), overrides, deadline: self.deadline })
    }

    /// The main checkout of a linked worktree (one `git worktree add` made);
    /// `None` in the main checkout itself or a bare repository's.
    pub fn main_checkout(&self) -> Option<PathBuf> {
        let arguments = ["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir"];
        let output = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
        let (common, own) = two_folders(&output.stdout)?;
        let (common, own) = (std::fs::canonicalize(common).ok()?, std::fs::canonicalize(own).ok()?);
        if common == own {
            return None;
        }
        main_root(&common).map(Path::to_path_buf)
    }
}

/// Whether git's error text `stderr` is its error for a folder that is in no
/// repository. git starts that error with these words. A search of the whole
/// text for them finds them also in a folder's name, in an error of another
/// kind. A line of a warning or of a hint can come before the error.
fn says_no_repository(stderr: &str) -> bool {
    stderr
        .lines()
        .find(|line| !line.starts_with("warning: ") && !line.starts_with("hint: "))
        .is_some_and(|line| line.starts_with("fatal: not a git repository"))
}

/// The `core.worktree` setting that git reads for `directory`, when one is
/// set: the bytes of its value.
fn core_worktree(
    directory: &Path,
    deadline: Option<Instant>,
) -> Result<Option<Vec<u8>>, GitFailure> {
    let arguments = ["config", "--null", "--get", "core.worktree"];
    let left = remaining(deadline);
    match run_git_within(directory, &[], &arguments, MAX_SMALL_OUTPUT_BYTES, left) {
        // A value that is longer than a path can be: a setting is there,
        // and it leads to no folder.
        Ok(output) if output.truncated => Ok(Some(Vec::new())),
        // `--null` ends the value with one NUL byte.
        Ok(output) => Ok(output.stdout.strip_suffix(&[0]).map(<[u8]>::to_vec)),
        // `--get` exits 1, with no text, when the setting is not there.
        Err(GitFailure::Exit(stderr)) if stderr.is_empty() => Ok(None),
        Err(failure) => Err(failure),
    }
}

/// Whether git's `stderr` says a submodule's `.git` file names no repository.
fn is_unreadable_gitfile(stderr: &str) -> bool {
    stderr.contains("not a git repository")
        || stderr.contains("gitfile does not point to a valid repository")
}

/// The most gitlink entries [`Repository::with_submodule_filters`] keeps
/// from one index.
const MAX_GITLINK_LISTING_BYTES: usize = 1024 * 1024;
/// The most submodules [`Repository::with_submodule_filters`] blanks.
const MAX_SUBMODULES: usize = 256;

/// A path git printed, byte for byte where the platform allows.
pub(crate) fn path_from_bytes(bytes: &[u8]) -> PathBuf {
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

/// The main checkout a common git folder belongs to: the parent of a `.git`
/// folder; `None` for a bare repository.
pub fn main_root(common_dir: &Path) -> Option<&Path> {
    if common_dir.file_name()? == ".git" { common_dir.parent() } else { None }
}

/// A filter driver runs a program on file contents (`clean`, `smudge`,
/// `process`), and diffing the working tree would run it. A read never
/// needs one, so every configured driver is blanked, from any config file:
/// an empty command is no filter, and nothing is required. That includes
/// the user's global ones, since a global driver such as git-lfs reads the
/// repository's own config, where `lfs.extension.<name>.clean` names a
/// program for it to run. A driver name that is not UTF-8 cannot be named
/// in an override, so the read is refused.
pub fn filter_overrides(root: &Path) -> Result<Vec<Override>, GitFailure> {
    filter_overrides_within(root, DEADLINE)
}

/// The time a run may take before `deadline`: at most one run's
/// [`DEADLINE`], and zero once it has passed.
fn remaining(deadline: Option<Instant>) -> Duration {
    deadline.map_or(DEADLINE, |deadline| deadline.saturating_duration_since(Instant::now()))
}

fn filter_overrides_within(root: &Path, deadline: Duration) -> Result<Vec<Override>, GitFailure> {
    let pattern = r"^filter\..*\.(clean|smudge|process|required)$";
    let arguments = ["config", "--null", "--name-only", "--get-regexp", pattern];
    let output = match run_git_within(root, &[], &arguments, MAX_SMALL_OUTPUT_BYTES, deadline) {
        Ok(output) if output.truncated => {
            return Err(GitFailure::Exit("too many filter drivers configured".to_string()));
        }
        Ok(output) => output,
        // `--get-regexp` exits 1 when nothing matches.
        Err(GitFailure::Exit(stderr)) if stderr.is_empty() => return Ok(Vec::new()),
        Err(failure) => return Err(failure),
    };
    blanked(output.stdout.split(|byte| *byte == 0).filter(|key| !key.is_empty()))
}

/// The most settings output [`Repository::open_with_diff_settings`] keeps.
const MAX_DIFF_SETTINGS_BYTES: usize = 1024 * 1024;

/// The overrides of [`filter_overrides_within`], and the output of the one
/// run that gives them: every `core`, `diff` and `filter` setting, each as
/// its name, a line feed, its value and a NUL.
fn diff_settings_within(
    root: &Path,
    deadline: Duration,
) -> Result<(Vec<Override>, Option<Vec<u8>>), GitFailure> {
    let arguments = ["config", "--null", "--get-regexp", r"^(core|diff|filter)\."];
    let output = match run_git_within(root, &[], &arguments, MAX_DIFF_SETTINGS_BYTES, deadline) {
        // A cut list could lack a driver: take the drivers from their own run.
        Ok(output) if output.truncated => {
            return Ok((filter_overrides_within(root, deadline)?, None));
        }
        Ok(output) => output,
        // `--get-regexp` exits 1 when nothing matches.
        Err(GitFailure::Exit(stderr)) if stderr.is_empty() => {
            return Ok((Vec::new(), Some(Vec::new())));
        }
        Err(failure) => return Err(failure),
    };
    let names = output.stdout.split(|byte| *byte == 0).filter_map(|setting| {
        // A setting with no value has no line feed.
        let name = setting.split(|byte| *byte == b'\n').next()?;
        let driver_setting = name.starts_with(b"filter.")
            && [b".clean".as_slice(), b".smudge", b".process", b".required"]
                .iter()
                .any(|suffix| name.ends_with(suffix));
        driver_setting.then_some(name)
    });
    Ok((blanked(names)?, Some(output.stdout)))
}

/// The overrides that blank each filter driver the setting names `keys`
/// (`filter.<driver>.<setting>`) name.
fn blanked<'a>(keys: impl Iterator<Item = &'a [u8]>) -> Result<Vec<Override>, GitFailure> {
    let mut drivers = BTreeSet::new();
    for key in keys {
        // A lossy copy would blank some other driver and leave this one.
        let Ok(key) = std::str::from_utf8(key) else {
            return Err(GitFailure::Exit("a filter driver name is not UTF-8".to_string()));
        };
        if let Some((driver, _)) = key.strip_prefix("filter.").and_then(|key| key.rsplit_once('.'))
        {
            drivers.insert(driver.to_string());
        }
    }
    Ok(drivers
        .into_iter()
        .flat_map(|driver| {
            [("clean", ""), ("smudge", ""), ("process", ""), ("required", "false")]
                .map(|(setting, value)| (format!("filter.{driver}.{setting}"), value.to_string()))
        })
        .collect())
}
