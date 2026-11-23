//! What `cmux customize use` takes as code (cmuxterm-hq
//! `docs/design/experiments-shelf.md`): every way code reaches someone's cmux
//! before it is in their build.
//!
//! ```text
//! pr:N | #N | PR link        a pull request of manaflow-ai/cmux (CI publishes its layer)
//! branch:NAME                a branch of manaflow-ai/cmux, its tip (CI publishes it)
//! sha:SHA                    a commit on a branch of manaflow-ai/cmux (CI publishes it)
//! dir:PATH                   a working copy on this computer, built here; no push, no CI
//! OWNER/REPO@REF             a fork's branch: the fork's own CI publishes its layer
//! ```

use std::path::{Path, PathBuf};

use super::pr::REPO;

/// One code source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Source {
    Pr(u64),
    Branch(String),
    /// A commit: 7 to 40 hex; a short one is resolved before use.
    Sha(String),
    Dir(PathBuf),
    Fork {
        repo: String,
        reference: String,
    },
}

/// The source `text` names, when it names code. A bare word is a profile.
pub(super) fn parse(text: &str) -> Option<Source> {
    if let Some(pr) = super::pr::pr_number(text) {
        return Some(Source::Pr(pr));
    }
    if let Some(name) = text.strip_prefix("branch:") {
        return valid_ref(name).then(|| Source::Branch(name.to_owned()));
    }
    if let Some(sha) = text.strip_prefix("sha:") {
        let sha = sha.to_ascii_lowercase();
        return is_hex(&sha, 7..=40).then_some(Source::Sha(sha));
    }
    if let Some(path) = text.strip_prefix("dir:") {
        return (!path.is_empty()).then(|| Source::Dir(expand_home(path)));
    }
    let (repo, reference) = text.split_once('@')?;
    let (owner, name) = repo.split_once('/')?;
    if !valid_part(owner) || !valid_part(name) || !valid_ref(reference) {
        return None;
    }
    if repo.eq_ignore_ascii_case(REPO) {
        // Our own repository: a branch, built by our CI.
        return Some(if is_hex(reference, 40..=40) {
            Source::Sha(reference.to_owned())
        } else {
            Source::Branch(reference.to_owned())
        });
    }
    Some(Source::Fork { repo: repo.to_owned(), reference: reference.to_owned() })
}

/// A git branch name we pass on: letters, digits, `.`, `_`, `-` and `/`, no
/// `..`, not starting with `-` or `/`.
pub(super) fn valid_ref(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 200
        && !name.starts_with(['-', '/', '.'])
        && !name.ends_with(['/', '.'])
        && !name.contains("..")
        && !name.contains("//")
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'/'))
}

fn valid_part(part: &str) -> bool {
    !part.is_empty()
        && part.len() <= 100
        && !part.starts_with('.')
        && part.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

pub(super) fn is_hex(text: &str, lengths: std::ops::RangeInclusive<usize>) -> bool {
    lengths.contains(&text.len())
        && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The path a branch or ref is published under: `/` becomes `--`
/// (cmux-next-web-bundle-publish.yml writes `ref/<slug>/`, the fork workflow
/// tags `cmux-web-layer-<slug>`).
pub(super) fn ref_slug(name: &str) -> String {
    name.replace('/', "--")
}

fn expand_home(path: &str) -> PathBuf {
    match path.strip_prefix("~/") {
        Some(rest) => std::env::var_os("HOME")
            .map(|home| Path::new(&home).join(rest))
            .unwrap_or_else(|| PathBuf::from(path)),
        None => PathBuf::from(path),
    }
}

#[cfg(test)]
#[path = "source_tests.rs"]
mod tests;
