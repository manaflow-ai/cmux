//! `cmux link sync pull --socket PATH LOCAL REMOTE`: brings a folder that
//! `cmux link sync push` copied to a Cloud machine back (Bring Back Local,
//! cmuxterm-hq#1874 slice 4), by a three-way merge against what the push
//! left there (its manifest).
//!
//! For each file of the push or of the machine's folder now:
//!
//! - the machine's still as pushed: this Mac's stays;
//! - this Mac's still as pushed: the machine's comes back (written, or
//!   deleted when the machine deleted it);
//! - both changed the same way: nothing to do;
//! - both changed differently: a conflict.
//!
//! The machine's `.git` never comes back as files: its branch and staged
//! changes take the git leg ([`super::git_back`]). New files of the machine
//! come back, except ones this working copy's ignore rules match, untracked
//! `.env*` files, symlinks and special files. Outside git every file of the
//! machine's folder counts.
//!
//! The machine is not trusted. The base is the copy of the push's record
//! this Mac kept ([`super::base`]), never the machine's; a listing that
//! names anything but plain names is refused; no path that reaches a
//! repository folder under any spelling (`.GIT`, `git~1`, ...: see
//! [`super::names`]) comes back, and no folder holding one (a nested
//! repository) either. Files are read with their revision checked before
//! and after, streamed to disk.
//!
//! On any conflict nothing here changes: the answer is `{"ok":false,
//! "error_code":"sync_conflict","conflicts":[paths]}`. Otherwise every
//! file the machine changed is first copied into a staging folder of this
//! command (in the repository's git folder, else a hidden folder at the top
//! of the folder) and the machine's commits are fetched; this Mac's files
//! are checked again, and only then do files move into place, as one
//! transaction ([`super::place`]): through folder handles that follow no
//! symlink, regular files only, each renamed over its target (which is
//! moved aside first), with 0644, 0755, 0600 or 0700 permissions. The
//! branch and index move last. Any failure puts back what changed.
//! The records then hold the merged state as the next base.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context as _, bail};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::git_back::{self, GitPlan};
use super::local::{self, GitDirs};
use super::place::{self, Dir, Entry, Expected, Transaction};
use super::remote::{self, Remote};
use super::{Manifest, Pushed, base, names};

/// Most bytes one file of the machine may have.
const MAX_FILE_BYTES: u64 = 4 << 30;
/// Most entries of all the machine folder's listings together.
const MAX_ENTRIES: usize = 2_000_000;

/// What a pull did, or the paths that stopped it.
pub(super) enum Pulled {
    Done(Value),
    /// The conflicting paths, and why for the git leg's.
    Conflict(Vec<String>, Vec<String>),
}

/// One side's file at a path.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Side {
    Missing,
    File {
        sha256: String,
        permissions: u32,
    },
    /// A folder, symlink or special file.
    Other,
}

/// What happens to one path.
enum Step {
    /// The machine's file replaces this Mac's: staged copy, permissions.
    Write {
        staged: String,
        permissions: u32,
        revision: String,
        sha256: String,
    },
    Delete,
    /// Both sides already agree; only the manifest moves.
    Settle(Option<Pushed>),
}

struct Planned {
    relative: String,
    local: Side,
    step: Step,
}

pub(super) fn pull(socket: &Path, local: &Path, remote_root: &str) -> anyhow::Result<Pulled> {
    pull_kept(socket, local, remote_root, &|_| true)
}

/// A pull that also leaves on the machine (and counts as skipped) every new
/// file of the machine `keep_new` refuses, by its path relative to the
/// folder: `cmux link access` never takes secret files back.
pub(super) fn pull_kept(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    keep_new: &dyn Fn(&str) -> bool,
) -> anyhow::Result<Pulled> {
    let local =
        std::fs::canonicalize(local).with_context(|| format!("cannot open {}", local.display()))?;
    if !std::fs::metadata(&local)?.is_dir() {
        bail!("{} is not a folder", local.display());
    }
    let git = GitDirs::of(&local)?;
    let manifest_name = if git.is_some() { ".git/cmux-sync.json" } else { ".cmux-sync.json" };
    let mut remote = Remote::connect(socket)?;
    let manifest_path = format!("{remote_root}/{manifest_name}");
    let record = remote.read(&manifest_path)?;
    let manifest = base::trusted(&local, remote_root, record.as_deref())?;
    let staging = Staging::make(git.as_ref().map_or(&local, |dirs| &dirs.own))?;
    let root = Dir::open(&local)?;

    let hooks = if git.is_some() { hook_folders(&local)? } else { Vec::new() };
    let MachineFiles { found, mut skipped, mut fenced } =
        machine_files(&mut remote, remote_root, &local, git.is_some(), &manifest, &hooks)?;
    // A repository here in a folder the push sent, whether or not the
    // machine still lists it: nothing in it is deleted.
    for dir in pushed_folders(&manifest) {
        if !fenced.iter().any(|folder| names::folded_within(&dir, folder))
            && local_names(&local, &dir)
                .iter()
                .any(|name| names::is_dotgit(name) || names::is_repository_marker(name))
        {
            fenced.insert(dir);
        }
    }
    let mut conflicts = Vec::new();
    let mut planned = Vec::new();
    let mut unchanged = 0u64;
    let mut paths: BTreeSet<&String> = manifest
        .files
        .keys()
        .filter(|path| is_tree_path(path))
        .filter(|path| !fenced.iter().any(|folder| names::folded_within(path, folder)))
        .collect();
    paths.extend(found.keys());
    for relative in paths {
        let base = manifest.files.get(relative);
        let pushed_side = base.map_or(Side::Missing, |pushed| Side::File {
            sha256: pushed.sha256.clone(),
            permissions: pushed.permissions,
        });
        let target = format!("{remote_root}/{relative}");
        let (machine, staged) = match found.get(relative) {
            None => (Side::Missing, None),
            Some(Found::Other) => (Side::Other, None),
            Some(Found::File(revision)) => {
                if base.is_some_and(|pushed| Some(&pushed.revision) == revision.as_ref()) {
                    unchanged += 1;
                    continue;
                }
                let staged = staging.stage(&mut remote, &target)?;
                let side =
                    Side::File { sha256: staged.sha256.clone(), permissions: staged.permissions };
                (side, Some(staged))
            }
        };
        if machine == pushed_side {
            unchanged += 1;
            continue;
        }
        if base.is_none() && (is_new_and_kept_out(relative, &machine) || !keep_new(relative)) {
            skipped += 1;
            continue;
        }
        let here = local_side(&root, relative)?;
        let step = if here == machine {
            Step::Settle(staged.map(|staged| staged.pushed()))
        } else if here != pushed_side {
            conflicts.push(relative.clone());
            continue;
        } else {
            match (machine, staged) {
                (Side::File { .. }, Some(staged)) => Step::Write {
                    permissions: staged.permissions,
                    revision: staged.revision,
                    sha256: staged.sha256,
                    staged: staged.name,
                },
                (Side::Missing, _) => Step::Delete,
                _ => {
                    conflicts.push(relative.clone());
                    continue;
                }
            }
        };
        planned.push(Planned { relative: relative.clone(), local: here, step });
    }

    let mut git_plan: Option<GitPlan> = None;
    let mut reasons = Vec::new();
    if let Some(dirs) = &git {
        let at = git_back::Where { folder: &local, common_dir: &dirs.common, staging: &staging.0 };
        match git_back::plan(&mut remote, remote_root, &at, &manifest, &hooks)? {
            Ok(plan) => git_plan = plan,
            Err(git_conflicts) => {
                for (path, why) in git_conflicts {
                    reasons.push(format!("{path}: {why}"));
                    conflicts.push(path);
                }
            }
        }
    }
    if !conflicts.is_empty() {
        conflicts.sort();
        conflicts.dedup();
        return Ok(Pulled::Conflict(conflicts, reasons));
    }
    // This Mac's files are as planned, or nothing moves.
    for step in &planned {
        if local_side(&root, &step.relative)? != step.local {
            return Ok(Pulled::Conflict(vec![step.relative.clone()], Vec::new()));
        }
    }
    // Only objects so far: the branch and index move last.
    if let Some(plan) = &git_plan {
        plan.fetch(&local)?;
    }

    let mut next = manifest;
    let mut transaction = Transaction::new(&local, &staging.0)?;
    let applied = apply(&mut transaction, &staging, planned, &mut next);
    let (written, deleted, bytes) = match applied {
        Ok(counts) => counts,
        Err(error) => return undone(transaction, &staging, error),
    };
    let fast_forwarded = match git_plan.as_ref().map(|plan| plan.commit(&local)).transpose() {
        Ok(moved) => moved.unwrap_or(false),
        Err(error) => return undone(transaction, &staging, error),
    };
    transaction.finish();
    let head = git_plan.as_ref().and_then(|plan| plan.settled.head.clone());
    if let Some(plan) = git_plan {
        next.git = Some(plan.settled);
    }
    // The next base, on the machine and here: a pull that ran again finds
    // nothing new. This Mac's copy moves only once the machine's did, so
    // the two stay equal when the machine's write fails.
    let saved = serde_json::to_vec(&next)
        .ok()
        .and_then(|manifest| remote.write(&manifest_path, &mut manifest.as_slice(), 0o600).ok())
        .is_some()
        && base::save(&local, remote_root, &next).is_ok();
    Ok(Pulled::Done(json!({
        "ok": true,
        "written": written,
        "deleted": deleted,
        "unchanged": unchanged,
        "skipped": skipped,
        "bytes": bytes,
        "fast_forwarded": fast_forwarded,
        "head": head,
        "manifest_saved": saved,
    })))
}

/// Puts back what `transaction` changed after `error`. A file that changed
/// here during the pull is a conflict; what could not be put back stays in
/// the staging folder, which the answer names.
fn undone(
    transaction: Transaction,
    staging: &Staging,
    error: anyhow::Error,
) -> anyhow::Result<Pulled> {
    if let Err(left) = transaction.roll_back() {
        staging.keep();
        return Err(error.context(format!(
            "cmux could not put back {}; what it moved aside is in {}",
            left.join(", "),
            staging.0.display()
        )));
    }
    if let Some(changed) = error.downcast_ref::<place::Changed>() {
        return Ok(Pulled::Conflict(vec![changed.0.clone()], Vec::new()));
    }
    Err(error)
}

/// Applies the planned steps through `transaction`, recording each in
/// `next`: written, deleted and bytes written.
fn apply(
    transaction: &mut Transaction,
    staging: &Staging,
    planned: Vec<Planned>,
    next: &mut Manifest,
) -> anyhow::Result<(u64, u64, u64)> {
    let (mut written, mut deleted, mut bytes) = (0u64, 0u64, 0u64);
    for step in planned {
        match step.step {
            Step::Write { staged, permissions, revision, sha256 } => {
                bytes += std::fs::metadata(staging.0.join(&staged))?.len();
                transaction.write(&step.relative, &staged, expected(&step.local).as_ref())?;
                written += 1;
                next.files.insert(step.relative, Pushed { sha256, permissions, revision });
            }
            Step::Delete => {
                let Some(expected) = expected(&step.local) else {
                    bail!("{} here is not a file", step.relative);
                };
                transaction.delete(&step.relative, &expected)?;
                deleted += 1;
                next.files.remove(&step.relative);
            }
            Step::Settle(Some(pushed)) => {
                next.files.insert(step.relative, pushed);
            }
            Step::Settle(None) => {
                next.files.remove(&step.relative);
            }
        }
    }
    Ok((written, deleted, bytes))
}

/// What this Mac's file must still be when it is replaced or deleted.
fn expected(side: &Side) -> Option<Expected> {
    match side {
        Side::File { sha256, permissions } => {
            Some(Expected { sha256: sha256.clone(), permissions: *permissions })
        }
        Side::Missing | Side::Other => None,
    }
}

/// A working-tree path of the record: no repository folder under any
/// spelling, not a part file.
fn is_tree_path(relative: &str) -> bool {
    names::safe_relative(relative)
        && relative != ".cmux-sync.json"
        && !relative.ends_with(".cmux-sync-part")
}

/// A new file of the machine that does not come back: an `.env*` file
/// (shared only on purpose) or a symlink or special file.
fn is_new_and_kept_out(relative: &str, machine: &Side) -> bool {
    let name = relative.rsplit('/').next().unwrap_or_default();
    name.starts_with(".env") || !matches!(machine, Side::File { .. })
}

/// What the machine's listing says about a path.
enum Found {
    /// A regular file, with its revision.
    File(Option<String>),
    Other,
}

/// What [`machine_files`] found: the files by path, how many entries were
/// left out, and the paths fenced off (nothing at or below them comes back
/// or is deleted here).
struct MachineFiles {
    found: BTreeMap<String, Found>,
    skipped: u64,
    fenced: BTreeSet<String>,
}

/// The machine's working-tree files, by path, from its folder's listings,
/// level by level. Folders this working copy ignores are not entered
/// (unless the push had files there). No name that reads as `.git` comes
/// back. Fenced off: a folder below the top that is a repository on either
/// side (a `.git`, a `HEAD` or a `commondir`), a top folder's repository
/// names when it has a repository's shape, and `hook_folders`.
fn machine_files(
    remote: &mut Remote,
    remote_root: &str,
    local: &Path,
    git: bool,
    manifest: &Manifest,
    hook_folders: &[String],
) -> anyhow::Result<MachineFiles> {
    let pushed_dirs = pushed_folders(manifest);
    let mut listed = 0usize;
    let mut found = BTreeMap::new();
    let mut skipped = 0u64;
    let mut fenced = BTreeSet::new();
    let mut level = vec![String::new()];
    while !level.is_empty() {
        let mut children: Vec<(String, bool, Found)> = Vec::new();
        for dir in level.drain(..) {
            let path =
                if dir.is_empty() { remote_root.into() } else { format!("{remote_root}/{dir}") };
            // Every listed name is one plain component (`Remote::list`).
            let Some(entries) = remote.list(&path)? else { continue };
            listed += entries.len();
            if listed > MAX_ENTRIES {
                bail!("the machine's folder has over {MAX_ENTRIES} entries");
            }
            let here = local_names(local, &dir);
            // A repository below the top, on either side (a `.git`, or a
            // bare repository's or linked worktree's shape): nothing in it
            // comes back or is deleted here.
            if !dir.is_empty()
                && entries
                    .keys()
                    .chain(&here)
                    .any(|name| names::is_dotgit(name) || names::is_repository_marker(name))
            {
                skipped += 1;
                fenced.insert(dir);
                continue;
            }
            // The top with a repository's shape: its repository names stay.
            let top_shaped = dir.is_empty()
                && entries.keys().chain(&here).any(|name| names::is_repository_marker(name));
            for (name, entry) in entries {
                if names::is_dotgit(&name) {
                    // The top's own `.git` is the repository, never a file.
                    if !(dir.is_empty() && name == ".git") {
                        skipped += 1;
                    }
                    continue;
                }
                let lower = name.to_ascii_lowercase();
                if lower.starts_with(".cmux-sync") || lower.ends_with(".cmux-sync-part") {
                    continue;
                }
                let relative = if dir.is_empty() { name.clone() } else { format!("{dir}/{name}") };
                let hooks =
                    hook_folders.iter().any(|folder| names::folded_within(&relative, folder));
                if (top_shaped && names::is_repository_part(&name)) || hooks {
                    skipped += 1;
                    fenced.insert(relative);
                    continue;
                }
                if !names::safe_relative(&relative) || !local::holdable(&relative) {
                    skipped += 1;
                    continue;
                }
                match entry.kind.as_str() {
                    "dir" => children.push((relative, true, Found::Other)),
                    "file" => children.push((relative, false, Found::File(entry.revision))),
                    _ => children.push((relative, false, Found::Other)),
                }
            }
        }
        let ignored = if git { ignored(local, &children)? } else { BTreeSet::new() };
        for (relative, is_dir, kind) in children {
            if ignored.contains(&relative) && !pushed_dirs.contains(&relative) {
                continue;
            }
            if is_dir {
                level.push(relative);
            } else {
                found.insert(relative, kind);
            }
        }
    }
    Ok(MachineFiles { found, skipped, fenced })
}

/// The folders the push sent files in, relative to the top.
fn pushed_folders(manifest: &Manifest) -> BTreeSet<String> {
    manifest
        .files
        .keys()
        .filter(|path| is_tree_path(path))
        .flat_map(|path| {
            let parts: Vec<&str> = path.split('/').collect();
            (1..parts.len()).map(move |end| parts[..end].join("/"))
        })
        .collect()
}

/// The names in this Mac's folder `dir` (relative to `local`); none when it
/// can't be read.
fn local_names(local: &Path, dir: &str) -> Vec<String> {
    let path = if dir.is_empty() { local.to_path_buf() } else { local.join(dir) };
    std::fs::read_dir(path)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default()
}

/// The working-tree folders whose files this working copy's git runs as
/// hooks: `core.hooksPath` when it is inside the folder, and the folder
/// above it for husky's `.husky/_` (whose hooks call `.husky/<hook>`).
pub(super) fn hook_folders(local: &Path) -> anyhow::Result<Vec<String>> {
    let Some(path) = git_back::hooks_path(local)? else { return Ok(Vec::new()) };
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let path = match (path.strip_prefix("~/"), home) {
        (Some(rest), Some(home)) => home.join(rest),
        _ => PathBuf::from(&path),
    };
    let inside = if path.is_absolute() {
        // `local` is canonical; so is the hooks folder when it exists.
        let path = std::fs::canonicalize(&path).unwrap_or(path);
        let Ok(inside) = path.strip_prefix(local) else { return Ok(Vec::new()) };
        inside.to_path_buf()
    } else {
        path
    };
    let mut parts: Vec<String> = Vec::new();
    for part in inside.components() {
        match part {
            std::path::Component::Normal(name) => parts.push(name.to_string_lossy().into_owned()),
            std::path::Component::CurDir => {}
            // `..`, `~` and the like point outside the folder.
            _ => return Ok(Vec::new()),
        }
    }
    if parts.first().is_some_and(|first| first.starts_with('~')) || parts.is_empty() {
        return Ok(Vec::new());
    }
    let mut folders = vec![parts.join("/")];
    if parts.len() > 1 && parts.last().is_some_and(|last| last == "_") {
        folders.push(parts[..parts.len() - 1].join("/"));
    }
    Ok(folders)
}

/// Which of `paths` this working copy's ignore rules match (tracked files
/// never). Folders are asked with a trailing slash.
fn ignored(local: &Path, paths: &[(String, bool, Found)]) -> anyhow::Result<BTreeSet<String>> {
    if paths.is_empty() {
        return Ok(BTreeSet::new());
    }
    let mut child = Command::new("git")
        .arg("-C")
        .arg(local)
        .args(["check-ignore", "--stdin", "-z"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("cannot run git")?;
    let mut input = Vec::new();
    for (relative, is_dir, _) in paths {
        input.extend_from_slice(relative.as_bytes());
        if *is_dir {
            input.push(b'/');
        }
        input.push(0);
    }
    let mut stdin = child.stdin.take().context("no stdin")?;
    let writer = std::thread::spawn(move || stdin.write_all(&input));
    let output = child.wait_with_output()?;
    let _ = writer.join();
    // 0: some are ignored; 1: none is.
    if !matches!(output.status.code(), Some(0 | 1)) {
        bail!("git check-ignore failed");
    }
    Ok(output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
        .map(|path| String::from_utf8_lossy(path).trim_end_matches('/').to_string())
        .collect())
}

/// This Mac's file at `relative`, read through folder handles. A path
/// through a symlink or anything but a folder is [`Side::Other`]: nothing
/// is written or deleted through it.
fn local_side(root: &Dir, relative: &str) -> anyhow::Result<Side> {
    let (dir, name) = match place::parent_of(root, relative) {
        Ok(Some(found)) => found,
        Ok(None) => return Ok(Side::Missing),
        Err(error) if matches!(error.raw_os_error(), Some(libc::ENOTDIR | libc::ELOOP)) => {
            return Ok(Side::Other);
        }
        Err(error) => return Err(error.into()),
    };
    match dir.entry(&name)? {
        Entry::Missing => Ok(Side::Missing),
        Entry::File { mode } => {
            let mut file = dir.open_file(&name)?;
            let mut hasher = Sha256::new();
            std::io::copy(&mut file, &mut hasher)?;
            Ok(Side::File {
                sha256: hex(&hasher.finalize()),
                permissions: local::permissions_of(mode),
            })
        }
        Entry::Dir | Entry::Other => Ok(Side::Other),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A machine file copied into the staging folder, by its name there.
struct Staged {
    name: String,
    sha256: String,
    permissions: u32,
    revision: String,
}

impl Staged {
    fn pushed(self) -> Pushed {
        Pushed { sha256: self.sha256, permissions: self.permissions, revision: self.revision }
    }
}

/// This pull's own folder, removed when the pull ends, unless it holds a
/// file a failed pull could not put back (or the pull panicked).
struct Staging(PathBuf, std::cell::Cell<u64>, std::cell::Cell<bool>);

impl Staging {
    fn make(parent: &Path) -> anyhow::Result<Self> {
        // A name of its own: a folder a failed pull kept is never reused.
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |since| since.as_nanos());
        let path = parent.join(format!(".cmux-sync-pull-{}-{nanos}", std::process::id()));
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .with_context(|| format!("cannot make {}", path.display()))?;
        Ok(Self(path, std::cell::Cell::new(0), std::cell::Cell::new(false)))
    }

    /// Keeps the folder when the pull ends.
    fn keep(&self) {
        self.2.set(true);
    }

    /// Copies the machine's file at `target` here, with its hash, synced
    /// permissions and revision, streamed to disk. Its revision is read
    /// before and after; a file that changed meanwhile is read again.
    fn stage(&self, remote: &mut Remote, target: &str) -> anyhow::Result<Staged> {
        for _ in 0..3 {
            let stat = remote.stat(target)?.with_context(|| format!("{target} went away"))?;
            if stat["kind"] != "file" {
                bail!("{target} is no longer a file");
            }
            let revision = stat["revision"].as_str().unwrap_or_default().to_string();
            let mode = stat["mode_display"].as_str().map_or(0o644, mode_bits);
            let permissions = local::permissions_of(mode);
            let number = self.1.get() + 1;
            self.1.set(number);
            let name = format!("file-{number}");
            let path = self.0.join(&name);
            let file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&path)?;
            let mut out = Hashing { file, hasher: Sha256::new() };
            remote
                .read_into(target, &mut out, MAX_FILE_BYTES)?
                .with_context(|| format!("{target} went away"))?;
            let after = remote.stat(target)?;
            if after.as_ref().and_then(|stat| stat["revision"].as_str()) != Some(revision.as_str())
            {
                drop(out);
                let _ = std::fs::remove_file(&path);
                continue;
            }
            out.file.set_permissions(std::fs::Permissions::from_mode(permissions))?;
            out.file.sync_all()?;
            let sha256 = hex(&out.hasher.finalize());
            return Ok(Staged { name, sha256, permissions, revision });
        }
        bail!("{target} kept changing while it was read")
    }
}

/// A file that hashes what is written to it.
struct Hashing {
    file: std::fs::File,
    hasher: Sha256,
}

impl Write for Hashing {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let written = self.file.write(bytes)?;
        self.hasher.update(&bytes[..written]);
        Ok(written)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        if self.2.get() || std::thread::panicking() {
            return;
        }
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// `rwxr-xr-x` back to its bits.
fn mode_bits(display: &str) -> u32 {
    display.chars().take(9).fold(0, |mode, c| (mode << 1) | u32::from(c != '-'))
}

/// The error code of a pull failure.
pub(super) fn failure_code(error: &anyhow::Error) -> String {
    if error.downcast_ref::<base::NoBase>().is_some() {
        return "sync_no_base".into();
    }
    if error.downcast_ref::<base::Mismatch>().is_some() {
        return "sync_base_mismatch".into();
    }
    if error.downcast_ref::<remote::UnsafeName>().is_some() {
        return "sync_unsafe_name".into();
    }
    remote::refusal_code(error).unwrap_or("sync_failed").to_string()
}
