//! What changed in a pushed folder since its last push, as a watcher saw it
//! (`cmux link sync watch`): the dirty set push-on-send sends ([`super::changed`]).
//!
//! One watcher process a Mac (a lock in `<state>/link-sync-watch/` keeps it
//! one), started by the first push of a chat's copy, watches each folder a
//! push asked about, recursively (FSEvents on macOS, inotify on Linux,
//! through `notify`). For each folder it keeps, in memory, every path that
//! changed below it with the sequence number of its last change. Nothing of
//! it is on disk: a watcher that stopped (the Mac restarted, the process
//! died) starts a new session, and every mark of the old one asks for a
//! rescan.
//!
//! A push asks over the watcher's socket (one JSON line each way). Before
//! answering, the watcher flushes: it makes a file in a folder of its own
//! that the same stream watches and answers only once that file's event has
//! come, so every change this Mac made before the question is in the answer
//! (one stream delivers its events in order). The answer is the paths
//! changed since the push's mark (`since`, the session and sequence number
//! the last push took before it listed the folder) and the mark to keep for
//! the next one, or a rescan: no mark, another session, an overflow since
//! the mark (the watcher's own drop or rescan event, or more than
//! [`MOST_KEPT`] paths), more than [`MOST_ANSWERED`] paths, a watch that
//! could not be set up, or no flush within [`FLUSH_WAIT`]. Never "nothing
//! changed" without a stream that saw everything since the mark.
//!
//! A folder's watch ends after [`WATCH_IDLE`] without a question; the
//! process ends once it watches nothing for [`PROCESS_IDLE`], or its state
//! folder is gone.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::json;

/// The protocol both sides speak; a watcher of another one is asked to end.
const VERSION: u64 = 1;
/// Paths a folder's watch keeps before it overflows (and asks for a rescan).
pub(super) const MOST_KEPT: usize = 50_000;
/// Paths an answer names; past it the push rescans, which costs about as much.
pub(super) const MOST_ANSWERED: usize = 5_000;
/// How long a flush waits for its own event.
const FLUSH_WAIT: Duration = Duration::from_secs(2);
/// A folder nobody asked about for this long is no longer watched.
const WATCH_IDLE: Duration = Duration::from_secs(3 * 24 * 3600);
/// The process ends after this long watching nothing.
const PROCESS_IDLE: Duration = Duration::from_secs(10 * 60);
/// How often the process looks for idle watches and its state folder.
const SWEEP_EVERY: Duration = Duration::from_secs(30);

/// Where the watcher keeps its lock, socket and flush files.
#[derive(Clone, Debug)]
pub(super) struct Place {
    pub(super) dir: PathBuf,
    pub(super) socket: PathBuf,
    /// Whether a question with no watcher running starts one (this program,
    /// `link sync watch`); tests run theirs in a thread.
    pub(super) start: bool,
}

#[cfg(test)]
thread_local! {
    /// The watcher a test thread's pushes ask: each test sets its own, so other
    /// tests' pushes in the same process ask none.
    static TEST_PLACE: std::cell::RefCell<Option<Place>> = const { std::cell::RefCell::new(None) };
}

impl Place {
    /// This Mac's watcher; None when `CMUX_SYNC_WATCH=0`, or with no state folder.
    pub(super) fn here() -> Option<Self> {
        #[cfg(test)]
        {
            TEST_PLACE.with(|place| place.borrow().clone())
        }
        #[cfg(not(test))]
        {
            if std::env::var("CMUX_SYNC_WATCH").is_ok_and(|value| value.trim() == "0") {
                return None;
            }
            let dir = super::state_dir()?.join("link-sync-watch");
            Some(Self::in_dir(dir, true))
        }
    }

    /// The watcher whose state is in `dir`: its socket there, unless that path is too
    /// long for a socket, then in the runtime folder by a digest of `dir`.
    pub(super) fn in_dir(dir: PathBuf, start: bool) -> Self {
        let socket = dir.join("w.sock");
        let socket = if socket.as_os_str().len() < 100 {
            socket
        } else {
            let digest = super::base::key(&dir, "");
            cmux_tui_core::platform::hashed_runtime_dir()
                .join(format!("link-sync-watch-{}.sock", &digest[..16]))
        };
        Self { dir, socket, start }
    }

    #[cfg(test)]
    pub(super) fn set_for_tests(place: Option<Self>) {
        TEST_PLACE.with(|set| *set.borrow_mut() = place);
    }
}

/// The point a push's listing started from: a session of the watcher and the
/// last sequence number it had then.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Mark {
    pub(super) session: String,
    pub(super) seq: u64,
}

/// What the watcher said of a folder.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Seen {
    /// Exactly these paths (relative, files or folders) changed since the mark;
    /// `mark` is the one to keep once a push of them is done.
    Paths { paths: BTreeSet<String>, mark: Mark },
    /// Anything may have changed: the push rescans. `mark` is the one to keep
    /// after that rescan, when the watcher could give one.
    Rescan { why: String, mark: Option<Mark> },
}

impl Seen {
    fn rescan(why: impl Into<String>) -> Self {
        Self::Rescan { why: why.into(), mark: None }
    }

    pub(super) fn mark(&self) -> Option<&Mark> {
        match self {
            Self::Paths { mark, .. } => Some(mark),
            Self::Rescan { mark, .. } => mark.as_ref(),
        }
    }
}

#[derive(Serialize, Deserialize)]
struct Question {
    v: u64,
    root: PathBuf,
    since: Option<Mark>,
}

#[derive(Serialize, Deserialize)]
struct Answer {
    #[serde(default)]
    mark: Option<Mark>,
    #[serde(default)]
    rescan: Option<String>,
    #[serde(default)]
    paths: Vec<String>,
}

/// Asks the watcher what changed in `root` (canonical) since `since`, starting
/// it when none answers (and `place.start`), waiting up to `wait` for it.
pub(super) fn ask(place: &Place, root: &Path, since: Option<&Mark>, wait: Duration) -> Seen {
    let deadline = Instant::now() + wait;
    let mut started = false;
    let stream = loop {
        match UnixStream::connect(&place.socket) {
            Ok(stream) => break stream,
            Err(_) if Instant::now() >= deadline => return Seen::rescan("no watcher answered"),
            Err(_) => {
                if !started && place.start {
                    started = true;
                    if !start_watcher() {
                        return Seen::rescan("the watcher did not start");
                    }
                }
                if !started {
                    return Seen::rescan("no watcher is running");
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    };
    let question = Question { v: VERSION, root: root.to_path_buf(), since: since.cloned() };
    match exchange(stream, &question, FLUSH_WAIT + Duration::from_secs(1)) {
        Ok(answer) => match (answer.rescan, answer.mark) {
            (None, Some(mark)) => Seen::Paths { paths: answer.paths.into_iter().collect(), mark },
            (why, mark) => Seen::Rescan { why: why.unwrap_or_else(|| "no mark".into()), mark },
        },
        Err(error) => Seen::rescan(format!("the watcher did not answer: {error}")),
    }
}

fn exchange(stream: UnixStream, question: &Question, wait: Duration) -> anyhow::Result<Answer> {
    stream.set_read_timeout(Some(wait))?;
    stream.set_write_timeout(Some(wait))?;
    let mut writer = stream.try_clone()?;
    writer.write_all(format!("{}\n", serde_json::to_string(question)?).as_bytes())?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line)?;
    Ok(serde_json::from_str(&line)?)
}

/// Starts `link sync watch` of this program in its own session.
fn start_watcher() -> bool {
    let Ok(program) = std::env::current_exe() else { return false };
    let mut child = cmux_process::Command::new(program);
    child
        .args(["link", "sync", "watch"])
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .new_session();
    match child.spawn() {
        Ok(mut child) => {
            child.detach("the sync watcher outlives the push that started it (its own session)");
            true
        }
        Err(_) => false,
    }
}

/// `cmux link sync watch`: runs this Mac's watcher until it is idle. Exit 0
/// also when another one already runs.
pub(super) fn run() -> i32 {
    let Some(place) = Place::here() else { return 0 };
    match serve(&place) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("cmux link sync watch: {error:#}");
            1
        }
    }
}

/// Serves the watcher at `place` (none when another holds its lock) until it
/// ends itself: it watches nothing for [`PROCESS_IDLE`], its state folder is
/// gone, or a watcher of another build asked. Every thread it starts is joined
/// before it returns. A test's watcher never ends itself.
pub(super) fn serve(place: &Place) -> anyhow::Result<()> {
    use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&place.dir)?;
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(place.dir.join("watch.lock"))?;
    if lock.try_lock().is_err() {
        return Ok(());
    }
    let dir = std::fs::canonicalize(&place.dir)?;
    let flushes = dir.join("flush");
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&flushes)?;
    if let Some(parent) = place.socket.parent() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(parent)?;
    }
    let _ = std::fs::remove_file(&place.socket);
    let listener = UnixListener::bind(&place.socket)?;
    std::fs::set_permissions(&place.socket, std::fs::Permissions::from_mode(0o600))?;
    let watcher = Arc::new(Watcher {
        state_dir: dir,
        flushes,
        watches: Mutex::new(HashMap::new()),
        last_question: Mutex::new(Instant::now()),
        next_nonce: std::sync::atomic::AtomicU64::new(0),
        ending: Ending {
            ended: Mutex::new(false),
            woken: Condvar::new(),
            socket: place.socket.clone(),
        },
    });
    let served = std::thread::scope(|threads| {
        threads.spawn(|| {
            while !watcher.ending.wait(SWEEP_EVERY) {
                // Only `cmux link sync watch`'s own process ends itself; a test's never does.
                if (watcher.sweep() || !place.dir.is_dir()) && !cfg!(test) {
                    watcher.ending.end();
                }
            }
        });
        let served = loop {
            match listener.accept() {
                Ok(_) if watcher.ending.ended() => break Ok(()),
                Ok((stream, _)) => {
                    let watcher = &watcher;
                    threads.spawn(move || watcher.answer(stream));
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(error) => break Err(error.into()),
            }
        };
        // The sweep ends with the server, whatever ended it.
        watcher.ending.end();
        served
    });
    drop(lock);
    served
}

/// How the server and its sweep end: the flag, a condition the sweep waits
/// on between rounds, and the server's socket, which a connection wakes.
struct Ending {
    ended: Mutex<bool>,
    woken: Condvar,
    socket: PathBuf,
}

impl Ending {
    fn ended(&self) -> bool {
        self.ended.lock().map_or(true, |ended| *ended)
    }

    /// Ends the server: the sweep stops waiting and `accept` returns.
    fn end(&self) {
        let Ok(mut ended) = self.ended.lock() else { return };
        if *ended {
            return;
        }
        *ended = true;
        drop(ended);
        self.woken.notify_all();
        let _ = UnixStream::connect(&self.socket);
    }

    /// Waits up to `limit` for the end; true once ended.
    fn wait(&self, limit: Duration) -> bool {
        let Ok(ended) = self.ended.lock() else { return true };
        match self.woken.wait_timeout_while(ended, limit, |ended| !*ended) {
            Ok((ended, _)) => *ended,
            Err(_) => true,
        }
    }
}

struct Watcher {
    /// The watcher's own folder, canonical: changes in it are never a folder's.
    state_dir: PathBuf,
    flushes: PathBuf,
    watches: Mutex<HashMap<PathBuf, Arc<Watch>>>,
    last_question: Mutex<Instant>,
    next_nonce: std::sync::atomic::AtomicU64,
    ending: Ending,
}

/// One watched folder.
struct Watch {
    session: String,
    root: PathBuf,
    flush_dir: PathBuf,
    /// Outside git a heavy folder ([`super::local::heavy_folder`]) never goes,
    /// so its changes are not kept.
    plain: bool,
    seen: Mutex<Changes>,
    flushed: Condvar,
    asked: Mutex<Instant>,
    /// Held for the watch's life; dropping it stops the stream.
    stream: Mutex<Option<notify::RecommendedWatcher>>,
}

#[derive(Default)]
struct Changes {
    seq: u64,
    /// The sequence number of the last overflow: every mark before it rescans.
    overflow_at: u64,
    paths: HashMap<String, u64>,
    /// Flush files whose event came.
    flushed: HashSet<String>,
    /// Why the watch cannot be trusted at all (it could not be set up).
    broken: Option<String>,
}

impl Changes {
    fn overflow(&mut self) {
        self.seq += 1;
        self.overflow_at = self.seq;
        self.paths.clear();
    }

    fn changed(&mut self, relative: String) {
        self.seq += 1;
        self.paths.insert(relative, self.seq);
        if self.paths.len() > MOST_KEPT {
            self.overflow();
        }
    }
}

impl Watcher {
    fn answer(&self, stream: UnixStream) {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let Ok(mut writer) = stream.try_clone() else { return };
        let mut line = String::new();
        if BufReader::new(stream).read_line(&mut line).is_err() {
            return;
        }
        let answer = match serde_json::from_str::<Question>(&line) {
            Ok(question) if question.v == VERSION => self.seen(&question),
            Ok(_) => {
                let answer = Answer {
                    mark: None,
                    rescan: Some("another watcher version".into()),
                    paths: Vec::new(),
                };
                let _ = writer.write_all(format!("{}\n", json!(answer)).as_bytes());
                // A watcher of another build gives way to the one that asked.
                if !cfg!(test) {
                    self.ending.end();
                }
                return;
            }
            Err(error) => Answer {
                mark: None,
                rescan: Some(format!("bad question: {error}")),
                paths: Vec::new(),
            },
        };
        if let Ok(mut last) = self.last_question.lock() {
            *last = Instant::now();
        }
        let _ = writer.write_all(format!("{}\n", json!(answer)).as_bytes());
    }

    fn seen(&self, question: &Question) -> Answer {
        let rescan = |why: &str, mark: Option<Mark>| Answer {
            mark,
            rescan: Some(why.into()),
            paths: Vec::new(),
        };
        let (watch, fresh) = match self.watch(&question.root) {
            Ok(found) => found,
            Err(error) => return rescan(&format!("cannot watch the folder: {error:#}"), None),
        };
        if let Ok(mut asked) = watch.asked.lock() {
            *asked = Instant::now();
        }
        if let Err(why) = self.flush(&watch) {
            return rescan(&why, None);
        }
        let Ok(changes) = watch.seen.lock() else { return rescan("the watch failed", None) };
        if let Some(why) = &changes.broken {
            return rescan(why, None);
        }
        let mark = Some(Mark { session: watch.session.clone(), seq: changes.seq });
        let since = match &question.since {
            _ if fresh => return rescan("the watch just started", mark),
            None => return rescan("no earlier push was watched", mark),
            Some(since) if since.session != watch.session => {
                return rescan("the watcher restarted since the last push", mark);
            }
            Some(since) if changes.overflow_at > since.seq => {
                return rescan("too much changed for the watcher to keep", mark);
            }
            Some(since) => since.seq,
        };
        let paths: Vec<String> = changes
            .paths
            .iter()
            .filter(|(_, seq)| **seq > since)
            .map(|(path, _)| path.clone())
            .collect();
        if paths.len() > MOST_ANSWERED {
            return rescan("too many files changed", mark);
        }
        Answer { mark, rescan: None, paths }
    }

    /// The watch of `root`, set up now when there is none (`true`).
    fn watch(&self, root: &Path) -> anyhow::Result<(Arc<Watch>, bool)> {
        let root = std::fs::canonicalize(root)?;
        let mut watches = self.watches.lock().map_err(|_| anyhow::anyhow!("watches poisoned"))?;
        if let Some(watch) = watches.get(&root) {
            return Ok((watch.clone(), false));
        }
        let key = super::base::key(&root, "");
        let flush_dir = self.flushes.join(&key[..24]);
        std::fs::create_dir_all(&flush_dir)?;
        let watch = Arc::new(Watch {
            session: uuid::Uuid::new_v4().to_string(),
            plain: !root.join(".git").is_dir(),
            root: root.clone(),
            flush_dir: flush_dir.clone(),
            seen: Mutex::new(Changes::default()),
            flushed: Condvar::new(),
            asked: Mutex::new(Instant::now()),
            stream: Mutex::new(None),
        });
        let heard = Arc::downgrade(&watch);
        let state_dir = self.state_dir.clone();
        let stream = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            if let Some(watch) = heard.upgrade() {
                watch.heard(&state_dir, event);
            }
        });
        let setup = stream.and_then(|mut stream| {
            use notify::Watcher as _;
            stream.watch(&flush_dir, notify::RecursiveMode::NonRecursive)?;
            stream.watch(&root, notify::RecursiveMode::Recursive)?;
            Ok(stream)
        });
        match setup {
            Ok(stream) => {
                if let Ok(mut held) = watch.stream.lock() {
                    *held = Some(stream);
                }
            }
            Err(error) => {
                if let Ok(mut changes) = watch.seen.lock() {
                    changes.broken = Some(format!("cannot watch the folder: {error}"));
                }
            }
        }
        watches.insert(root, watch.clone());
        Ok((watch, true))
    }

    /// Makes a file the watch's own stream sees and waits for its event: every
    /// change made before this call is then in the watch.
    fn flush(&self, watch: &Watch) -> Result<(), String> {
        if watch.seen.lock().map(|changes| changes.broken.is_some()).unwrap_or(true) {
            return Ok(());
        }
        let nonce = format!(
            "{}-{}",
            std::process::id(),
            self.next_nonce.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        );
        let path = watch.flush_dir.join(&nonce);
        std::fs::write(&path, b"").map_err(|error| format!("cannot flush the watch: {error}"))?;
        let deadline = Instant::now() + FLUSH_WAIT;
        let mut changes = watch.seen.lock().map_err(|_| "the watch failed".to_string())?;
        let came = loop {
            if changes.flushed.remove(&nonce) {
                break true;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break false;
            }
            changes = match watch.flushed.wait_timeout(changes, left) {
                Ok((changes, _)) => changes,
                Err(_) => return Err("the watch failed".into()),
            };
        };
        drop(changes);
        let _ = std::fs::remove_file(&path);
        if came { Ok(()) } else { Err("the watcher's stream did not catch up in time".into()) }
    }

    /// Ends the watches nobody asked about for [`WATCH_IDLE`]; true when the
    /// process should end.
    fn sweep(&self) -> bool {
        let Ok(mut watches) = self.watches.lock() else { return true };
        watches.retain(|_, watch| {
            let fresh = watch.asked.lock().is_ok_and(|asked| asked.elapsed() < WATCH_IDLE);
            if !fresh {
                let _ = std::fs::remove_dir_all(&watch.flush_dir);
            }
            fresh && watch.root.is_dir()
        });
        watches.is_empty()
            && self.last_question.lock().map_or(true, |last| last.elapsed() >= PROCESS_IDLE)
    }
}

impl Watch {
    fn heard(&self, state_dir: &Path, event: notify::Result<notify::Event>) {
        let Ok(mut changes) = self.seen.lock() else { return };
        let event = match event {
            Ok(event) => event,
            Err(_) => {
                changes.overflow();
                return;
            }
        };
        if event.need_rescan() {
            changes.overflow();
            return;
        }
        if matches!(event.kind, notify::EventKind::Access(_)) {
            return;
        }
        // inotify names a renamed folder's files by its old path until notify re-reads it: what
        // changes in it after is not where the watch says. FSEvents names paths as they are.
        #[cfg(target_os = "linux")]
        if matches!(event.kind, notify::EventKind::Modify(notify::event::ModifyKind::Name(_)))
            && event.paths.iter().any(|path| path.is_dir() && path.starts_with(&self.root))
        {
            changes.overflow();
            return;
        }
        let mut flushed = false;
        for path in &event.paths {
            if path.parent() == Some(self.flush_dir.as_path()) {
                // Its removal, once answered, says nothing.
                if matches!(event.kind, notify::EventKind::Remove(_)) {
                    continue;
                }
                if changes.flushed.len() > 1_000 {
                    changes.flushed.clear();
                }
                if let Some(name) = path.file_name().and_then(|name| name.to_str()) {
                    flushed |= changes.flushed.insert(name.to_owned());
                }
                continue;
            }
            if path.starts_with(state_dir) {
                continue;
            }
            match path.strip_prefix(&self.root) {
                // The folder itself moved or went: nothing of a mark holds.
                Ok(relative) if relative.as_os_str().is_empty() => {
                    if matches!(
                        event.kind,
                        notify::EventKind::Remove(_)
                            | notify::EventKind::Modify(notify::event::ModifyKind::Name(_))
                    ) {
                        changes.overflow();
                    }
                }
                Ok(relative) => match relative.to_str() {
                    Some(relative) => {
                        if self.plain && super::local::heavy_folder(&self.root, relative).is_some()
                        {
                            continue;
                        }
                        changes.changed(relative.to_owned());
                    }
                    // A name no push sends, but it may be a folder holding ones it does.
                    None => changes.overflow(),
                },
                // A folder above the root moved: the root is no longer where it was.
                Err(_) if self.root.starts_with(path) => changes.overflow(),
                Err(_) => {}
            }
        }
        if flushed {
            self.flushed.notify_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Changes, MOST_KEPT};

    /// Past [`MOST_KEPT`] paths the watch forgets them and marks an overflow: every mark
    /// before it asks for a rescan, none is answered "nothing changed".
    #[test]
    fn past_its_bound_a_watch_overflows() {
        let mut changes = Changes::default();
        for n in 0..=MOST_KEPT {
            changes.changed(format!("f{n}"));
        }
        assert!(changes.paths.is_empty());
        assert_eq!(changes.overflow_at, changes.seq);
        changes.changed("after".into());
        assert_eq!(changes.paths.len(), 1);
        assert!(changes.overflow_at < changes.seq);
    }
}
