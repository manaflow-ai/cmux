//! A repository's top level and the config overrides every run carries.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::MAX_SMALL_OUTPUT_BYTES;
use crate::parse;
use crate::run::{DEADLINE, GitFailure, GitOutput, run_git_within};

/// A repository's top level, which every run works from, and the config
/// overrides every run carries. A repository opened with
/// [`Repository::open_within`] stops every run at its deadline, so a whole
/// read stays bounded.
#[derive(Debug, Clone)]
pub struct Repository {
    pub root: PathBuf,
    pub overrides: Vec<String>,
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
        let arguments = ["rev-parse", "--show-toplevel"];
        let left = remaining(deadline);
        let output = match run_git_within(directory, &[], &arguments, MAX_SMALL_OUTPUT_BYTES, left)
        {
            Ok(output) => output,
            Err(GitFailure::Exit(stderr)) if stderr.contains("not a git repository") => {
                return Err(OpenError::NotARepository);
            }
            Err(failure) => return Err(OpenError::Git(failure)),
        };
        let root = String::from_utf8_lossy(&output.stdout).trim_end_matches('\n').to_string();
        if root.is_empty() {
            return Err(OpenError::NotARepository);
        }
        let root = PathBuf::from(root);
        let overrides =
            filter_overrides_within(&root, remaining(deadline)).map_err(OpenError::Git)?;
        Ok(Self { root, overrides, deadline })
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

    /// The main checkout of a linked worktree (one `git worktree add` made);
    /// `None` in the main checkout itself or a bare repository's.
    pub fn main_checkout(&self) -> Option<PathBuf> {
        let arguments = ["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir"];
        let output = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut lines = text.lines();
        let common = std::fs::canonicalize(lines.next()?).ok()?;
        let own = std::fs::canonicalize(lines.next()?).ok()?;
        if common == own {
            return None;
        }
        main_root(&common).map(Path::to_path_buf)
    }
}

/// The main checkout a common git folder belongs to: the parent of a `.git`
/// folder; `None` for a bare repository.
pub fn main_root(common_dir: &Path) -> Option<&Path> {
    if common_dir.file_name()? == ".git" { common_dir.parent() } else { None }
}

/// A filter driver runs a program on file contents (`clean`, `smudge`,
/// `process`), and diffing the working tree would run it. A read never needs
/// one, so every configured driver is blanked: an empty command is no filter,
/// and nothing is required.
pub fn filter_overrides(root: &Path) -> Result<Vec<String>, GitFailure> {
    filter_overrides_within(root, DEADLINE)
}

/// The time a run may take before `deadline`: at most one run's
/// [`DEADLINE`], and zero once it has passed.
fn remaining(deadline: Option<Instant>) -> Duration {
    deadline.map_or(DEADLINE, |deadline| deadline.saturating_duration_since(Instant::now()))
}

fn filter_overrides_within(root: &Path, deadline: Duration) -> Result<Vec<String>, GitFailure> {
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
    let drivers = parse::file_list(&output.stdout)
        .into_iter()
        .filter_map(|key| {
            let (driver, _) = key.strip_prefix("filter.")?.rsplit_once('.')?;
            Some(driver.to_string())
        })
        .collect::<BTreeSet<_>>();
    Ok(drivers
        .into_iter()
        .flat_map(|driver| {
            [
                format!("filter.{driver}.clean="),
                format!("filter.{driver}.smudge="),
                format!("filter.{driver}.process="),
                format!("filter.{driver}.required=false"),
            ]
        })
        .collect())
}
