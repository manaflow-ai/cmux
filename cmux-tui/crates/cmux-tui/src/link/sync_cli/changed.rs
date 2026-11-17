//! Push-on-send: before a turn is sent to a Cloud chat whose folder came from
//! this Mac, only the files that changed here since the last push go
//! (`cmux link sync on-send`), and nothing at all, with no request to the
//! machine, when nothing changed.
//!
//! What changed comes from this Mac's watcher ([`super::watch`]): every push
//! of a chat's copy takes a mark from it before it lists the folder and keeps
//! that mark once it is done (`<state>/link-sync-watch/marks/`); the next
//! push-on-send asks for the paths changed since. With no watcher, another
//! session, an overflow or too many paths, the push rescans: the ordinary
//! push, never "nothing changed".
//!
//! A push of the changed paths ([`Only`]) lists the folder by the push's own
//! rules (so a skipped path never goes, and a file that a `.gitignore` edit
//! let in or left out is seen), then hashes, compares with the machine and
//! writes only what the watcher named, what is new or gone since the last
//! push, what changed its permissions, and what the push makes itself (packs,
//! cleaned git config). Every other file is recorded as the last push left
//! it, unread. The machine's record and this Mac's base copy end exactly as a
//! full push would leave them for those paths, so a pull after it merges
//! against the right base.
//!
//! A file the machine changed since the last push (its revision is not the
//! one the push recorded) is not written over: it is named in `conflicts`,
//! its record stays the last push's, so Bring Back Local's three-way merge
//! sees both edits; it is looked at again by every push-on-send until it is
//! settled.
//!
//! The send is never held past `--within`: the push runs in a detached
//! process of its own (one at a time a folder, under a lock), and an answer
//! past the bound is `arriving`, with a note for the agent.

use std::collections::BTreeSet;
use std::io::{BufRead as _, BufReader};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::local::{LocalFile, LocalSet, Source};
use super::watch::{self, Mark, Place, Seen};
use super::{Manifest, base, hash};

/// How long a question to the watcher may take, its start included.
const ASK_WAIT: Duration = Duration::from_millis(1500);
/// The bound of a send when the caller gives none.
pub(crate) const WITHIN: Duration = Duration::from_secs(3);

/// The paths a push of what changed looks at; all of them on a rescan.
pub(in crate::link) struct Only {
    root: PathBuf,
    /// Relative paths (files or folders); None: every path (a rescan that
    /// still keeps the machine's own edits).
    paths: Option<BTreeSet<String>>,
}

impl Only {
    pub(super) fn new(root: &Path, paths: Option<BTreeSet<String>>) -> Self {
        Self { root: root.to_path_buf(), paths }
    }

    /// Whether `relative` or a folder above it changed.
    pub(super) fn touches_path(&self, relative: &str) -> bool {
        let Some(paths) = &self.paths else { return true };
        let mut at = relative;
        loop {
            if paths.contains(at) {
                return true;
            }
            match at.rsplit_once('/') {
                Some((parent, _)) => at = parent,
                None => return false,
            }
        }
    }

    /// Whether the push looks at `file`, listed as `relative`: what the watcher
    /// named, and anything not read from its own path in the folder (made
    /// here, or from a git folder outside it), but a pack of git's, whose name
    /// is its content.
    pub(super) fn touches(&self, relative: &str, file: &LocalFile) -> bool {
        if self.touches_path(relative) {
            return true;
        }
        match &file.source {
            Source::File(path) if *path == self.root.join(relative) => false,
            Source::File(path) => match path.strip_prefix(&self.root) {
                Ok(inside) => inside.to_str().is_none_or(|inside| self.touches_path(inside)),
                Err(_) => !is_pack(path),
            },
            Source::Bytes(_) | Source::Checked(_) => true,
        }
    }

    /// Whether `set`, as listed, is what the last push left (`base`, this
    /// Mac's copy of its record): nothing new, gone or with other permissions,
    /// and every file looked at hashes as it was. Reads only those files.
    pub(super) fn nothing_to_send(&self, base: &Manifest, set: &LocalSet) -> bool {
        if self.paths.is_none() || base.links != set.links || base.files.len() != set.files.len() {
            return false;
        }
        set.files.iter().all(|(relative, file)| {
            base.files.get(relative).is_some_and(|pushed| {
                pushed.permissions == file.permissions
                    && (!self.touches(relative, file)
                        || hash(file).is_ok_and(|sha| sha == pushed.sha256))
            })
        })
    }
}

/// A git pack (`pack-<id>.pack`, `.idx`, `.rev`), never changed once made.
fn is_pack(path: &Path) -> bool {
    path.file_name().and_then(|name| name.to_str()).is_some_and(|name| name.starts_with("pack-"))
}

/// What this Mac keeps of a folder's last push for the next push-on-send.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Kept {
    pub(super) mark: Option<Mark>,
    /// Paths the machine had changed when this Mac's changed too: looked at again.
    #[serde(default)]
    pub(super) conflicts: BTreeSet<String>,
}

fn kept_path(place: &Place, local: &Path, remote_root: &str) -> PathBuf {
    place.dir.join("marks").join(format!("{}.json", base::key(local, remote_root)))
}

pub(super) fn load(place: &Place, local: &Path, remote_root: &str) -> Kept {
    std::fs::read(kept_path(place, local, remote_root))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

pub(super) fn keep(place: &Place, local: &Path, remote_root: &str, kept: &Kept) {
    use std::os::unix::fs::DirBuilderExt as _;
    let path = kept_path(place, local, remote_root);
    let Some(dir) = path.parent() else { return };
    if std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).is_err() {
        return;
    }
    let part = path.with_extension(format!("{}.part", std::process::id()));
    if serde_json::to_vec(kept).is_ok_and(|bytes| std::fs::write(&part, bytes).is_ok()) {
        let _ = std::fs::rename(&part, &path);
    }
}

/// Forgets the mark (a push is under way: until it is done, any mark is wrong).
pub(super) fn forget(place: &Place, local: &Path, remote_root: &str) {
    let mut kept = load(place, local, remote_root);
    if kept.mark.take().is_some() {
        keep(place, local, remote_root, &kept);
    }
}

/// One push into a folder pair at a time, across processes.
pub(super) struct PairLock(Option<std::fs::File>);

pub(super) fn lock(place: Option<&Place>, local: &Path, remote_root: &str) -> PairLock {
    use std::os::unix::fs::DirBuilderExt as _;
    let Some(place) = place else { return PairLock(None) };
    let dir = place.dir.join("locks");
    if std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir).is_err() {
        return PairLock(None);
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(dir.join(format!("{}.lock", base::key(local, remote_root))));
    PairLock(file.ok().filter(|file| file.lock().is_ok()))
}

impl Drop for PairLock {
    fn drop(&mut self) {
        if let Some(file) = &self.0 {
            let _ = file.unlock();
        }
    }
}

/// Whether the watcher's view of `local` can be trusted: a folder whose `.git`
/// is a file (a linked worktree, a submodule) keeps its git state outside it.
fn watchable(local: &Path) -> bool {
    std::fs::symlink_metadata(local.join(".git")).map_or(true, |meta| meta.is_dir())
}

/// What changed in `local` since the push `kept` names, as the watcher says.
fn seen(place: Option<&Place>, local: &Path, kept: &Kept) -> Seen {
    let Some(place) = place else {
        return Seen::Rescan { why: "no watcher on this Mac".into(), mark: None };
    };
    let seen = watch::ask(place, local, kept.mark.as_ref(), ASK_WAIT);
    if watchable(local) {
        return seen;
    }
    let mark = seen.mark().cloned();
    Seen::Rescan { why: "the folder's git state is outside it".into(), mark }
}

/// The ordinary push's mark: taken before it lists, kept once it is done.
pub(super) fn before_push(local: &Path, remote_root: &str) -> Option<(Place, Option<Mark>)> {
    let place = Place::here()?;
    forget(&place, local, remote_root);
    let mark = seen(Some(&place), local, &Kept::default()).mark().cloned();
    Some((place, mark))
}

pub(super) fn after_push(
    taken: Option<(Place, Option<Mark>)>,
    local: &Path,
    remote_root: &str,
    conflicts: &[String],
) {
    let Some((place, mark)) = taken else { return };
    let kept = Kept { mark, conflicts: conflicts.iter().cloned().collect() };
    keep(&place, local, remote_root, &kept);
}

/// `cmux link sync on-send`'s answer for `local` (canonical) pushed to
/// `remote_root`: `unchanged` at once when the watcher saw nothing, else the
/// answer of `worker` (which pushes, [`run_worker`]) if it comes within
/// `within`, else `arriving` (the worker goes on).
pub(super) fn on_send_with(
    place: Option<&Place>,
    local: &Path,
    remote_root: &str,
    within: Duration,
    worker: &dyn Fn() -> anyhow::Result<std::sync::mpsc::Receiver<Value>>,
) -> Value {
    if let Some(place) = place {
        let kept = load(place, local, remote_root);
        if kept.conflicts.is_empty()
            && let Seen::Paths { paths, .. } = seen(Some(place), local, &kept)
            && paths.is_empty()
        {
            return json!({"ok": true, "state": "unchanged"});
        }
    }
    let answers = match worker() {
        Ok(answers) => answers,
        Err(error) => {
            return json!({"ok": false, "error": format!("cannot start the push: {error:#}"),
                          "error_code": "sync_failed"});
        }
    };
    match answers.recv_timeout(within) {
        Ok(answer) => answer,
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            json!({"ok": true, "state": "arriving", "notice": notice(local, remote_root)})
        }
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            json!({"ok": false, "error": "the push ended without an answer",
                   "error_code": "sync_failed"})
        }
    }
}

/// The note the agent gets with a turn whose files are still on their way.
pub(super) fn notice(local: &Path, remote_root: &str) -> String {
    let name = local.file_name().and_then(|name| name.to_str()).unwrap_or("the folder");
    format!(
        "Files the person changed on their Mac in {name} since the last message are still \
         arriving in {remote_root}. A file read in the next few seconds may still be the \
         older copy: if something the person mentions looks out of date, wait a moment and \
         read it again."
    )
}

/// The push-on-send itself, under the folder's lock: asks the watcher again
/// (a push before this one may have sent it all), then pushes the paths it
/// names, or rescans; `push` is the push of a copy or the delta of a seed
/// ([`super::super::seed_cli::push_since_last_changed`]), answering the copy's
/// summary when there is one.
pub(super) fn run_worker(
    place: Option<&Place>,
    local: &Path,
    remote_root: &str,
    push: &dyn Fn(&Only) -> anyhow::Result<Pushed>,
) -> Value {
    let _lock = lock(place, local, remote_root);
    let kept = place.map(|place| load(place, local, remote_root)).unwrap_or_default();
    let (paths, mark) = match seen(place, local, &kept) {
        Seen::Paths { mut paths, mark } => {
            if paths.is_empty() && kept.conflicts.is_empty() {
                return json!({"ok": true, "state": "unchanged"});
            }
            paths.extend(kept.conflicts.iter().cloned());
            (Some(paths), Some(mark))
        }
        Seen::Rescan { mark, .. } => (None, mark),
    };
    let rescan = paths.is_none();
    if let Some(place) = place {
        forget(place, local, remote_root);
    }
    match push(&Only::new(local, paths)) {
        Ok(pushed) => {
            if let Some(place) = place {
                let conflicts = pushed.conflicts.iter().cloned().collect();
                keep(place, local, remote_root, &Kept { mark, conflicts });
            }
            let state =
                if pushed.unchanged && pushed.conflicts.is_empty() { "unchanged" } else { "sent" };
            json!({"ok": true, "state": state, "mode": pushed.mode, "rescan": rescan,
                   "written": pushed.written, "deleted": pushed.deleted,
                   "conflicts": pushed.conflicts})
        }
        Err(error) => super::super::seed_cli::failure(&error),
    }
}

/// What a push-on-send's push did.
#[derive(Debug, Default)]
pub(in crate::link) struct Pushed {
    pub(in crate::link) mode: &'static str,
    pub(in crate::link) unchanged: bool,
    pub(in crate::link) written: u64,
    pub(in crate::link) deleted: u64,
    pub(in crate::link) conflicts: Vec<String>,
}

/// `cmux link sync on-send --socket PATH [--within MS] LOCAL REMOTE`.
pub(super) fn run(args: &[String]) -> i32 {
    let usage =
        "usage: cmux link sync on-send --socket PATH [--within MS] LOCAL_FOLDER REMOTE_FOLDER";
    let Some((socket, within, local, remote)) = parse(args) else {
        eprintln!("{usage}");
        return 64;
    };
    let answer = match on_send(&socket, &local, &remote, within) {
        Ok(answer) => answer,
        Err(error) => {
            json!({"ok": false, "error": format!("{error:#}"), "error_code": "sync_failed"})
        }
    };
    println!("{answer}");
    i32::from(answer["ok"] != json!(true))
}

/// `cmux link sync on-send-run --socket PATH LOCAL REMOTE`: [`on_send`]'s
/// detached worker; one line on stdout once done, which may go nowhere.
pub(super) fn run_detached(args: &[String]) -> i32 {
    let Some((socket, _, local, remote)) = parse(args) else { return 64 };
    let Ok(local) = std::fs::canonicalize(&local) else { return 1 };
    let place = Place::here();
    let answer = run_worker(place.as_ref(), &local, &remote, &|only| {
        // A folder `cmux link sync push` copied has no seed record, only the copy's own.
        if !super::super::seed_cli::has_record(&local, &remote)
            && base::kept(&local, &remote).is_ok_and(|kept| kept.is_some())
        {
            let summary = super::push_changed(&socket, &local, &remote, only)?;
            return Ok(Pushed {
                mode: "copy",
                unchanged: summary.written == 0 && summary.deleted == 0,
                written: summary.written,
                deleted: summary.deleted,
                conflicts: summary.conflicts,
            });
        }
        super::super::seed_cli::push_since_last_changed(&socket, &local, &remote, only)
    });
    // The asker may be gone: a line nobody reads is fine.
    let _ = std::io::Write::write_all(&mut std::io::stdout(), format!("{answer}\n").as_bytes());
    i32::from(answer["ok"] != json!(true))
}

fn parse(args: &[String]) -> Option<(PathBuf, Duration, PathBuf, String)> {
    let mut socket = None;
    let mut within = WITHIN;
    let mut positional = Vec::new();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--socket" => socket = Some(PathBuf::from(rest.next()?)),
            "--within" => within = Duration::from_millis(rest.next()?.parse().ok()?),
            flag if flag.starts_with('-') => return None,
            value => positional.push(value),
        }
    }
    let [local, remote] = positional.as_slice() else { return None };
    if !remote.starts_with('/') {
        return None;
    }
    Some((socket?, within, PathBuf::from(local), remote.trim_end_matches('/').to_string()))
}

/// Push-on-send of `local` to `remote_root` on the machine `socket` reaches,
/// bounded by `within` (module docs); its answer line.
pub(crate) fn on_send(
    socket: &Path,
    local: &Path,
    remote_root: &str,
    within: Duration,
) -> anyhow::Result<Value> {
    let local = std::fs::canonicalize(local)?;
    let place = Place::here();
    let worker = || -> anyhow::Result<std::sync::mpsc::Receiver<Value>> {
        let program = std::env::current_exe()?;
        let mut child = cmux_process::Command::new(program);
        child
            .args(["link", "sync", "on-send-run", "--socket"])
            .arg(socket)
            .arg(&local)
            .arg(remote_root)
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::null())
            .new_session();
        let mut child = child.spawn()?;
        child.detach("a push-on-send finishes behind the message it was for (its own session)");
        let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("no answer pipe"))?;
        let (send, answers) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut line = String::new();
            let answer = match BufReader::new(stdout).read_line(&mut line) {
                Ok(read) if read > 0 => serde_json::from_str(&line).unwrap_or_else(|_| {
                    json!({"ok": false, "error": "the push answered no line", "error_code": "sync_failed"})
                }),
                _ => json!({"ok": false, "error": "the push ended without an answer",
                            "error_code": "sync_failed"}),
            };
            let _ = send.send(answer);
            let _ = child.wait();
        });
        Ok(answers)
    };
    Ok(on_send_with(place.as_ref(), &local, remote_root, within, &worker))
}

#[cfg(test)]
mod tests;
