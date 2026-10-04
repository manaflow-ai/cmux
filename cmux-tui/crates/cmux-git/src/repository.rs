//! A repository's top level and the config overrides every run carries.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::MAX_SMALL_OUTPUT_BYTES;
use crate::parse;
use crate::run::{GitFailure, GitOutput, run_git};

/// A repository's top level, which every run works from, and the config
/// overrides every run carries.
#[derive(Debug, Clone)]
pub struct Repository {
    pub root: PathBuf,
    pub overrides: Vec<String>,
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
        let arguments = ["rev-parse", "--show-toplevel"];
        let output = match run_git(directory, &[], &arguments, MAX_SMALL_OUTPUT_BYTES) {
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
        let overrides = filter_overrides(&root).map_err(OpenError::Git)?;
        Ok(Self { root, overrides })
    }

    /// Runs `git <arguments>` at the top level with this repository's
    /// overrides.
    pub fn run(&self, arguments: &[&str], max_stdout: usize) -> Result<GitOutput, GitFailure> {
        run_git(&self.root, &self.overrides, arguments, max_stdout)
    }

    /// The commit a revision names, or `None`.
    pub fn commit(&self, revision: &str) -> Option<String> {
        let revision = format!("{revision}^{{commit}}");
        let arguments = ["rev-parse", "--verify", "--quiet", "--end-of-options", revision.as_str()];
        let output = self.run(&arguments, MAX_SMALL_OUTPUT_BYTES).ok()?;
        let commit = String::from_utf8_lossy(&output.stdout).trim().to_string();
        (!commit.is_empty()).then_some(commit)
    }

    /// The empty tree in this repository's hash, to compare against before
    /// the first commit.
    pub fn empty_tree(&self) -> Result<String, GitFailure> {
        let output = self.run(&["hash-object", "-t", "tree", "--stdin"], MAX_SMALL_OUTPUT_BYTES)?;
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    /// The branch the branch scope compares with, as (ref, short name):
    /// origin's default branch, else origin/main, origin/master, main or
    /// master.
    pub fn base_branch(&self) -> Option<(String, String)> {
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
}

/// A filter driver runs a program on file contents (`clean`, `smudge`,
/// `process`), and diffing the working tree would run it. A read never needs
/// one, so every configured driver is blanked: an empty command is no filter,
/// and nothing is required.
pub fn filter_overrides(root: &Path) -> Result<Vec<String>, GitFailure> {
    let pattern = r"^filter\..*\.(clean|smudge|process|required)$";
    let arguments = ["config", "--null", "--name-only", "--get-regexp", pattern];
    let output = match run_git(root, &[], &arguments, MAX_SMALL_OUTPUT_BYTES) {
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
