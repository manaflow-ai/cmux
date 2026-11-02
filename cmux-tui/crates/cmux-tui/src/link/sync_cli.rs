//! `cmux link sync push --socket PATH LOCAL REMOTE`: copies a folder (a git
//! working copy with its repository) to a Cloud machine's home through the
//! machine daemon's `fs-v1` ops (Move to Cloud, cmuxterm-hq#1874 slice 2).
//! `--socket` is the machine daemon's socket as this Mac reaches it (the
//! machine link's local socket); `REMOTE` is an absolute folder under the
//! machine's home. What goes is in [`local`]. `cmux link sync pull` brings
//! it back by a three-way merge against the push ([`pull`]).
//!
//! A manifest on the machine (`REMOTE/.git/cmux-sync.json` in a git
//! working copy, else `REMOTE/.cmux-sync.json`) records each pushed file's
//! SHA-256, permissions and the revision the machine gave it, and in git
//! the branch, HEAD commit and staged changes the push left
//! ([`git_back::GitBase`]). A file
//! whose hash, permissions and revision still match is not written again,
//! and a file the manifest lists but the folder no longer has is deleted
//! while the machine still has it as this push left it. Files the machine
//! made or changed itself are never deleted. This Mac keeps a copy of the
//! manifest ([`base`]); a pull trusts only that copy.
//!
//! The manifest is also saved as a push goes (every [`SAVE_EVERY_FILES`]
//! files or [`SAVE_EVERY_BYTES`] written), so a push cut off partway is
//! resumed by the next one into the same folder: what already landed is
//! not written again.
//!
//! Output: one JSON line on stdout, `{"ok":true,"written":N,"unchanged":N,
//! "deleted":N,"skipped":N,"bytes":N,"skipped_files":[{"path","kind","why"}],
//! "skipped_counts":{KIND:N}}` (a pull adds `fast_forwarded` and `head`),
//! exit 0; on failure `{"ok":false,"error":...,"error_code":...}` on stdout
//! (a pull's conflict adds `"conflicts":[paths]` under `sync_conflict`; a
//! full disk on the machine is `disk_full`), exit 1; bad usage exits 64. A
//! push also prints its progress on stderr as JSON lines
//! (`{"progress":{"files_done","files_total","bytes_done","bytes_total"}}`):
//! the totals before anything is written, then at most every
//! [`PROGRESS_EVERY`], and the end. Unix only, like the link.

use cmux_json::JsonSet as _;

mod base;
mod git_back;
mod local;
mod names;
mod place;
mod pull;
mod remote;
mod seed_pull;

/// `cmux link seed pull`'s engine ([`super::seed_cli`] is its CLI).
pub(super) use seed_pull::{
    SeedBase, SeedPulled, failure_code as seed_pull_failure_code, is_sha, seed_pull,
};
mod skips;

use std::collections::{BTreeMap, BTreeSet};
use std::io::Read as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest as _, Sha256};

use local::{LocalFile, Source};
use remote::{Remote, RemoteEntry};

const USAGE: &str = "usage: cmux link sync push|pull --socket PATH LOCAL_FOLDER REMOTE_FOLDER";

/// What the machine holds of earlier pushes; this Mac keeps a copy
/// ([`base`]), which is what a pull trusts.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Manifest {
    version: u32,
    files: BTreeMap<String, Pushed>,
    /// The git state the push left; None outside git and from older pushes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    git: Option<git_back::GitBase>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct Pushed {
    sha256: String,
    permissions: u32,
    revision: String,
}

#[derive(Default)]
pub(super) struct Summary {
    pub(super) written: u64,
    pub(super) unchanged: u64,
    pub(super) deleted: u64,
    /// Every path left out, named or not.
    pub(super) skipped: u64,
    pub(super) bytes: u64,
    /// The first [`skips::LISTED`] skipped paths, `[{path, kind, why}]`.
    pub(super) skipped_files: serde_json::Value,
    /// How many were skipped of each kind (`other`: counted, not named).
    pub(super) skipped_counts: serde_json::Value,
}

impl Summary {
    pub(super) fn json(&self) -> serde_json::Value {
        json!({
            "written": self.written,
            "unchanged": self.unchanged,
            "deleted": self.deleted,
            "skipped": self.skipped,
            "bytes": self.bytes,
            "skipped_files": if self.skipped_files.is_null() { json!([]) } else { self.skipped_files.clone() },
            "skipped_counts": if self.skipped_counts.is_null() { json!({}) } else { self.skipped_counts.clone() },
        })
    }
}

/// How far a push is: files and bytes done (written or found unchanged)
/// against the totals.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct Progress {
    pub(super) files_done: u64,
    pub(super) files_total: u64,
    pub(super) bytes_done: u64,
    pub(super) bytes_total: u64,
}

impl Progress {
    pub(super) fn json(&self) -> serde_json::Value {
        json!({"progress": {
            "files_done": self.files_done,
            "files_total": self.files_total,
            "bytes_done": self.bytes_done,
            "bytes_total": self.bytes_total,
        }})
    }
}

/// Least time between two progress lines.
pub(super) const PROGRESS_EVERY: std::time::Duration = std::time::Duration::from_millis(250);
/// The manifest is saved after this many files written since its last save
/// (or a twentieth of the push's files, when that is more: a big record is
/// not rewritten every few hundred files)...
const SAVE_EVERY_FILES: u64 = 500;
/// ...or this many bytes written.
const SAVE_EVERY_BYTES: u64 = 256 * 1024 * 1024;

/// Prints a push's progress on stderr as JSON lines, at most every
/// [`PROGRESS_EVERY`]; the first and the last always go.
pub(super) fn progress_printer() -> impl FnMut(Progress) {
    let mut last: Option<std::time::Instant> = None;
    move |progress: Progress| {
        let end = progress.files_done == progress.files_total;
        if !end && last.is_some_and(|at| at.elapsed() < PROGRESS_EVERY) {
            return;
        }
        last = Some(std::time::Instant::now());
        eprintln!("{}", progress.json());
    }
}

/// A failed push's error code and message: the machine's full disk is
/// `disk_full` in plain words, a refusal of the machine its own code.
pub(super) fn push_failure(error: &anyhow::Error) -> (String, String) {
    match remote::refusal_code(error) {
        Some("fs.no_space") => {
            ("disk_full".to_string(), "The Cloud machine's disk is full".to_string())
        }
        Some(code) => (code.to_string(), format!("{error:#}")),
        None => ("sync_failed".to_string(), format!("{error:#}")),
    }
}

pub(super) fn run(args: &[String]) -> i32 {
    if matches!(args.first().map(String::as_str), Some("-h" | "--help" | "help")) {
        println!("{USAGE}");
        return 0;
    }
    let Some((action, socket, local, remote)) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    // A machine too old for `fs-v1` says so before anything is copied.
    if let Some(outdated) =
        super::machine_gate::outdated(&socket, &[cmux_tui_core::fs_ops::FS_CAPABILITY])
    {
        println!("{}", outdated.line());
        return 1;
    }
    if action == Action::Pull {
        return finish_pull(pull::pull(&socket, &local, &remote));
    }
    match push(&socket, &local, &remote) {
        Ok(summary) => {
            let mut line = summary.json();
            line.set("ok", json!(true));
            println!("{line}");
            0
        }
        Err(error) => {
            let (code, error) = push_failure(&error);
            println!("{}", json!({ "ok": false, "error": error, "error_code": code }));
            1
        }
    }
}

/// What a pull for `cmux link access` did ([`pull_back`]).
pub(super) enum Back {
    /// Its summary line.
    Done(serde_json::Value),
    /// The conflicting paths, and why for the git leg's; nothing changed.
    Conflict(Vec<String>, Vec<String>),
    Failed {
        code: String,
        error: String,
    },
}

/// A pull of `remote_root` back into `local` ([`pull`]), for `cmux link
/// access`: a new file of the machine `keep_new` refuses stays there.
pub(super) fn pull_back(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    keep_new: &dyn Fn(&str) -> bool,
) -> Back {
    // A copy pushed files only: in git its pull would take the machine's
    // staged paths into this Mac's index.
    if in_git(local) {
        return Back::Failed {
            code: "grant_folder_changed".into(),
            error: format!("{} is in a git working copy now", local.display()),
        };
    }
    match pull::pull_kept(socket, local, remote_root, keep_new) {
        Ok(pull::Pulled::Done(summary)) => Back::Done(summary),
        Ok(pull::Pulled::Conflict(conflicts, reasons)) => Back::Conflict(conflicts, reasons),
        Err(error) => {
            Back::Failed { code: pull::failure_code(&error), error: format!("{error:#}") }
        }
    }
}

/// A pull of `remote_root` into `local`, as `cmux link sync pull` does: for `cmux link agent move
/// --sync pull`, which pulls the last changes of a chat it froze.
pub(super) fn pull_into(socket: &Path, local: &Path, remote_root: &str) -> Back {
    match pull::pull(socket, local, remote_root) {
        Ok(pull::Pulled::Done(summary)) => Back::Done(summary),
        Ok(pull::Pulled::Conflict(conflicts, reasons)) => Back::Conflict(conflicts, reasons),
        Err(error) => {
            Back::Failed { code: pull::failure_code(&error), error: format!("{error:#}") }
        }
    }
}

/// Whether `error` is the machine daemon's own refusal (an `ok: false`
/// answer), not a connection that failed.
pub(super) fn is_refusal(error: &anyhow::Error) -> bool {
    remote::refusal_code(error).is_some()
}

/// The error code of a failed push.
pub(super) fn push_failure_code(error: &anyhow::Error) -> String {
    push_failure(error).0
}

/// One request on the machine daemon's socket: its `data`, or its refusal
/// (whose code [`push_failure_code`] tells).
pub(super) fn machine_call(
    socket: &Path,
    cmd: &str,
    params: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    Remote::connect(socket)?.call(cmd, params)
}

/// What is at `path` on the machine (`file`, `dir`, ...); None when nothing.
pub(super) fn remote_kind(socket: &Path, path: &str) -> anyhow::Result<Option<String>> {
    Remote::connect(socket)?.kind(path)
}

/// Copies the one regular file at `local` (never through a symlink) to
/// `target` on the machine, making its folder.
pub(super) fn copy_file(socket: &Path, local: &Path, target: &str) -> anyhow::Result<()> {
    let mut ignored = || {};
    copy_file_with_progress(socket, local, target, &mut ignored)
}

/// Copies one file and invokes `progress` after each remote fs write. Upload
/// uses this to keep the CLI's bounded idle deadline alive for slow links.
pub(super) fn copy_file_with_progress(
    socket: &Path,
    local: &Path,
    target: &str,
    progress: &mut dyn FnMut(),
) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt as _;
    let meta = std::fs::symlink_metadata(local)
        .with_context(|| format!("cannot read {}", local.display()))?;
    if !meta.file_type().is_file() {
        anyhow::bail!("{} is not a regular file", local.display());
    }
    let file = LocalFile {
        source: Source::File(local.to_path_buf()),
        permissions: local::permissions_of(meta.permissions().mode()),
    };
    let mut remote = Remote::connect(socket)?;
    let (parent, _) = remote::split(target)?;
    remote.mkdir_all(parent)?;
    write_with_progress(&mut remote, target, &file, progress).map(|_| ())
}

/// Uploads the regular file at `local` (never through a symlink) to
/// `target` on the machine as 0600, making its folder; `progress` hears the
/// bytes read so far as the parts go (`cmux link seed push`'s bundle).
pub(super) fn upload(
    socket: &Path,
    local: &Path,
    target: &str,
    progress: &mut dyn FnMut(u64),
) -> anyhow::Result<()> {
    struct Counted<R> {
        inner: R,
        read: std::rc::Rc<std::cell::Cell<u64>>,
    }
    impl<R: std::io::Read> std::io::Read for Counted<R> {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            let read = self.inner.read(buffer)?;
            self.read.set(self.read.get() + read as u64);
            Ok(read)
        }
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(local)
        .with_context(|| format!("cannot read {}", local.display()))?;
    if !file.metadata()?.is_file() {
        anyhow::bail!("{} is not a regular file", local.display());
    }
    let read = std::rc::Rc::new(std::cell::Cell::new(0));
    let mut reader = Counted { inner: file, read: read.clone() };
    let mut remote = Remote::connect(socket)?;
    let (parent, _) = remote::split(target)?;
    remote.mkdir_all(parent)?;
    remote.write_with_progress(target, &mut reader, 0o600, &mut || progress(read.get()))?;
    Ok(())
}

/// Deletes the folder at `path` on the machine whose daemon `socket`
/// reaches; one already gone is fine.
pub(super) fn delete_remote(socket: &Path, path: &str) -> anyhow::Result<()> {
    Remote::connect(socket)?.delete(&[path.to_string()])
}

/// Prints a pull's answer line and returns its exit code.
fn finish_pull(pulled: anyhow::Result<pull::Pulled>) -> i32 {
    let line = match pulled {
        Ok(pull::Pulled::Done(summary)) => {
            println!("{summary}");
            return 0;
        }
        Ok(pull::Pulled::Conflict(conflicts, reasons)) => {
            let mut error = format!(
                "{} changed both here and on the machine; nothing was brought back",
                conflicts.join(", ")
            );
            if !reasons.is_empty() {
                error = format!("{error} ({})", reasons.join("; "));
            }
            json!({ "ok": false, "error": error, "error_code": "sync_conflict",
                    "conflicts": conflicts })
        }
        Err(error) => json!({ "ok": false, "error": format!("{error:#}"),
                              "error_code": pull::failure_code(&error) }),
    };
    println!("{line}");
    1
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Action {
    Push,
    Pull,
}

fn parse(args: &[String]) -> Option<(Action, PathBuf, PathBuf, String)> {
    let [action, rest @ ..] = args else { return None };
    let action = match action.as_str() {
        "push" => Action::Push,
        "pull" => Action::Pull,
        _ => return None,
    };
    let mut socket = None;
    let mut positional = Vec::new();
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--socket" => socket = Some(PathBuf::from(rest.next()?)),
            flag if flag.starts_with('-') => return None,
            value => positional.push(value),
        }
    }
    let [local, remote] = positional.as_slice() else { return None };
    if !remote.starts_with('/') {
        return None;
    }
    Some((action, socket?, PathBuf::from(local), remote.trim_end_matches('/').to_string()))
}

/// A chat's copy (`cmux link sync push`, `cmux link start-chat copy`), its
/// progress on stderr ([`progress_printer`]).
pub(super) fn push(socket: &Path, local: &Path, remote_root: &str) -> anyhow::Result<Summary> {
    let mut printer = progress_printer();
    push_inner(socket, local, remote_root, &|_, _| true, false, Some(&mut printer))
}

/// Whether `folder` is in a git working copy (its top folder or below it).
pub(super) fn in_git(folder: &Path) -> bool {
    !matches!(local::GitDirs::of(folder), Ok(None))
}

/// The top folder of the git working copy `folder` is in; None outside git
/// or above `ceiling` (`GIT_CEILING_DIRECTORIES`). For a folder a Cloud
/// machine named: no system config, no bare repository found by discovery,
/// no fsmonitor.
pub(super) fn git_top(folder: &Path, ceiling: &std::ffi::OsStr) -> Option<PathBuf> {
    let output = std::process::Command::new("git")
        .args(["-c", "safe.bareRepository=explicit", "-c", "core.fsmonitor=false", "-C"])
        .arg(folder)
        .args(["rev-parse", "--show-toplevel"])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CEILING_DIRECTORIES", ceiling)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let top = String::from_utf8(output.stdout).ok().filter(|_| output.status.success())?;
    std::fs::canonicalize(top.trim()).ok()
}

/// Whether `name` reads as `.git` on any disk ([`names::is_dotgit`]).
pub(super) fn is_dotgit(name: &str) -> bool {
    names::is_dotgit(name)
}

/// A push of a folder's files only, for `cmux link access`
/// ([`super::access_cli`]): every file `keep` refuses (by its path relative
/// to the folder, and whether the folder is a git working copy) is left out
/// and counted as skipped, the record is `REMOTE/.cmux-sync.json` even in
/// git, and it records no git state (such a copy is never pulled in git).
pub(super) fn push_kept(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    keep: &dyn Fn(&str, bool) -> bool,
) -> anyhow::Result<Summary> {
    push_inner(socket, local, remote_root, keep, true, None)
}

fn push_inner(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    keep: &dyn Fn(&str, bool) -> bool,
    files_only: bool,
    mut progress: Option<&mut dyn FnMut(Progress)>,
) -> anyhow::Result<Summary> {
    let local =
        std::fs::canonicalize(local).with_context(|| format!("cannot open {}", local.display()))?;
    let rules = if files_only { local::Rules::Share } else { local::Rules::Copy };
    let mut set = local::collect(&local, rules)?;
    let before = set.files.len();
    let in_git = set.git;
    set.files.retain(|relative, _| keep(relative, in_git));
    set.skipped += (before - set.files.len()) as u64;
    let git_record = set.git && !files_only;
    let manifest_name = if git_record { ".git/cmux-sync.json" } else { ".cmux-sync.json" };
    // The manifest's own name is never pushed over it.
    if set.files.remove(manifest_name).is_some() {
        set.skips.note(manifest_name, skips::Why::Reserved);
    }
    set.skips.unnamed(set.skipped);
    let (skipped_files, skipped_counts) = set.skips.json();
    let mut summary =
        Summary { skipped: set.skips.total(), skipped_files, skipped_counts, ..Summary::default() };
    let mut done = Progress {
        files_total: set.files.len() as u64,
        bytes_total: set.files.values().map(|file| size(file).unwrap_or(0)).sum(),
        ..Progress::default()
    };
    if let Some(report) = progress.as_mut() {
        report(done);
    }
    // What a pull compares the machine's branch and staged changes with.
    let git = if git_record { Some(git_back::base_of(&local)?) } else { None };
    let mut remote = Remote::connect(socket)?;
    remote.mkdir_all(remote_root)?;
    let manifest_path = format!("{remote_root}/{manifest_name}");
    let mut previous: Manifest = remote
        .read(&manifest_path)?
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    // A key that is not a plain relative path (empty, absolute, `.` or `..`
    // parts) names nothing this push made: it is dropped, never deleted.
    previous.files.retain(|relative, _| plain_relative(relative));
    let mut listings = Listings::default();

    // Deletes first, so a file that became a folder (or the reverse) is out
    // of the way. Only a file still as this push left it goes; one the
    // machine changed since stays.
    for (relative, pushed) in &previous.files {
        if set.files.contains_key(relative) {
            continue;
        }
        let target = format!("{remote_root}/{relative}");
        if listings.revision(&mut remote, &target)?.as_deref() == Some(pushed.revision.as_str()) {
            remote.delete(std::slice::from_ref(&target))?;
            summary.deleted += 1;
        }
        let (parent, name) = remote::split(&target)?;
        remote.delete(&[format!("{parent}/.{name}.cmux-sync-part")])?;
    }
    listings.clear();

    let mut made: BTreeSet<String> = BTreeSet::new();
    let mut next = Manifest { version: 1, files: BTreeMap::new(), git };
    let save_every_files = SAVE_EVERY_FILES.max(done.files_total / 20);
    let (mut files_since_save, mut bytes_since_save) = (0u64, 0u64);
    for (relative, file) in &set.files {
        let target = format!("{remote_root}/{relative}");
        let (parent, _) = remote::split(&target)?;
        let sha256 = hash(file)?;
        let bytes = size(file)?;
        if let Some(pushed) = previous.files.get(relative)
            && pushed.sha256 == sha256
            && pushed.permissions == file.permissions
            && listings.revision(&mut remote, &target)?.as_deref() == Some(pushed.revision.as_str())
        {
            summary.unchanged += 1;
            next.files.insert(relative.clone(), pushed.clone());
        } else {
            if made.insert(parent.to_string()) {
                remote.mkdir_all(parent)?;
            }
            let revision = write(&mut remote, &target, file)?;
            summary.written += 1;
            summary.bytes += bytes;
            next.files.insert(
                relative.clone(),
                Pushed { sha256, permissions: file.permissions, revision },
            );
            files_since_save += 1;
            bytes_since_save += bytes;
            if files_since_save >= save_every_files || bytes_since_save >= SAVE_EVERY_BYTES {
                save_partway(&mut remote, &manifest_path, &previous, &next, &set.files)?;
                (files_since_save, bytes_since_save) = (0, 0);
            }
        }
        done.files_done += 1;
        done.bytes_done += bytes;
        if let Some(report) = progress.as_mut() {
            report(done);
        }
    }

    let manifest = serde_json::to_vec(&next)?;
    remote
        .write(&manifest_path, &mut manifest.as_slice(), 0o600)
        .context("cannot save the sync manifest")?;
    // A pull's base is this copy, never the machine's.
    base::save(&local, remote_root, &next).context("cannot keep the sync record on this Mac")?;
    Ok(summary)
}

/// Saves the manifest of a push still going on the machine: what it wrote
/// so far, and the earlier push's record of the files it has not reached
/// (still listed here), so a push cut off after this is resumed by the next
/// one: a file whose hash, permissions and revision match is not written
/// again. The git state stays the earlier push's until the push ends.
fn save_partway(
    remote: &mut Remote,
    manifest_path: &str,
    previous: &Manifest,
    next: &Manifest,
    listed: &BTreeMap<String, LocalFile>,
) -> anyhow::Result<()> {
    let mut files: BTreeMap<String, Pushed> = previous
        .files
        .iter()
        .filter(|(relative, _)| listed.contains_key(*relative))
        .map(|(relative, pushed)| (relative.clone(), pushed.clone()))
        .collect();
    files.extend(next.files.iter().map(|(relative, pushed)| (relative.clone(), pushed.clone())));
    let partway = Manifest { version: 1, files, git: previous.git.clone() };
    let bytes = serde_json::to_vec(&partway)?;
    remote
        .write(manifest_path, &mut bytes.as_slice(), 0o600)
        .context("cannot save the sync manifest")?;
    Ok(())
}

/// Writes `file` to `target`. An empty folder in the way (left by a folder
/// that became a file) is removed first; a folder with anything in it stays
/// and the write fails.
fn write(remote: &mut Remote, target: &str, file: &LocalFile) -> anyhow::Result<String> {
    let mut ignored = || {};
    write_with_progress(remote, target, file, &mut ignored)
}

fn write_with_progress(
    remote: &mut Remote,
    target: &str,
    file: &LocalFile,
    progress: &mut dyn FnMut(),
) -> anyhow::Result<String> {
    if remote.kind(target)?.as_deref() == Some("dir")
        && remote.list(target)?.is_some_and(|entries| entries.is_empty())
    {
        remote.delete(&[target.to_string()])?;
    }
    let mut reader = open(file)?;
    remote.write_with_progress(target, &mut reader, file.permissions, progress)
}

/// A relative path of plain names: no empty, `.` or `..` part.
fn plain_relative(relative: &str) -> bool {
    !relative.is_empty() && relative.split('/').all(|name| !matches!(name, "" | "." | ".."))
}

/// Folder listings of the machine, fetched once per folder.
#[derive(Default)]
struct Listings(BTreeMap<String, Option<BTreeMap<String, RemoteEntry>>>);

impl Listings {
    /// The revision of the file at `target`; None when it is missing or not
    /// a file.
    fn revision(&mut self, remote: &mut Remote, target: &str) -> anyhow::Result<Option<String>> {
        let (parent, name) = remote::split(target)?;
        if !self.0.contains_key(parent) {
            let listing = remote.list(parent)?;
            self.0.insert(parent.to_string(), listing);
        }
        Ok(self.0[parent]
            .as_ref()
            .and_then(|entries| entries.get(name))
            .filter(|entry| entry.kind == "file")
            .and_then(|entry| entry.revision.clone()))
    }

    fn clear(&mut self) {
        self.0.clear();
    }
}

/// Opens `file` without following a symlink or blocking on a FIFO swapped
/// in since it was listed; anything but a regular file is refused.
fn open(file: &LocalFile) -> anyhow::Result<Box<dyn std::io::Read>> {
    Ok(match &file.source {
        Source::File(path) => {
            let opened = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(path)
                .with_context(|| format!("cannot read {}", path.display()))?;
            if !opened.metadata()?.is_file() {
                anyhow::bail!("{} is no longer a regular file", path.display());
            }
            Box::new(opened)
        }
        Source::Bytes(bytes) => Box::new(std::io::Cursor::new(bytes.clone())),
    })
}

fn size(file: &LocalFile) -> anyhow::Result<u64> {
    Ok(match &file.source {
        Source::File(path) => std::fs::metadata(path)?.len(),
        Source::Bytes(bytes) => bytes.len() as u64,
    })
}

fn hash(file: &LocalFile) -> anyhow::Result<String> {
    let mut hasher = Sha256::new();
    let mut reader = open(file)?;
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}
