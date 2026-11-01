//! The engine of `cmux link seed pull` ([`super::super::seed_cli`], which
//! parses it and keeps the base in its record): brings a seeded Cloud
//! folder's changes back to this Mac as a diff, never a folder copy
//! (leo-workspace `design/cloud.md`, "Getting the project onto the machine",
//! rule 6).
//!
//! The base is the seed this Mac last sent or pulled (its HEAD, INDEX and
//! WORK commits; `cmux link seed push` and every pull keep them). The machine answers
//! `git.seed.export` with one bundle of what changed since (`git-seed-export-v1`),
//! read here through `fs-v1` and streamed to disk. It is fetched into a
//! quarantine repository whose object store borrows this one's, every object
//! checked (`transfer.fsckObjects`), as `cmux link sync pull`'s git leg does
//! ([`super::git_back`]). Then three ways, against the base:
//!
//! - HEAD: the machine's commits come back only as a fast-forward of the
//!   branch this Mac is on, and only while this Mac's HEAD is still the
//!   seed's. A switched branch, a rewritten history or both sides moving is
//!   a conflict (`.git/HEAD`).
//! - Staged: the machine's INDEX tree is staged here when this Mac's staged
//!   tree is still the seed's; both changed differently is a conflict
//!   (`.git/index`).
//! - Working tree, per file, between the seed's WORK tree, the machine's
//!   and this Mac's working tree now (as a seed would send it): the
//!   machine's version (or its delete) where this Mac's is unchanged, this
//!   Mac's where the machine's is unchanged, a conflict where both changed
//!   differently. No path that reaches a repository or a hook comes back
//!   ([`super::names::carries_repository_or_hook`]), nor a symlink or a
//!   submodule the machine changed.
//!
//! Ignored files on the machine (`node_modules`, build output), untracked
//! secrets and nested repositories never come back: the export leaves them
//! out of its WORK.
//!
//! On any conflict nothing here changes ([`SeedPulled::Conflict`]). Otherwise files move into place
//! through [`super::place::Transaction`], then the branch moves by
//! compare-and-swap and the index follows; any failure puts back what
//! changed. The answer's `base` (the machine's HEAD, INDEX and WORK) is the
//! next pull's and the next delta push's base. A machine that changed
//! nothing answers `unchanged` and nothing is downloaded.

use std::collections::BTreeMap;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use anyhow::{Context as _, bail};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::git_back::{self, GitBase, checked, local, quarantine_git};
use super::local::{GitDirs, permissions_of};
use super::place::{self, Dir, Entry, Expected, Transaction};
use super::remote::Remote;
use super::{names, pull};

/// Most bytes of the machine's bundle (big untracked files travel in it).
const MAX_BUNDLE_BYTES: u64 = 64 << 30;
/// How long the export may run.
const EXPORT_DEADLINE: Duration = Duration::from_secs(30 * 60);
const EXPORT_POLL: Duration = Duration::from_millis(200);

/// The seed a pull merges against: its HEAD, INDEX and WORK commits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SeedBase {
    pub(crate) head: String,
    pub(crate) index: String,
    pub(crate) work: String,
}

/// What a pull did, or the paths that stopped it.
pub(crate) enum SeedPulled {
    Done(Value),
    /// The conflicting paths, and why for each one that has a reason.
    Conflict(Vec<String>, Vec<String>),
}

/// The machine refused or failed the export: its code and message.
#[derive(Debug)]
pub(crate) struct ExportFailed {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for ExportFailed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for ExportFailed {}

/// The base's commits are not in this repository.
#[derive(Debug)]
pub(crate) struct NoSeedBase;

impl std::fmt::Display for NoSeedBase {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .write_str("this repository does not have the seed's commits; nothing was brought back")
    }
}

impl std::error::Error for NoSeedBase {}

/// The machine's state, as its export answered it.
struct Exported {
    head_ref: Option<String>,
    head: String,
    index: String,
    work: String,
    unchanged: bool,
    bundle_bytes: u64,
    left_out: Value,
}

/// One tree entry: mode and object id.
type TreeEntry = (String, String);
/// Each changed path with its entry on either side (None: absent).
type TreeDiff = BTreeMap<String, (Option<TreeEntry>, Option<TreeEntry>)>;

/// What happens to one working-tree path.
enum Step {
    Write { relative: String, staged: String, expected: Option<Expected> },
    Delete { relative: String, expected: Expected },
}

/// The error code of a failed [`seed_pull`].
pub(crate) fn failure_code(error: &anyhow::Error) -> String {
    if let Some(failed) = error.downcast_ref::<ExportFailed>() {
        return failed.code.clone();
    }
    if error.downcast_ref::<NoSeedBase>().is_some() {
        return "sync_no_base".into();
    }
    pull::failure_code(error)
}

/// Whether `text` is a full object id (SHA-1 or SHA-256), lowercase.
pub(crate) fn is_sha(text: &str) -> bool {
    matches!(text.len(), 40 | 64)
        && text.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Pulls the machine's changes to the seeded folder `remote_root` since
/// `base` into the working copy at `local`.
pub(crate) fn seed_pull(
    socket: &Path,
    local_folder: &Path,
    remote_root: &str,
    base: &SeedBase,
) -> anyhow::Result<SeedPulled> {
    let folder = std::fs::canonicalize(local_folder)
        .with_context(|| format!("cannot open {}", local_folder.display()))?;
    let dirs = GitDirs::of(&folder)?.context("the folder is not a git working copy")?;
    for sha in [&base.head, &base.index, &base.work] {
        let present =
            checked(local(&folder).args(["cat-file", "-e"]).arg(format!("{sha}^{{commit}}")));
        if present.is_err() {
            return Err(NoSeedBase.into());
        }
    }
    let mut remote = Remote::connect(socket)?;
    let (parent, _) = super::remote::split(remote_root)?;
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    let remote_bundle = format!(
        "{}/.cmux-seed-back-{}-{nanos}.bundle",
        parent.trim_end_matches('/'),
        std::process::id()
    );
    let exported = export(&mut remote, remote_root, base, &remote_bundle)?;
    let new_base = json!({ "head": exported.head, "index": exported.index, "work": exported.work });
    if exported.unchanged {
        return Ok(SeedPulled::Done(json!({
            "ok": true, "unchanged": true, "written": 0, "deleted": 0, "bytes": 0,
            "bundle_bytes": 0, "fast_forwarded": false, "staged": false,
            "head": exported.head, "base": new_base, "left_out": exported.left_out,
        })));
    }
    let staging = Staging::make(&dirs.own)?;
    let bundle = staging.path.join("back.bundle");
    let downloaded = download(&mut remote, &remote_bundle, &bundle);
    let _ = remote.delete(&[remote_bundle]);
    downloaded?;
    let quarantine = staging.path.join("quarantine.git");
    git_back::quarantined(&quarantine, &dirs.common)?;
    receive(&quarantine, &bundle, &exported)?;

    // The branch and the staged changes are read on both sides of the
    // snapshot the merge decides from, so the decision and the check in
    // [`move_git`] see one state.
    let here_git = git_back::base_of(&folder)?;
    let here = super::super::seed::plan::current(&folder)
        .map_err(|fallback| anyhow::anyhow!("cannot read this folder: {}", fallback.why))?;
    if git_back::base_of(&folder)? != here_git {
        bail!(
            "this Mac's branch or staged changes changed during the pull; nothing was brought back"
        );
    }
    let hooks = pull::hook_folders(&folder)?;
    let q = Quarantine(&quarantine);
    let mut conflicts = Vec::new();
    let mut reasons = Vec::new();
    let mut conflict = |path: &str, why: Option<String>| {
        conflicts.push(path.to_string());
        if let Some(why) = why {
            reasons.push(format!("{path}: {why}"));
        }
    };

    // HEAD.
    let mut fast_forward = None;
    let machine_head = (exported.head_ref.as_deref(), exported.head.as_str());
    let here_head = (here.head_ref.as_deref(), here.head.as_str());
    let head_settled =
        machine_head.1 == base.head && machine_head.0 == here_head.0 || machine_head == here_head;
    if head_settled {
        // Nothing moved, or both sides moved to the same commit.
    } else if here_head.1 != base.head {
        conflict(".git/HEAD", Some("both this Mac and the machine moved the branch".into()));
    } else if machine_head.0 != here_head.0 {
        let name = machine_head.0.unwrap_or("a detached HEAD");
        conflict(".git/HEAD", Some(format!("the machine switched to {name}")));
    } else if q.is_ancestor(&base.head, &exported.head) {
        if let Some(path) = q.carried(&base.head, &exported.head, &hooks)? {
            conflict(
                ".git/HEAD",
                Some(format!("the machine's commits add a hook or a repository: {path}")),
            );
        }
        fast_forward = Some(exported.head.clone());
    } else {
        conflict(".git/HEAD", Some("the machine rewrote the branch's history".into()));
    }

    // Staged.
    let mut staged = None;
    let tree = |commit: &str| q.text(&["rev-parse", &format!("{commit}^{{tree}}")]);
    let (base_index, machine_index, here_index) =
        (tree(&base.index)?, tree(&exported.index)?, tree(&here.index)?);
    if machine_index != base_index && machine_index != here_index {
        if here_index != base_index {
            let why = "both this Mac and the machine changed what is staged";
            conflict(".git/index", Some(why.into()));
        } else if let Some(path) = q.carried(&base.index, &exported.index, &hooks)? {
            let why = format!("the machine staged a hook or a repository: {path}");
            conflict(".git/index", Some(why));
        } else {
            staged = Some(machine_index);
        }
    }

    // The working tree.
    let theirs = q.diff(&base.work, &exported.work)?;
    let ours = q.diff(&base.work, &here.work)?;
    let root = Dir::open(&folder)?;
    let mut planned: Vec<(String, Option<TreeEntry>, Option<TreeEntry>)> = Vec::new();
    for (relative, (base_entry, machine)) in theirs {
        let here_entry = ours.get(&relative).map_or(base_entry.clone(), |(_, here)| here.clone());
        if here_entry == machine {
            continue;
        }
        if here_entry != base_entry {
            conflict(&relative, None);
            continue;
        }
        if !names::safe_relative(&relative) || names::carries_repository_or_hook(&relative, &hooks)
        {
            conflict(&relative, Some("it reaches a repository or a hook".into()));
            continue;
        }
        let regular = |entry: &Option<TreeEntry>| {
            entry.as_ref().is_none_or(|(mode, _)| matches!(mode.as_str(), "100644" | "100755"))
        };
        if !regular(&machine) || !regular(&here_entry) {
            conflict(&relative, Some("a symlink or submodule changed; it stays as it is".into()));
            continue;
        }
        planned.push((relative, here_entry, machine));
    }
    if !conflicts.is_empty() {
        conflicts.sort();
        conflicts.dedup();
        return Ok(SeedPulled::Conflict(conflicts, reasons));
    }

    // Stage the machine's files and read what each replaces here.
    let mut steps = Vec::new();
    let mut bytes = 0u64;
    for (relative, here_entry, machine) in planned {
        let expected = match &here_entry {
            Some((_, blob)) => match disk_file(&root, &folder, &staging, &relative, blob)? {
                Some(expected) => Some(expected),
                None => {
                    let why = format!("{relative}: it changed here during the pull");
                    return Ok(SeedPulled::Conflict(vec![relative], vec![why]));
                }
            },
            None => None,
        };
        match machine {
            Some((mode, blob)) => {
                let staged_name = staging.stage(&quarantine, &blob, &mode)?;
                bytes += std::fs::metadata(staging.path.join(&staged_name))?.len();
                steps.push(Step::Write { relative, staged: staged_name, expected });
            }
            None => {
                if let Some(expected) = expected {
                    steps.push(Step::Delete { relative, expected });
                }
            }
        }
    }
    // Only objects so far: this repository gets the machine's commits.
    q.fetch_into(&folder, &exported)?;
    // Deletes first, so a file may take the place of a folder it emptied.
    steps.sort_by_key(|step| matches!(step, Step::Write { .. }));
    let mut transaction = Transaction::new(&folder, &staging.path)?;
    let (mut written, mut deleted) = (0u64, 0u64);
    for step in steps {
        let applied = match &step {
            Step::Write { relative, staged, expected } => {
                transaction.write(relative, staged, expected.as_ref()).map(|()| written += 1)
            }
            Step::Delete { relative, expected } => {
                transaction.delete(relative, expected).map(|()| deleted += 1)
            }
        };
        if let Err(error) = applied {
            return undone(transaction, &staging, error);
        }
    }
    if let Err(error) = move_git(&folder, &here_git, fast_forward.as_deref(), staged.as_deref()) {
        return undone(transaction, &staging, error);
    }
    transaction.finish();
    Ok(SeedPulled::Done(json!({
        "ok": true,
        "unchanged": false,
        "written": written,
        "deleted": deleted,
        "bytes": bytes,
        "bundle_bytes": exported.bundle_bytes,
        "fast_forwarded": fast_forward.is_some(),
        "staged": staged.is_some(),
        "head": exported.head,
        "base": new_base,
        "left_out": exported.left_out,
    })))
}

/// Starts the export and waits (bounded) for it to end.
fn export(
    remote: &mut Remote,
    remote_root: &str,
    base: &SeedBase,
    bundle: &str,
) -> anyhow::Result<Exported> {
    let refused = |error: anyhow::Error| match super::remote::refusal_code(&error) {
        Some(code) => anyhow::Error::from(ExportFailed {
            code: code.to_string(),
            message: format!("{error:#}"),
        }),
        None => error,
    };
    let started = remote
        .call(
            "git.seed.export",
            json!({ "folder": remote_root, "since_work": base.work, "since_head": base.head, "bundle": bundle }),
        )
        .map_err(refused)?;
    let job = started["job"].as_str().context("the export answered no job")?.to_string();
    let deadline = Instant::now() + EXPORT_DEADLINE;
    let status = loop {
        let status = remote.call("git.seed.status", json!({ "job": job })).map_err(refused)?;
        if status["state"] != "running" {
            break status;
        }
        if Instant::now() > deadline {
            bail!("the machine's export did not finish");
        }
        std::thread::sleep(EXPORT_POLL);
    };
    if status["state"] != "done" {
        return Err(ExportFailed {
            code: status["error_code"].as_str().unwrap_or("seed.export_failed").to_string(),
            message: status["error"].as_str().unwrap_or("the machine's export failed").to_string(),
        }
        .into());
    }
    let sha = |name: &str| -> anyhow::Result<String> {
        let value = status[name].as_str().unwrap_or_default();
        if !is_sha(value) {
            bail!("the machine's export answered no {name} commit");
        }
        Ok(value.to_string())
    };
    let head_ref = status["head_ref"].as_str().map(str::to_string);
    if let Some(name) = &head_ref
        && name.strip_prefix("refs/heads/").is_none_or(str::is_empty)
    {
        bail!("the machine's HEAD names {name}, not a branch");
    }
    Ok(Exported {
        head_ref,
        head: sha("head")?,
        index: sha("index")?,
        work: sha("work")?,
        unchanged: status["unchanged"] == json!(true),
        bundle_bytes: status["bundle_bytes"].as_u64().unwrap_or(0),
        left_out: status["left_out"].clone(),
    })
}

/// Streams the machine's bundle to `to` (a new private file).
fn download(remote: &mut Remote, from: &str, to: &Path) -> anyhow::Result<()> {
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(to)?;
    remote
        .read_into(from, &mut out, MAX_BUNDLE_BYTES)?
        .context("the machine's bundle went away")?;
    out.sync_all()?;
    Ok(())
}

/// Verifies the bundle and fetches it into the quarantine, every object
/// checked; the commits the export named must be there, a ref the bundle
/// carried must name the same commit, and they must chain as a seed's do
/// (WORK on INDEX on HEAD).
fn receive(quarantine: &Path, bundle: &Path, exported: &Exported) -> anyhow::Result<()> {
    let invalid = "the machine's bundle is not valid";
    checked(quarantine_git(quarantine).args(["bundle", "verify", "-q"]).arg(bundle))
        .context(invalid)?;
    checked(
        quarantine_git(quarantine)
            .args(["-c", "protocol.file.allow=always"])
            .args(["-c", "transfer.fsckObjects=true", "-c", "fetch.fsckObjects=true"])
            .args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head"])
            .args(["--no-recurse-submodules", "--no-auto-gc"])
            .arg(bundle)
            .arg("+refs/cmux-back/*:refs/cmux-back/*"),
    )
    .context(invalid)?;
    let q = Quarantine(quarantine);
    let heads = String::from_utf8_lossy(&checked(
        quarantine_git(quarantine).args(["bundle", "list-heads"]).arg(bundle),
    )?)
    .into_owned();
    for (name, sha) in
        [("head", &exported.head), ("index", &exported.index), ("work", &exported.work)]
    {
        if q.text(&["rev-parse", "--verify", "--quiet", &format!("{sha}^{{commit}}")])
            .ok()
            .as_deref()
            != Some(sha.as_str())
        {
            bail!("the machine's bundle lacks its {name} commit");
        }
        let reference = format!("refs/cmux-back/{name}");
        let carried = heads.lines().find_map(|line| {
            line.split_once(' ').filter(|(_, listed)| *listed == reference).map(|(id, _)| id)
        });
        if carried.is_some_and(|carried| carried != sha) {
            bail!("the machine's bundle names another {name} commit");
        }
    }
    let parent =
        |commit: &str| q.text(&["rev-parse", "--verify", "--quiet", &format!("{commit}^1")]);
    if parent(&exported.work)? != exported.index || parent(&exported.index)? != exported.head {
        bail!("the machine's export is not a seed's commits");
    }
    Ok(())
}

/// The quarantine, read with no global or system settings.
struct Quarantine<'a>(&'a Path);

impl Quarantine<'_> {
    fn text(&self, args: &[&str]) -> anyhow::Result<String> {
        Ok(String::from_utf8_lossy(&checked(quarantine_git(self.0).args(args))?).trim().to_string())
    }

    fn is_ancestor(&self, old: &str, new: &str) -> bool {
        quarantine_git(self.0)
            .args(["merge-base", "--is-ancestor", old, new])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    /// A path `new` adds or changes over `old` that carries a repository or
    /// a hook here.
    fn carried(&self, old: &str, new: &str, hooks: &[String]) -> anyhow::Result<Option<String>> {
        let paths = checked(quarantine_git(self.0).args([
            "diff-tree",
            "-r",
            "-z",
            "--no-renames",
            "--name-only",
            old,
            new,
        ]))?;
        Ok(paths
            .split(|byte| *byte == 0)
            .map(|path| String::from_utf8_lossy(path).into_owned())
            .find(|path| !path.is_empty() && names::carries_repository_or_hook(path, hooks)))
    }

    /// The paths that differ between the trees of `old` and `new`, with
    /// each side's entry (None: absent).
    fn diff(&self, old: &str, new: &str) -> anyhow::Result<TreeDiff> {
        let listing = checked(quarantine_git(self.0).args([
            "diff-tree",
            "-r",
            "-z",
            "--no-renames",
            old,
            new,
        ]))?;
        let mut changed = BTreeMap::new();
        let mut fields = listing.split(|byte| *byte == 0).filter(|field| !field.is_empty());
        while let (Some(meta), Some(path)) = (fields.next(), fields.next()) {
            // `:100644 100644 <old> <new> M`
            let meta = String::from_utf8_lossy(meta);
            let parts: Vec<&str> = meta.trim_start_matches(':').split(' ').collect();
            let [old_mode, new_mode, old_id, new_id, _status] = parts.as_slice() else {
                bail!("git diff-tree gave an unexpected line");
            };
            let Ok(path) = String::from_utf8(path.to_vec()) else {
                bail!("the machine's tree names a path that is not UTF-8");
            };
            let entry = |mode: &str, id: &str| {
                (mode != "000000").then(|| (mode.to_string(), id.to_string()))
            };
            changed.insert(path, (entry(old_mode, old_id), entry(new_mode, new_id)));
        }
        Ok(changed)
    }

    /// Fetches the machine's HEAD, INDEX and WORK commits into the working
    /// copy at `folder`, every object checked: they are the next base. No
    /// ref changes there.
    fn fetch_into(&self, folder: &Path, exported: &Exported) -> anyhow::Result<()> {
        let mut wanted = Vec::new();
        for (name, sha) in
            [("head", &exported.head), ("index", &exported.index), ("work", &exported.work)]
        {
            let reference = format!("refs/cmux-pull/{name}");
            checked(quarantine_git(self.0).args(["update-ref", &reference, sha]))?;
            wanted.push(reference);
        }
        checked(
            local(folder)
                .args(["-c", "transfer.fsckObjects=true", "-c", "fetch.fsckObjects=true"])
                .args(["fetch", "--quiet", "--no-tags", "--no-write-fetch-head"])
                .args(["--no-recurse-submodules", "--no-auto-gc"])
                .arg(self.0)
                .args(&wanted),
        )
        .context("cannot fetch the machine's commits")?;
        Ok(())
    }
}

/// This Mac's regular file at `relative` as a transaction checks it; None
/// when it is not a regular file reached without a symlink.
fn disk_file(
    root: &Dir,
    folder: &Path,
    staging: &Staging,
    relative: &str,
    blob: &str,
) -> anyhow::Result<Option<Expected>> {
    let Ok(Some((dir, name))) = place::parent_of(root, relative) else { return Ok(None) };
    let Entry::File { mode } = dir.entry(&name)? else { return Ok(None) };
    let mut file = dir.open_file(&name)?;
    // One read: the bytes hashed for the transaction are the bytes checked
    // against the blob the merge planned from (as `git add` would store
    // them, through the path's filters). A file saved since the snapshot,
    // or one git was told to assume unchanged, is not that blob.
    let (copy, sha256) = staging.copy(&mut file)?;
    let stored =
        checked(local(folder).args(["hash-object", "--path"]).arg(relative).arg("--").arg(&copy))?;
    let _ = std::fs::remove_file(&copy);
    if String::from_utf8_lossy(&stored).trim() != blob {
        return Ok(None);
    }
    Ok(Some(Expected { sha256, permissions: permissions_of(mode) }))
}

/// Moves HEAD's branch (compare-and-swap) and then the index, once this
/// Mac's branch and staged changes are checked to be still `planned`. The
/// branch moves back if the index can't follow. The index is git's own
/// `index.lock` from that check until the new index is in place, so nothing
/// staged in between is lost.
fn move_git(
    folder: &Path,
    planned: &GitBase,
    head: Option<&str>,
    staged: Option<&str>,
) -> anyhow::Result<()> {
    if head.is_none() && staged.is_none() {
        return Ok(());
    }
    let lock = staged.map(|_| IndexLock::take(folder)).transpose()?;
    if git_back::base_of(folder)? != *planned {
        bail!("this Mac's branch or staged changes changed during the pull");
    }
    let move_ref = |new: &str, old: &str| {
        let mut command = local(folder);
        command.args(["update-ref", "-m", "cmux seed pull: bring back from the machine"]);
        match &planned.head_ref {
            Some(name) => command.arg(name),
            None => command.args(["--no-deref", "HEAD"]),
        };
        checked(command.args([new, old])).map(drop)
    };
    let old = planned.head.clone().unwrap_or_default();
    if let Some(head) = head {
        move_ref(head, &old).context("cannot move the branch")?;
    }
    if let (Some(tree), Some(lock)) = (staged, &lock)
        && let Err(error) = lock.replace(folder, tree)
    {
        if let Some(head) = head {
            let _ = move_ref(&old, head);
        }
        return Err(error.context("cannot stage the machine's changes"));
    }
    Ok(())
}

/// git's `index.lock` of a working copy, held: no git command stages while
/// it is there. Dropped, it goes.
struct IndexLock {
    index: PathBuf,
    lock: PathBuf,
}

impl IndexLock {
    fn take(folder: &Path) -> anyhow::Result<Self> {
        let path = checked(local(folder).args([
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "index",
        ]))?;
        let index = PathBuf::from(String::from_utf8_lossy(&path).trim_end_matches('\n'));
        let lock = index.with_extension("lock");
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o644)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&lock)
            .with_context(|| format!("another git process is using {}", lock.display()))?;
        Ok(Self { index, lock })
    }

    /// Writes the index of `tree` to a new file beside the index and renames
    /// it over the index while the lock is held.
    fn replace(&self, folder: &Path, tree: &str) -> anyhow::Result<()> {
        let fresh = self.index.with_extension(format!("cmux-seed-pull-{}", std::process::id()));
        let _ = std::fs::remove_file(&fresh);
        let written =
            checked(local(folder).env("GIT_INDEX_FILE", &fresh).arg("read-tree").arg(tree))
                .and_then(|_| {
                    std::fs::rename(&fresh, &self.index)
                        .with_context(|| format!("cannot write {}", self.index.display()))
                });
        if written.is_err() {
            let _ = std::fs::remove_file(&fresh);
        }
        written
    }
}

impl Drop for IndexLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.lock);
    }
}

/// Puts back what `transaction` changed after `error`. A file that changed
/// here during the pull is a conflict.
fn undone(
    transaction: Transaction,
    staging: &Staging,
    error: anyhow::Error,
) -> anyhow::Result<SeedPulled> {
    if let Err(left) = transaction.roll_back() {
        staging.keep.set(true);
        return Err(error.context(format!(
            "cmux could not put back {}; what it moved aside is in {}",
            left.join(", "),
            staging.path.display()
        )));
    }
    if let Some(changed) = error.downcast_ref::<place::Changed>() {
        return Ok(SeedPulled::Conflict(vec![changed.0.clone()], Vec::new()));
    }
    Err(error)
}

/// This pull's own folder in the repository's git folder, removed when the
/// pull ends unless it holds a file a failed pull could not put back.
struct Staging {
    path: PathBuf,
    files: std::cell::Cell<u64>,
    keep: std::cell::Cell<bool>,
}

impl Staging {
    fn make(git_dir: &Path) -> anyhow::Result<Self> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_nanos());
        let path = git_dir.join(format!(".cmux-seed-pull-{}-{nanos}", std::process::id()));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .with_context(|| format!("cannot make {}", path.display()))?;
        Ok(Self { path, files: std::cell::Cell::new(0), keep: std::cell::Cell::new(false) })
    }

    /// Copies `file` to a new file here as it reads it; the copy and the
    /// SHA-256 of what was read.
    fn copy(&self, file: &mut std::fs::File) -> anyhow::Result<(PathBuf, String)> {
        let number = self.files.get() + 1;
        self.files.set(number);
        let path = self.path.join(format!("here-{number}"));
        let mut out = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0u8; 1 << 16];
        loop {
            let read = std::io::Read::read(file, &mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
            out.write_all(&buffer[..read])?;
        }
        let sha256 = hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
        Ok((path, sha256))
    }

    /// Writes the blob `id` of the quarantine to a new file here with the
    /// tree's `mode` (0644 or 0755); its name here.
    fn stage(&self, quarantine: &Path, id: &str, mode: &str) -> anyhow::Result<String> {
        let number = self.files.get() + 1;
        self.files.set(number);
        let name = format!("file-{number}");
        let mut out = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.path.join(&name))?;
        let mut child = quarantine_git(quarantine)
            .args(["cat-file", "blob", id])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .context("cannot run git")?;
        let mut stdout = child.stdout.take().context("no stdout")?;
        let copied = std::io::copy(&mut stdout, &mut out);
        let status = child.wait()?;
        copied?;
        if !status.success() {
            bail!("the machine's blob {id} is missing");
        }
        let bits = if mode == "100755" { 0o755 } else { 0o644 };
        out.set_permissions(std::fs::Permissions::from_mode(bits))?;
        out.flush()?;
        out.sync_all()?;
        Ok(name)
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        if self.keep.get() || std::thread::panicking() {
            return;
        }
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
