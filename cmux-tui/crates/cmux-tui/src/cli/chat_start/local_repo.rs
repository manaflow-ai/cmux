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

/// The folder inside a clone's folder that claims it while one start clones (module docs of
/// [`ensure`]).
pub(super) const CLAIM: &str = ".cmux-clone";

/// `url` cloned into `dir` (an empty or missing folder), `reference` checked out when given; or
/// the clone already in `dir` when its origin is `url`. Err: a `{code, message, details}` error.
///
/// One start clones a folder: it claims it by making [`CLAIM`] inside it (a `mkdir`, which only
/// one start wins, through any symlink to the folder), clones and checks out into the claim,
/// moves the checkout up with `.git` last and removes the claim. Any other start meanwhile is
/// answered `repo.cloning` (retryable), and none sees a clone before its checkout is done, so a
/// failed checkout only ever removes what is inside its own claim. Reusing a clone writes
/// nothing.
pub(super) fn ensure(url: &str, reference: Option<&str>, dir: &Path) -> Result<Ready, Value> {
    let claim = dir.join(CLAIM);
    // A folder with its own `.git` is a finished clone (`.git` moves in last), whatever else it
    // holds: a repository may track a `.cmux-clone` of its own.
    if dir.join(".git").exists() {
        return reuse(url, dir);
    }
    if claim.exists() {
        return Err(cloning(dir, &claim));
    }
    if is_nonempty(dir) {
        return reuse(url, dir);
    }
    let made = make_dir(dir)?;
    match std::fs::create_dir(&claim) {
        Ok(()) => {}
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(cloning(dir, &claim));
        }
        Err(err) => return Err(failed(dir, format!("could not claim {}: {err}", dir.display()))),
    }
    // Checked again under the claim: another start may have cloned and let its claim go between
    // the check above and this claim. Its clone is reused, never written over.
    if !only_claim(dir) {
        let _ = std::fs::remove_dir(&claim);
        return reuse(url, dir);
    }
    // `clone_into` takes away its own staging folder, wherever it is by then, on every path out;
    // nothing here deletes by the claim's fixed name.
    let result = clone_into(url, reference, dir, &claim);
    if result.is_err() {
        if made {
            // Only when nothing else is in it: `remove_dir` leaves a folder that is not empty.
            let _ = std::fs::remove_dir(dir);
        }
    }
    result.map(|()| Ready::Cloned)
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

/// `dir` made with its parents. Ok(true) when this call made it.
fn make_dir(dir: &Path) -> Result<bool, Value> {
    if let Some(parent) = dir.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| failed(dir, format!("could not make {}: {err}", parent.display())))?;
    }
    match std::fs::create_dir(dir) {
        Ok(()) => Ok(true),
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
        Err(err) => Err(failed(dir, format!("could not make {}: {err}", dir.display()))),
    }
}

/// The clone made inside `claim` and moved up into `dir`, `.git` last.
fn clone_into(url: &str, reference: Option<&str>, dir: &Path, claim: &Path) -> Result<(), Value> {
    // The folder this start owns: the claim, or the claim once moved aside under a name of this
    // start's own. Only it is ever removed, on success and failure alike.
    let mut staging = claim.to_path_buf();
    let result = stage_and_publish(url, reference, dir, &mut staging);
    let _ = std::fs::remove_dir_all(&staging);
    result
}

/// [`clone_into`]'s work; `staging` follows the folder this start owns as it moves.
fn stage_and_publish(
    url: &str,
    reference: Option<&str>,
    dir: &Path,
    staging: &mut PathBuf,
) -> Result<(), Value> {
    let work = staging.join("checkout");
    // Blobless: the whole history's commits and trees now, each file's contents when read, so a
    // big repository starts as fast as a small one.
    let clone = ["clone", "--quiet", "--filter=blob:none", "--", url].map(OsStr::new);
    git(None, clone.into_iter().chain([work.as_os_str()])).map_err(|said| {
        error("repo.clone_failed", format!("git clone {url} failed: {said}"), json!({"url": url}))
    })?;
    if let Some(reference) = reference {
        git(Some(&work), ["checkout", "--quiet", reference]).map_err(|said| {
            error(
                "repo.checkout_failed",
                format!("cloned {url}, but git checkout {reference} failed: {said}"),
                json!({"url": url, "ref": reference, "dir": dir}),
            )
        })?;
    }
    let entries = std::fs::read_dir(&work)
        .map_err(|err| failed(dir, format!("could not read the clone: {err}")))?;
    let names: Vec<_> = entries.flatten().map(|entry| entry.file_name()).collect();
    let publish = |name: &OsStr, from: &Path| {
        let to = dir.join(name);
        // Never over anything: the claim keeps only other starts out, so a path that is there
        // now is someone else's, and the move refuses it in the same call (no check-then-move).
        rename_no_replace(&from.join(name), &to).map_err(|err| {
            if err.kind() == std::io::ErrorKind::AlreadyExists {
                failed(dir, format!("{} appeared while cloning", to.display()))
            } else {
                failed(dir, format!("could not move {} into place: {err}", name.to_string_lossy()))
            }
        })
    };
    let tracks_claim = names.iter().any(|name| name == CLAIM);
    for name in names.iter().filter(|name| *name != ".git" && *name != CLAIM) {
        publish(name, &work)?;
    }
    // A `.cmux-clone` the repository tracks takes the claim's place: the claim moves aside, under
    // a name no other start uses and never over anything, and `staging` follows it. A start
    // reading the folder meanwhile sees files and no `.git`, and is refused, never let in.
    if tracks_claim {
        let aside = dir.join(format!("{CLAIM}-{}-{}", std::process::id(), unique()));
        rename_no_replace(staging, &aside)
            .map_err(|err| failed(dir, format!("could not move the claim aside: {err}")))?;
        *staging = aside;
        publish(OsStr::new(CLAIM), &staging.join("checkout"))?;
    }
    // `.git` last: no start sees a clone before the rest of it is in place.
    publish(OsStr::new(".git"), &staging.join("checkout"))
}

/// A number no other start in this process or another picks at the same moment.
fn unique() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos())
}

/// `from` moved to `to` in one call that fails `AlreadyExists` when anything is at `to`, never
/// replacing it (Linux `renameat2(RENAME_NOREPLACE)`, macOS `renamex_np(RENAME_EXCL)`).
pub(super) fn rename_no_replace(from: &Path, to: &Path) -> std::io::Result<()> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        use std::os::unix::ffi::OsStrExt as _;
        let c = |path: &Path| {
            std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| {
                std::io::Error::new(std::io::ErrorKind::InvalidInput, "a NUL in a path")
            })
        };
        let (from, to) = (c(from)?, c(to)?);
        #[cfg(target_os = "linux")]
        // SAFETY: both are NUL-terminated paths that live past the call; renameat2 only reads them.
        let code = unsafe {
            libc::renameat2(
                libc::AT_FDCWD,
                from.as_ptr(),
                libc::AT_FDCWD,
                to.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        #[cfg(target_os = "macos")]
        // SAFETY: both are NUL-terminated paths that live past the call; renamex_np only reads them.
        let code = unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) };
        if code == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        // No no-replace rename here: a hard link refuses an existing path (files only).
        std::fs::hard_link(from, to)?;
        std::fs::remove_file(from)
    }
}

/// Whether `dir` holds nothing but the claim.
fn only_claim(dir: &Path) -> bool {
    std::fs::read_dir(dir)
        .is_ok_and(|entries| entries.flatten().all(|entry| entry.file_name() == CLAIM))
}

fn cloning(dir: &Path, claim: &Path) -> Value {
    let mut error = error(
        "repo.cloning",
        format!(
            "another start is cloning into {}; run this again once it is done (if none is, remove \
             {})",
            dir.display(),
            claim.display()
        ),
        json!({"dir": dir}),
    );
    error["retryable"] = json!(true);
    error
}

fn failed(dir: &Path, message: String) -> Value {
    error("repo.clone_failed", message, json!({"dir": dir}))
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
