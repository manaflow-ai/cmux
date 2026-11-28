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
//!   Mac's where the machine's is unchanged. Where both changed it
//!   differently, cmux-sync's three-tree module decides (RFD 0155): text
//!   edits merge by line (diff3) and a clean merge is written; overlapping
//!   or binary edits put the machine's version at the path and this Mac's
//!   beside it as `NAME.cmux-sync-conflict` (the answer's `conflict_files`);
//!   an edit against a delete keeps the edit (`kept_edits`). None of these
//!   refuses the pull. No path that reaches a repository or a hook comes back
//!   ([`super::names::carries_repository_or_hook`]), nor a symlink or a
//!   submodule the machine changed.
//!
//! Ignored files on the machine (`node_modules`, build output), untracked
//! secrets and nested repositories never come back: the export leaves them
//! out of its WORK.
//!
//! On any conflict left (HEAD, the index, a hook, a symlink) nothing here changes ([`SeedPulled::Conflict`]) but `refs/cmux/carry/<branch>/*`,
//! which keep the machine's commits and uncommitted work as a second branch to merge. Otherwise files move into place
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
use cmux_json::JsonSet as _;
use cmux_sync::three_tree::{self, Decision, Resolution};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::git_back::{self, GitBase, checked, local, quarantine_git};
use super::local::{GitDirs, permissions_of};
use super::merge::{CONFLICT_SUFFIX, TEXT_MAX};
use super::place::{self, Dir, Entry, Expected, Transaction};
use super::remote::Remote;
use super::{names, pull};

/// Where a conflicting pull keeps the machine's work ([`Quarantine::keep`]).
pub(crate) const CARRY_REFS: &str = "refs/cmux/carry";

/// How long the export may run.
const EXPORT_DEADLINE: Duration = Duration::from_secs(30 * 60);
const EXPORT_POLL: Duration = Duration::from_millis(200);

/// The seed a pull merges against: its HEAD, INDEX and WORK commits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SeedBase {
    pub(crate) head: String,
    pub(crate) index: String,
    pub(crate) work: String,
    pub(crate) stash: Option<String>,
    /// Whether we know the previous stash ref (including an absent ref).
    pub(crate) stash_known: bool,
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
pub(crate) struct Exported {
    pub(crate) head_ref: Option<String>,
    pub(crate) head: String,
    pub(crate) index: String,
    pub(crate) work: String,
    pub(crate) stash: Option<String>,
    pub(crate) unchanged: bool,
    pub(crate) bundle_bytes: u64,
    left_out: Value,
    /// A move's export only ([`export_move_to`]): the base it used and the remote's URL.
    pub(crate) moved: Option<MoveBase>,
}

/// The base a move's export used (its HEAD and WORK), and the remote's URL as the folder
/// configures it.
pub(crate) struct MoveBase {
    pub(crate) head: String,
    pub(crate) work: String,
    pub(crate) url: String,
}

/// Compare-and-swap update of refs/stash, planned against the last accepted seed.
struct StashUpdate {
    before: Option<String>,
    after: Option<String>,
}

/// One tree entry: mode and object id.
type TreeEntry = (String, String);
/// Each changed path with its entry on either side (None: absent).
type TreeDiff = BTreeMap<String, (Option<TreeEntry>, Option<TreeEntry>)>;

/// What a planned working-tree path gets: the machine's entry (None: deleted), or the bytes of a
/// clean three-way merge with their mode.
enum Source {
    Blob(Option<TreeEntry>),
    Merged(Vec<u8>, String),
}

/// How many conflict file names a path gets: `NAME.cmux-sync-conflict`, then
/// `NAME.2.cmux-sync-conflict` up to this (as `cmux link sync pull`'s).
const CONFLICT_NAMES: u32 = 9;

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

/// Whether every one of `shas` names a commit in `folder`'s repository, read
/// with one `git cat-file --batch-check` (a Bring Back pulls twice, before
/// and after the freeze, and three `cat-file -e` runs were each pull's base
/// check).
fn commits_present(folder: &Path, shas: &[&String]) -> anyhow::Result<bool> {
    let mut asked: Vec<&str> = shas.iter().map(|sha| sha.as_str()).collect();
    asked.dedup();
    if asked.iter().any(|sha| !is_sha(sha)) {
        return Ok(false);
    }
    let mut command = local(folder);
    command
        .args(["cat-file", "--batch-check=%(objecttype)"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let name = crate::link::spans::git_name(command.get_args());
    let output = crate::link::spans::time(&name, || -> std::io::Result<_> {
        let mut child = command.spawn()?;
        let mut stdin =
            child.stdin.take().ok_or_else(|| std::io::Error::other("git cat-file has no stdin"))?;
        let lines: String = asked.iter().map(|sha| format!("{sha}^{{commit}}\n")).collect();
        let wrote = stdin.write_all(lines.as_bytes());
        drop(stdin);
        let output = child.wait_with_output()?;
        wrote?;
        Ok(output)
    })
    .context("cannot run git")?;
    if !output.status.success() {
        bail!("git: {}", String::from_utf8_lossy(&output.stderr).trim());
    }
    let answers = String::from_utf8_lossy(&output.stdout);
    let types: Vec<&str> = answers.lines().collect();
    Ok(types.len() == asked.len() && types.iter().all(|kind| *kind == "commit"))
}

/// Pulls the machine's changes to the seeded folder `remote_root` since
/// `base` into the working copy at `local`.
pub(crate) fn seed_pull(
    socket: &Path,
    local_folder: &Path,
    remote_root: &str,
    base: &SeedBase,
) -> anyhow::Result<SeedPulled> {
    let mut laps = crate::link::spans::Laps::new("pull");
    let folder = std::fs::canonicalize(local_folder)
        .with_context(|| format!("cannot open {}", local_folder.display()))?;
    let dirs = GitDirs::of(&folder)?.context("the folder is not a git working copy")?;
    if !commits_present(&folder, &[&base.head, &base.index, &base.work])? {
        return Err(NoSeedBase.into());
    }
    laps.mark("verify_base");
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
    let since = json!({ "since_work": base.work, "since_head": base.head });
    let exported = export(&mut remote, remote_root, since, &remote_bundle)?;
    laps.mark("export");
    let new_base = json!({
        "head": exported.head, "index": exported.index, "work": exported.work,
        "stash": exported.stash,
    });
    let stash = match plan_stash(&folder, base, &exported.stash)? {
        Ok(change) => change,
        Err(reason) => {
            return Ok(SeedPulled::Conflict(
                vec![".git/refs/stash".into()],
                vec![format!(".git/refs/stash: {reason}")],
            ));
        }
    };
    if exported.unchanged {
        // An export may omit its bundle for a stash-only deletion. Apply the
        // ref with the same compare-and-swap check as a full pull.
        if let Some(change) = &stash {
            let here_git = git_back::base_of(&folder)?;
            move_git(&folder, &here_git, None, None, Some(change))?;
        }
        return Ok(SeedPulled::Done(json!({
            "ok": true, "unchanged": stash.is_none(), "written": 0, "deleted": 0, "bytes": 0,
            "bundle_bytes": 0, "fast_forwarded": false, "staged": false,
            "stash_changed": stash.is_some(),
            "head": exported.head, "base": new_base, "left_out": exported.left_out,
        })));
    }
    let staging = Staging::make(&dirs.own)?;
    let bundle = staging.path.join("back.bundle");
    let downloaded = download(&mut remote, &remote_bundle, &bundle);
    let _ = remote.delete(&[remote_bundle]);
    downloaded?;
    laps.mark("download");
    let quarantine = staging.path.join("quarantine.git");
    git_back::quarantined(&quarantine, &dirs.common)?;
    receive(&quarantine, &bundle, &exported)?;
    laps.mark("receive");

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
    laps.mark("read_here");
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
    laps.mark("decide");
    let root = Dir::open(&folder)?;
    let mut planned: Vec<(String, Option<TreeEntry>, Source)> = Vec::new();
    // Paths either side changed, so a conflict file never takes one of their names.
    let changed: std::collections::BTreeSet<String> =
        theirs.keys().chain(ours.keys()).cloned().collect();
    let mut asides: Vec<(String, TreeEntry)> = Vec::new();
    let (mut merged, mut conflict_files, mut kept_edits) = (Vec::new(), Vec::new(), Vec::new());
    for (relative, (base_entry, machine)) in theirs {
        let here_entry = ours.get(&relative).map_or(base_entry.clone(), |(_, here)| here.clone());
        if here_entry == machine {
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
        if !regular(&machine) || !regular(&here_entry) || !regular(&base_entry) {
            conflict(&relative, Some("a symlink or submodule changed; it stays as it is".into()));
            continue;
        }
        // Both changed it differently: the three-tree module (cmux-sync) settles it, so one
        // file never refuses the whole pull. A delete never beats an edit.
        let found =
            match three_tree::decide(base_entry.as_ref(), here_entry.as_ref(), machine.as_ref()) {
                Decision::Nothing | Decision::Push(_) | Decision::RecordSynced(_) => continue,
                Decision::Apply(_) => {
                    planned.push((relative, here_entry, Source::Blob(machine)));
                    continue;
                }
                Decision::Conflict(found) => found,
            };
        let texts = match &found {
            three_tree::Conflict::Content { local, remote } => {
                let base_text = match &base_entry {
                    Some((_, id)) => q.text_blob(id)?,
                    None => Some(Vec::new()),
                };
                match (base_text, q.text_blob(&local.1)?, q.text_blob(&remote.1)?) {
                    (Some(base), Some(here), Some(there)) => Some((base, here, there)),
                    _ => None,
                }
            }
            _ => None,
        };
        let (keep, aside) = match three_tree::resolve(base_entry.as_ref(), &found, texts.is_some())
        {
            Resolution::KeepEdit(edit) => {
                kept_edits.push(relative.clone());
                if here_entry.is_none() {
                    // This Mac deleted it, the machine edited it: the edit comes back.
                    planned.push((relative, None, Source::Blob(Some(edit))));
                }
                // Otherwise the machine deleted this Mac's edit: the file stays, and the
                // next push restores it there.
                continue;
            }
            Resolution::ConflictFile { keep, aside } => (keep, aside),
            Resolution::ThreeWay { base, local, remote } => {
                let mode = match (&base, &local.0, &remote.0) {
                    (_, here, there) if here == there => Some(there.clone()),
                    (Some((base, _)), here, there) if here == base => Some(there.clone()),
                    (Some((base, _)), here, there) if there == base => Some(here.clone()),
                    _ => None,
                };
                if let (Some(mode), Some((base, here, there))) = (mode, &texts) {
                    let mut options = diffy::MergeOptions::new();
                    options.set_conflict_style(diffy::ConflictStyle::Diff3);
                    if let Ok(bytes) = options.merge_bytes(base, here, there) {
                        merged.push(relative.clone());
                        planned.push((relative, here_entry, Source::Merged(bytes, mode)));
                        continue;
                    }
                }
                // Overlapping edits (or permissions both changed): a conflict file.
                (remote, local)
            }
        };
        // The machine's version takes the path; this Mac's is kept beside it.
        let Some(side) = free_conflict_name(&root, &relative, |name| {
            changed.contains(name) || asides.iter().any(|(taken, _)| taken == name)
        })?
        else {
            conflict(&relative, Some("every conflict file name for it is taken".into()));
            continue;
        };
        conflict_files.push(side.clone());
        asides.push((side, aside));
        planned.push((relative, here_entry, Source::Blob(Some(keep))));
    }
    if !conflicts.is_empty() {
        conflicts.sort();
        conflicts.dedup();
        // Nothing here moves, but the machine's work is not left behind: its commits and its
        // uncommitted files stay as refs of their own, a second branch to merge (RFD 0155 goal 5).
        match q.keep(&folder, &exported) {
            Ok(at) => reasons.push(format!(
                "the machine's work is kept at {at}/head (its commits) and {at}/work (with its \
                 uncommitted files); merge or check it out with git"
            )),
            Err(error) => reasons.push(format!("the machine's work was not kept here: {error:#}")),
        }
        return Ok(SeedPulled::Conflict(conflicts, reasons));
    }

    // Stage the machine's files and read what each replaces here.
    let mut steps = Vec::new();
    let mut bytes = 0u64;
    for (relative, here_entry, source) in planned {
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
        match source {
            Source::Blob(Some((mode, blob))) => {
                let staged_name = staging.stage(&quarantine, &blob, &mode)?;
                bytes += std::fs::metadata(staging.path.join(&staged_name))?.len();
                steps.push(Step::Write { relative, staged: staged_name, expected });
            }
            Source::Blob(None) => {
                if let Some(expected) = expected {
                    steps.push(Step::Delete { relative, expected });
                }
            }
            Source::Merged(merged_bytes, mode) => {
                bytes += merged_bytes.len() as u64;
                let staged_name = staging.put(&merged_bytes, &mode)?;
                steps.push(Step::Write { relative, staged: staged_name, expected });
            }
        }
    }
    // This Mac's side of each conflict, as a new file beside it (never replacing one).
    for (side, (mode, blob)) in asides {
        let staged_name = staging.stage(&quarantine, &blob, &mode)?;
        bytes += std::fs::metadata(staging.path.join(&staged_name))?.len();
        steps.push(Step::Write { relative: side, staged: staged_name, expected: None });
    }
    laps.mark("stage");
    // Only objects so far: this repository gets the machine's commits.
    q.fetch_into(&folder, &exported)?;
    laps.mark("fetch_into");
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
    if let Err(error) =
        move_git(&folder, &here_git, fast_forward.as_deref(), staged.as_deref(), stash.as_ref())
    {
        return undone(transaction, &staging, error);
    }
    transaction.finish();
    laps.mark("apply");
    Ok(SeedPulled::Done(json!({
        "ok": true,
        "unchanged": false,
        "written": written,
        "deleted": deleted,
        "bytes": bytes,
        "bundle_bytes": exported.bundle_bytes,
        "fast_forwarded": fast_forward.is_some(),
        "staged": staged.is_some(),
        "stash_changed": stash.is_some(),
        "head": exported.head,
        "base": new_base,
        "left_out": exported.left_out,
        "merged": merged,
        "conflict_files": conflict_files,
        "kept_edits": kept_edits,
    })))
}

/// The first conflict file name beside `relative` that is free: no file, folder or link here and
/// not `taken` (a path the pull changes, or another conflict file of this pull). None when all
/// [`CONFLICT_NAMES`] are taken.
fn free_conflict_name(
    root: &Dir,
    relative: &str,
    taken: impl Fn(&str) -> bool,
) -> anyhow::Result<Option<String>> {
    let (folder, name) = match relative.rsplit_once('/') {
        Some((folder, name)) => (Some(folder), name),
        None => (None, relative),
    };
    let parent = place::parent_of(root, relative)?;
    for n in 1..=CONFLICT_NAMES {
        let side = if n == 1 {
            format!("{name}{CONFLICT_SUFFIX}")
        } else {
            format!("{name}.{n}{CONFLICT_SUFFIX}")
        };
        let path = folder.map_or(side.clone(), |folder| format!("{folder}/{side}"));
        if taken(&path) {
            continue;
        }
        let free = match &parent {
            Some((dir, _)) => matches!(dir.entry(&side)?, Entry::Missing),
            // The folder is not here yet: the transaction makes it.
            None => true,
        };
        if free {
            return Ok(Some(path));
        }
    }
    Ok(None)
}

/// The machine at `socket`'s export of `remote_root` since `base`, its bundle streamed to `to`
/// (a new private file on this Mac, never in a working copy). Move to another Cloud machine
/// sends it on to the second machine (`seed_cli::hop`). None when nothing changed since `base`.
pub(crate) fn export_to(
    socket: &Path,
    remote_root: &str,
    base: &SeedBase,
    to: &Path,
) -> anyhow::Result<Option<Exported>> {
    let params = json!({ "since_work": base.work, "since_head": base.head });
    Ok(Some(export_into(socket, remote_root, params, to)?).filter(|exported| !exported.unchanged))
}

/// A move's export of `remote_root` on the machine at `socket` (`git.seed.export` with `move`:
/// its own refs, the folder's seed records left as they are), streamed to `to` as
/// [`export_to`] streams it. `from` is `upstream` (since the tip its branch tracks, which GitHub
/// has), `seed` (since the folder's own seed) or `since` (since `since`, the move's last
/// export: HEAD, WORK). `unchanged` (and no bundle at `to`) when nothing changed since.
pub(crate) fn export_move_to(
    socket: &Path,
    remote_root: &str,
    from: &str,
    since: Option<(&str, &str)>,
    to: &Path,
) -> anyhow::Result<(Exported, MoveBase)> {
    let mut params = json!({ "move": from });
    if let Some((head, work)) = since {
        params.set("since_head", json!(head));
        params.set("since_work", json!(work));
    }
    let mut exported = export_into(socket, remote_root, params, to)?;
    let moved = exported
        .moved
        .take()
        .context("the machine's export named no base: it runs a cmux-tui without move exports")?;
    Ok((exported, moved))
}

/// Whether the folder at `remote_root` is still as its record `head`/`work` left it (a move's
/// `check`: nothing is recorded and no bundle is written there).
pub(crate) fn still_as_recorded(
    socket: &Path,
    remote_root: &str,
    head: &str,
    work: &str,
) -> anyhow::Result<bool> {
    let mut remote = Remote::connect(socket)?;
    let params = json!({ "move": "check", "since_head": head, "since_work": work });
    // The daemon writes no bundle for a check; the name is never created.
    let (parent, _) = super::remote::split(remote_root)?;
    let unused = format!("{}/.cmux-seed-check.bundle", parent.trim_end_matches('/'));
    Ok(export(&mut remote, remote_root, params, &unused)?.unchanged)
}

fn export_into(
    socket: &Path,
    remote_root: &str,
    params: Value,
    to: &Path,
) -> anyhow::Result<Exported> {
    let mut remote = Remote::connect(socket)?;
    let (parent, _) = super::remote::split(remote_root)?;
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |since| since.as_nanos());
    let remote_bundle = format!(
        "{}/.cmux-seed-move-{}-{nanos}.bundle",
        parent.trim_end_matches('/'),
        std::process::id()
    );
    let exported = export(&mut remote, remote_root, params, &remote_bundle)?;
    if exported.unchanged {
        return Ok(exported);
    }
    let downloaded = download(&mut remote, &remote_bundle, to);
    let _ = remote.delete(&[remote_bundle]);
    downloaded?;
    Ok(exported)
}

/// Starts the export and waits (bounded) for it to end.
fn export(
    remote: &mut Remote,
    remote_root: &str,
    mut params: Value,
    bundle: &str,
) -> anyhow::Result<Exported> {
    let refused = |error: anyhow::Error| match super::remote::refusal_code(&error) {
        Some(code) => anyhow::Error::from(ExportFailed {
            code: code.to_string(),
            message: format!("{error:#}"),
        }),
        None => error,
    };
    params.set("folder", json!(remote_root));
    params.set("bundle", json!(bundle));
    let started = remote.call("git.seed.export", params).map_err(refused)?;
    let job = started
        .get("job")
        .and_then(Value::as_str)
        .context("the export answered no job")?
        .to_string();
    let deadline = Instant::now() + EXPORT_DEADLINE;
    let mut wait = crate::link::spans::PollWait::up_to(EXPORT_POLL);
    let status = loop {
        let status = remote
            .call(
                "git.seed.status",
                json!({ "job": job, "wait_ms": crate::link::seed_cli::STATUS_HOLD_MS }),
            )
            .map_err(refused)?;
        if status.get("state").and_then(Value::as_str) != Some("running") {
            crate::link::spans::remote("git.seed.export", &status);
            break status;
        }
        if Instant::now() > deadline {
            bail!("the machine's export did not finish");
        }
        // A machine that held the answer while the export ran is asked again at once.
        if status.get("waited").and_then(Value::as_bool) != Some(true) {
            wait.sleep("seed.export poll");
        }
    };
    let text = |name: &str| status.get(name).and_then(Value::as_str);
    if text("state") != Some("done") {
        return Err(ExportFailed {
            code: text("error_code").unwrap_or("seed.export_failed").to_string(),
            message: text("error").unwrap_or("the machine's export failed").to_string(),
        }
        .into());
    }
    let sha = |name: &str| -> anyhow::Result<String> {
        let value = text(name).unwrap_or_default();
        if !is_sha(value) {
            bail!("the machine's export answered no {name} commit");
        }
        Ok(value.to_string())
    };
    let head_ref = text("head_ref").map(str::to_string);
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
        stash: match status.get("stash") {
            Some(Value::Null) => None,
            Some(Value::String(value)) if is_sha(value) => Some(value.clone()),
            _ => bail!("the machine's export answered no valid stash state"),
        },
        unchanged: status.get("unchanged").and_then(Value::as_bool) == Some(true),
        bundle_bytes: status.get("bundle_bytes").and_then(Value::as_u64).unwrap_or(0),
        left_out: status.get("left_out").cloned().unwrap_or_default(),
        moved: match text("url") {
            Some(url) => Some(MoveBase {
                head: sha("since_head")?,
                work: sha("since_work")?,
                url: url.to_string(),
            }),
            None => None,
        },
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
    remote.read_into(from, &mut out)?.context("the machine's bundle went away")?;
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
    let mut named =
        vec![("head", &exported.head), ("index", &exported.index), ("work", &exported.work)];
    if let Some(stash) = &exported.stash {
        named.push(("stash", stash));
    }
    for (name, sha) in named {
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

    /// The blob `id`'s bytes when it is text a line merge can hold: no NUL byte and at most
    /// [`TEXT_MAX`]. None for a binary or bigger one.
    fn text_blob(&self, id: &str) -> anyhow::Result<Option<Vec<u8>>> {
        let size: u64 = self.text(&["cat-file", "-s", id])?.parse().context("a blob size")?;
        if size > TEXT_MAX {
            return Ok(None);
        }
        let bytes = checked(quarantine_git(self.0).args(["cat-file", "blob", id]))?;
        Ok((!bytes.contains(&0)).then_some(bytes))
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

    /// A pull that conflicts keeps the machine's HEAD, INDEX and WORK here as
    /// `refs/cmux/carry/<branch>/{head,index,work}` (`detached` for a detached HEAD), the newest
    /// export replacing the last. Only those refs change: never a branch, the index or a file.
    fn keep(&self, folder: &Path, exported: &Exported) -> anyhow::Result<String> {
        let branch = exported
            .head_ref
            .as_deref()
            .and_then(|name| name.strip_prefix("refs/heads/"))
            .unwrap_or("detached");
        let at = format!("{CARRY_REFS}/{branch}");
        checked(local(folder).args(["check-ref-format", &format!("{at}/head")]))
            .with_context(|| format!("{at} is not a ref name"))?;
        self.fetch_into(folder, exported)?;
        let named =
            [("head", &exported.head), ("index", &exported.index), ("work", &exported.work)];
        for (name, sha) in named {
            checked(local(folder).args(["update-ref", &format!("{at}/{name}"), sha]))?;
        }
        Ok(at)
    }

    /// Fetches the machine's HEAD, INDEX and WORK commits into the working
    /// copy at `folder`, every object checked: they are the next base. No
    /// ref changes there.
    fn fetch_into(&self, folder: &Path, exported: &Exported) -> anyhow::Result<()> {
        let mut wanted = Vec::new();
        let mut named =
            vec![("head", &exported.head), ("index", &exported.index), ("work", &exported.work)];
        if let Some(stash) = &exported.stash {
            named.push(("stash", stash));
        }
        for (name, sha) in named {
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
/// Read the ref itself, distinct from the stash's worktree contents.
fn stash_ref(folder: &Path) -> anyhow::Result<Option<String>> {
    let output = local(folder)
        // `show-ref --verify` exits 128 for a missing ref; `rev-parse --quiet` exits 1.
        .args(["rev-parse", "--verify", "--quiet", "refs/stash"])
        .output()
        .context("cannot read refs/stash")?;
    if output.status.code() == Some(1) && output.stdout.is_empty() {
        return Ok(None);
    }
    if !output.status.success() {
        bail!("cannot read refs/stash: {}", String::from_utf8_lossy(&output.stderr));
    }
    let id = std::str::from_utf8(&output.stdout)?.trim();
    if !is_sha(id) {
        bail!("refs/stash is not a commit id");
    }
    Ok(Some(id.to_owned()))
}

/// A Cloud stash change is safe when this Mac still has the accepted baseline.
/// Legacy records and manual --base-* flags lack that baseline: refuse a
/// differing ref instead of silently replacing someone's local stash.
fn plan_stash(
    folder: &Path,
    base: &SeedBase,
    machine: &Option<String>,
) -> anyhow::Result<Result<Option<StashUpdate>, String>> {
    let here = stash_ref(folder)?;
    if !base.stash_known {
        return Ok(if &here == machine {
            Ok(None)
        } else {
            Err("the older seed record has no stash baseline; re-seed before pulling a changed stash".into())
        });
    }
    if &base.stash == machine || &here == machine {
        return Ok(Ok(None));
    }
    if here != base.stash {
        return Ok(Err("refs/stash changed on both this Mac and the Cloud machine".into()));
    }
    Ok(Ok(Some(StashUpdate { before: here, after: machine.clone() })))
}

/// Apply or delete refs/stash only if it still has the value observed above.
fn move_stash_ref(folder: &Path, old: Option<&str>, new: Option<&str>) -> anyhow::Result<()> {
    if old == new {
        return Ok(());
    }
    let zero = "0".repeat(old.or(new).map_or(40, str::len));
    let mut command = local(folder);
    command.args(["update-ref", "-m", "cmux seed pull: bring back stash"]);
    if let Some(new) = new {
        command.args(["--create-reflog", "refs/stash", new, old.unwrap_or(&zero)]);
    } else if let Some(old) = old {
        command.args(["-d", "refs/stash", old]);
    }
    checked(&mut command).context("refs/stash changed while bringing back the Cloud session")?;
    Ok(())
}

/// Commit HEAD, index, and stash with compare-and-swap. Stash moves first and
/// is reversed if a subsequent Git operation fails. The caller rolls back
/// working-tree files if this operation fails.
fn move_git(
    folder: &Path,
    planned: &GitBase,
    head: Option<&str>,
    staged: Option<&str>,
    stash: Option<&StashUpdate>,
) -> anyhow::Result<()> {
    if head.is_none() && staged.is_none() && stash.is_none() {
        return Ok(());
    }
    let lock = staged.map(|_| IndexLock::take(folder)).transpose()?;
    if git_back::base_of(folder)? != *planned {
        bail!("this Mac's branch or staged changes changed during the pull");
    }
    if let Some(stash) = stash {
        if stash_ref(folder)? != stash.before {
            bail!("refs/stash changed during the pull");
        }
        move_stash_ref(folder, stash.before.as_deref(), stash.after.as_deref())?;
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
    let result = (|| -> anyhow::Result<()> {
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
    })();
    if let Err(error) = result {
        if let Some(stash) = stash {
            move_stash_ref(folder, stash.after.as_deref(), stash.before.as_deref())
                .context("could not restore refs/stash after a failed Git update")?;
        }
        return Err(error);
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
            let chunk = buffer.get(..read).context("a read said it filled more than its buffer")?;
            hasher.update(chunk);
            out.write_all(chunk)?;
        }
        let sha256 = hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
        Ok((path, sha256))
    }

    /// Writes `bytes` (a three-way merge) to a new file here with the tree's `mode`; its name here.
    fn put(&self, bytes: &[u8], mode: &str) -> anyhow::Result<String> {
        let number = self.files.get() + 1;
        self.files.set(number);
        let name = format!("merged-{number}");
        let mut out = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.path.join(&name))?;
        out.write_all(bytes)?;
        let bits = if mode == "100755" { 0o755 } else { 0o644 };
        out.set_permissions(std::fs::Permissions::from_mode(bits))?;
        out.sync_all()?;
        Ok(name)
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

#[cfg(test)]
#[path = "seed_pull_commits_present_tests.rs"]
mod commits_present_tests;
