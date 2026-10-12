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
//! On any conflict nothing here changes: the answer is `{"ok":false,
//! "error_code":"sync_conflict","conflicts":[paths]}`. Otherwise every
//! file the machine changed is first copied into a staging folder of this
//! command (in the repository's git folder, else a hidden folder at the top
//! of the folder), this Mac's files are checked again, and only then do
//! files move into place: through no symlink, regular files only, each
//! renamed over its target, with 0644, 0755, 0600 or 0700 permissions.
//! The manifest then records the merged state as the next base.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _, PermissionsExt as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context as _, bail};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::git_back::{self, GitPlan};
use super::local::{self, GitDirs};
use super::remote::{self, Remote};
use super::{Manifest, Pushed, plain_relative};

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
        staged: PathBuf,
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
    let local =
        std::fs::canonicalize(local).with_context(|| format!("cannot open {}", local.display()))?;
    if !std::fs::metadata(&local)?.is_dir() {
        bail!("{} is not a folder", local.display());
    }
    let git = GitDirs::of(&local)?;
    let manifest_name = if git.is_some() { ".git/cmux-sync.json" } else { ".cmux-sync.json" };
    let mut remote = Remote::connect(socket)?;
    let manifest_path = format!("{remote_root}/{manifest_name}");
    let manifest: Manifest = match remote.read(&manifest_path)? {
        Some(bytes) => serde_json::from_slice(&bytes).context("the sync manifest is not valid")?,
        None => return Err(NoBase.into()),
    };
    let staging = Staging::make(git.as_ref().map_or(&local, |dirs| &dirs.own))?;

    let mut skipped = 0u64;
    let found = machine_files(&mut remote, remote_root, &local, git.is_some(), &manifest)?;
    let mut conflicts = Vec::new();
    let mut planned = Vec::new();
    let mut unchanged = 0u64;
    let mut paths: BTreeSet<&String> =
        manifest.files.keys().filter(|path| is_tree_path(path)).collect();
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
        if base.is_none() && is_new_and_kept_out(relative, &machine) {
            skipped += 1;
            continue;
        }
        let here = local_side(&local, relative)?;
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
                    staged: staged.path,
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
        match git_back::plan(&mut remote, remote_root, &local, &dirs.common, &manifest, &staging.0)?
        {
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
        if local_side(&local, &step.relative)? != step.local {
            return Ok(Pulled::Conflict(vec![step.relative.clone()], Vec::new()));
        }
    }

    let fast_forwarded = match &git_plan {
        Some(plan) => plan.apply(&local)?,
        None => false,
    };
    let mut next = manifest;
    let (mut written, mut deleted, mut bytes) = (0u64, 0u64, 0u64);
    for step in planned {
        let target = local.join(&step.relative);
        match step.step {
            Step::Write { staged, permissions, revision, sha256 } => {
                bytes += std::fs::metadata(&staged)?.len();
                place(&local, &step.relative, &staged, permissions)?;
                written += 1;
                next.files.insert(step.relative, Pushed { sha256, permissions, revision });
            }
            Step::Delete => {
                if std::fs::symlink_metadata(&target).is_ok_and(|meta| meta.is_file()) {
                    std::fs::remove_file(&target)
                        .with_context(|| format!("cannot delete {}", target.display()))?;
                    remove_empty_parents(&local, &target);
                }
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
    let head = git_plan.as_ref().and_then(|plan| plan.settled.head.clone());
    if let Some(plan) = git_plan {
        next.git = Some(plan.settled);
    }
    // The next base: a pull that ran again finds nothing new.
    let saved = serde_json::to_vec(&next)
        .ok()
        .and_then(|manifest| remote.write(&manifest_path, &mut manifest.as_slice(), 0o600).ok())
        .is_some();
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

/// No push left a manifest at the folder.
#[derive(Debug)]
pub(super) struct NoBase;

impl std::fmt::Display for NoBase {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("no sync push left this folder on the machine")
    }
}

impl std::error::Error for NoBase {}

/// A working-tree path of the manifest: not the repository, not a part file.
fn is_tree_path(relative: &str) -> bool {
    plain_relative(relative)
        && relative != ".git"
        && !relative.starts_with(".git/")
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

/// The machine's working-tree files, by path, from its folder's listings,
/// level by level. Folders this working copy ignores are not entered
/// (unless the push had files there), and nested repositories never.
fn machine_files(
    remote: &mut Remote,
    remote_root: &str,
    local: &Path,
    git: bool,
    manifest: &Manifest,
) -> anyhow::Result<BTreeMap<String, Found>> {
    let pushed_dirs: BTreeSet<String> = manifest
        .files
        .keys()
        .filter(|path| is_tree_path(path))
        .flat_map(|path| {
            let parts: Vec<&str> = path.split('/').collect();
            (1..parts.len()).map(move |end| parts[..end].join("/"))
        })
        .collect();
    let mut found = BTreeMap::new();
    let mut level = vec![String::new()];
    while !level.is_empty() {
        let mut children: Vec<(String, bool, Found)> = Vec::new();
        for dir in level.drain(..) {
            let path =
                if dir.is_empty() { remote_root.into() } else { format!("{remote_root}/{dir}") };
            let Some(entries) = remote.list(&path)? else { continue };
            for (name, entry) in entries {
                let relative = if dir.is_empty() { name.clone() } else { format!("{dir}/{name}") };
                if name == ".git"
                    || name.starts_with(".cmux-sync")
                    || name.ends_with(".cmux-sync-part")
                {
                    continue;
                }
                if !local::holdable(&relative) {
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
    Ok(found)
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

/// This Mac's file at `relative`. A path through a symlinked folder is
/// [`Side::Other`]: nothing is written or deleted through it.
fn local_side(local: &Path, relative: &str) -> anyhow::Result<Side> {
    let mut at = local.to_path_buf();
    let parts: Vec<&str> = relative.split('/').collect();
    for part in &parts[..parts.len() - 1] {
        at.push(part);
        match std::fs::symlink_metadata(&at) {
            Ok(meta) if meta.is_dir() => {}
            Ok(_) => return Ok(Side::Other),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Side::Missing),
            Err(error) => return Err(error.into()),
        }
    }
    at.push(parts[parts.len() - 1]);
    match std::fs::symlink_metadata(&at) {
        Ok(meta) if meta.is_file() => {
            let permissions = local::permissions_of(meta.permissions().mode());
            let sha256 = hash_file(&at)?;
            Ok(Side::File { sha256, permissions })
        }
        Ok(_) => Ok(Side::Other),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Side::Missing),
        Err(error) => Err(error.into()),
    }
}

fn hash_file(path: &Path) -> anyhow::Result<String> {
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let mut hasher = Sha256::new();
    std::io::copy(&mut file, &mut hasher)?;
    Ok(hex(&hasher.finalize()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A machine file copied into the staging folder.
struct Staged {
    path: PathBuf,
    sha256: String,
    permissions: u32,
    revision: String,
}

impl Staged {
    fn pushed(self) -> Pushed {
        Pushed { sha256: self.sha256, permissions: self.permissions, revision: self.revision }
    }
}

/// This pull's own folder, removed when the pull ends.
struct Staging(PathBuf, std::cell::Cell<u64>);

impl Staging {
    fn make(parent: &Path) -> anyhow::Result<Self> {
        let path = parent.join(format!(".cmux-sync-pull-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::DirBuilder::new()
            .mode(0o700)
            .create(&path)
            .with_context(|| format!("cannot make {}", path.display()))?;
        Ok(Self(path, std::cell::Cell::new(0)))
    }

    /// Copies the machine's file at `target` here, with its hash, synced
    /// permissions and revision.
    fn stage(&self, remote: &mut Remote, target: &str) -> anyhow::Result<Staged> {
        let stat = remote.stat(target)?.with_context(|| format!("{target} went away"))?;
        let revision = stat["revision"].as_str().unwrap_or_default().to_string();
        let mode = stat["mode_display"].as_str().map_or(0o644, mode_bits);
        let permissions = local::permissions_of(mode);
        let bytes = remote.read(target)?.with_context(|| format!("{target} went away"))?;
        let number = self.1.get() + 1;
        self.1.set(number);
        let path = self.0.join(format!("file-{number}"));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        file.write_all(&bytes)?;
        file.set_permissions(std::fs::Permissions::from_mode(permissions))?;
        file.sync_all()?;
        Ok(Staged { path, sha256: hex(&Sha256::digest(&bytes)), permissions, revision })
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// `rwxr-xr-x` back to its bits.
fn mode_bits(display: &str) -> u32 {
    display.chars().take(9).fold(0, |mode, c| (mode << 1) | u32::from(c != '-'))
}

/// Moves `staged` to `relative` under `local`, making missing folders and
/// refusing a path through anything but a folder (a symlink above it, or a
/// folder where the file goes).
fn place(local: &Path, relative: &str, staged: &Path, permissions: u32) -> anyhow::Result<()> {
    let mut at = local.to_path_buf();
    let parts: Vec<&str> = relative.split('/').collect();
    for part in &parts[..parts.len() - 1] {
        at.push(part);
        match std::fs::symlink_metadata(&at) {
            Ok(meta) if meta.is_dir() => {}
            Ok(_) => bail!("{} is not a folder", at.display()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                std::fs::create_dir(&at)
                    .with_context(|| format!("cannot make {}", at.display()))?;
            }
            Err(error) => return Err(error.into()),
        }
    }
    let target = at.join(parts[parts.len() - 1]);
    if std::fs::symlink_metadata(&target).is_ok_and(|meta| !meta.is_file()) {
        bail!("{} is not a regular file", target.display());
    }
    match std::fs::rename(staged, &target) {
        Ok(()) => Ok(()),
        // Another file system (a mount inside the folder): copy next to it.
        Err(error) if error.raw_os_error() == Some(libc::EXDEV) => {
            let part = at.join(format!(".{}.cmux-sync-part", parts[parts.len() - 1]));
            let _ = std::fs::remove_file(&part);
            let mut out = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&part)?;
            std::io::copy(&mut std::fs::File::open(staged)?, &mut out)?;
            out.set_permissions(std::fs::Permissions::from_mode(permissions))?;
            out.sync_all()?;
            std::fs::rename(&part, &target)
                .with_context(|| format!("cannot write {}", target.display()))
        }
        Err(error) => Err(error).with_context(|| format!("cannot write {}", target.display())),
    }
}

/// Removes the folders above `target` that its delete left empty, up to
/// `local` (never `local` itself).
fn remove_empty_parents(local: &Path, target: &Path) {
    let mut at = target.parent();
    while let Some(dir) = at {
        if dir == local || !dir.starts_with(local) || std::fs::remove_dir(dir).is_err() {
            return;
        }
        at = dir.parent();
    }
}

/// The error code of a pull failure.
pub(super) fn failure_code(error: &anyhow::Error) -> String {
    if error.downcast_ref::<NoBase>().is_some() {
        return "sync_no_base".into();
    }
    remote::refusal_code(error).unwrap_or("sync_failed").to_string()
}
