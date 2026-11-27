//! `cmux chat --repo URL`: a chat here in a clone of a repository (goal local-start-matrix; Leo,
//! 2026-11-06, on the Cloud start matrix's rows: "these should be goals for local too").
//!
//! The spec is the one `cloud new-machine --repo` reads ([`machine_repo::parse`]): `OWNER/NAME` on
//! GitHub, or any https git URL (GitLab's, a company server's), with `@REF` or a `/tree/REF` tail
//! for a branch, tag or commit. It is cloned with the person's own git and credentials into
//! `~/cmux/repos/HOST/OWNER/NAME` ([`default_dir`]), or `--cwd DIR`, and the chat starts there. A
//! clone of the same repository already in that folder is used as it is, never fetched or checked
//! out again, so a second chat on it keeps the first one's work. A folder holding anything else is
//! refused (`repo.dir_taken`), never written into.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use cmux_cloud_start_core::machine_repo::{self, Invalid, Repo};
use serde_json::{Value, json};

/// The repository `spec` names, or why it names none, for the usage error.
pub(super) fn parse(spec: &str) -> Result<Repo, String> {
    machine_repo::parse(spec).map_err(|invalid| match invalid {
        Invalid::Unrecognized => format!(
            "--repo {spec}: give OWNER/NAME on GitHub or an https git URL (https://HOST/GROUP/NAME)"
        ),
        Invalid::CredentialsInUrl => format!(
            "--repo {spec}: the URL holds a login or token; give it without one (git uses your \
             own credentials)"
        ),
        Invalid::InvalidRef => format!("--repo {spec}: the @REF is not a branch, tag or commit"),
    })
}

/// Where `repo` is cloned without `--cwd`: `HOME/cmux/repos/HOST/OWNER/NAME`, so two hosts or
/// owners with the same name never share a folder.
pub(super) fn default_dir(home: &Path, repo: &Repo) -> PathBuf {
    let mut dir = home.join("cmux").join("repos").join(&repo.host);
    dir.extend(repo.owner.split('/'));
    dir.join(&repo.name)
}

/// What [`ensure`] did.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Ready {
    Cloned,
    /// A clone of the same repository was already there.
    Reused,
}

/// `url` cloned into `dir` (an empty or missing folder), `reference` checked out when given; or
/// the clone already in `dir` when its origin is `url` (and it is at `reference`, when given).
/// Err: a `{code, message, details}` error.
///
/// Nothing here deletes anything. git clones into the folder itself (its permissions, its inode,
/// a symlink to it all stay), refuses one that is not empty, and on a failed clone removes only
/// what it made. A checkout that fails leaves the clone on its default branch, and says so; a
/// later start at that ref finds it is not there ([`reuse`]) and is refused, never let in on the
/// wrong commit.
pub(super) fn ensure(url: &str, reference: Option<&str>, dir: &Path) -> Result<Ready, Value> {
    if is_nonempty(dir) {
        return reuse(url, reference, dir);
    }
    if let Some(parent) = dir.parent() {
        std::fs::create_dir_all(parent).map_err(|err| {
            error(
                "repo.clone_failed",
                format!("could not make {}: {err}", parent.display()),
                json!({"dir": dir}),
            )
        })?;
    }
    // Blobless: the whole history's commits and trees now, each file's contents when read, so a
    // big repository starts as fast as a small one.
    let clone = ["clone", "--quiet", "--filter=blob:none", "--", url].map(OsStr::new);
    git(None, clone.into_iter().chain([dir.as_os_str()])).map_err(|said| {
        error("repo.clone_failed", format!("git clone {url} failed: {said}"), json!({"url": url}))
    })?;
    if let Some(reference) = reference {
        git(Some(dir), ["-c", "advice.detachedHead=false", "checkout", "--quiet", reference])
            .map_err(|said| {
                error(
                    "repo.checkout_failed",
                    format!(
                        "cloned {url} into {}, but git checkout {reference} failed: {said}; the \
                         clone stays there on its default branch",
                        dir.display()
                    ),
                    json!({"url": url, "ref": reference, "dir": dir}),
                )
            })?;
    }
    Ok(Ready::Cloned)
}

/// The clone already in `dir`, when its origin is `url` and, with `reference`, its HEAD is that
/// commit. Read only: nothing is fetched or checked out, so a chat's work there stays.
fn reuse(url: &str, reference: Option<&str>, dir: &Path) -> Result<Ready, Value> {
    // Only a folder with its own `.git` is asked: git would otherwise answer for a repository the
    // folder sits in.
    let origin = dir
        .join(".git")
        .exists()
        .then(|| git(Some(dir), ["remote", "get-url", "origin"]).ok())
        .flatten();
    if !origin.as_deref().is_some_and(|origin| same_remote(origin, url)) {
        return Err(error(
            "repo.dir_taken",
            format!(
                "{} already holds something other than a clone of {url}; give another folder \
                 with --cwd DIR",
                dir.display()
            ),
            json!({"dir": dir, "origin": origin}),
        ));
    }
    let Some(reference) = reference else { return Ok(Ready::Reused) };
    let commit = |name: &str| git(Some(dir), ["rev-parse", "--verify", "--quiet", name]).ok();
    let head = commit("HEAD^{commit}");
    // A branch is where the chat's commits go: when checkout would pick a branch for `@REF`, the
    // clone must be on `refs/heads/REF` (the full name, so a tag of that name cannot shorten it),
    // never on another branch at the same commit. A tag or commit is decided by the commit alone.
    let on_branch = || {
        git(Some(dir), ["symbolic-ref", "--quiet", "HEAD"]).ok()
            == Some(format!("refs/heads/{reference}"))
    };
    if let Some(Target { commit: target, branch }) = checkout_target(reference, commit)
        && head.as_deref() == Some(target.as_str())
        && (!branch || on_branch())
    {
        return Ok(Ready::Reused);
    }
    Err(error(
        "repo.ref_mismatch",
        format!(
            "{} holds a clone of {url} that is not at {reference}; check {reference} out there, \
             or give another folder with --cwd DIR",
            dir.display()
        ),
        json!({"dir": dir, "ref": reference, "head": head}),
    ))
}

/// The commit `git checkout REFERENCE` would check out, as `commit` (a `rev-parse`) reads it. git
/// resolves the name and prefers a local branch of it, so a local branch comes first, then the
/// name anywhere (a tag, a commit, a full ref), then the remote branch checkout would make a
/// local branch from.
pub(super) fn checkout_target(
    reference: &str,
    commit: impl Fn(&str) -> Option<String>,
) -> Option<Target> {
    [
        (format!("refs/heads/{reference}^{{commit}}"), true),
        (format!("{reference}^{{commit}}"), false),
        (format!("refs/remotes/origin/{reference}^{{commit}}"), true),
    ]
    .into_iter()
    .find_map(|(name, branch)| commit(&name).map(|commit| Target { commit, branch }))
}

/// What [`checkout_target`] found: the commit, and whether checkout puts HEAD on a branch for it
/// (a local branch, or the one it makes from origin's) rather than detached at a tag or commit.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Target {
    pub commit: String,
    pub branch: bool,
}

/// Whether two remote URLs name one repository: equal once a trailing `/` and `.git` are dropped
/// and the host is lowercased (what [`machine_repo::parse`] reads them as, when it reads both).
pub(super) fn same_remote(a: &str, b: &str) -> bool {
    match (machine_repo::parse(a), machine_repo::parse(b)) {
        (Ok(a), Ok(b)) => a.host == b.host && a.owner == b.owner && a.name == b.name,
        _ => trimmed(a) == trimmed(b),
    }
}

fn trimmed(url: &str) -> &str {
    let url = url.trim().trim_end_matches('/');
    url.strip_suffix(".git").unwrap_or(url)
}

fn is_nonempty(dir: &Path) -> bool {
    match std::fs::read_dir(dir) {
        Ok(mut entries) => entries.next().is_some(),
        // A file where the folder goes is taken too.
        Err(_) => dir.exists(),
    }
}

/// `git ARGS` (in `dir` when given) with no prompt, so a repository that needs a login fails at
/// once instead of waiting on a terminal nobody reads. Err: what git said.
fn git<I, S>(dir: Option<&Path>, args: I) -> Result<String, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    // Stdin is null: `output` sets it.
    let mut command = cmux_process::Command::new("git");
    if let Some(dir) = dir {
        command.arg("-C").arg(dir);
    }
    let output = command
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .map_err(|err| format!("could not run git: {err}"))?;
    if output.status.success() {
        return Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned());
    }
    let said = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    Err(if said.is_empty() { format!("exit {}", output.status) } else { said })
}

fn error(code: &str, message: String, details: Value) -> Value {
    json!({"code": code, "message": message, "details": details, "retryable": false})
}

#[cfg(test)]
mod tests;
