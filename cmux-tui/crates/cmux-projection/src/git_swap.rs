//! A projected repository's `.git` switching from the Mac to the machine's own fetch (RFD 0007,
//! seed bundles: "a repo with a public remote should still take its objects from the remote
//! (C) ... The open part is the swap: serving `.git` by projection until the machine's own fetch
//! lands, then switching to it").
//!
//! At session start `.git` is the projection's, its bytes from the Mac on first read. Beside it,
//! [`prepare`] builds the machine's own repository on its disk (`<state>/git-local`):
//! 1. a blobless fetch (`--filter=blob:none`) from the repository's public remote of the branches
//!    the Mac tracks there: history and trees from the remote, blobs on first use, from the remote
//!    too (a `cmux-seed` promisor remote, so the Mac's own remote settings stay as they are);
//! 2. a fetch from the projected `.git` itself of every ref (`+refs/*:refs/*`), negotiated against
//!    what step 1 brought: only what the remote lacks crosses the Mac's link, which is the
//!    unpushed commits, their trees and blobs, and the stash;
//! 3. the Mac's `HEAD`, `index`, `config` (with the promisor remote added) and `info/` copied as
//!    they read through the mount, the remote's refs of step 1 deleted.
//!
//! [`swap`] then puts a link to it at `.git` in the upper layer in one rename
//! ([`crate::overlay::Overlay::swap_to_link`]) and has the kernel forget the old entry. The two
//! repositories hold the same refs, HEAD and index, and the new one every object the old one
//! reached, so a git process that read part of its state before the switch and part after
//! still sees one repository. The Mac's state is fingerprinted ([`fingerprint`]) before step 2
//! and again just before the rename; a change between (a commit on the machine meanwhile) runs
//! steps 2 and 3 again.
//!
//! A repository is left on projection when its remote cannot be read without credentials
//! (`GIT_TERMINAL_PROMPT=0`), when it is shallow, has submodules' repositories in
//! `.git/modules`, or is mid-merge, rebase, cherry-pick or bisect.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use cmux_process::{Command, Stdio};

/// The promisor remote the machine's repository fetches blobs from.
pub const SEED_REMOTE: &str = "cmux-seed";
/// Where the remote's refs land during [`prepare`] (deleted at its end).
const SEED_REFS: &str = "refs/cmux-seed/";
/// The machine's repository, in the projection's state folder.
pub const LOCAL_DIR: &str = "git-local";
/// How many times a moving Mac state is copied again before the swap gives up for now.
const ATTEMPTS: usize = 3;
/// What in `.git` leaves the repository on projection: git is mid-operation, or the state is one
/// the copy does not carry.
const UNSWAPPABLE: [&str; 9] = [
    "shallow",
    "modules",
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "BISECT_LOG",
    "rebase-merge",
    "rebase-apply",
    "sequencer",
];

fn git(git_dir: &Path) -> Command {
    let mut command = Command::new("git");
    // `GIT_DIR`, not `--git-dir`: a `git` wrapper on PATH (a machine's own) that reads only
    // the command line sees a plain command.
    command.env("GIT_DIR", git_dir);
    // A private remote fails at once instead of asking for a password nobody types.
    command.env("GIT_TERMINAL_PROMPT", "0").env("GIT_ASKPASS", "true").env("SSH_ASKPASS", "true");
    command.env("GIT_SSH_COMMAND", "ssh -oBatchMode=yes");
    command
}

fn output(mut command: Command) -> anyhow::Result<Vec<u8>> {
    let out = command.stdin(Stdio::null()).stderr(Stdio::piped()).output()?;
    anyhow::ensure!(
        out.status.success(),
        "{command:?} failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(out.stdout)
}

fn text(command: Command) -> anyhow::Result<String> {
    Ok(String::from_utf8(output(command)?)?)
}

/// Runs `command` with `lines` on its stdin.
fn with_stdin(mut command: Command, lines: &[String]) -> anyhow::Result<()> {
    let mut child =
        command.stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped()).spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        for line in lines {
            writeln!(stdin, "{line}")?;
        }
    }
    let out = child.wait_with_output()?;
    anyhow::ensure!(
        out.status.success(),
        "{command:?} failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    Ok(())
}

/// The URL a public remote is fetched from anonymously: `https://` and `file://` as they are
/// (user info cut), a GitHub SSH form as its `https://` one; anything else is none.
#[must_use]
pub fn anonymous_url(url: &str) -> Option<String> {
    let url = url.trim();
    for prefix in ["git@github.com:", "ssh://git@github.com/"] {
        if let Some(rest) = url.strip_prefix(prefix) {
            return Some(format!("https://github.com/{rest}"));
        }
    }
    if let Some(rest) = url.strip_prefix("https://") {
        let rest = match rest.split_once('/') {
            Some((host, path)) => {
                let host = host.rsplit_once('@').map_or(host, |(_, host)| host);
                format!("{host}/{path}")
            }
            None => rest.to_owned(),
        };
        return Some(format!("https://{rest}"));
    }
    url.starts_with("file://").then(|| url.to_owned())
}

/// The remote the repository at `git_dir` takes its objects from, and its anonymous URL: the
/// current branch's upstream remote, else `origin`.
pub fn seed_remote(git_dir: &Path) -> Option<(String, String)> {
    let config = git_dir.join("config");
    let get = |key: &str| {
        let mut command = Command::new("git");
        command.arg("config").arg("--file").arg(&config).args(["--get", key]);
        text(command).ok().map(|value| value.trim().to_owned()).filter(|value| !value.is_empty())
    };
    let head = std::fs::read_to_string(git_dir.join("HEAD")).ok()?;
    let branch = head.trim().strip_prefix("ref: refs/heads/").map(str::to_owned);
    let remote = branch
        .and_then(|branch| get(&format!("branch.{branch}.remote")))
        .filter(|remote| remote != ".")
        .unwrap_or_else(|| "origin".to_owned());
    let url = anonymous_url(&get(&format!("remote.{remote}.url"))?)?;
    Some((remote, url))
}

/// What must match between the copy and the swap: HEAD, every ref, and the index's size and
/// modification time. `None` while git is mid-operation there (a lock file, a merge).
pub fn fingerprint(git_dir: &Path) -> anyhow::Result<Option<String>> {
    for name in UNSWAPPABLE {
        if std::fs::symlink_metadata(git_dir.join(name)).is_ok() {
            return Ok(None);
        }
    }
    for lock in ["index.lock", "HEAD.lock", "packed-refs.lock"] {
        if std::fs::symlink_metadata(git_dir.join(lock)).is_ok() {
            return Ok(None);
        }
    }
    let head = std::fs::read_to_string(git_dir.join("HEAD"))?;
    let mut refs = git(git_dir);
    refs.args(["for-each-ref", "--format=%(objectname) %(refname)"]);
    let refs = text(refs)?;
    let index = match std::fs::metadata(git_dir.join("index")) {
        Ok(meta) => {
            use std::os::unix::fs::MetadataExt as _;
            format!("{} {}.{}", meta.len(), meta.mtime(), meta.mtime_nsec())
        }
        Err(_) => "none".to_owned(),
    };
    Ok(Some(format!("{head}\n{index}\n{refs}")))
}

/// The machine's repository at `local`, made from `projected` (the `.git` as the mount serves
/// it) and the public `url`, as the module doc says. Returns the fingerprint it matches.
pub fn prepare(projected: &Path, local: &Path, url: &str) -> anyhow::Result<String> {
    let Some(before) = fingerprint(projected)? else {
        anyhow::bail!("git is busy in {} (a lock or an operation in progress)", projected.display())
    };
    if local.exists() {
        std::fs::remove_dir_all(local)?;
    }
    let mut init = Command::new("git");
    init.args(["init", "--bare", "--quiet"]).arg(local);
    output(init)?;
    for (key, value) in [
        ("core.repositoryformatversion", "1"),
        ("extensions.partialClone", SEED_REMOTE),
        (&format!("remote.{SEED_REMOTE}.url"), url),
        (&format!("remote.{SEED_REMOTE}.promisor"), "true"),
        (&format!("remote.{SEED_REMOTE}.partialclonefilter"), "blob:none"),
    ] {
        let mut set = git(local);
        set.args(["config", key, value]);
        output(set)?;
    }
    fetch_remote(projected, local)?;
    let mut fingerprint_now = before;
    for _ in 0..ATTEMPTS {
        copy_mac_state(projected, local)?;
        match fingerprint(projected)? {
            Some(after) if after == fingerprint_now => return Ok(after),
            Some(after) => fingerprint_now = after,
            None => {}
        }
    }
    anyhow::bail!("the repository kept changing while it was copied")
}

/// Step 1: the branches the Mac tracks on the remote (that the remote still has), blobless.
fn fetch_remote(projected: &Path, local: &Path) -> anyhow::Result<()> {
    let mut remote = git(local);
    remote.args(["ls-remote", "--symref", SEED_REMOTE, "HEAD", "refs/heads/*"]);
    let listed = text(remote)?;
    let mut mac = git(projected);
    mac.args(["for-each-ref", "--format=%(refname)", "refs/remotes/"]);
    let tracked: std::collections::BTreeSet<String> = text(mac)?
        .lines()
        .filter_map(|name| name.strip_prefix("refs/remotes/"))
        .filter_map(|rest| rest.split_once('/').map(|(_, branch)| branch.to_owned()))
        .collect();
    let mut wanted = Vec::new();
    let mut head = None;
    for line in listed.lines() {
        if let Some(rest) = line.strip_prefix("ref: refs/heads/") {
            head = rest.split_whitespace().next().map(str::to_owned);
            continue;
        }
        let Some((_, name)) = line.split_once('\t') else { continue };
        let Some(branch) = name.strip_prefix("refs/heads/") else { continue };
        if tracked.contains(branch) {
            wanted.push(branch.to_owned());
        }
    }
    if wanted.is_empty() {
        wanted.extend(head);
    }
    if wanted.is_empty() {
        return Ok(());
    }
    let specs: Vec<String> =
        wanted.iter().map(|branch| format!("+refs/heads/{branch}:{SEED_REFS}{branch}")).collect();
    let mut fetch = git(local);
    fetch.args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--filter=blob:none"]);
    fetch.args(["--recurse-submodules=no", "--stdin", SEED_REMOTE]);
    with_stdin(fetch, &specs)
}

/// Steps 2 and 3: every ref and the objects the remote lacks from the projected `.git`, then
/// its HEAD, index, config and info.
fn copy_mac_state(projected: &Path, local: &Path) -> anyhow::Result<()> {
    let mut fetch = git(local);
    fetch.args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--update-head-ok"]);
    // No `--prune`: git prunes before it negotiates, which would drop the seed refs and with
    // them every `have`, and the Mac would send its whole history. Pruned below instead.
    fetch.args(["--recurse-submodules=no"]);
    // Negotiation only from what is already here, never a lazy blob fetch to check one.
    fetch.env("GIT_NO_LAZY_FETCH", "1");
    fetch.arg(projected).arg("+refs/*:refs/*");
    output(fetch)?;
    let mut mac = git(projected);
    mac.args(["for-each-ref", "--format=%(refname)"]);
    let on_mac: std::collections::HashSet<String> = text(mac)?.lines().map(str::to_owned).collect();
    let mut list = git(local);
    list.args(["for-each-ref", "--format=%(refname)"]);
    // The seed refs, and refs the Mac deleted since an earlier attempt.
    let deletes: Vec<String> = text(list)?
        .lines()
        .filter(|name| !on_mac.contains(*name))
        .map(|name| format!("delete {name}"))
        .collect();
    if !deletes.is_empty() {
        let mut update = git(local);
        update.args(["update-ref", "--stdin"]);
        with_stdin(update, &deletes)?;
    }
    let config = std::fs::read_to_string(projected.join("config")).unwrap_or_default();
    let lead = if config.is_empty() || config.ends_with('\n') { "" } else { "\n" };
    let ours = format!(
        "{lead}[core]\n\tbare = false\n\trepositoryformatversion = 1\n\tcheckStat = minimal\n\t\
         trustctime = false\n[extensions]\n\tpartialClone = {SEED_REMOTE}\n[remote \"{SEED_REMOTE}\"]\n\t\
         url = {url}\n\tpromisor = true\n\tpartialclonefilter = blob:none\n",
        url = seed_url(local)?,
    );
    write_atomic(&local.join("config"), format!("{config}{ours}").as_bytes())?;
    let info = projected.join("info");
    if let Ok(entries) = std::fs::read_dir(&info) {
        std::fs::create_dir_all(local.join("info"))?;
        for entry in entries.flatten() {
            if entry.file_type().is_ok_and(|kind| kind.is_file()) {
                let bytes = std::fs::read(entry.path())?;
                write_atomic(&local.join("info").join(entry.file_name()), &bytes)?;
            }
        }
    }
    match std::fs::read(projected.join("index")) {
        Ok(bytes) => write_atomic(&local.join("index"), &bytes)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let _ = std::fs::remove_file(local.join("index"));
        }
        Err(error) => return Err(error.into()),
    }
    write_atomic(&local.join("HEAD"), &std::fs::read(projected.join("HEAD"))?)?;
    Ok(())
}

fn seed_url(local: &Path) -> anyhow::Result<String> {
    let mut get = git(local);
    get.args(["config", "--get", &format!("remote.{SEED_REMOTE}.url")]);
    Ok(text(get)?.trim().to_owned())
}

fn write_atomic(file: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let temp = file.with_extension("cmux-swap.tmp");
    std::fs::write(&temp, bytes)?;
    std::fs::rename(&temp, file)?;
    Ok(())
}

/// What a swap attempt did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// `.git` is now the machine's repository at this path.
    Swapped(PathBuf),
    /// `.git` was already the machine's (an earlier swap, kept in the upper layer).
    Already,
    /// The folder has no `.git` folder from the Mac.
    NoRepository,
    /// No remote that reads without credentials: `.git` stays on projection.
    NoPublicRemote,
}

/// Prepares and swaps the `.git` of the projected folder mounted at `at` with its state in
/// `state`. `forget` drops the kernel's cached `.git` entry once the overlay answers the link
/// ([`crate::mount::Mounted::forget_entry`] of the root); it runs only after the long fetch, so a
/// caller can take its mount's lock there alone. Linux only (the mount is).
#[cfg(target_os = "linux")]
pub fn run(
    overlay: &crate::overlay::Overlay,
    forget: &dyn Fn() -> std::io::Result<()>,
    at: &Path,
    state: &Path,
) -> anyhow::Result<Outcome> {
    let projected = at.join(".git");
    match std::fs::symlink_metadata(&projected) {
        Ok(meta) if meta.file_type().is_symlink() => return Ok(Outcome::Already),
        Ok(meta) if meta.is_dir() => {}
        _ => return Ok(Outcome::NoRepository),
    }
    let Some((_, url)) = seed_remote(&projected) else { return Ok(Outcome::NoPublicRemote) };
    let local = state.join(LOCAL_DIR);
    let ready = match prepare(&projected, &local, &url) {
        Ok(ready) => ready,
        Err(error) if is_unreachable(&error) => return Ok(Outcome::NoPublicRemote),
        Err(error) => return Err(error),
    };
    swap(overlay, forget, &projected, &local, &ready)?;
    Ok(Outcome::Swapped(local))
}

/// The rename itself: refused (an error, `.git` stays on projection) when the Mac's state moved
/// since `ready` was taken.
#[cfg(target_os = "linux")]
pub fn swap(
    overlay: &crate::overlay::Overlay,
    forget: &dyn Fn() -> std::io::Result<()>,
    projected: &Path,
    local: &Path,
    ready: &str,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        fingerprint(projected)?.as_deref() == Some(ready),
        "the repository changed after it was copied"
    );
    overlay
        .swap_to_link(".git", local)
        .map_err(|errno| anyhow::anyhow!("swapping .git: errno {errno}"))?;
    forget()?;
    Ok(())
}

fn is_unreachable(error: &anyhow::Error) -> bool {
    let text = format!("{error:#}");
    text.contains("ls-remote")
        && ["could not read", "Authentication", "not found", "terminal prompts disabled"]
            .iter()
            .any(|needle| text.contains(needle))
}

#[cfg(all(test, target_os = "linux"))]
#[path = "git_swap_tests.rs"]
mod tests;
