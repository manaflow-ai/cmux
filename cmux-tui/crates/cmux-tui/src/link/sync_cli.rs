//! `cmux link sync push --socket PATH LOCAL REMOTE`: copies a folder (a git
//! working copy with its repository) to a Cloud machine's home through the
//! machine daemon's `fs-v1` ops (Move to Cloud, cmuxterm-hq#1874 slice 2).
//! `--socket` is the machine daemon's socket as this Mac reaches it (the
//! machine link's local socket); `REMOTE` is an absolute folder under the
//! machine's home. What goes is in [`local`]; git's loose objects go as
//! packs ([`packs`]). `cmux link sync pull` brings
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
//! A symlink whose target stays inside the folder is kept as a symlink both
//! ways, its text in the manifest's `links` ([`links`]); one pointing
//! outside, at nothing or into a repository folder is skipped and named.
//! A machine without `fs-symlink-v1` gets none, each named as skipped.
//!
//! Small files are written several at once, each on a connection of its
//! own ([`CONNECTIONS`], `CMUX_SYNC_PUSH_CONNECTIONS`); a file over
//! [`ALONE_BYTES`] is written after them, alone. The first failed write
//! stops new ones; those under way finish and are recorded.
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
mod history;
mod links;
mod local;
mod merge;
mod names;
mod packs;
mod place;
mod pull;
mod remote;
mod seed_pull;

/// `cmux link seed pull`'s engine ([`super::seed_cli`] is its CLI).
pub(super) use seed_pull::{
    SeedBase, SeedPulled, failure_code as seed_pull_failure_code, is_sha, seed_pull,
};
mod skips;
mod store;

pub(crate) use store::{Config as StoreConfig, configure as configure_store};

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

const USAGE: &str = "usage: cmux link sync push|pull --socket PATH [--store PLATFORM|default] LOCAL_FOLDER REMOTE_FOLDER\n       (--store: through the content-addressed store, the cmux credential on stdin)\n       cmux link sync history|undo LOCAL_FOLDER REMOTE_FOLDER\n       cmux link sync restore LOCAL_FOLDER REMOTE_FOLDER SNAPSHOT";

/// What the machine holds of earlier pushes; this Mac keeps a copy
/// ([`base`]), which is what a pull trusts.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
struct Manifest {
    version: u32,
    files: BTreeMap<String, Pushed>,
    /// The git state the push left; None outside git and from older pushes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    git: Option<git_back::GitBase>,
    /// The symlinks kept as symlinks ([`links`]), by path; none from older
    /// pushes.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    links: BTreeMap<String, Linked>,
}

/// A symlink the sync keeps: its text on the machine, relative and inside
/// the folder, and this Mac's own text when that differs (an absolute one
/// the push wrote relative), which is what a pull compares this Mac's with.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct Linked {
    target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    here: Option<String>,
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
    /// The content-addressed store's part ([`store`]), when one was asked for.
    pub(super) store: Option<serde_json::Value>,
}

impl Summary {
    pub(super) fn json(&self) -> serde_json::Value {
        let mut line = json!({
            "written": self.written,
            "unchanged": self.unchanged,
            "deleted": self.deleted,
            "skipped": self.skipped,
            "bytes": self.bytes,
            "skipped_files": if self.skipped_files.is_null() { json!([]) } else { self.skipped_files.clone() },
            "skipped_counts": if self.skipped_counts.is_null() { json!({}) } else { self.skipped_counts.clone() },
        });
        if let Some(store) = &self.store {
            line.set("store", store.clone());
        }
        line
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
/// Connections a push writes small files on at once, unless
/// `CMUX_SYNC_PUSH_CONNECTIONS` says otherwise (1 to [`MOST_CONNECTIONS`]).
const CONNECTIONS: usize = 8;
const MOST_CONNECTIONS: usize = 64;
/// A file bigger than this is written alone, after the small ones.
const ALONE_BYTES: u64 = 4 * 1024 * 1024;

/// How many connections a push writes small files on at once.
fn connections() -> usize {
    std::env::var("CMUX_SYNC_PUSH_CONNECTIONS")
        .ok()
        .and_then(|value| value.trim().parse::<usize>().ok())
        .unwrap_or(CONNECTIONS)
        .clamp(1, MOST_CONNECTIONS)
}

/// One file a push writes.
struct Job {
    relative: String,
    target: String,
    file: LocalFile,
    sha256: String,
    bytes: u64,
    /// What is at the target, from its folder's listing, when every write
    /// is no-follow; None: asked right before the write.
    found: Option<Option<String>>,
}

/// What a push needs to save its record partway.
struct Saving<'a> {
    manifest_path: &'a str,
    previous: &'a Manifest,
    listed: &'a BTreeMap<String, LocalFile>,
}

/// What a push has done so far: its answer, its record and its progress.
struct Tally<'a> {
    summary: Summary,
    next: Manifest,
    done: Progress,
    progress: Option<&'a mut dyn FnMut(Progress)>,
    save_every_files: u64,
    /// Files and bytes written since the record was last saved.
    since_save: (u64, u64),
}

impl Tally<'_> {
    fn step(&mut self, bytes: u64) {
        self.done.files_done += 1;
        self.done.bytes_done += bytes;
        if let Some(report) = self.progress.as_mut() {
            report(self.done);
        }
    }

    fn unchanged(&mut self, relative: &str, pushed: &Pushed, bytes: u64) {
        self.summary.unchanged += 1;
        self.next.files.insert(relative.to_string(), pushed.clone());
        self.step(bytes);
    }

    /// Records a file that landed as `revision`, and saves the record
    /// partway when it is due ([`save_partway`]).
    fn written(
        &mut self,
        job: Job,
        revision: String,
        remote: &mut Remote,
        saving: &Saving<'_>,
    ) -> anyhow::Result<()> {
        let bytes = job.bytes;
        self.summary.written += 1;
        self.summary.bytes += bytes;
        let pushed = Pushed { sha256: job.sha256, permissions: job.file.permissions, revision };
        self.next.files.insert(job.relative, pushed);
        self.since_save = (self.since_save.0 + 1, self.since_save.1 + bytes);
        if self.since_save.0 >= self.save_every_files || self.since_save.1 >= SAVE_EVERY_BYTES {
            save_partway(remote, saving.manifest_path, saving.previous, &self.next, saving.listed)?;
            self.since_save = (0, 0);
        }
        self.step(bytes);
        Ok(())
    }
}

/// Writes `jobs` on up to `connections` connections of their own, each
/// opened on its first job; `landed` hears each write's outcome, on this
/// thread, as it comes. The first error `landed` answers stops new writes,
/// the ones under way finish (and are still heard), and that error is the
/// answer.
fn write_parallel(
    socket: &Path,
    remote_root: &str,
    jobs: Vec<Job>,
    connections: usize,
    landed: &mut dyn FnMut(Job, anyhow::Result<String>) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    use std::sync::atomic::{AtomicBool, Ordering};
    let workers = connections.min(jobs.len());
    if workers == 0 {
        return Ok(());
    }
    let queue = std::sync::Mutex::new(jobs.into_iter());
    let stop = AtomicBool::new(false);
    let (sent, results) = std::sync::mpsc::channel::<(Job, anyhow::Result<String>)>();
    std::thread::scope(|scope| {
        for _ in 0..workers {
            let sent = sent.clone();
            let (queue, stop) = (&queue, &stop);
            scope.spawn(move || {
                let mut remote: Option<Remote> = None;
                let mut seen = BTreeMap::new();
                while !stop.load(Ordering::Relaxed) {
                    let Some(job) = queue.lock().ok().and_then(|mut jobs| jobs.next()) else {
                        break;
                    };
                    let written = write_on(&mut remote, &mut seen, socket, remote_root, &job);
                    if sent.send((job, written)).is_err() {
                        break;
                    }
                }
            });
        }
        drop(sent);
        let mut failed = None;
        for (job, written) in results {
            if let Err(error) = landed(job, written) {
                stop.store(true, Ordering::Relaxed);
                failed.get_or_insert(error);
            }
        }
        failed.map_or(Ok(()), Err)
    })
}

/// Writes `job` on `remote`, connecting it first when it is not yet.
/// Writes `job` on `remote`, connecting it first when it is not yet;
/// `seen` is that connection's own record of which folders below
/// `remote_root` are symlinks ([`write_checked`]).
fn write_on(
    remote: &mut Option<Remote>,
    seen: &mut BTreeMap<String, bool>,
    socket: &Path,
    remote_root: &str,
    job: &Job,
) -> anyhow::Result<String> {
    if remote.is_none() {
        *remote = Some(Remote::connect_negotiated(socket)?);
    }
    let Some(remote) = remote.as_mut() else { anyhow::bail!("no connection to the machine") };
    write_checked(remote, seen, remote_root, job)
}

/// Writes `job` unless a folder on the way to it below `remote_root` is a
/// symlink on the machine ([`LinkInTheWay`]): checked on the connection
/// that writes, right before its first write into each folder.
fn write_checked(
    remote: &mut Remote,
    seen: &mut BTreeMap<String, bool>,
    remote_root: &str,
    job: &Job,
) -> anyhow::Result<String> {
    let mut ignored = || {};
    if let Some(found) = job.found.as_ref().filter(|_| remote.no_follow()) {
        // The machine itself refuses a symlink anywhere on the path.
        return write_found(remote, &job.target, found.as_deref(), &job.file, &mut ignored);
    }
    let (parent, _) = remote::split(&job.target)?;
    if through_link(remote, remote_root, parent, seen)? {
        return Err(LinkInTheWay.into());
    }
    write_with_progress(remote, &job.target, &job.file, &mut ignored)
}

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
    if let Some(too_big) = error.downcast_ref::<TooBig>() {
        return ("folder_too_big".to_string(), too_big.to_string());
    }
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
    if let Some(code) = run_history(args) {
        return code;
    }
    let Some((action, socket, local, remote, store)) = parse(args) else {
        eprintln!("{USAGE}");
        return 64;
    };
    if let Some(store) = store
        && let Err(error) = store_from_stdin(&store, &mut std::io::stdin().lock())
    {
        println!("{}", json!({ "ok": false, "error": error, "error_code": "unauthorized" }));
        return 1;
    }
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
    match pull::pull_kept(socket, local, remote_root, keep_new, false) {
        Ok(pull::Pulled::Done(summary)) => Back::Done(summary),
        Ok(pull::Pulled::Conflict(conflicts, reasons, _)) => Back::Conflict(conflicts, reasons),
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
        Ok(pull::Pulled::Conflict(conflicts, reasons, _)) => Back::Conflict(conflicts, reasons),
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
    let mut remote = Remote::connect_negotiated(socket)?;
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
    let mut remote = Remote::connect_negotiated(socket)?;
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
        Ok(pull::Pulled::Conflict(conflicts, reasons, merge_files)) => {
            let mut error = format!(
                "{} changed both here and on the machine; nothing was brought back",
                conflicts.join(", ")
            );
            if !reasons.is_empty() {
                error = format!("{error} ({})", reasons.join("; "));
            }
            json!({ "ok": false, "error": error, "error_code": "sync_conflict",
                    "conflicts": conflicts, "merge_files": merge_files })
        }
        Err(error) => json!({ "ok": false, "error": format!("{error:#}"),
                              "error_code": pull::failure_code(&error) }),
    };
    println!("{line}");
    1
}

/// `history`, `undo` and `restore`: this Mac's snapshots of a synced
/// folder ([`history`]); no machine is reached. None for another action.
fn run_history(args: &[String]) -> Option<i32> {
    let [action, rest @ ..] = args else { return None };
    if !matches!(action.as_str(), "history" | "undo" | "restore") {
        return None;
    }
    let usage = || {
        eprintln!("{USAGE}");
        Some(64)
    };
    if rest.iter().any(|arg| arg.starts_with('-')) {
        return usage();
    }
    let (local, remote, which) = match (action.as_str(), rest) {
        ("history" | "undo", [local, remote]) => (local, remote, history::Which::Undo),
        ("restore", [local, remote, seq]) => match seq.parse() {
            Ok(seq) => (local, remote, history::Which::Seq(seq)),
            Err(_) => return usage(),
        },
        _ => return usage(),
    };
    if !remote.starts_with('/') {
        return usage();
    }
    let remote = remote.trim_end_matches('/');
    let local = PathBuf::from(local);
    let answer = if action == "history" {
        history::history_line(&local, remote)
    } else {
        history::restore(&local, remote, &which)
    };
    let line = match answer {
        Ok(line) => {
            println!("{line}");
            return Some(0);
        }
        Err(error) => match error.downcast_ref::<history::Refused>() {
            Some(refused) => json!({ "ok": false, "error": refused.error,
                                     "error_code": refused.code, "paths": refused.paths }),
            None => json!({ "ok": false, "error": format!("{error:#}"),
                            "error_code": "sync_failed" }),
        },
    };
    println!("{line}");
    Some(1)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Action {
    Push,
    Pull,
}

/// Turns the store on for this process ([`store::configure`]): `platform`
/// is the cmux platform's origin, or `default` for the usual one
/// ([`crate::cli::platform_origin`]); the cmux credential is the first line
/// of `stdin`.
pub(crate) fn store_from_stdin(
    platform: &str,
    stdin: &mut dyn std::io::BufRead,
) -> Result<(), String> {
    let mut credential = String::new();
    if stdin.read_line(&mut credential).is_err() || credential.trim().is_empty() {
        return Err("--store needs the cmux credential on stdin".into());
    }
    let env = |name: &str| std::env::var(name).ok();
    let flag = (platform != "default").then_some(platform);
    let origin = crate::cli::platform_origin(flag, &env)?;
    configure_store(StoreConfig { origin, credential: credential.trim().to_string() });
    Ok(())
}

type Parsed = (Action, PathBuf, PathBuf, String, Option<String>);

fn parse(args: &[String]) -> Option<Parsed> {
    let [action, rest @ ..] = args else { return None };
    let action = match action.as_str() {
        "push" => Action::Push,
        "pull" => Action::Pull,
        _ => return None,
    };
    let mut socket = None;
    let mut store = None;
    let mut positional = Vec::new();
    let mut rest = rest.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--socket" => socket = Some(PathBuf::from(rest.next()?)),
            "--store" if action == Action::Push => store = Some(rest.next()?.clone()),
            flag if flag.starts_with('-') => return None,
            value => positional.push(value),
        }
    }
    let [local, remote] = positional.as_slice() else { return None };
    if !remote.starts_with('/') {
        return None;
    }
    Some((action, socket?, PathBuf::from(local), remote.trim_end_matches('/').to_string(), store))
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
    // A share of files (`cmux link access`) takes no symlink.
    if files_only {
        for relative in std::mem::take(&mut set.links).into_keys() {
            set.skips.note(&relative, skips::Why::SymlinkInside);
        }
    }
    let git_record = set.git && !files_only;
    let manifest_name = if git_record { ".git/cmux-sync.json" } else { ".cmux-sync.json" };
    // A pull's conflict merges stay here, and so does anything by that name.
    let merges: Vec<String> = set
        .files
        .keys()
        .chain(set.links.keys())
        .filter(|relative| merge::is_conflict_file(relative))
        .cloned()
        .collect();
    for relative in merges {
        set.files.remove(&relative);
        set.links.remove(&relative);
        set.skips.note(&relative, skips::Why::ConflictMerge);
    }
    // The manifest's own name is never pushed over it, as a file or a symlink.
    if set.files.remove(manifest_name).is_some() | set.links.remove(manifest_name).is_some() {
        set.skips.note(manifest_name, skips::Why::Reserved);
    }
    // Loose objects go as packs ([`packs`]).
    if git_record {
        let dirs = local::GitDirs::of(&local)?.context("the folder is no longer in git")?;
        packs::pack_loose(&mut set.files, &dirs.common, &base::packs_dir(&local, remote_root)?)?;
    }
    set.skips.unnamed(set.skipped);
    let (skipped_files, skipped_counts) = set.skips.json();
    let mut summary =
        Summary { skipped: set.skips.total(), skipped_files, skipped_counts, ..Summary::default() };
    let done = Progress {
        files_total: set.files.len() as u64,
        bytes_total: set.files.values().map(|file| size(file).unwrap_or(0)).sum(),
        ..Progress::default()
    };
    if let Some(report) = progress.as_mut() {
        report(done);
    }
    // What a pull compares the machine's branch and staged changes with.
    let git = if git_record { Some(git_back::base_of(&local)?) } else { None };
    let mut remote = Remote::connect_negotiated(socket)?;
    remote.mkdir_all(remote_root)?;
    // A store fetch of an earlier push may still be running there: it stops
    // before this push deletes or writes anything.
    let served = store::fetch_served(socket);
    let left = match served {
        Some(true) => store::fence(&mut remote, remote_root)?,
        Some(false) => store::Left::default(),
        None => store::fence_unknown(&mut remote, remote_root)?,
    };
    let fetch_served = served == Some(true);
    let manifest_path = format!("{remote_root}/{manifest_name}");
    let mut previous: Manifest = remote
        .read(&manifest_path)?
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    // A key that is not a plain relative path (empty, absolute, `.` or `..`
    // parts) names nothing this push made: it is dropped, never deleted.
    previous.files.retain(|relative, _| plain_relative(relative));
    previous.links.retain(|relative, _| plain_relative(relative));
    let mut listings = Listings::default();
    // A file an earlier store fetch wrote may be in no manifest (its push
    // failed after the fetch wrote). One the machine still has as that fetch
    // left it counts as this push's, so one gone from the tree is deleted
    // below and one still in it is rewritten. One the manifest has at a
    // revision a fetch left is already recorded; one changed since (a later
    // link write, or the machine's own edit) is not taken over.
    let prefix = format!("{remote_root}/");
    for (path, revisions) in &left.written {
        let Some(relative) = path.strip_prefix(&prefix) else { continue };
        if !plain_relative(relative)
            || previous
                .files
                .get(relative)
                .is_some_and(|pushed| revisions.contains(&pushed.revision))
        {
            continue;
        }
        let Some(current) = listings.revision(&mut remote, path)? else { continue };
        if revisions.contains(&current) {
            previous.files.insert(
                relative.to_owned(),
                Pushed { sha256: String::new(), permissions: 0, revision: current },
            );
        }
    }
    // A folder too big for the machine stops here, before any file goes. A
    // file the machine already holds is rewritten in place and needs no new
    // room; a daemon too old to name its free space is not asked.
    let needed = set
        .files
        .iter()
        .filter(|(relative, _)| !previous.files.contains_key(*relative))
        .map(|(_, file)| size(file).unwrap_or(0))
        .fold(0, u64::saturating_add);
    if let Some(free) = remote.stat(remote_root)?.and_then(|stat| stat["available_bytes"].as_u64())
        && needed > free
    {
        return Err(TooBig { needed, free }.into());
    }
    let mut links = LinkSync::default();

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
    // A symlink this push made that is gone here (or points elsewhere now)
    // goes, while the machine still has it as this push left it.
    for (relative, linked) in &previous.links {
        if set.links.get(relative).map(|kept| &kept.target) == Some(&linked.target) {
            continue;
        }
        let target = format!("{remote_root}/{relative}");
        if links.ours(&mut remote, &target, &linked.target)? {
            remote.delete(std::slice::from_ref(&target))?;
            if !set.links.contains_key(relative) && !set.files.contains_key(relative) {
                summary.deleted += 1;
            }
        }
    }
    listings.clear();

    let mut made: BTreeSet<String> = BTreeSet::new();
    let mut folder_links: BTreeMap<String, bool> = BTreeMap::new();
    let mut tally = Tally {
        summary,
        next: Manifest { version: 1, files: BTreeMap::new(), git, links: BTreeMap::new() },
        save_every_files: SAVE_EVERY_FILES.max(done.files_total / 20),
        since_save: (0, 0),
        done,
        progress,
    };
    // What is unchanged is settled here; what is not becomes a write, its
    // folder made first (once each). Through the store, the writes are
    // gathered and the machine fetches them after the loop.
    let via_store = store::usable(fetch_served);
    let (mut small, mut alone, mut deferred) = (Vec::new(), Vec::new(), Vec::new());
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
            tally.unchanged(relative, pushed, bytes);
            continue;
        }
        // A symlink of the machine's on the way to it: the write would
        // land wherever that link points, so this Mac's file stays.
        if through_link(&mut remote, remote_root, parent, &mut folder_links)? {
            set.skips.note(relative, skips::Why::SymlinkTaken);
            tally.step(bytes);
            continue;
        }
        // With no-follow writes the folder's listing says what is in the
        // way (one fs.list a folder, not one fs.stat a file): a symlink put
        // there since is refused by the machine itself. Otherwise the
        // connection that writes asks right before its write.
        let found =
            if remote.no_follow() { Some(listings.kind(&mut remote, &target)?) } else { None };
        if made.insert(parent.to_string()) {
            remote.mkdir_all(parent)?;
        }
        let job =
            Job { relative: relative.clone(), target, file: file.clone(), sha256, bytes, found };
        if via_store {
            deferred.push(job);
        } else if bytes > ALONE_BYTES {
            alone.push(job);
        } else {
            small.push(job);
        }
    }
    // Through the store, the machine fetches first; what it did not write
    // goes over the link below, like every other write.
    let fetched = if via_store {
        Some(send_through_store(
            &mut remote,
            remote_root,
            &deferred,
            tally.done,
            &mut tally.progress,
        )?)
    } else {
        None
    };
    let saving = Saving { manifest_path: &manifest_path, previous: &previous, listed: &set.files };
    let named = &mut set.skips;
    // What became of one write: recorded, or (a symlink of the machine's at
    // its path, which a file written there would go through) skipped.
    let mut landed = |job: Job, written: anyhow::Result<String>, remote: &mut Remote| match written
    {
        Ok(revision) => tally.written(job, revision, remote, &saving),
        Err(error) if error.is::<LinkInTheWay>() => {
            named.note(&job.relative, skips::Why::SymlinkTaken);
            tally.step(job.bytes);
            Ok(())
        }
        Err(error) => Err(error),
    };
    // Small files go several at once, each connection its own write
    // stream; big ones after them, one at a time.
    write_parallel(socket, remote_root, small, connections(), &mut |job, written| {
        landed(job, written, &mut remote)
    })?;
    let mut seen = BTreeMap::new();
    for job in alone {
        let written = write_checked(&mut remote, &mut seen, remote_root, &job);
        landed(job, written, &mut remote)?;
    }
    let store_part = match fetched {
        Some((part, written)) => Some(finish_deferred(
            &mut remote,
            remote_root,
            deferred,
            written.as_ref(),
            part,
            &mut landed,
        )?),
        None => None,
    };
    let Tally { mut summary, mut next, .. } = tally;
    summary.store = store_part;
    // A link whose target is a link not made yet waits for the next pass;
    // passes go on while one makes something.
    let mut waiting: Vec<(&String, &Linked)> = set.links.iter().collect();
    let mut skipped: Vec<(String, skips::Why)> = Vec::new();
    loop {
        let mut again = Vec::new();
        skipped.clear();
        let mut placed_any = false;
        for (relative, kept) in waiting {
            let target = format!("{remote_root}/{relative}");
            match links.place(&mut remote, &target, &kept.target)? {
                Placed::Made => {
                    placed_any = true;
                    summary.written += 1;
                    next.links.insert(relative.clone(), kept.clone());
                }
                Placed::Already => {
                    placed_any = true;
                    summary.unchanged += 1;
                    next.links.insert(relative.clone(), kept.clone());
                }
                Placed::Skipped(skips::Why::SymlinkBroken) => {
                    again.push((relative, kept));
                    skipped.push((relative.clone(), skips::Why::SymlinkBroken));
                }
                Placed::Skipped(why) => skipped.push((relative.clone(), why)),
            }
        }
        if !placed_any || again.is_empty() {
            break;
        }
        // Only the ones that waited go round again.
        skipped.retain(|(_, why)| *why != skips::Why::SymlinkBroken);
        for (relative, why) in skipped.drain(..) {
            set.skips.note(&relative, why);
        }
        waiting = again;
    }
    for (relative, why) in skipped {
        set.skips.note(&relative, why);
    }
    // Links skipped since the summary began are named too.
    let (skipped_files, skipped_counts) = set.skips.json();
    summary.skipped = set.skips.total();
    summary.skipped_files = skipped_files;
    summary.skipped_counts = skipped_counts;

    let manifest = serde_json::to_vec(&next)?;
    remote
        .write(&manifest_path, &mut manifest.as_slice(), 0o600)
        .context("cannot save the sync manifest")?;
    store::forget(&mut remote, &left.jobs);
    // A pull's base is this copy, never the machine's.
    base::save(&local, remote_root, &next).context("cannot keep the sync record on this Mac")?;
    // What this push left, for `cmux link sync undo`: every file's blob this
    // Mac does not keep yet, and a snapshot ([`history`]). Neither can fail
    // the push.
    snapshot_push(&local, remote_root, &next, &set.files, git_record);
    Ok(summary)
}

/// Has the machine fetch the `deferred` files through the store
/// ([`store::send`]). Answers the summary's `store` part and what the machine
/// wrote (`None` when it wrote nothing: the store failed before it did, or
/// the files are too few bytes to be worth it); [`finish_deferred`] sends the
/// rest over the link.
fn send_through_store(
    remote: &mut Remote,
    remote_root: &str,
    deferred: &[Job],
    base: Progress,
    progress: &mut Option<&mut dyn FnMut(Progress)>,
) -> anyhow::Result<(serde_json::Value, Option<BTreeMap<String, String>>)> {
    let total: u64 = deferred.iter().map(|job| job.bytes).sum();
    if total < STORE_MIN_BYTES {
        // A store round trip costs more than these bytes over the link.
        return Ok((json!({"used": false, "reason": "small"}), None));
    }
    let pending: Vec<store::Pending<'_>> = deferred
        .iter()
        .map(|job| store::Pending {
            target: job.target.clone(),
            file: &job.file,
            sha256: job.sha256.clone(),
            size: job.bytes,
        })
        .collect();
    let sent = if pending.is_empty() {
        Ok(store::Sent::default())
    } else {
        store::send(remote, remote_root, &pending, &mut |bytes| {
            if let Some(report) = progress.as_mut() {
                report(Progress { bytes_done: base.bytes_done + bytes, ..base });
            }
        })
    };
    // The machine may still be writing: nothing goes over the link now.
    let sent = match sent {
        Err(error) if error.is::<store::Unsettled>() || error.is::<store::Superseded>() => {
            return Err(error);
        }
        other => other,
    };
    Ok(match sent {
        Ok(sent) => (
            json!({"used": true, "uploaded_bytes": sent.uploaded, "reused_bytes": sent.reused,
                   "fetched_files": sent.written.len()}),
            Some(sent.written),
        ),
        Err(error) => (json!({"used": false, "error": format!("{error:#}")}), None),
    })
}

/// Below this many bytes to write, a push goes over the link: the store's
/// plan, grant and fetch round trips cost more than the bytes themselves.
const STORE_MIN_BYTES: u64 = 1024 * 1024;

/// What becomes of one write: recorded, or skipped for a symlink in its way.
type Landed<'a> = dyn FnMut(Job, anyhow::Result<String>, &mut Remote) -> anyhow::Result<()> + 'a;

/// Records each deferred file: its revision on the machine when the store
/// wrote it (`written`, the revision its write left), or a write over the
/// link when it did not (`written` is `None` when the store wrote nothing).
fn finish_deferred(
    remote: &mut Remote,
    remote_root: &str,
    deferred: Vec<Job>,
    written: Option<&BTreeMap<String, String>>,
    mut part: serde_json::Value,
    landed: &mut Landed<'_>,
) -> anyhow::Result<serde_json::Value> {
    let mut direct = 0u64;
    let mut seen = BTreeMap::new();
    for job in deferred {
        let result = match written.and_then(|written| written.get(&job.target)).cloned() {
            Some(revision) => Ok(revision),
            None => {
                direct += 1;
                write_checked(remote, &mut seen, remote_root, &job)
            }
        };
        landed(job, result, remote)?;
    }
    part.set("direct_files", json!(direct));
    Ok(part)
}

/// Keeps the blobs and the snapshot of a push that left `next`.
fn snapshot_push(
    local: &Path,
    remote_root: &str,
    next: &Manifest,
    files: &BTreeMap<String, LocalFile>,
    git: bool,
) {
    let Ok(root) = place::Dir::open(local) else { return };
    for (relative, pushed) in &next.files {
        if history::is_worktree_path(relative)
            && matches!(files.get(relative).map(|file| &file.source), Some(Source::File(_)))
            && history::blob(&pushed.sha256).is_none()
        {
            history::keep_blob(&root, relative, &pushed.sha256);
        }
    }
    let git = if git { history::git_now(local) } else { None };
    // A push changes nothing here: nothing it records is ever put back.
    let _ = history::record(
        local,
        remote_root,
        "push",
        history::paths_of(next),
        git,
        None,
        history::Changed::default(),
    );
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
    let partway =
        Manifest { version: 1, files, git: previous.git.clone(), links: previous.links.clone() };
    let bytes = serde_json::to_vec(&partway)?;
    remote
        .write(manifest_path, &mut bytes.as_slice(), 0o600)
        .context("cannot save the sync manifest")?;
    Ok(())
}

/// What [`LinkSync::place`] did with one symlink.
enum Placed {
    Made,
    /// The machine already has it with this text.
    Already,
    Skipped(skips::Why),
}

/// The symlinks of one push on the machine, through `fs-symlink-v1`; once
/// the machine shows it lacks those ops, every symlink is skipped with why.
#[derive(Default)]
struct LinkSync {
    unsupported: bool,
}

impl LinkSync {
    /// Whether the machine's entry at `target` is a symlink with `text`.
    fn ours(&mut self, remote: &mut Remote, target: &str, text: &str) -> anyhow::Result<bool> {
        if self.unsupported || remote.kind(target)?.as_deref() != Some("symlink") {
            return Ok(false);
        }
        match remote.readlink(target) {
            Ok(found) => Ok(found.as_deref() == Some(text)),
            Err(error) if is_refusal(&error) => {
                self.unsupported |= remote::lacks_symlinks(&error);
                Ok(false)
            }
            Err(error) => Err(error),
        }
    }

    /// Makes the symlink `target` with `text` on the machine, unless it is
    /// there already. Something else there (the machine's own) stays.
    fn place(&mut self, remote: &mut Remote, target: &str, text: &str) -> anyhow::Result<Placed> {
        if self.unsupported {
            return Ok(Placed::Skipped(skips::Why::SymlinkUnsupported));
        }
        match remote.kind(target)?.as_deref() {
            None => {}
            Some("symlink") if self.ours(remote, target, text)? => return Ok(Placed::Already),
            // A folder that became a symlink here leaves an empty one.
            Some("dir") if remote.list(target)?.is_some_and(|entries| entries.is_empty()) => {
                remote.delete(&[target.to_string()])?;
            }
            _ if self.unsupported => return Ok(Placed::Skipped(skips::Why::SymlinkUnsupported)),
            _ => return Ok(Placed::Skipped(skips::Why::SymlinkTaken)),
        }
        let (parent, _) = remote::split(target)?;
        remote.mkdir_all(parent)?;
        match remote.symlink(target, text) {
            Ok(()) => Ok(Placed::Made),
            Err(error) if remote::refusal_code(&error) == Some("fs.exists") => {
                Ok(Placed::Skipped(skips::Why::SymlinkTaken))
            }
            // The daemon follows the text through the machine's own links.
            Err(error) if remote::refusal_code(&error) == Some("fs.permission_denied") => {
                Ok(Placed::Skipped(skips::Why::SymlinkOutside))
            }
            Err(error) if remote::refusal_code(&error) == Some("params.invalid") => {
                Ok(Placed::Skipped(skips::Why::SymlinkBroken))
            }
            Err(error) if is_refusal(&error) => {
                self.unsupported |= remote::lacks_symlinks(&error);
                Ok(Placed::Skipped(skips::Why::SymlinkUnsupported))
            }
            Err(error) => Err(error),
        }
    }
}

/// Writes `file` to `target`. An empty folder in the way (left by a folder
/// that became a file) is removed first; a folder with anything in it stays
/// and the write fails; a symlink there is [`LinkInTheWay`].
fn write_with_progress(
    remote: &mut Remote,
    target: &str,
    file: &LocalFile,
    progress: &mut dyn FnMut(),
) -> anyhow::Result<String> {
    // Asked right before each write, never from a listing read earlier: a
    // symlink the machine put there since must stop this file.
    let found = remote.kind(target)?;
    write_found(remote, target, found.as_deref(), file, progress)
}

/// [`write_with_progress`] with what is at `target` already known: from an
/// `fs.stat` just now, or, when every write is no-follow, from the folder's
/// listing (the machine then refuses a symlink that came since).
fn write_found(
    remote: &mut Remote,
    target: &str,
    found: Option<&str>,
    file: &LocalFile,
    progress: &mut dyn FnMut(),
) -> anyhow::Result<String> {
    // A folder from a listing is asked again before it goes: a symlink
    // swapped in since (to an empty folder, say) must not be deleted.
    let fresh = match found {
        Some("dir") if remote.no_follow() => remote.kind(target)?,
        found => found.map(str::to_string),
    };
    match fresh.as_deref() {
        Some("dir") if remote.list(target)?.is_some_and(|entries| entries.is_empty()) => {
            remote.delete(&[target.to_string()])?;
        }
        Some("symlink") => return Err(LinkInTheWay.into()),
        _ => {}
    }
    let mut reader = open(file)?;
    match remote.write_with_progress(target, &mut reader, file.permissions, progress) {
        Err(error) if remote::refusal_code(&error) == Some(remote::SYMLINK_IN_PATH) => {
            Err(LinkInTheWay.into())
        }
        written => written,
    }
}

/// Whether a folder of `parent` below `remote_root` is a symlink on the
/// machine (each folder looked at once per push, in `seen`).
fn through_link(
    remote: &mut Remote,
    remote_root: &str,
    parent: &str,
    seen: &mut BTreeMap<String, bool>,
) -> anyhow::Result<bool> {
    let Some(below) = parent.strip_prefix(remote_root) else { return Ok(false) };
    let mut folder = remote_root.to_string();
    for name in below.split('/').filter(|name| !name.is_empty()) {
        folder.push('/');
        folder.push_str(name);
        let is_link = match seen.get(&folder) {
            Some(is_link) => *is_link,
            None => {
                let kind = remote.kind(&folder)?;
                let is_link = kind.as_deref() == Some("symlink");
                seen.insert(folder.clone(), is_link);
                if kind.is_none() {
                    return Ok(false);
                }
                is_link
            }
        };
        if is_link {
            return Ok(true);
        }
    }
    Ok(false)
}

/// A symlink on the machine where a file would be written: never written
/// through.
#[derive(Debug)]
struct LinkInTheWay;

impl std::fmt::Display for LinkInTheWay {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a symlink is at that path on the machine")
    }
}

impl std::error::Error for LinkInTheWay {}

/// A relative path of plain names: no empty, `.` or `..` part.
fn plain_relative(relative: &str) -> bool {
    !relative.is_empty() && relative.split('/').all(|name| !matches!(name, "" | "." | ".."))
}

/// Folder listings of the machine, fetched once per folder.
#[derive(Default)]
struct Listings(BTreeMap<String, Listed>);

/// What one folder's listing gave.
enum Listed {
    /// Its entries; None when the folder is missing.
    Entries(Option<BTreeMap<String, RemoteEntry>>),
    /// Too many entries to list (`fs.too_large`): each target is asked with
    /// `fs.stat` instead.
    TooLarge,
}

impl Listings {
    /// The revision of the file at `target`; None when it is missing or not
    /// a file.
    fn revision(&mut self, remote: &mut Remote, target: &str) -> anyhow::Result<Option<String>> {
        Ok(self
            .entry(remote, target)?
            .filter(|entry| entry.kind == "file")
            .and_then(|entry| entry.revision))
    }

    /// The kind of the entry at `target` (`file`, `dir`, `symlink`, ...);
    /// None when it is missing.
    fn kind(&mut self, remote: &mut Remote, target: &str) -> anyhow::Result<Option<String>> {
        Ok(self.entry(remote, target)?.map(|entry| entry.kind))
    }

    fn entry(&mut self, remote: &mut Remote, target: &str) -> anyhow::Result<Option<RemoteEntry>> {
        let (parent, name) = remote::split(target)?;
        if !self.0.contains_key(parent) {
            let listed = match remote.list(parent) {
                Ok(entries) => Listed::Entries(entries),
                Err(error) if remote::refusal_code(&error) == Some("fs.too_large") => {
                    Listed::TooLarge
                }
                Err(error) => return Err(error),
            };
            self.0.insert(parent.to_string(), listed);
        }
        match self.0.get(parent) {
            Some(Listed::Entries(entries)) => {
                Ok(entries.as_ref().and_then(|entries| entries.get(name)).cloned())
            }
            Some(Listed::TooLarge) => Ok(remote.stat(target)?.map(|stat| {
                let text = |key: &str| stat.get(key).and_then(serde_json::Value::as_str);
                RemoteEntry {
                    kind: text("kind").unwrap_or_default().to_string(),
                    revision: text("revision").map(str::to_string),
                }
            })),
            None => Ok(None),
        }
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

/// A push whose new files need more room than the machine has left.
#[derive(Debug)]
pub(super) struct TooBig {
    needed: u64,
    free: u64,
}

impl std::fmt::Display for TooBig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "The folder needs {} on the Cloud machine, which has {} free",
            bytes_text(self.needed),
            bytes_text(self.free)
        )
    }
}

impl std::error::Error for TooBig {}

/// `bytes` in decimal units as Finder shows them: "980 bytes", "12 kB",
/// "12.8 GB".
fn bytes_text(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["kB", "MB", "GB", "TB", "PB"];
    if bytes < 1000 {
        return format!("{bytes} bytes");
    }
    // Tenths of the unit, rounded: exact in integers up to u64::MAX.
    let mut scaled = bytes;
    let mut unit = 0;
    while scaled >= 999_950 && unit < UNITS.len().saturating_sub(1) {
        scaled /= 1000;
        unit = unit.saturating_add(1);
    }
    let tenths = scaled.saturating_add(50) / 100;
    let (whole, tenth) = (tenths / 10, tenths % 10);
    let name = UNITS.get(unit).copied().unwrap_or("PB");
    if tenth == 0 { format!("{whole} {name}") } else { format!("{whole}.{tenth} {name}") }
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
