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
    #[serde(default)]
    base: Option<String>,
    #[serde(default)]
    bundle: Option<String>,
    #[serde(default)]
    head_ref: Option<String>,
    #[serde(default)]
    head: Option<String>,
    #[serde(default)]
    index: Option<String>,
    #[serde(default)]
    work: Option<String>,
    #[serde(default)]
    stash: Option<String>,
    #[serde(default)]
    sparse: Option<String>,
    #[serde(default)]
    lfs: bool,
    #[serde(default)]
    since: Option<String>,
    /// Clone only: the branch, tag or commit to check out.
    #[serde(default, rename = "ref")]
    git_ref: Option<String>,
    /// The checkout may open at its head first ([`HeadFirst`]).
    #[serde(default)]
    head_first: bool,
    /// With `head_first`: the folder below the repository's root the chat opens in.
    #[serde(default)]
    subpath: Option<String>,
    /// `git-seed-carry-v1`: the uploaded pack of `base` at depth 1 ([`StartParams::carry`]).
    #[serde(default)]
    carry: Option<String>,
    /// A warm mirror of the repository on this machine ([`StartParams::mirror`]).
    #[serde(default)]
    mirror: Option<String>,
    /// Where missing objects come from, in order ([`StartParams::promisors`]).
    #[serde(default)]
    promisors: Vec<String>,
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
    /// Clone only (no bundle, no Mac folder): `Some(ref)` with the branch,
    /// tag or commit to check out (`None` inside: the remote's default).
    pub clone_only: Option<Option<String>>,
    /// The checkout opens at its head first: only for a whole seed (no `since`) without
    /// the Mac's sparse patterns, and only when the subpath can be written as a pattern.
    pub head_first: Option<HeadFirst>,
    /// `git-seed-carry-v1`: the path (under the roots, like `bundle`) of a pack the sender made
    /// from its own objects with `base`, its tree and every blob of it, and nothing older. A fresh
    /// folder becomes a shallow repository at `base` from it instead of a clone (no GitHub, no
    /// credential); a folder with a repository already, or a pack that does not index, clones as
    /// before. Only for a whole seed (no `since`).
    pub carry: Option<String>,
    /// A warm mirror of the same repository on this machine (an absolute path: a bare
    /// repository or a checkout, such as `wt`'s blobless mirror). A fresh folder borrows its
    /// objects through `objects/info/alternates` instead of a carry or a clone when the mirror's
    /// `origin` is this repository and the base with its whole tree is in it (`run/borrow.rs`);
    /// otherwise the seed carries or clones as before. A clone-only start borrows it and fetches
    /// the rest from `origin` (`Seed::borrow_clone`). Only for a whole seed (no `since`).
    pub mirror: Option<String>,
    /// Where a borrowed or carried folder lazily fetches what it lacks (history, old blobs), in
    /// the order git tries them: each `url` itself (the forge) or an absolute path on this machine
    /// to a repository of the same repository (a peer). Empty: a borrowed folder fetches from
    /// `origin`, a carried one stays shallow as before. Only for a whole seed (no `since`).
    pub promisors: Vec<String>,
}

/// A seed that marks its head (`cmux_git::sync_barrier::Sync::head_ready`) before it fills
/// the rest of the checkout: the root's files, the harness folders and each folder on
/// `subpath` with its own files (`super::run`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HeadFirst {
    /// The subpath's folders, outermost first (`a`, `b` for `a/b`).
    pub subpath: Vec<String>,
}

/// Deepest subpath a head names.
const MAX_SUBPATH_PARTS: usize = 32;

impl HeadFirst {
    /// `None` when the subpath has a part a non-cone pattern cannot name literally: such a
    /// seed fills whole before it answers, as it did before heads.
    pub(super) fn of(subpath: Option<&str>) -> Option<Self> {
        let subpath = subpath.unwrap_or("").trim_matches('/');
        if subpath.is_empty() {
            return Some(Self { subpath: Vec::new() });
        }
        let parts: Vec<String> = subpath.split('/').map(str::to_owned).collect();
        let literal = |part: &String| {
            !part.is_empty()
                && part != "."
                && part != ".."
                && part.len() <= 255
                && !part.starts_with(' ')
                && !part.ends_with(' ')
                && !part.chars().any(|c| c.is_control() || "*?[]\\!#".contains(c))
        };
        (parts.len() <= MAX_SUBPATH_PARTS && parts.iter().all(literal))
            .then_some(Self { subpath: parts })
    }

    /// The subpath's folders, each relative to the root (`a`, `a/b`).
    pub fn folders(&self) -> Vec<String> {
        let mut at = String::new();
        self.subpath
            .iter()
            .map(|part| {
                if !at.is_empty() {
                    at.push('/');
                }
                at.push_str(part);
                at.clone()
            })
            .collect()
    }
}

impl StartParams {
    /// What makes a retry the same job, with the folder.
    pub fn retry_key(&self) -> String {
        // Every field, so a start that differs in anything is a new job.
        format!("{self:?}")
    }
}

impl StartParams {
    pub fn parse(params: &Value) -> Result<Self, SeedRefusal> {
        let wire: Wire = serde_json::from_value(params.clone())
            .map_err(|error| SeedRefusal::bad_request(format!("invalid params: {error}")))?;
        check_url(&wire.url, &wire.repo)?;
        let seed_fields = [&wire.base, &wire.bundle, &wire.head, &wire.index, &wire.work];
        if seed_fields.iter().all(|field| field.is_none())
            && wire.stash.is_none()
            && wire.since.is_none()
            && wire.head_ref.is_none()
        {
            return Self::clone_only(wire);
        }
        if wire.git_ref.is_some() {
            return Err(SeedRefusal::bad_request("ref is for a clone without a bundle"));
        }
        let required = |name: &str, value: Option<String>| {
            value.ok_or_else(|| SeedRefusal::bad_request(format!("{name} is required")))
        };
        let base = required("base", wire.base)?;
        let bundle = required("bundle", wire.bundle)?;
        let head = required("head", wire.head)?;
        let index = required("index", wire.index)?;
        let work = required("work", wire.work)?;
        for (name, sha) in [("base", &base), ("head", &head), ("index", &index), ("work", &work)] {
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
        if wire.carry.is_some() && wire.since.is_some() {
            return Err(SeedRefusal::bad_request("carry is for a whole seed, not a delta"));
        }
        if (wire.mirror.is_some() || !wire.promisors.is_empty()) && wire.since.is_some() {
            return Err(SeedRefusal::bad_request(
                "mirror and promisors are for a whole seed, not a delta",
            ));
        }
        if let Some(mirror) = &wire.mirror {
            check_local_path("mirror", mirror)?;
        }
        check_promisors(&wire.promisors, &wire.url)?;
        let head_first = (wire.head_first && wire.since.is_none() && wire.sparse.is_none())
            .then(|| HeadFirst::of(wire.subpath.as_deref()))
            .flatten();
        Ok(Self {
            folder: wire.folder,
            url: wire.url,
            base,
            bundle,
            branch,
            head,
            index,
            work,
            stash: wire.stash,
            sparse: wire.sparse,
            lfs: wire.lfs,
            since: wire.since,
            clone_only: None,
            head_first,
            carry: wire.carry,
            mirror: wire.mirror,
            promisors: wire.promisors,
        })
    }

    fn clone_only(wire: Wire) -> Result<Self, SeedRefusal> {
        if let Some(git_ref) = &wire.git_ref {
            check_clone_ref(git_ref)?;
        }
        if wire.sparse.is_some() {
            return Err(SeedRefusal::bad_request("sparse needs a seed bundle"));
        }
        if wire.carry.is_some() {
            return Err(SeedRefusal::bad_request("carry needs a seed bundle"));
        }
        if !wire.promisors.is_empty() {
            return Err(SeedRefusal::bad_request("promisors need a seed bundle"));
        }
        if let Some(mirror) = &wire.mirror {
            check_local_path("mirror", mirror)?;
        }
        Ok(Self {
            folder: wire.folder,
            url: wire.url,
            base: String::new(),
            bundle: String::new(),
            branch: None,
            head: String::new(),
            index: String::new(),
            work: String::new(),
            stash: None,
            sparse: None,
            lfs: wire.lfs,
            since: None,
            clone_only: Some(wire.git_ref),
            head_first: None,
            carry: None,
            mirror: wire.mirror,
            promisors: Vec::new(),
        })
    }
}

/// Most promisor sources a start names.
const MAX_PROMISORS: usize = 8;
/// Longest local path (`PATH_MAX`).
const MAX_PATH: usize = 4096;

/// An absolute path git reads as one line (`objects/info/alternates`, a remote's URL): no
/// control character, no `..` part.
pub(super) fn check_local_path(name: &str, path: &str) -> Result<(), SeedRefusal> {
    let fine = path.starts_with('/')
        && path.len() <= MAX_PATH
        && !path.chars().any(char::is_control)
        && !path.split('/').any(|part| part == "..");
    if fine {
        Ok(())
    } else {
        Err(SeedRefusal::bad_request(format!("{name} must be an absolute path")))
    }
}

/// Each promisor is `url` itself or a local path, and none twice.
fn check_promisors(promisors: &[String], url: &str) -> Result<(), SeedRefusal> {
    if promisors.len() > MAX_PROMISORS {
        return Err(SeedRefusal::bad_request(format!("at most {MAX_PROMISORS} promisors")));
    }
    for (at, promisor) in promisors.iter().enumerate() {
        if promisor != url {
            check_local_path("a promisor other than url", promisor)?;
        }
        if promisors[..at].contains(promisor) {
            return Err(SeedRefusal::bad_request("a promisor is named twice"));
        }
    }
    Ok(())
}

/// A clone's `ref`: a full object name, or a branch or tag name in
/// CloudMachineRepo's safe subset (letters, digits, `.`, `_`, `-`, `/`; no
/// part starting with `.` or ending with `.lock`, no `..`, not `HEAD`).
fn check_clone_ref(git_ref: &str) -> Result<(), SeedRefusal> {
    if check_sha("ref", git_ref).is_ok() {
        return Ok(());
    }
    let refused = || SeedRefusal::bad_request("ref must be a branch, tag or full commit");
    let safe = !git_ref.is_empty()
        && git_ref.len() <= 255
        && git_ref != "HEAD"
        && !git_ref.starts_with("HEAD/")
        && !git_ref.starts_with('-')
        && !git_ref.starts_with('/')
        && !git_ref.ends_with('/')
        && !git_ref.ends_with('.')
        && !git_ref.contains("..")
        && !git_ref.contains("//")
        && git_ref.split('/').all(|part| !part.starts_with('.') && !part.ends_with(".lock"))
        && git_ref.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-/".contains(&byte));
    if safe { Ok(()) } else { Err(refused()) }
}

/// `url` is exactly `https://github.com/<owner>/<name>.git` and `repo` is
/// `<owner>/<name>`.
pub(super) fn check_url(url: &str, repo: &str) -> Result<(), SeedRefusal> {
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
pub(super) fn check_sha(name: &str, sha: &str) -> Result<(), SeedRefusal> {
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
        // No `--`: git's check-ref-format refuses it. The ref starts with
        // `refs/heads/`, so it is never read as an option.
        .args(["check-ref-format", head_ref])
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
#[path = "params_tests.rs"]
mod tests;
