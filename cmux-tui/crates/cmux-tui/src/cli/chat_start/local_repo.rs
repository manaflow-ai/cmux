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

/// `url` cloned into `dir` (an empty or missing folder) at `reference` when given; or the clone
/// already in `dir` when its origin is `url`. Err: a `{code, message, details}` error.
///
/// The clone is made and checked out in a staging folder beside `dir` that only this start
/// names, then put in place by one `rename`, which takes a missing or empty `dir` and refuses one
/// that is not empty. No other start ever sees a clone before its checkout is done, and a failure
/// at any step removes only the staging folder. A `dir` that was there keeps its permissions.
pub(super) fn ensure(url: &str, reference: Option<&str>, dir: &Path) -> Result<Ready, Value> {
    if is_nonempty(dir) {
        return reuse(url, dir);
    }
    let (Some(parent), Some(name)) = (dir.parent(), dir.file_name()) else {
        return Err(failed(dir, format!("{} has no parent folder", dir.display())));
    };
    std::fs::create_dir_all(parent)
        .map_err(|err| failed(dir, format!("could not make {}: {err}", parent.display())))?;
    let mut staging_name = std::ffi::OsString::from(".");
    staging_name.push(name);
    staging_name.push(format!(".cmux-clone-{}-{}", std::process::id(), unique()));
    let staging = parent.join(staging_name);
    let result = clone_at(url, reference, &staging).and_then(|()| publish(url, &staging, dir));
    let _ = std::fs::remove_dir_all(&staging);
    result
}

/// `url` cloned into `staging` (which does not exist) and checked out at `reference`.
fn clone_at(url: &str, reference: Option<&str>, staging: &Path) -> Result<(), Value> {
    let commit = reference.filter(|reference| is_commit(reference));
    // Blobless: the whole history's commits and trees now, each file's contents when read, so a
    // big repository starts as fast as a small one.
    let mut args = vec![OsStr::new("clone"), "--quiet".as_ref(), "--filter=blob:none".as_ref()];
    match (reference, commit) {
        (_, Some(_)) => args.push("--no-checkout".as_ref()),
        (Some(reference), None) => args.extend([OsStr::new("--branch"), reference.as_ref()]),
        (None, None) => {}
    }
    args.extend([OsStr::new("--"), url.as_ref(), staging.as_os_str()]);
    git(None, args).map_err(|said| {
        let at = reference.map(|reference| format!(" at {reference}")).unwrap_or_default();
        error(
            "repo.clone_failed",
            format!("git clone {url}{at} failed: {said}"),
            json!({"url": url, "ref": reference}),
        )
    })?;
    if let Some(commit) = commit {
        git(Some(staging), ["-c", "advice.detachedHead=false", "checkout", "--quiet", commit])
            .map_err(|said| {
                error(
                    "repo.checkout_failed",
                    format!("cloned {url}, but git checkout {commit} failed: {said}"),
                    json!({"url": url, "ref": commit}),
                )
            })?;
    }
    Ok(())
}

/// The finished clone in `staging` put at `dir` in one `rename`. A `dir` that is there (empty, or
/// [`ensure`] would not have cloned) lends the clone its permissions first. When another start
/// put its clone there meanwhile, the rename is refused and that clone is reused.
fn publish(url: &str, staging: &Path, dir: &Path) -> Result<Ready, Value> {
    if let Ok(meta) = std::fs::metadata(dir) {
        let _ = std::fs::set_permissions(staging, meta.permissions());
    }
    match std::fs::rename(staging, dir) {
        Ok(()) => Ok(Ready::Cloned),
        Err(_) if is_nonempty(dir) => reuse(url, dir),
        Err(err) => {
            Err(failed(dir, format!("could not put the clone at {}: {err}", dir.display())))
        }
    }
}

/// A number no other start picks at the same moment, with the process id beside it.
fn unique() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos())
}

fn failed(dir: &Path, message: String) -> Value {
    error("repo.clone_failed", message, json!({"dir": dir}))
}

/// Whether `reference` reads as a commit id (7 to 40 hex digits) rather than a branch or tag,
/// which `git clone --branch` takes.
pub(super) fn is_commit(reference: &str) -> bool {
    (7..=40).contains(&reference.len()) && reference.bytes().all(|b| b.is_ascii_hexdigit())
}

/// The clone already in `dir`, when its origin is `url`.
fn reuse(url: &str, dir: &Path) -> Result<Ready, Value> {
    // Only a folder with its own `.git` is asked: git would otherwise answer for a repository the
    // folder sits in.
    let origin = dir
        .join(".git")
        .exists()
        .then(|| git(Some(dir), ["remote", "get-url", "origin"]).ok())
        .flatten();
    if origin.as_deref().is_some_and(|origin| same_remote(origin, url)) {
        return Ok(Ready::Reused);
    }
    Err(error(
        "repo.dir_taken",
        format!(
            "{} already holds something other than a clone of {url}; give another folder with \
             --cwd DIR",
            dir.display()
        ),
        json!({"dir": dir, "origin": origin}),
    ))
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
