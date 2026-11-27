//! Projected `.git` switches to a repository prepared from the sender's carry pack.
//!
//! [`prepare_carry`] indexes the depth-one commit/tree pack, then fetches refs, HEAD history,
//! and staged blobs from the projection itself. It never contacts the configured remote.
//! [`prepare`] retains the older public-remote path for its existing callers and benchmark.
//!
//! [`swap`] installs the prepared repository as one upper-layer symlink rename. Both packed
//! and loose refs are kept so a Git reader crossing the rename can resolve either layout.
//! HEAD, refs and index are fingerprinted before preparation and again before the rename.
//! Busy, shallow, unsupported or failed preparations retain the projected repository.
//!
//! Bring Back expands this owned link and includes the local repository in its transfer mark,
//! so commits and staged work made after the swap return to the Mac before the state is freed.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use cmux_process::{Command, Stdio};

/// The promisor remote the machine's repository fetches blobs from.
pub const SEED_REMOTE: &str = "cmux-seed";
/// Where the remote's refs land during [`prepare`] (deleted at its end).
const SEED_REFS: &str = "refs/cmux-seed/";
/// The machine's repository, in the projection's state folder.
pub const LOCAL_DIR: &str = "git-local";
/// Present only after a carried repository has been fully copied and is safe to read as the
/// machine's complete Git state during Bring Back.
pub const SWAP_MARKER: &str = "cmux-carry.complete";
/// The swap's owned repository, only while the upper `.git` link names it. Ordinary
/// user symlinks remain links in Bring Back; they never cause a directory traversal.
pub(crate) fn swapped_repository(state: &Path) -> std::io::Result<Option<PathBuf>> {
    let target = state.join(LOCAL_DIR);
    match std::fs::read_link(state.join("upper/.git")) {
        Ok(link) if link == target => {
            let metadata = std::fs::symlink_metadata(&target)?;
            Ok(metadata.is_dir().then_some(target))
        }
        Ok(_) => Ok(None),
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::InvalidInput
            ) =>
        {
            Ok(None)
        }
        Err(error) => Err(error),
    }
}

/// The virtual files a projection server adds for `git-seed-carry-v1`.
pub const CARRY_PACK: &str = "cmux-carry.pack";
pub const CARRY_BASE: &str = "cmux-carry.base";
/// How many times a moving Mac state is copied again before the swap gives up for now.
const ATTEMPTS: usize = 3;

/// Whether projected git carry is enabled. Carry is on by default so projection starts can use
/// the sender's local objects. Set `CMUX_PROJECTION_GIT_SWAP=off` to disable it for a diagnosis.
#[must_use]
pub fn enabled() -> bool {
    !std::env::var_os("CMUX_PROJECTION_GIT_SWAP")
        .is_some_and(|value| value.to_string_lossy().eq_ignore_ascii_case("off"))
}
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
    init.args(["init", "--bare", "--quiet"]);
    init.arg(local);
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
        copy_mac_state(projected, local, Some(url))?;
        match fingerprint(projected)? {
            Some(after) if after == fingerprint_now => return Ok(after),
            Some(after) => fingerprint_now = after,
            None => {}
        }
    }
    anyhow::bail!("the repository kept changing while it was copied")
}

/// Builds the machine repository from the carried depth-1 `pack` and `base` supplied by the Mac.
/// The projected repository is then used only as a local object/ref source. In particular, this
/// path never asks the repository's configured remote for `ls-remote` or a fetch.
pub fn prepare_carry(
    projected: &Path,
    local: &Path,
    pack: &Path,
    base: &str,
) -> anyhow::Result<String> {
    anyhow::ensure!(valid_object_name(base), "invalid carry base {base:?}");
    let Some(before) = fingerprint(projected)? else {
        anyhow::bail!("git is busy in {} (a lock or an operation in progress)", projected.display())
    };
    if local.exists() {
        std::fs::remove_dir_all(local)?;
    }
    let mut init = Command::new("git");
    init.args(["init", "--bare", "--quiet"]);
    if base.len() == 64 {
        init.arg("--object-format=sha256");
    }
    init.arg(local);
    output(init)?;
    for (key, value) in [
        ("core.repositoryformatversion", "1"),
        ("core.bare", "false"),
        ("core.checkStat", "minimal"),
        ("core.trustctime", "false"),
    ] {
        let mut set = git(local);
        set.args(["config", key, value]);
        output(set)?;
    }
    write_atomic(&local.join("shallow"), format!("{base}\n").as_bytes())?;
    index_carry(local, pack)?;
    // A blobless pack intentionally omits the base tree's blobs. The projected repository is
    // fetched below to fill those holes; checking reachability here would reject the pack before
    // that transfer. The base commit itself must be present so the receiver has a stable anchor.
    let mut commit = git(local);
    commit.args(["rev-parse", "--verify", &format!("{base}^{{commit}}")]);
    output(commit)?;

    // The carried pack is intentionally depth one.  Remove that temporary boundary before
    // asking the projected repository for its refs, otherwise fetch treats the carried tip as
    // complete and silently drops every parent commit from the machine's visible history.
    let _ = std::fs::remove_file(local.join("shallow"));

    let mut fingerprint_now = before;
    for _ in 0..ATTEMPTS {
        copy_mac_state(projected, local, None)?;
        match fingerprint(projected)? {
            Some(after) if after == fingerprint_now => {
                write_atomic(&local.join(SWAP_MARKER), b"v1\n")?;
                return Ok(after);
            }
            Some(after) => fingerprint_now = after,
            None => {}
        }
    }
    anyhow::bail!("the repository kept changing while it was copied")
}

fn valid_object_name(name: &str) -> bool {
    matches!(name.len(), 40 | 64) && name.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn index_carry(local: &Path, pack: &Path) -> anyhow::Result<()> {
    let metadata = std::fs::metadata(pack)?;
    anyhow::ensure!(metadata.is_file() && metadata.len() > 0, "the carry pack is empty");
    let packs = local.join("objects").join("pack");
    std::fs::create_dir_all(&packs)?;
    let incoming = packs.join("tmp_cmux_carry.pack");
    std::fs::copy(pack, &incoming)?;
    let mut index = git(local);
    // Projection carry packs use `blob:none`: the commit and trees are present, while blobs
    // arrive from the projected repository during `copy_mac_state`. Index the pack's checksum
    // and object table here without requiring connectivity to those intentionally omitted blobs.
    index.args(["index-pack"]).arg(&incoming);
    let name = String::from_utf8_lossy(&output(index)?).trim().to_owned();
    anyhow::ensure!(valid_object_name(&name), "index-pack answered {name:?}");
    for extension in ["rev", "idx", "pack"] {
        let from = packs.join(format!("tmp_cmux_carry.{extension}"));
        let to = packs.join(format!("pack-{name}.{extension}"));
        match std::fs::rename(from, to) {
            Err(error) if extension == "rev" && error.kind() == std::io::ErrorKind::NotFound => {}
            done => done?,
        }
    }
    Ok(())
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
fn copy_mac_state(projected: &Path, local: &Path, seed_url: Option<&str>) -> anyhow::Result<()> {
    let mut fetch = git(local);
    fetch.args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--update-head-ok"]);
    // No `--prune`: git prunes before it negotiates, which would drop the seed refs and with
    // them every `have`, and the Mac would send its whole history. Pruned below instead.
    fetch.args(["--recurse-submodules=no"]);
    // Negotiation only from what is already here, never a lazy blob fetch to check one.
    fetch.env("GIT_NO_LAZY_FETCH", "1");
    // A reachable seed remote already owns the ordinary blobs; keep this projected transfer
    // blobless so the carry path does not retransmit the remote's history. When the remote probe
    // failed (or there is no remote), copy the blobs from the projection for a self-contained swap.
    if seed_url.is_some() {
        fetch.arg("--filter=blob:none");
    }
    // HEAD may be detached and unreachable from any named ref. Transfer it alongside refs.
    fetch.arg(projected).args(["+refs/*:refs/*", "HEAD"]);
    output(fetch)?;
    // HEAD's tree is already covered by the refs/HEAD transfer (or the legacy seed's
    // promisor). Only index objects outside that tree need an extra projected transfer.
    // Fetching every index object would force ordinary promisor blobs over the Mac's link.
    let mut tree = git(projected);
    tree.args(["ls-tree", "-r", "-z", "HEAD"]);
    let committed: std::collections::HashSet<String> = text(tree)?
        .split('\0')
        .filter_map(|entry| {
            let (metadata, _) = entry.split_once('\t')?;
            metadata.split_whitespace().nth(2).map(str::to_owned)
        })
        .collect();
    // An index can name staged blobs that no ref reaches. Fetch those object IDs explicitly,
    // including every conflict stage; a gitlink belongs to a separate repository.
    let mut staged = git(projected);
    staged.args(["ls-files", "--stage", "-z"]);
    let staged: std::collections::BTreeSet<String> = staged_objects(&output(staged)?, &committed);
    if !staged.is_empty() {
        let mut fetch = git(local);
        fetch.args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--stdin"]);
        fetch.args(["--recurse-submodules=no"]);
        fetch.env("GIT_NO_LAZY_FETCH", "1").arg(projected);
        // The index can contain millions of paths. Never put their object IDs in argv.
        with_stdin(fetch, &staged.into_iter().collect::<Vec<_>>())?;
    }
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
    // A reader may have cached the projected loose-ref directory before the swap and
    // open packed-refs after it. The sender can keep all its refs packed (git gc), whereas
    // fetch wrote ours loose. Keep both representations so either lookup order crosses the
    // swap without losing refs. Do not prune the loose refs: a reader can also have cached
    // the old packed-refs before it reads the new loose-ref tree.
    let mut pack_refs = git(local);
    pack_refs.args(["pack-refs", "--all", "--no-prune"]);
    output(pack_refs)?;
    let config = std::fs::read_to_string(projected.join("config")).unwrap_or_default();
    let lead = if config.is_empty() || config.ends_with('\n') { "" } else { "\n" };
    let ours = match seed_url {
        Some(url) => format!(
            "{lead}[core]\n\tbare = false\n\trepositoryformatversion = 1\n\tcheckStat = minimal\n\t\
             trustctime = false\n[extensions]\n\tpartialClone = {SEED_REMOTE}\n[remote \"{SEED_REMOTE}\"]\n\t\
             url = {url}\n\tpromisor = true\n\tpartialclonefilter = blob:none\n"
        ),
        None => format!(
            "{lead}[core]\n\tbare = false\n\trepositoryformatversion = 1\n\tcheckStat = minimal\n\t\
             trustctime = false\n"
        ),
    };
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

/// Extracts staged object IDs from Git's NUL-delimited index listing without interpreting the
/// path bytes. Git permits arbitrary bytes in a filename, so converting the whole listing to
/// UTF-8 would make a carry fail for an otherwise valid repository.
fn staged_objects(
    listing: &[u8],
    committed: &std::collections::HashSet<String>,
) -> std::collections::BTreeSet<String> {
    listing
        .split(|byte| *byte == 0)
        .filter_map(|entry| {
            let tab = entry.iter().position(|byte| *byte == b'\t')?;
            let mut fields = entry.get(..tab)?.split(|byte| byte.is_ascii_whitespace());
            let mode = fields.next()?;
            let object = fields.next()?;
            // A gitlink belongs to the submodule's object store, not this repository.
            if mode == b"160000"
                || !matches!(object.len(), 40 | 64)
                || !object.iter().all(u8::is_ascii_hexdigit)
                || object.iter().all(|byte| *byte == b'0')
            {
                return None;
            }
            let object = std::str::from_utf8(object).ok()?;
            (!committed.contains(object)).then(|| object.to_owned())
        })
        .collect()
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
    let base = match std::fs::read_to_string(projected.join(CARRY_BASE)) {
        Ok(base) if valid_object_name(base.trim()) => base.trim().to_owned(),
        _ => return Ok(Outcome::NoPublicRemote),
    };
    let local = state.join(LOCAL_DIR);
    let ready = match prepare_carry(&projected, &local, &projected.join(CARRY_PACK), &base) {
        Ok(ready) => ready,
        Err(error) => {
            eprintln!(
                "cmux projection: carry preparation failed for {}: {error:#}",
                projected.display()
            );
            return Ok(Outcome::NoPublicRemote);
        }
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

#[cfg(all(test, target_os = "linux"))]
#[path = "git_swap_tests.rs"]
mod tests;
