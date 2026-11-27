//! A new worktree's setup and a removed one's teardown, from the project's
//! recipe ([`super::worktree_recipe`]).
//!
//! Setup never holds up `git.worktree.create`: the reply comes once git has
//! made the worktree, and a thread of the session host then copies the
//! `.worktreeinclude` files and runs the setup command in the worktree. Its
//! state and output live in the worktree's own git folder
//! (`cmux-setup.json`, `cmux-setup.log`), written as it runs, so
//! `git.worktree.setup` reads them while it runs and after; they go with the
//! worktree. A setup that fails keeps the worktree as it is.
//!
//! A command from the repository's own files waits for the person: the
//! worktree's setup is `awaiting_approval` (nothing copied, nothing run)
//! until `git.worktree.setup.run` brings the fingerprint of the recipe the
//! person read ([`approvals`]); a recipe approved before runs at once, as
//! before. A teardown from the repository's files runs only for a recipe
//! approved so. `git.worktree.setup.run` also runs a setup that failed,
//! timed out or was interrupted again; it never starts a second one while
//! one runs.
//!
//! Setup and teardown run in the user's login shell (`$SHELL -l -c`), in a
//! session of their own with stdin closed, with the inherited environment
//! less git's own variables, and:
//!
//! - `CMUX_ROOT_PATH`: the main checkout.
//! - `CMUX_WORKSPACE_PATH`: the worktree.
//! - `CMUX_WORKSPACE_NAME`: the worktree's name (its folder's).
//! - `CMUX_PORT`: the first of ten ports kept for this worktree
//!   (`cmux-worktree-ports.json` in the repository's git folder) until it
//!   is removed.
//!
//! Each also under the name an imported recipe may use
//! (`cmux_conductor_import::VARIABLE_ALIASES`), so a script runs as written.
//! Setup is stopped after 30 minutes, teardown after one; removing a worktree
//! stops its setup first, its whole process group, from any session host.

use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File};
use std::io::Write as _;
use std::net::{Ipv4Addr, TcpListener};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_process::{Child, Command, Stdio};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::worktree_include::{self, Report};
use super::worktree_recipe::Recipe;
use own_folder::{Access, OwnFolder};

const STATUS_FILE: &str = "cmux-setup.json";
const LOG_FILE: &str = "cmux-setup.log";
/// Left by a session host that removes the worktree while another one
/// copies its files: the copy stops at its next file.
const CANCEL_FILE: &str = "cmux-setup.cancel";
/// Held (`flock`) by the session host for the whole run and by the setup's
/// shell, which inherits it: while anyone holds it, the run is alive and
/// the process group in the status file is still that setup's.
const LOCK_FILE: &str = "cmux-setup.lock";
/// The descriptor the setup's shell holds the lock on.
const LOCK_FD: i32 = 7;
const SETUP_DEADLINE: Duration = Duration::from_secs(30 * 60);
const TEARDOWN_DEADLINE: Duration = Duration::from_secs(60);
/// How long a stopped setup has after SIGTERM before SIGKILL.
const STOP_GRACE: Duration = Duration::from_secs(5);
/// How long a removal waits for a stopped setup to end: far more than a
/// copy's next chunk, or the poll and the grace a setup takes.
const STOP_WAIT: Duration = Duration::from_secs(60);
/// How often a running setup looks for a stop.
const CANCEL_POLL: Duration = Duration::from_millis(250);
/// Ports go out in blocks of ten from here, below the ephemeral range.
const FIRST_PORT: u16 = 40_000;
const PORT_BLOCK: u16 = 10;
const PORT_BLOCKS: u16 = 1_000;
/// The output a read returns at most.
pub(super) const MAX_OUTPUT_BYTES: u64 = 64 * 1024;
/// The most bytes that are read of a file that cmux keeps in a git folder
/// (a setup's status, the repository's ports), and of the `.git` file of a
/// new worktree ([`read_small`]). A real one is far smaller.
const MAX_OWN_BYTES: u64 = 1024 * 1024;
/// Teardown output a removal reply carries.
const MAX_TEARDOWN_OUTPUT_BYTES: u64 = 16 * 1024;

/// A worktree's setup as its status file keeps it.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub(super) struct Status {
    /// `copying`, `running`, `succeeded`, `failed` or `timed_out`; a read
    /// adds `interrupted` for a run the session host no longer has.
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub setup: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    /// The process group the setup leads while it runs, so a removal from
    /// any session host (or after a restart) can stop it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub include: Option<Report>,
    /// While `awaiting_approval`: the fingerprint of the recipe the person
    /// is asked about ([`approvals`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub approval: Option<String>,
    pub started_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_ms: Option<u64>,
}

/// The worktree a setup or teardown runs in.
pub(super) struct Place {
    pub root: PathBuf,
    pub main_root: Option<PathBuf>,
    /// The worktree's own git folder, open: the setup's status, log, run
    /// lock and stop marker are files of this folder.
    own: Arc<OwnFolder>,
    /// The repository's git folder, open: the ports of its worktrees and
    /// their lock are files of this folder.
    shared: OwnFolder,
}

impl Place {
    /// The place of the worktree `root`, whose own git folder is `git_dir`,
    /// in the repository whose git folder is `common_dir`. The 2 folders are
    /// opened here, one time: a setup or a teardown in this place keeps the
    /// 2 folders that it has at its start.
    pub(super) fn new(
        root: PathBuf,
        main_root: Option<PathBuf>,
        git_dir: &Path,
        common_dir: &Path,
    ) -> Self {
        let own = Arc::new(OwnFolder::open(git_dir));
        Self { root, main_root, own, shared: OwnFolder::open(common_dir) }
    }

    /// Whether the worktree's own git folder, as this place opened it, is
    /// the git folder that the repository whose git folder is `common_dir`
    /// keeps for the worktree ([`OwnFolder::is_of`]).
    pub(super) fn is_of(&self, common_dir: &Path) -> bool {
        self.own.is_of(&self.root, common_dir)
    }

    /// Why the worktree's own git folder is not open in this place
    /// ([`OwnFolder::not_opened`]); `None` when it is open.
    pub(super) fn not_opened(&self) -> Option<std::io::ErrorKind> {
        self.own.not_opened()
    }

    fn name(&self) -> String {
        self.root.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
    }

    fn environment(&self, port: Option<u16>) -> BTreeMap<String, String> {
        let mut values = BTreeMap::new();
        let main = self.main_root.as_deref().unwrap_or(&self.root);
        values.insert("CMUX_ROOT_PATH".to_string(), main.to_string_lossy().into_owned());
        values.insert("CMUX_WORKSPACE_PATH".to_string(), self.root.to_string_lossy().into_owned());
        values.insert("CMUX_WORKSPACE_NAME".to_string(), self.name());
        if let Some(port) = port {
            values.insert("CMUX_PORT".to_string(), port.to_string());
        }
        for (alias, name) in cmux_conductor_import::VARIABLE_ALIASES {
            if let Some(value) = values.get(name).cloned() {
                values.insert(alias.to_string(), value);
            }
        }
        values
    }
}

/// Starts a new worktree's setup and answers what `git.worktree.create`
/// reports of it. Nothing starts twice for one worktree. `consent`: the
/// fingerprint of the repository's commands in the recipe
/// ([`super::worktree_recipe::Resolved::consent`]); unless the person
/// approved it, the setup waits for them (`awaiting_approval`).
pub(super) fn start(place: Place, recipe: Recipe, consent: Option<String>) -> Value {
    begin(place, recipe, consent, false).unwrap_or_else(|state| json!({"state": state}))
}

/// Why `git.worktree.setup.run` starts nothing.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum NotRun {
    /// A setup runs there now (`copying` or `running`).
    Running(String),
}

/// `git.worktree.setup.run`: the setup of a worktree whose last setup waits
/// for the person, ended (failed, timed out, interrupted, succeeded) or never
/// started, from the start. The person's answer is kept first by the caller.
pub(super) fn rerun(place: Place, recipe: Recipe) -> Result<Value, NotRun> {
    begin(place, recipe, None, true).map_err(NotRun::Running)
}

fn begin(
    place: Place,
    recipe: Recipe,
    consent: Option<String>,
    again: bool,
) -> Result<Value, String> {
    let allocated = ports::allocate(&place.shared, &place.root);
    let port = allocated.unwrap_or_default();
    if recipe.is_empty() {
        return Ok(json!({"state": "none", "port": port}));
    }
    // The run's lock comes first: of two session hosts starting the same
    // worktree, only the one holding it reads no status and starts.
    let lock = hold(&place.own);
    let live_here =
        running().lock().unwrap_or_else(PoisonError::into_inner).contains_key(&place.root);
    if (lock.is_none() && held(&place.own)) || (again && live_here) {
        let state = read_status(&place.own).map_or_else(|| "copying".into(), |status| status.state);
        if again {
            return Err(state);
        }
        return Ok(json!({"state": state, "port": port}));
    }
    if let Some(status) = read_status(&place.own)
        && !again
    {
        return Ok(json!({"state": status.state, "port": status.port}));
    }
    if let Some(fingerprint) =
        consent.filter(|fingerprint| !approvals::approved(&place.shared, fingerprint))
    {
        let status = Status {
            state: "awaiting_approval".into(),
            port,
            setup: recipe.setup,
            approval: Some(fingerprint.clone()),
            started_ms: now_ms(),
            ..Status::default()
        };
        if write_status(&place.own, &status).is_err() {
            return Ok(json!({"state": "none", "port": port}));
        }
        return Ok(json!({"state": "awaiting_approval", "port": port, "approval": fingerprint}));
    }
    if again && let Some(mut log) = open_log(&place.own) {
        let _ = writeln!(log, "--- Setup started again ---");
    }
    let mut status = Status {
        state: "copying".into(),
        port,
        setup: recipe.setup.clone(),
        started_ms: now_ms(),
        ..Status::default()
    };
    if let Err(why) = allocated {
        // The ports that other worktrees have are not known, or the block
        // of this worktree is in no list: nothing runs.
        if let Some(mut log) = open_log(&place.own) {
            let _ = writeln!(log, "Setup did not start: {}", why.text());
        }
        finish(&mut status, &place.own, "failed", None);
        return Ok(json!({"state": "failed", "port": port}));
    }
    if write_status(&place.own, &status).is_err() {
        return Ok(json!({"state": "none", "port": port}));
    }
    let handle = Arc::new(Run::default());
    running()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(place.root.clone(), handle.clone());
    let state = status.state.clone();
    let (root, own) = (place.root.clone(), place.own.clone());
    let spawned = std::thread::Builder::new().name("cmux-worktree-setup".into()).spawn(move || {
        run(&place, &recipe, &mut status, &handle, lock);
        // Only this run's own entry: a later run of the same path keeps its.
        let mut running = running().lock().unwrap_or_else(PoisonError::into_inner);
        if running.get(&place.root).is_some_and(|entry| Arc::ptr_eq(entry, &handle)) {
            running.remove(&place.root);
        }
        drop(running);
        handle.finish();
    });
    if spawned.is_err() {
        // No thread: the run ends here, so reads and a removal never wait on it.
        if let Some(handle) = running().lock().unwrap_or_else(PoisonError::into_inner).remove(&root)
        {
            handle.finish();
        }
        let mut status = read_status(&own).unwrap_or_default();
        finish(&mut status, &own, "failed", None);
        return Ok(json!({"state": "failed", "port": port}));
    }
    Ok(json!({"state": state, "port": port}))
}

fn run(place: &Place, recipe: &Recipe, status: &mut Status, handle: &Run, lock: Option<File>) {
    let own = &*place.own;
    let cancelled = || handle.is_cancelled() || own.has(CANCEL_FILE);
    let Some(mut log) = open_log(own) else {
        return finish(status, own, "failed", None);
    };
    if !recipe.include.is_empty() {
        let _ = writeln!(log, "Copying files listed in {} ...", worktree_include::FILE_NAME);
        let patterns = worktree_include::parse(recipe.include.iter().map(String::as_str));
        let report = match &place.main_root {
            Some(main) => worktree_include::copy(main, &place.root, &patterns, &cancelled),
            None => Report::default(),
        };
        let _ =
            writeln!(log, "Copied {} files; kept {} the worktree has.", report.copied, report.kept);
        for path in &report.outside {
            let _ = writeln!(log, "Left out {path}: it links outside the repository.");
        }
        for problem in &report.problems {
            let _ = writeln!(log, "{problem}");
        }
        status.include = Some(report);
    }
    if cancelled() {
        let _ = writeln!(log, "Stopped: the worktree is being removed.");
        return finish(status, own, "failed", None);
    }
    let Some(setup) = &recipe.setup else {
        return finish(status, own, "succeeded", None);
    };
    let _ = writeln!(log, "$ {setup}");
    status.state = "running".into();
    let _ = write_status(own, status);
    let outcome = shell(
        place,
        setup,
        status.port,
        &log,
        SETUP_DEADLINE,
        Some((handle, status, lock.as_ref())),
    );
    status.pid = None;
    if cancelled() {
        let _ = writeln!(log, "Stopped: the worktree is being removed.");
    }
    match outcome {
        Outcome::Exited(Some(0)) => finish(status, own, "succeeded", Some(0)),
        Outcome::Exited(code) => {
            let _ = writeln!(
                log,
                "Setup exited with {}.",
                code.map_or("a signal".into(), |code| format!("code {code}"))
            );
            finish(status, own, "failed", code);
        }
        Outcome::TimedOut => {
            let _ =
                writeln!(log, "Setup was stopped after {} minutes.", SETUP_DEADLINE.as_secs() / 60);
            finish(status, own, "timed_out", None);
        }
        Outcome::NotStarted(error) => {
            let _ = writeln!(log, "Setup could not start: {error}");
            finish(status, own, "failed", None);
        }
    }
}

fn finish(status: &mut Status, folder: &OwnFolder, state: &str, exit_code: Option<i32>) {
    status.state = state.into();
    status.exit_code = exit_code;
    status.finished_ms = Some(now_ms());
    let _ = write_status(folder, status);
}

enum Outcome {
    Exited(Option<i32>),
    TimedOut,
    NotStarted(String),
}

/// Runs `script` in the worktree, its output appended to `log`. A setup
/// records its process group (in its run and its status file) so a removal
/// can stop it; a setup cancelled before it starts never starts.
fn shell(
    place: &Place,
    script: &str,
    port: Option<u16>,
    log: &File,
    deadline: Duration,
    setup: Option<(&Run, &mut Status, Option<&File>)>,
) -> Outcome {
    let shell = std::env::var("SHELL")
        .ok()
        .filter(|shell| shell.starts_with('/'))
        .unwrap_or_else(|| "/bin/sh".to_string());
    let (Ok(stdout), Ok(stderr)) = (log.try_clone(), log.try_clone()) else {
        return Outcome::NotStarted("the output file could not be shared".into());
    };
    let mut command = Command::new(&shell);
    command
        .args(["-l", "-c", script])
        .current_dir(&place.root)
        .env_clear()
        .envs(std::env::vars_os().filter(|(name, _)| !name.as_encoded_bytes().starts_with(b"GIT_")))
        .envs(place.environment(port))
        .stdin(Stdio::null())
        .stdout(stdout)
        .stderr(stderr);
    // The script leads a session, so its group is one a stop can end.
    command.new_session();
    #[cfg(unix)]
    {
        use std::os::fd::AsFd as _;
        if let Some((_, _, Some(lock))) = &setup
            && let Err(error) = command.inherit_fd(lock.as_fd(), LOCK_FD)
        {
            return Outcome::NotStarted(error.to_string());
        }
    }
    let spawned = match &setup {
        // Spawned under the run's lock: a stop either is seen here or comes
        // after the process exists, and the loop below sees it.
        Some((handle, _, _)) => {
            let _spawning = handle.spawning.lock().unwrap_or_else(PoisonError::into_inner);
            if handle.is_cancelled() || place.own.has(CANCEL_FILE) {
                return Outcome::Exited(None);
            }
            command.spawn()
        }
        None => command.spawn(),
    };
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => return Outcome::NotStarted(error.to_string()),
    };
    // A setup also ends when its run is cancelled here (where no signal
    // reaches the group) or another session host removes the worktree:
    // that host leaves the cancel file, and only this one signals the
    // group it started.
    let stops_on_the_marker = setup.is_some();
    let run = setup.as_ref().map(|(run, _, _)| *run);
    if let Some((_, status, _)) = setup {
        status.pid = Some(child.id());
        let _ = write_status(&place.own, status);
    }
    let started = Instant::now();
    loop {
        let left = deadline.saturating_sub(started.elapsed());
        match child.wait_timeout(left.min(CANCEL_POLL)) {
            Ok(Some(status)) => return Outcome::Exited(status.code()),
            Ok(None) if left > CANCEL_POLL => {
                if run.is_some_and(Run::is_cancelled)
                    || (stops_on_the_marker && place.own.has(CANCEL_FILE))
                {
                    end_group(&mut child);
                    return Outcome::Exited(None);
                }
            }
            Ok(None) | Err(_) => {
                end_group(&mut child);
                return Outcome::TimedOut;
            }
        }
    }
}

/// SIGTERM to the group `child` leads, then SIGKILL for whatever is left
/// (a child that ignores SIGTERM).
fn end_group(child: &mut Child) {
    let pid = child.id();
    signal_group(pid, Signal::Terminate);
    // The leader stays unreaped until the last signal: its pid, and so its
    // group's, can be no other process's until then.
    let deadline = Instant::now() + STOP_GRACE;
    while !exited(pid) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    signal_group(pid, Signal::Kill);
    let _ = child.kill();
    let _ = child.wait();
}

/// Whether the child `pid` has exited, leaving it to be reaped.
#[cfg(unix)]
fn exited(pid: u32) -> bool {
    let id = libc::id_t::from(pid);
    // SAFETY: plain data the call fills; zeroed, it reads as "nothing yet".
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    let flags = libc::WEXITED | libc::WNOWAIT | libc::WNOHANG;
    // SAFETY: a live buffer; WNOWAIT leaves the child to be reaped.
    let result = unsafe { libc::waitid(libc::P_PID, id, &raw mut info, flags) };
    result != 0 || info.si_signo != 0
}

/// Elsewhere no group is signalled: the child is ended at once.
#[cfg(not(unix))]
fn exited(_pid: u32) -> bool {
    true
}

/// Runs a worktree's teardown before it is removed, after stopping a setup
/// still running there. Answers what `git.worktree.remove` reports of it.
/// `consent`: as for [`start`]; a teardown from the repository's files that
/// the person never approved does not run, and the reply says so.
pub(super) fn teardown(
    place: &Place,
    teardown: Option<&str>,
    consent: Option<&str>,
) -> Option<Value> {
    stop(place);
    let script = teardown?;
    if consent.is_some_and(|fingerprint| !approvals::approved(&place.shared, fingerprint)) {
        return Some(json!({"state": "not_approved", "output": ""}));
    }
    let log = open_log(&place.own)?;
    let start = log.metadata().map_or(0, |metadata| metadata.len());
    let _ = writeln!(&log, "$ {script}");
    let outcome = shell(
        place,
        script,
        ports::lookup(&place.shared, &place.root),
        &log,
        TEARDOWN_DEADLINE,
        None,
    );
    // The teardown's lines are read from the log that it wrote, not from the log's name.
    let (output, _, _) = tail_of(&log, start, MAX_TEARDOWN_OUTPUT_BYTES);
    Some(match outcome {
        Outcome::Exited(code) => json!({
            "output": output,
            "exit_code": code,
            "state": if code == Some(0) { "succeeded" } else { "failed" },
        }),
        Outcome::TimedOut => json!({"output": output, "state": "timed_out"}),
        Outcome::NotStarted(error) => json!({"output": error, "state": "failed"}),
    })
}

/// Whether `git_dir` is the git folder that the repository whose git folder
/// is `common_dir` keeps for the worktree `root` ([`OwnFolder::is_of`]). The
/// folder is opened here for this one check.
pub(super) fn keeps(git_dir: &Path, root: &Path, common_dir: &Path) -> bool {
    OwnFolder::open(git_dir).is_of(root, common_dir)
}

/// What the check of a worktree's git folder gives ([`kept`]).
#[derive(Clone, Copy, Debug)]
pub(super) enum Kept {
    /// The repository keeps the folder for the worktree, and git has no lock
    /// on the worktree.
    Yes,
    /// The repository keeps the folder for the worktree, and git has its
    /// lock on the worktree.
    Locked,
    /// The folder is open, and the repository does not keep it for the
    /// worktree.
    No,
    /// The folder is not open: the kind of the error of its open.
    NotOpened(std::io::ErrorKind),
}

/// The name that git gives the lock of a worktree in the worktree's git
/// folder. `git worktree add` keeps the lock while it checks the files out.
const LOCKED: &str = "locked";

/// [`keeps`], and whether git has its lock on the worktree. The folder is
/// opened here one time: the check and the look for the lock are at the
/// folder that was opened, and the lock is read by its name in that folder,
/// not by a path. A thing at the name is a lock; a link is not followed.
pub(super) fn kept(git_dir: &Path, root: &Path, common_dir: &Path) -> Kept {
    let folder = OwnFolder::open(git_dir);
    if let Some(kind) = folder.not_opened() {
        return Kept::NotOpened(kind);
    }
    if !folder.is_of(root, common_dir) {
        return Kept::No;
    }
    if folder.has(LOCKED) { Kept::Locked } else { Kept::Yes }
}

/// A worktree folder with its links resolved, as the setup and its ports
/// are kept by it (`~/.cmux/worktrees` is a link on macOS).
pub(super) fn resolved(root: &Path) -> PathBuf {
    fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf())
}

/// After a removal: the worktree's ports go back to the list of the
/// repository whose git folder is `common_dir`.
pub(super) fn removed(common_dir: &Path, root: &Path) {
    ports::free(&OwnFolder::open(common_dir), root);
}

/// The setup of the worktree whose git folder is `git_dir`, and its output
/// from byte `since` (at most the last 64 KiB of it). The git folder and the
/// repository's git folder `common_dir` are opened one time for the read.
pub(super) fn read(root: &Path, git_dir: &Path, common_dir: &Path, since: u64) -> Value {
    let port = ports::lookup(&OwnFolder::open(common_dir), root);
    let own = &OwnFolder::open(git_dir);
    let Some(mut status) = read_status(own) else {
        return json!({"state": "none", "port": port, "output": "", "output_start": "0", "output_end": "0"});
    };
    // Live here, or (for a setup another session host started) its
    // process group still there.
    let live =
        running().lock().unwrap_or_else(PoisonError::into_inner).contains_key(root) || held(own);
    if matches!(status.state.as_str(), "copying" | "running") && !live {
        status.state = "interrupted".into();
    }
    let (output, start, end) = tail(own, LOG_FILE, since, MAX_OUTPUT_BYTES);
    status.pid = None;
    let mut value = json!(status);
    put(&mut value, "port", json!(port.or(status.port)));
    put(&mut value, "started_ms", json!(status.started_ms.to_string()));
    if let Some(finished) = status.finished_ms {
        put(&mut value, "finished_ms", json!(finished.to_string()));
    }
    put(&mut value, "output", json!(output));
    put(&mut value, "output_start", json!(start.to_string()));
    put(&mut value, "output_end", json!(end.to_string()));
    value
}

/// Sets `key` on a JSON object (and nothing on any other value).
pub(super) fn put(value: &mut Value, key: &str, item: Value) {
    if let Some(object) = value.as_object_mut() {
        object.insert(key.to_owned(), item);
    }
}

/// `git.worktree.setup`: the recipe of the repository a request names, and
/// the setup of its worktree with the output from `since`.
pub(super) fn dispatch(
    mux: &Arc<crate::Mux>,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, crate::resource::ResourceError> {
    const OPERATION: &str = "git.worktree.setup";
    // A decimal string, as every 64-bit number on the wire.
    let since = match request.fields.get("since") {
        Some(Value::String(text)) => text.parse::<u64>().unwrap_or(0),
        Some(value) => value.as_u64().unwrap_or(0),
        None => 0,
    };
    let target = super::mutation::Target::resolve(mux, request, OPERATION)?;
    let main = cmux_git::main_root(target.common_dir()).map(Path::to_path_buf);
    let project = main.clone().unwrap_or_else(|| target.common_dir().to_path_buf());
    let recipe = super::worktree_recipe::resolve(mux, main.as_deref(), &project);
    let root = &resolved(&target.repository.root);
    let mut recipe_value = recipe.value();
    if let Some(fingerprint) = recipe.consent() {
        let approved = approvals::approved(&OwnFolder::open(target.common_dir()), &fingerprint);
        put(
            &mut recipe_value,
            "approval",
            json!({"fingerprint": fingerprint, "approved": approved}),
        );
    }
    let mut value = json!({
        "root": root.to_string_lossy(),
        "recipe": recipe_value,
    });
    if let Some(main) = &main {
        put(&mut value, "main_root", json!(main.to_string_lossy()));
    }
    // The main checkout is set up by its user, not by cmux.
    let linked = main.as_deref().is_none_or(|main| !same_folder(main, root));
    let run = if linked {
        read(root, target.git_dir(), target.common_dir(), since)
    } else {
        json!({"state": "none", "output": "", "output_start": "0", "output_end": "0"})
    };
    put(&mut value, "run", run);
    Ok(value)
}

/// `git.worktree.setup.run`: runs the setup of the linked worktree a
/// request names from its start, after the person read its recipe.
/// `approve`, the fingerprint of the recipe they read (the `approval` of a
/// `git.worktree.setup` read), keeps their yes first; a recipe that changed
/// since is refused with `recipe_changed`, one never approved with
/// `approval_required`, and a setup that runs now with `setup_running`.
pub(super) fn dispatch_run(
    mux: &Arc<crate::Mux>,
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Value, crate::resource::ResourceError> {
    use super::checkpoint::ledger;
    use super::mutation::refused;
    const OPERATION: &str = "git.worktree.setup.run";
    let key = super::mutation::key(request);
    let target = super::mutation::Target::resolve(mux, request, OPERATION)?;
    let fingerprint = target.fingerprint(request);
    target.exclusive(OPERATION, || {
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let main = cmux_git::main_root(target.common_dir()).map(Path::to_path_buf);
        let root = resolved(&target.repository.root);
        if main.as_deref().is_none_or(|main| same_folder(main, &root)) {
            let message = "the main checkout is set up by its user: name a worktree cmux made";
            return Err(refused(OPERATION, "not_a_worktree", message, Value::Null));
        }
        let project = main.clone().unwrap_or_else(|| target.common_dir().to_path_buf());
        let resolved_recipe = super::worktree_recipe::resolve(mux, main.as_deref(), &project);
        let place = Place::new(root, main, target.git_dir(), target.common_dir());
        if let Some(consent) = resolved_recipe.consent()
            && !approvals::approved(&place.shared, &consent)
        {
            let extra = json!({"fingerprint": consent});
            match request.fields.get("approve").and_then(Value::as_str) {
                Some(answer) if answer == consent => {
                    if let Err(error) = approvals::approve(&place.shared, &consent) {
                        let message = format!("the answer could not be kept: {error}");
                        return Err(refused(OPERATION, "store_failed", message, extra));
                    }
                }
                Some(_) => {
                    let message = "the recipe changed after it was read: read it again";
                    return Err(refused(OPERATION, "recipe_changed", message, extra));
                }
                None => {
                    let message =
                        "the repository's setup runs once the person approves it (approve)";
                    return Err(refused(OPERATION, "approval_required", message, extra));
                }
            }
        }
        let value = rerun(place, resolved_recipe.recipe).map_err(|NotRun::Running(state)| {
            let message = "a setup runs in this worktree now";
            refused(OPERATION, "setup_running", message, json!({"state": state}))
        })?;
        ledger::commit(mux, &key, OPERATION, &fingerprint, &value, false, &request.actor)
    })
}

fn same_folder(left: &Path, right: &Path) -> bool {
    match (fs::canonicalize(left), fs::canonicalize(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}

/// The text of the log `name` of `folder` from `since` (or from where the
/// last `limit` bytes start, if later) to its end, with that start and end.
/// A log that has a second name gives no text: its text is the text of the
/// file at that name.
fn tail(folder: &OwnFolder, name: &str, since: u64, limit: u64) -> (String, u64, u64) {
    match folder.file(name).filter(|file| folder.has_one_name(file, name)) {
        Some(file) => tail_of(&file, since, limit),
        None => (String::new(), 0, 0),
    }
}

/// [`tail`] of the open log `file`.
fn tail_of(file: &File, since: u64, limit: u64) -> (String, u64, u64) {
    let end = file.metadata().map_or(0, |metadata| metadata.len());
    let start = since.min(end).max(end.saturating_sub(limit));
    let bytes = bytes_between(file, start, end);
    (String::from_utf8_lossy(&bytes).into_owned(), start, start + bytes.len() as u64)
}

/// The bytes of the open file `file` from `start` to `end`, or to where a
/// read ends. The read does not move the place of the open file: a process
/// that writes the log shares that place.
#[cfg(unix)]
fn bytes_between(file: &File, start: u64, end: u64) -> Vec<u8> {
    use std::os::unix::fs::FileExt as _;
    let mut bytes = vec![0_u8; usize::try_from(end.saturating_sub(start)).unwrap_or(0)];
    let mut read = 0_usize;
    while let Some(rest) = bytes.get_mut(read..).filter(|rest| !rest.is_empty()) {
        match file.read_at(rest, start.saturating_add(read as u64)) {
            Ok(0) => break,
            Ok(count) => read = read.saturating_add(count),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    bytes.truncate(read);
    bytes
}

/// Where a file has no read at a given place, the read moves the place of
/// the open file.
#[cfg(not(unix))]
fn bytes_between(mut file: &File, start: u64, end: u64) -> Vec<u8> {
    use std::io::{Read as _, Seek as _, SeekFrom};
    let mut bytes = Vec::new();
    if file.seek(SeekFrom::Start(start)).is_ok() {
        let _ = file.take(end.saturating_sub(start)).read_to_end(&mut bytes);
    }
    bytes
}

/// Stops the setup still running in `root`, and waits for it to end. This
/// host's run ends itself: a copy at its next chunk, a setup that has not
/// started never does, and a running setup's thread, which holds the child
/// unreaped, sends its group SIGTERM, then SIGKILL for whatever is left. A
/// setup another session host started is told to stop by a file, and
/// waited for; nothing here signals a process this host did not start.
fn stop(place: &Place) {
    let handle = running().lock().unwrap_or_else(PoisonError::into_inner).get(&place.root).cloned();
    let Some(handle) = handle else {
        // Another session host's setup: it stops itself on the cancel file.
        let live = |status: &Status| matches!(status.state.as_str(), "copying" | "running");
        let unfinished =
            |status: Option<Status>| status.is_some_and(|status| live(&status) && held(&place.own));
        // The marker goes first: a run whose status says copying may not
        // hold its lock yet, and it checks the marker once it does. Only the
        // marker's name is used, so the marker is made with create-new: a
        // file that is at the name is not opened.
        if read_status(&place.own).is_some_and(|status| live(&status)) {
            drop(place.own.make_new(CANCEL_FILE, Access::Write));
        }
        if unfinished(read_status(&place.own)) {
            let deadline = Instant::now() + STOP_WAIT;
            while unfinished(read_status(&place.own)) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        return;
    };
    {
        let _spawning = handle.spawning.lock().unwrap_or_else(PoisonError::into_inner);
        handle.cancelled.store(true, Ordering::SeqCst);
    }
    // Waited for, so nothing of the setup runs once the teardown starts.
    handle.wait(STOP_WAIT);
}

/// A setup thread of this session host.
#[derive(Default)]
struct Run {
    cancelled: AtomicBool,
    /// Held while the setup starts, so a stop comes before or after it.
    spawning: Mutex<()>,
    done: Mutex<bool>,
    finished: Condvar,
}

impl Run {
    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    fn finish(&self) {
        *self.done.lock().unwrap_or_else(PoisonError::into_inner) = true;
        self.finished.notify_all();
    }

    /// Whether the thread ended within `timeout`.
    fn wait(&self, timeout: Duration) -> bool {
        let done = self.done.lock().unwrap_or_else(PoisonError::into_inner);
        let (done, _) = self
            .finished
            .wait_timeout_while(done, timeout, |done| !*done)
            .unwrap_or_else(PoisonError::into_inner);
        *done
    }
}

/// The worktrees whose setup thread is alive here.
fn running() -> &'static Mutex<HashMap<PathBuf, Arc<Run>>> {
    static RUNNING: OnceLock<Mutex<HashMap<PathBuf, Arc<Run>>>> = OnceLock::new();
    RUNNING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The run's lock, taken for this session host (`None` where there is no
/// `flock`, or the git folder cannot hold it).
#[cfg(unix)]
fn hold(folder: &OwnFolder) -> Option<File> {
    use std::os::fd::AsRawFd as _;
    // A link or a named pipe in the lock's place is nobody's lock, and a
    // lock file that has a second name is made new.
    let file = folder.open_or_make(LOCK_FILE, Access::Write)?;
    // SAFETY: a live descriptor; flock(2) only locks it.
    (unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0).then_some(file)
}

#[cfg(not(unix))]
fn hold(_folder: &OwnFolder) -> Option<File> {
    None
}

/// Whether a run (a session host's, or the setup shell it started) still
/// holds the lock of the worktree whose git folder is `folder`.
#[cfg(unix)]
fn held(folder: &OwnFolder) -> bool {
    // A link or a named pipe in the lock's place is nobody's lock, and so
    // is a lock file that has a second name.
    let lock = folder.file(LOCK_FILE).filter(|file| folder.has_one_name(file, LOCK_FILE));
    lock.is_some_and(held_on)
}

/// [`held`] on the lock file opened as `file`.
/// The look never leaves a lock behind (the next `start` must take the run's lock, also while a
/// child the server forked meanwhile has this descriptor). A look that fails reads as held, as
/// before.
#[cfg(unix)]
fn held_on(file: File) -> bool {
    use cmux_file_lock::{FileLock, Kind};
    FileLock::held_elsewhere(&file, Kind::Shared).unwrap_or(true)
}

#[cfg(not(unix))]
fn held(_folder: &OwnFolder) -> bool {
    false
}

enum Signal {
    Terminate,
    Kill,
}

#[cfg(unix)]
fn signal_group(pid: u32, signal: Signal) {
    let signal = match signal {
        Signal::Terminate => libc::SIGTERM,
        Signal::Kill => libc::SIGKILL,
    };
    if let Ok(group) = libc::pid_t::try_from(pid) {
        // SAFETY: `kill` takes plain integers; the group is the one the
        // script leads (setsid above).
        unsafe {
            libc::kill(-group, signal);
        }
    }
}

#[cfg(not(unix))]
fn signal_group(_pid: u32, _signal: Signal) {}

/// The setup's status, from the worktree's git folder `folder`. A status
/// file above the size limit is no status.
fn read_status(folder: &OwnFolder) -> Option<Status> {
    serde_json::from_slice(&folder.read(STATUS_FILE).ok()??).ok()
}

/// A file that cmux keeps in a git folder is larger than [`MAX_OWN_BYTES`].
#[derive(Clone, Copy, Debug)]
struct TooLarge;

/// The bytes of the small file `name` in the folder `folder` of a work
/// tree, read as a file that cmux keeps in a git folder is read
/// ([`OwnFolder::read`]); `None` when there is no such file to read, and for
/// a file above the size limit.
pub(super) fn read_small(folder: &Path, name: &str) -> Option<Vec<u8>> {
    OwnFolder::open(folder).read(name).ok().flatten()
}

/// Opens the log of the worktree whose git folder is `folder`, for a read
/// and for writes at its end, and makes it when there is none
/// ([`OwnFolder::open_or_make`]).
fn open_log(folder: &OwnFolder) -> Option<File> {
    folder.open_or_make(LOG_FILE, Access::Append)
}

/// Writes the setup's status to the worktree's git folder `folder`
/// ([`OwnFolder::write`]).
fn write_status(folder: &OwnFolder, status: &Status) -> std::io::Result<()> {
    folder.write(STATUS_FILE, &serde_json::to_vec(status)?)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as u64)
}

/// The ports each worktree keeps, in `cmux-worktree-ports.json` in the
/// repository's git folder: the first port of a block of ten by worktree
/// folder. A folder that is gone gives its block back on the next
/// allocation.
mod ports;

/// The repository recipes the person approved ([`Status::approval`]).
pub(super) mod approvals;

/// A git folder that cmux keeps files in, open: each file is reached by its
/// name in the open folder.
mod own_folder;

#[cfg(test)]
mod tests;

#[cfg(all(test, unix))]
mod lock_probe_tests {
    use super::*;

    /// A `held` look at a free run lock leaves it free, also while a child the server forked
    /// meanwhile has the look's descriptor: else the next `start` cannot take the run's lock
    /// and runs the setup without it (no fd 7 for the shell).
    #[test]
    fn a_held_look_leaves_the_run_lock_free_while_a_forked_child_keeps_its_descriptor() {
        let dir = crate::fork_tests::Scratch::new("worktree_setup");
        fs::write(dir.path().join(LOCK_FILE), b"").unwrap();
        let look = File::open(dir.path().join(LOCK_FILE)).unwrap();
        let keeper = crate::fork_tests::Keeper::fork();
        let looked = held_on(look);
        let run = hold(&OwnFolder::open(dir.path()));
        drop(keeper);
        assert!(!looked, "a free run lock read as held");
        assert!(run.is_some(), "the look left the run lock held");
    }
}
