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
//! Setup and teardown run in the user's login shell (`$SHELL -l -c`), in a
//! session of their own with stdin closed, with the inherited environment
//! less git's own variables, and:
//!
//! - `CMUX_ROOT_PATH`: the main checkout.
//! - `CMUX_WORKSPACE_PATH`: the worktree.
//! - `CMUX_WORKSPACE_NAME`: the worktree's name (its folder's).
//! - `CMUX_PORT`: the first of ten ports kept for this worktree
//!   (`~/.cmux/worktree-ports.json`) until it is removed.
//!
//! Each also under the name an imported recipe may use
//! (`cmux_conductor_import::VARIABLE_ALIASES`), so a script runs as written.
//! Setup is stopped after 30 minutes, teardown after one; removing a worktree
//! stops its setup first, its whole process group, from any session host.

use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File, OpenOptions};
use std::io::{Read as _, Seek as _, SeekFrom, Write as _};
use std::net::{Ipv4Addr, TcpListener};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use wait_timeout::ChildExt;

use super::worktree_include::{self, Report};
use super::worktree_recipe::Recipe;

const STATUS_FILE: &str = "cmux-setup.json";
const LOG_FILE: &str = "cmux-setup.log";
/// Left by a session host that removes the worktree while another one
/// copies its files: the copy stops at its next file.
const CANCEL_FILE: &str = "cmux-setup.cancel";
const SETUP_DEADLINE: Duration = Duration::from_secs(30 * 60);
const TEARDOWN_DEADLINE: Duration = Duration::from_secs(60);
/// How long a stopped setup has after SIGTERM before SIGKILL.
const STOP_GRACE: Duration = Duration::from_secs(5);
/// How often a running setup looks for another host's cancel file.
const CANCEL_POLL: Duration = Duration::from_millis(250);
/// Ports go out in blocks of ten from here, below the ephemeral range.
const FIRST_PORT: u16 = 40_000;
const PORT_BLOCK: u16 = 10;
const PORT_BLOCKS: u16 = 1_000;
/// The output a read returns at most.
pub(super) const MAX_OUTPUT_BYTES: u64 = 64 * 1024;
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
    pub started_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_ms: Option<u64>,
}

/// The worktree a setup or teardown runs in.
pub(super) struct Place {
    pub root: PathBuf,
    pub main_root: Option<PathBuf>,
    /// The worktree's own git folder.
    pub git_dir: PathBuf,
}

impl Place {
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
/// reports of it. Nothing starts twice for one worktree.
pub(super) fn start(place: Place, recipe: Recipe) -> Value {
    let port = ports::allocate(&place.root);
    if recipe.is_empty() {
        return json!({"state": "none", "port": port});
    }
    let status_path = place.git_dir.join(STATUS_FILE);
    if let Some(status) = read_status(&place.git_dir) {
        return json!({"state": status.state, "port": status.port});
    }
    let mut status = Status {
        state: "copying".into(),
        port,
        setup: recipe.setup.clone(),
        started_ms: now_ms(),
        ..Status::default()
    };
    if write_status(&status_path, &status).is_err() {
        return json!({"state": "none", "port": port});
    }
    let handle = Arc::new(Run::default());
    running()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .insert(place.root.clone(), handle.clone());
    let state = status.state.clone();
    std::thread::Builder::new()
        .name("cmux-worktree-setup".into())
        .spawn(move || {
            run(&place, &recipe, &mut status, &handle);
            running().lock().unwrap_or_else(PoisonError::into_inner).remove(&place.root);
            handle.finish();
        })
        .ok();
    json!({"state": state, "port": port})
}

fn run(place: &Place, recipe: &Recipe, status: &mut Status, handle: &Run) {
    let status_path = place.git_dir.join(STATUS_FILE);
    let cancel_path = place.git_dir.join(CANCEL_FILE);
    let cancelled = || handle.is_cancelled() || cancel_path.exists();
    let mut log =
        match OpenOptions::new().create(true).append(true).open(place.git_dir.join(LOG_FILE)) {
            Ok(log) => log,
            Err(_) => return finish(status, &status_path, "failed", None),
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
        return finish(status, &status_path, "failed", None);
    }
    let Some(setup) = &recipe.setup else {
        return finish(status, &status_path, "succeeded", None);
    };
    let _ = writeln!(log, "$ {setup}");
    status.state = "running".into();
    let _ = write_status(&status_path, status);
    let outcome = shell(place, setup, status.port, &log, SETUP_DEADLINE, Some((handle, status)));
    status.pid = None;
    if cancelled() {
        let _ = writeln!(log, "Stopped: the worktree is being removed.");
    }
    match outcome {
        Outcome::Exited(Some(0)) => finish(status, &status_path, "succeeded", Some(0)),
        Outcome::Exited(code) => {
            let _ = writeln!(
                log,
                "Setup exited with {}.",
                code.map_or("a signal".into(), |code| format!("code {code}"))
            );
            finish(status, &status_path, "failed", code);
        }
        Outcome::TimedOut => {
            let _ =
                writeln!(log, "Setup was stopped after {} minutes.", SETUP_DEADLINE.as_secs() / 60);
            finish(status, &status_path, "timed_out", None);
        }
        Outcome::NotStarted(error) => {
            let _ = writeln!(log, "Setup could not start: {error}");
            finish(status, &status_path, "failed", None);
        }
    }
}

fn finish(status: &mut Status, path: &Path, state: &str, exit_code: Option<i32>) {
    status.state = state.into();
    status.exit_code = exit_code;
    status.finished_ms = Some(now_ms());
    let _ = write_status(path, status);
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
    setup: Option<(&Run, &mut Status)>,
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
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // SAFETY: setsid(2) is async-signal-safe and touches no Rust state in
        // the post-fork child. The script leads a group a stop can end.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
            });
        }
    }
    let spawned = match &setup {
        // Spawned under the run's lock: a stop either sees the process or
        // keeps it from starting.
        Some((handle, _)) => {
            let mut pid = handle.pid.lock().unwrap_or_else(PoisonError::into_inner);
            if handle.is_cancelled() || place.git_dir.join(CANCEL_FILE).exists() {
                return Outcome::Exited(None);
            }
            command.spawn().inspect(|child| *pid = Some(child.id()))
        }
        None => command.spawn(),
    };
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => return Outcome::NotStarted(error.to_string()),
    };
    // A setup also ends when another session host removes the worktree:
    // that host leaves the cancel file, and only this one signals the
    // group it started.
    let cancel = setup.is_some().then(|| place.git_dir.join(CANCEL_FILE));
    if let Some((_, status)) = setup {
        status.pid = Some(child.id());
        let _ = write_status(&place.git_dir.join(STATUS_FILE), status);
    }
    let started = Instant::now();
    loop {
        let left = deadline.saturating_sub(started.elapsed());
        match child.wait_timeout(left.min(CANCEL_POLL)) {
            Ok(Some(status)) => return Outcome::Exited(status.code()),
            Ok(None) if left > CANCEL_POLL => {
                if cancel.as_ref().is_some_and(|cancel| cancel.exists()) {
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
fn end_group(child: &mut std::process::Child) {
    signal_group(child.id(), Signal::Terminate);
    let _ = child.wait_timeout(STOP_GRACE);
    signal_group(child.id(), Signal::Kill);
    let _ = child.kill();
    let _ = child.wait();
}

/// Runs a worktree's teardown before it is removed, after stopping a setup
/// still running there. Answers what `git.worktree.remove` reports of it.
pub(super) fn teardown(place: &Place, teardown: Option<&str>) -> Option<Value> {
    stop(place);
    let script = teardown?;
    let path = place.git_dir.join(LOG_FILE);
    let log = OpenOptions::new().create(true).read(true).append(true).open(&path).ok()?;
    let start = log.metadata().map_or(0, |metadata| metadata.len());
    let _ = writeln!(&log, "$ {script}");
    let outcome = shell(place, script, ports::lookup(&place.root), &log, TEARDOWN_DEADLINE, None);
    let (output, _, _) = tail(&path, start, MAX_TEARDOWN_OUTPUT_BYTES);
    let mut value = json!({"output": output});
    match outcome {
        Outcome::Exited(code) => {
            value["exit_code"] = json!(code);
            value["state"] = json!(if code == Some(0) { "succeeded" } else { "failed" });
        }
        Outcome::TimedOut => value["state"] = json!("timed_out"),
        Outcome::NotStarted(error) => {
            value["state"] = json!("failed");
            value["output"] = json!(error);
        }
    }
    Some(value)
}

/// A worktree folder with its links resolved, as the setup and its ports
/// are kept by it (`~/.cmux/worktrees` is a link on macOS).
pub(super) fn resolved(root: &Path) -> PathBuf {
    fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf())
}

/// After a removal: the worktree's ports go back.
pub(super) fn removed(root: &Path) {
    ports::free(root);
}

/// The setup of the worktree whose git folder is `git_dir`, and its output
/// from byte `since` (at most the last 64 KiB of it).
pub(super) fn read(root: &Path, git_dir: &Path, since: u64) -> Value {
    let port = ports::lookup(root);
    let Some(mut status) = read_status(git_dir) else {
        return json!({"state": "none", "port": port, "output": "", "output_start": "0", "output_end": "0"});
    };
    // Live here, or (for a setup another session host started) its
    // process group still there.
    let live = running().lock().unwrap_or_else(PoisonError::into_inner).contains_key(root)
        || status.pid.is_some_and(group_alive);
    if matches!(status.state.as_str(), "copying" | "running") && !live {
        status.state = "interrupted".into();
    }
    let (output, start, end) = tail(&git_dir.join(LOG_FILE), since, MAX_OUTPUT_BYTES);
    status.pid = None;
    let mut value = json!(status);
    value["port"] = json!(port.or(status.port));
    value["started_ms"] = json!(status.started_ms.to_string());
    if let Some(finished) = status.finished_ms {
        value["finished_ms"] = json!(finished.to_string());
    }
    value["output"] = json!(output);
    value["output_start"] = json!(start.to_string());
    value["output_end"] = json!(end.to_string());
    value
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
    let mut value = json!({
        "root": root.to_string_lossy(),
        "recipe": recipe.value(),
    });
    if let Some(main) = &main {
        value["main_root"] = json!(main.to_string_lossy());
    }
    // The main checkout is set up by its user, not by cmux.
    let linked = main.as_deref().is_none_or(|main| !same_folder(main, root));
    value["run"] = if linked {
        read(root, target.git_dir(), since)
    } else {
        json!({"state": "none", "output": "", "output_start": "0", "output_end": "0"})
    };
    Ok(value)
}

fn same_folder(left: &Path, right: &Path) -> bool {
    match (fs::canonicalize(left), fs::canonicalize(right)) {
        (Ok(left), Ok(right)) => left == right,
        _ => left == right,
    }
}

/// The text of `path` from `since` (or from where the last `limit` bytes
/// start, if later) to its end, with that start and end.
fn tail(path: &Path, since: u64, limit: u64) -> (String, u64, u64) {
    let Ok(mut file) = File::open(path) else { return (String::new(), 0, 0) };
    let end = file.metadata().map_or(0, |metadata| metadata.len());
    let start = since.min(end).max(end.saturating_sub(limit));
    let mut bytes = Vec::new();
    if file.seek(SeekFrom::Start(start)).is_ok() {
        let _ = file.take(end - start).read_to_end(&mut bytes);
    }
    (String::from_utf8_lossy(&bytes).into_owned(), start, start + bytes.len() as u64)
}

/// Stops the setup still running in `root`, if this session host runs one.
/// A copy stops at its next file and a setup that has not started never
/// does; a running setup's group gets SIGTERM, then SIGKILL for whatever is
/// left. A setup another session host started (or one from before a
/// restart) is told to stop by a file, and waited for.
fn stop(place: &Place) {
    let handle = running().lock().unwrap_or_else(PoisonError::into_inner).get(&place.root).cloned();
    let Some(handle) = handle else {
        // Another session host's setup: it stops itself on the cancel file.
        // A pid from a status file is never signalled here, since after a
        // crash or a restart it may name someone else's process.
        let unfinished = |status: Option<Status>| {
            status.is_some_and(|status| match status.state.as_str() {
                "copying" => true,
                "running" => status.pid.is_none_or(group_alive),
                _ => false,
            })
        };
        if unfinished(read_status(&place.git_dir)) {
            let _ = fs::write(place.git_dir.join(CANCEL_FILE), b"");
            let deadline = Instant::now() + CANCEL_POLL + STOP_GRACE * 2;
            while unfinished(read_status(&place.git_dir)) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        return;
    };
    let pid = {
        let pid = handle.pid.lock().unwrap_or_else(PoisonError::into_inner);
        handle.cancelled.store(true, Ordering::SeqCst);
        *pid
    };
    if let Some(pid) = pid {
        signal_group(pid, Signal::Terminate);
    }
    // The copy and the setup end within the grace once told to; the
    // thread is waited for so nothing starts after the teardown does.
    if !handle.wait(STOP_GRACE)
        && let Some(pid) = pid
    {
        signal_group(pid, Signal::Kill);
        handle.wait(STOP_GRACE);
    }
    if let Some(pid) = pid {
        signal_group(pid, Signal::Kill);
    }
}

/// A setup thread of this session host.
#[derive(Default)]
struct Run {
    cancelled: AtomicBool,
    /// The setup's process group once it started; set under this lock.
    pid: Mutex<Option<u32>>,
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

/// Whether any process of the group `pid` leads is left.
#[cfg(unix)]
fn group_alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the group exists.
    libc::pid_t::try_from(pid).is_ok_and(|group| unsafe { libc::kill(-group, 0) } == 0)
}

#[cfg(not(unix))]
fn group_alive(_pid: u32) -> bool {
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

fn read_status(git_dir: &Path) -> Option<Status> {
    serde_json::from_slice(&fs::read(git_dir.join(STATUS_FILE)).ok()?).ok()
}

fn write_status(path: &Path, status: &Status) -> std::io::Result<()> {
    let partial = path.with_extension("json.partial");
    fs::write(&partial, serde_json::to_vec(status)?)?;
    fs::rename(partial, path)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |elapsed| elapsed.as_millis() as u64)
}

/// The ports each worktree keeps, in `~/.cmux/worktree-ports.json`: the
/// first port of a block of ten by worktree folder. A folder that is gone
/// gives its block back on the next allocation.
mod ports {
    use super::*;

    /// This process's lock, then the file lock every session host's
    /// allocation takes (`worktree-ports.lock`, released when it closes).
    struct Lock {
        _guard: std::sync::MutexGuard<'static, ()>,
        _file: Option<File>,
    }

    fn lock() -> Lock {
        static LOCK: Mutex<()> = Mutex::new(());
        let guard = LOCK.lock().unwrap_or_else(PoisonError::into_inner);
        let file = path().and_then(|path| {
            fs::create_dir_all(path.parent()?).ok()?;
            OpenOptions::new()
                .create(true)
                .truncate(false)
                .write(true)
                .open(path.with_extension("lock"))
                .ok()
        });
        #[cfg(unix)]
        if let Some(file) = &file {
            use std::os::fd::AsRawFd as _;
            // SAFETY: flock(2) on a descriptor this process owns; it blocks
            // until another session host's allocation is done.
            unsafe {
                libc::flock(file.as_raw_fd(), libc::LOCK_EX);
            }
        }
        Lock { _guard: guard, _file: file }
    }

    fn path() -> Option<PathBuf> {
        crate::platform::home_dir().map(|home| home.join(".cmux").join("worktree-ports.json"))
    }

    fn load(path: &Path) -> BTreeMap<String, u16> {
        fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn save(path: &Path, ports: &BTreeMap<String, u16>) {
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let partial = path.with_extension("json.partial");
        if serde_json::to_vec_pretty(ports).is_ok_and(|bytes| fs::write(&partial, bytes).is_ok()) {
            let _ = fs::rename(partial, path);
        }
    }

    fn key(root: &Path) -> String {
        root.to_string_lossy().into_owned()
    }

    pub(super) fn lookup(root: &Path) -> Option<u16> {
        let _guard = lock();
        load(&path()?).get(&key(root)).copied()
    }

    /// The worktree's block, kept from before or the first free one whose
    /// first port nothing listens on.
    pub(super) fn allocate(root: &Path) -> Option<u16> {
        let _guard = lock();
        let path = path()?;
        let mut ports = load(&path);
        if let Some(port) = ports.get(&key(root)) {
            return Some(*port);
        }
        ports.retain(|folder, _| Path::new(folder).exists());
        let taken: std::collections::BTreeSet<u16> = ports.values().copied().collect();
        let port = (0..PORT_BLOCKS).map(|block| FIRST_PORT + block * PORT_BLOCK).find(|port| {
            !taken.contains(port) && TcpListener::bind((Ipv4Addr::LOCALHOST, *port)).is_ok()
        })?;
        ports.insert(key(root), port);
        save(&path, &ports);
        Some(port)
    }

    pub(super) fn free(root: &Path) {
        let _guard = lock();
        let Some(path) = path() else { return };
        let mut ports = load(&path);
        if ports.remove(&key(root)).is_some() {
            save(&path, &ports);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tail_reads_from_an_offset_within_the_limit() {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let path = std::env::temp_dir().join(format!("cmux-setup-log-{hex}"));
        fs::write(&path, "0123456789").unwrap();
        assert_eq!(tail(&path, 4, 100), ("456789".to_string(), 4, 10));
        assert_eq!(tail(&path, 0, 3), ("789".to_string(), 7, 10));
        assert_eq!(tail(&path, 99, 100), (String::new(), 10, 10));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn the_environment_has_both_names() {
        let place = Place {
            root: PathBuf::from("/w/fix-login"),
            main_root: Some(PathBuf::from("/repo")),
            git_dir: PathBuf::from("/repo/.git/worktrees/fix-login"),
        };
        let values = place.environment(Some(40_010));
        assert_eq!(values["CMUX_ROOT_PATH"], "/repo");
        assert_eq!(values["CONDUCTOR_ROOT_PATH"], "/repo");
        assert_eq!(values["CMUX_WORKSPACE_NAME"], "fix-login");
        assert_eq!(values["CONDUCTOR_PORT"], "40010");
    }

    #[cfg(unix)]
    #[test]
    fn a_setup_stops_itself_when_another_host_removes_the_worktree() {
        let mut bytes = [0_u8; 6];
        getrandom::fill(&mut bytes).unwrap();
        let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        let root = std::env::temp_dir().join(format!("cmux-setup-stop-{hex}"));
        fs::create_dir_all(&root).unwrap();
        let place = Place { root: root.clone(), main_root: None, git_dir: root.clone() };
        let log = File::create(root.join(LOG_FILE)).unwrap();
        let cancel = root.join(CANCEL_FILE);
        let other_host = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            fs::write(cancel, b"").unwrap();
        });
        let (handle, mut status) = (Run::default(), Status::default());
        let started = Instant::now();
        let outcome =
            shell(&place, "sleep 30", None, &log, SETUP_DEADLINE, Some((&handle, &mut status)));
        other_host.join().unwrap();
        assert!(matches!(outcome, Outcome::Exited(None)));
        assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
        fs::remove_dir_all(root).unwrap();
    }
}
