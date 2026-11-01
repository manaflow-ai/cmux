//! The params of `git.seed.start`, checked before any job starts. Every
//! value that reaches git passed these checks, and none can be read by git
//! as an option.

use serde::Deserialize;
use serde_json::Value;

use super::SeedRefusal;

/// Longest sparse pattern list.
const MAX_SPARSE_BYTES: usize = 1024 * 1024;
/// Longest owner or name (CloudMachineRepo's `isPathComponent`).
const MAX_COMPONENT: usize = 100;

#[derive(Deserialize)]
struct Wire {
    folder: String,
    url: String,
    repo: String,
    base: String,
    bundle: String,
    #[serde(default)]
    head_ref: Option<String>,
    head: String,
    index: String,
    work: String,
    #[serde(default)]
    stash: Option<String>,
    #[serde(default)]
    sparse: Option<String>,
    #[serde(default)]
    lfs: bool,
    #[serde(default)]
    since: Option<String>,
}

/// A checked start request. The paths are not yet placed in the sandbox
/// ([`super::place`] does that).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartParams {
    pub folder: String,
    pub url: String,
    pub base: String,
    pub bundle: String,
    /// The branch name under `refs/heads/` (`None`: a detached HEAD).
    pub branch: Option<String>,
    pub head: String,
    pub index: String,
    pub work: String,
    pub stash: Option<String>,
    pub sparse: Option<String>,
    pub lfs: bool,
    /// A delta seed: the WORK commit of the seed this one builds on.
    pub since: Option<String>,
}

impl StartParams {
    pub fn parse(params: &Value) -> Result<Self, SeedRefusal> {
        let wire: Wire = serde_json::from_value(params.clone())
            .map_err(|error| SeedRefusal::bad_request(format!("invalid params: {error}")))?;
        check_url(&wire.url, &wire.repo)?;
        for (name, sha) in [
            ("base", &wire.base),
            ("head", &wire.head),
            ("index", &wire.index),
            ("work", &wire.work),
        ] {
            check_sha(name, sha)?;
        }
        if let Some(stash) = &wire.stash {
            check_sha("stash", stash)?;
        }
        if let Some(since) = &wire.since {
            check_sha("since", since)?;
        }
        let branch = wire.head_ref.as_deref().map(check_head_ref).transpose()?;
        if let Some(sparse) = &wire.sparse
            && (sparse.len() > MAX_SPARSE_BYTES || sparse.contains('\0'))
        {
            return Err(SeedRefusal::bad_request("invalid sparse patterns"));
        }
        Ok(Self {
            folder: wire.folder,
            url: wire.url,
            base: wire.base,
            bundle: wire.bundle,
            branch,
            head: wire.head,
            index: wire.index,
            work: wire.work,
            stash: wire.stash,
            sparse: wire.sparse,
            lfs: wire.lfs,
            since: wire.since,
        })
    }
}

/// `url` is exactly `https://github.com/<owner>/<name>.git` and `repo` is
/// `<owner>/<name>`.
fn check_url(url: &str, repo: &str) -> Result<(), SeedRefusal> {
    let refused = || SeedRefusal::bad_request("url must be https://github.com/OWNER/NAME.git");
    let rest = url.strip_prefix("https://github.com/").ok_or_else(refused)?;
    let rest = rest.strip_suffix(".git").ok_or_else(refused)?;
    let (owner, name) = rest.split_once('/').ok_or_else(refused)?;
    if !is_component(owner) || !is_component(name) {
        return Err(refused());
    }
    if repo != rest {
        return Err(SeedRefusal::bad_request("repo does not match url"));
    }
    Ok(())
}

/// Letters, digits, `.`, `_`, `-`; not starting with `.` or `-`.
fn is_component(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_COMPONENT
        && !value.starts_with('.')
        && !value.starts_with('-')
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

/// A full object name: 40 (SHA-1) or 64 (SHA-256) lowercase hex digits.
fn check_sha(name: &str, sha: &str) -> Result<(), SeedRefusal> {
    let hex = sha.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
    if hex && (sha.len() == 40 || sha.len() == 64) {
        Ok(())
    } else {
        Err(SeedRefusal::bad_request(format!("{name} must be a full lowercase object name")))
    }
}

/// The branch of `refs/heads/<branch>`, when git's own `check-ref-format`
/// accepts the ref and the branch cannot be read as an option.
fn check_head_ref(head_ref: &str) -> Result<String, SeedRefusal> {
    let refused = || SeedRefusal::bad_request("head_ref must be a valid ref under refs/heads/");
    let branch = head_ref.strip_prefix("refs/heads/").ok_or_else(refused)?;
    if branch.is_empty()
        || branch.starts_with('-')
        || head_ref.len() > 1024
        || head_ref.chars().any(char::is_control)
    {
        return Err(refused());
    }
    let valid = std::process::Command::new("git")
        .args(["check-ref-format", "--", head_ref])
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success());
    if valid { Ok(branch.to_owned()) } else { Err(refused()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_are_exactly_github_https_matching_repo() {
        assert!(check_url("https://github.com/o/n.git", "o/n").is_ok());
        assert!(check_url("https://github.com/manaflow-ai/cmux.git", "manaflow-ai/cmux").is_ok());
        for (url, repo) in [
            ("https://github.com/o/n.git", "o/m"),
            ("https://github.com/o/n", "o/n"),
            ("http://github.com/o/n.git", "o/n"),
            ("https://x@github.com/o/n.git", "o/n"),
            ("https://github.com.evil.com/o/n.git", "o/n"),
            ("https://github.com/o/n/x.git", "o/n/x"),
            ("https://github.com/-o/n.git", "-o/n"),
            ("https://github.com/./n.git", "./n"),
            ("https://github.com/o/n?.git", "o/n?"),
            ("git@github.com:o/n.git", "o/n"),
            ("file:///tmp/o/n.git", "o/n"),
        ] {
            assert!(check_url(url, repo).is_err(), "{url} {repo}");
        }
    }

    #[test]
    fn shas_are_full_lowercase_hex() {
        assert!(check_sha("x", &"a".repeat(40)).is_ok());
        assert!(check_sha("x", &"0".repeat(64)).is_ok());
        for sha in ["", "abc", &"A".repeat(40), &"g".repeat(40), &"a".repeat(41), "HEAD"] {
            assert!(check_sha("x", sha).is_err(), "{sha}");
        }
    }

    #[test]
    fn head_refs_are_checked_by_git() {
        assert_eq!(check_head_ref("refs/heads/feature/x").unwrap(), "feature/x");
        for head_ref in [
            "refs/heads/",
            "refs/tags/v1",
            "main",
            "refs/heads/-x",
            "refs/heads/a..b",
            "refs/heads/a b",
            "refs/heads/x.lock",
            "refs/heads/a~1",
        ] {
            assert!(check_head_ref(head_ref).is_err(), "{head_ref}");
        }
    }
}
