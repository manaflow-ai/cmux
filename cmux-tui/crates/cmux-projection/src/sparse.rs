//! Non-cone sparse patterns for a projected checkout (`git-mount --sparse FILE`): the format of
//! `git sparse-checkout set --no-cone --stdin` and of `$GIT_DIR/info/sparse-checkout`, one
//! gitignore-style pattern a line, `!` to leave a path out again, the last matching pattern wins.
//!
//! A path is in the checkout as git decides it (`path_in_sparse_checkout` in git's `dir.c`): the
//! path itself is matched as a file, and while no pattern decides it, each folder above it is
//! matched as a folder, nearest first. A path no pattern decides is left out. The paths left out
//! are not projected, and the index written for the mount marks them skip-worktree, so
//! `git status` stays clean.

use std::path::Path;

use ignore::Match;
use ignore::gitignore::{Gitignore, GitignoreBuilder};

/// Parsed sparse patterns.
pub struct Sparse {
    patterns: Gitignore,
    /// The file's text as given, for `info/sparse-checkout`.
    text: String,
}

impl Sparse {
    /// The patterns in `text` (blank lines and `#` comments are skipped, as git does).
    pub fn parse(text: &str) -> anyhow::Result<Self> {
        let mut builder = GitignoreBuilder::new(".");
        for line in text.lines() {
            builder
                .add_line(None, line)
                .map_err(|error| anyhow::anyhow!("bad sparse pattern {line:?}: {error}"))?;
        }
        let patterns = builder.build()?;
        let mut text = text.to_owned();
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        Ok(Self { patterns, text })
    }

    /// The patterns in `file`.
    pub fn load(file: &Path) -> anyhow::Result<Self> {
        let text = std::fs::read_to_string(file)
            .map_err(|error| anyhow::anyhow!("reading {}: {error}", file.display()))?;
        Self::parse(&text)
    }

    /// Whether the tree path `path` (relative, `/`-separated) is in the checkout.
    #[must_use]
    pub fn includes(&self, path: &str) -> bool {
        let path = path.trim_start_matches('/');
        if path.is_empty() {
            return true;
        }
        // A pattern line is an "ignore" glob to the crate, which here means "in the checkout";
        // a `!` line is its whitelist, which here means "left out".
        matches!(self.patterns.matched_path_or_any_parents(path, false), Match::Ignore(_))
    }

    /// The text git keeps in `info/sparse-checkout`.
    #[must_use]
    pub fn text(&self) -> &str {
        &self.text
    }
}

#[cfg(test)]
#[path = "sparse_tests.rs"]
mod tests;
