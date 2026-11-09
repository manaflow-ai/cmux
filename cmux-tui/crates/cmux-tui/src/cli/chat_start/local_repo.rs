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
/// the clone already in `dir` when its origin is `url`. Err: a `{code, message, details}` error.
///
/// One start at a time does this for a folder ([`lock`]): a second start waits for the first's
/// clone and checkout and then reuses it, so it never works in a clone that a failed checkout is
/// about to take away.
pub(super) fn ensure(url: &str, reference: Option<&str>, dir: &Path) -> Result<Ready, Value> {
    let _lock = lock(dir)?;
    if is_nonempty(dir) {
        // Only a folder with its own `.git` is asked: git would otherwise answer for a repository
        // the folder sits in.
        let origin = dir
            .join(".git")
            .exists()
            .then(|| git(Some(dir), ["remote", "get-url", "origin"]).ok())
            .flatten();
        if origin.as_deref().is_some_and(|origin| same_remote(origin, url)) {
            return Ok(Ready::Reused);
        }
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
    // Blobless: the whole history's commits and trees now, each file's contents when read, so a
    // big repository starts as fast as a small one.
    let existed = dir.exists();
    let clone = ["clone", "--quiet", "--filter=blob:none", "--", url].map(OsStr::new);
    git(None, clone.into_iter().chain([dir.as_os_str()])).map_err(|said| {
        error("repo.clone_failed", format!("git clone {url} failed: {said}"), json!({"url": url}))
    })?;
    if let Some(reference) = reference {
        git(Some(dir), ["checkout", "--quiet", reference]).map_err(|said| {
            // The clone is this start's own (no other start reuses it before the lock is let go):
            // take it away, so a retry clones again and checks the ref out instead of reusing a
            // clone on the default branch. A folder that was there stays, with its permissions.
            if existed {
                empty(dir);
            } else {
                let _ = std::fs::remove_dir_all(dir);
            }
            error(
                "repo.checkout_failed",
                format!("cloned {url}, but git checkout {reference} failed: {said}"),
                json!({"url": url, "ref": reference, "dir": dir}),
            )
        })?;
    }
    Ok(Ready::Cloned)
}

/// The advisory lock on `dir`'s clone (`.NAME.cmux-clone.lock` beside it, made with its parent
/// folders), held until the returned file is dropped.
fn lock(dir: &Path) -> Result<std::fs::File, Value> {
    let failed = |err: std::io::Error| {
        error(
            "repo.clone_failed",
            format!("could not lock {} for its clone: {err}", dir.display()),
            json!({"dir": dir}),
        )
    };
    let (Some(parent), Some(name)) = (dir.parent(), dir.file_name()) else {
        return Err(failed(std::io::Error::other("the folder has no parent")));
    };
    std::fs::create_dir_all(parent).map_err(failed)?;
    let mut lock_name = std::ffi::OsString::from(".");
    lock_name.push(name);
    lock_name.push(".cmux-clone.lock");
    // Only the advisory lock matters; the file holds no data, so opening it never truncates.
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(parent.join(lock_name))
        .map_err(failed)?;
    fs4::FileExt::lock(&file).map_err(failed)?;
    Ok(file)
}

/// Everything in `dir` removed, `dir` itself kept.
fn empty(dir: &Path) {
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        let _ = if entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
    }
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
