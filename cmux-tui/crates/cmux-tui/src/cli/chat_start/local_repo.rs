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
/// A branch or tag is checked out by `git clone --branch` itself. A commit ([`is_commit`]) is
/// cloned with `--no-checkout` and then checked out: until that checkout makes the index, the
/// clone is never reused ([`reuse`]), so no chat works in it, and a failed checkout removes only
/// the clone's own `.git` (and the folder, when this start made it and it is empty). git refuses a
/// folder that is not empty and on a failed clone removes only what it made, so a folder that was
/// there stays, with its permissions.
pub(super) fn ensure(url: &str, reference: Option<&str>, dir: &Path) -> Result<Ready, Value> {
    if is_nonempty(dir) {
        return reuse(url, dir);
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
    let existed = dir.exists();
    let commit = reference.filter(|reference| is_commit(reference));
    // Blobless: the whole history's commits and trees now, each file's contents when read, so a
    // big repository starts as fast as a small one.
    let mut args = vec![OsStr::new("clone"), "--quiet".as_ref(), "--filter=blob:none".as_ref()];
    match (reference, commit) {
        (_, Some(_)) => args.push("--no-checkout".as_ref()),
        (Some(reference), None) => args.extend([OsStr::new("--branch"), reference.as_ref()]),
        (None, None) => {}
    }
    args.extend([OsStr::new("--"), url.as_ref(), dir.as_os_str()]);
    git(None, args).map_err(|said| {
        let at = reference.map(|reference| format!(" at {reference}")).unwrap_or_default();
        error(
            "repo.clone_failed",
            format!("git clone {url}{at} failed: {said}"),
            json!({"url": url, "ref": reference}),
        )
    })?;
    if let Some(commit) = commit {
        git(Some(dir), ["-c", "advice.detachedHead=false", "checkout", "--quiet", commit])
            .map_err(|said| {
                // Never reused (no index yet), so this clone is this start's alone.
                let _ = std::fs::remove_dir_all(dir.join(".git"));
                if !existed {
                    let _ = std::fs::remove_dir(dir);
                }
                error(
                    "repo.checkout_failed",
                    format!("cloned {url}, but git checkout {commit} failed: {said}"),
                    json!({"url": url, "ref": commit, "dir": dir}),
                )
            })?;
    }
    Ok(Ready::Cloned)
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
        // A clone with no index has had no checkout yet: another start is still making it.
        if !dir.join(".git").join("index").exists() {
            let mut error = error(
                "repo.cloning",
                format!("{} is still being cloned; run this again in a moment", dir.display()),
                json!({"dir": dir}),
            );
            error["retryable"] = json!(true);
            return Err(error);
        }
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
