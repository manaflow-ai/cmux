//! `cmux live auto`: the daemon's save router (RFD 0168 slice 3).
//!
//! One watcher per checkout, owned by this daemon. Each burst of saves is
//! classified with `live_apply.py`'s own rules (`rules.rs`, read from the
//! checkout's `scripts/cmux-next/live-apply-rules.json`), routed to the
//! fastest layer that takes it (`route.rs`), and reported as one
//! `swap.done` event per layer on the `subscribe` stream:
//!
//! ```text
//! {event:"swap.done", worktree, layer, ms, trigger_ms, state_kept, paths,
//!  error?, reason?, daemons?, outcome?}
//! ```
//!
//! No prompt, no toast, no focus change: the router only emits the event.
//! rust-live swaps the very daemon that runs this router, so the watched
//! checkouts and the saves handed to it are kept in a state file
//! (`state.json`) and taken up again when the next daemon on the same
//! socket starts (`resume`); its receipt (`last.json`) then becomes the
//! `swap.done`.

pub mod route;
pub mod rules;
#[cfg(test)]
mod tests;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use notify::{EventKind, RecursiveMode, Watcher as _};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::Mux;
use route::{Action, Dispatch, Live, Saved};
use rules::{FfiClosure, Rules, Status};

/// One saved path: its status against HEAD, the path, and (Swift only) its
/// `-U0` diff lines.
pub type SavedFile = (Status, String, Vec<(char, String)>);

/// A burst ends when no save came for this long.
pub const QUIET: Duration = Duration::from_millis(8);
/// ...or this long after its first save, however busy the editor is.
pub const MAX_BURST: Duration = Duration::from_millis(40);
/// A hand-off rust-live never answers is reported failed after this.
const HANDOFF_TIMEOUT_SECS: f64 = 30.0 * 60.0;
/// `swap.done` events `status` keeps, newest last.
const RECENT: usize = 32;
/// Trigger samples `status` summarizes.
const SAMPLES: usize = 512;

/// Folders no save in them is a change to the app: build output, packages
/// and VCS state. Matched as any path component.
const SKIP_DIRS: &[&str] = &[
    ".git",
    "target",
    "node_modules",
    ".build",
    "DerivedData",
    "dist",
    ".vite",
    ".next",
    ".turbo",
    "__pycache__",
    ".swiftpm",
    "xcuserdata",
    ".zig-cache",
    "zig-cache",
    "zig-out",
];

/// An editor's scratch file, never the save itself.
fn scratch_file(name: &str) -> bool {
    name.ends_with('~')
        || name.ends_with(".swp")
        || name.ends_with(".swx")
        || name.ends_with(".tmp")
        || name.starts_with(".#")
        || name == "4913"
        || name == ".DS_Store"
}

/// The repo-relative path of `path` under `root`, or `None` when no save
/// there can change the app (outside the checkout, a skipped folder, an
/// editor's scratch file).
pub fn relevant(root: &Path, path: &Path) -> Option<String> {
    let rel = path.strip_prefix(root).ok()?;
    let mut parts = Vec::new();
    for part in rel.components() {
        let part = part.as_os_str().to_str()?;
        if SKIP_DIRS.contains(&part) {
            return None;
        }
        parts.push(part);
    }
    let name = parts.last()?;
    if scratch_file(name) {
        return None;
    }
    Some(parts.join("/"))
}

// ---------------------------------------------------------------- where things live

fn cache_root() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from);
    if cfg!(target_os = "macos") {
        return home.map(|h| h.join("Library/Caches"));
    }
    std::env::var_os("XDG_CACHE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| home.map(|h| h.join(".cache")))
}

fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|d| !d.is_empty()).map(PathBuf::from)
}

/// This router's state folder.
pub fn state_dir() -> Option<PathBuf> {
    env_dir("CMUX_LIVE_AUTO_STATE_DIR")
        .or_else(|| cache_root().map(|c| c.join("cmux-next/live-auto")))
}

/// rust-live.py's state folder (`state_dir()` there).
pub fn rust_live_dir() -> Option<PathBuf> {
    env_dir("CMUX_RUST_LIVE_STATE_DIR")
        .or_else(|| cache_root().map(|c| c.join("cmux-next/rust-live")))
}

/// web-overlay.sh's state folder.
fn web_slot_dir() -> Option<PathBuf> {
    env_dir("CMUX_WEB_SLOT_STATE_DIR").or_else(|| {
        std::env::var_os("HOME")
            .filter(|h| !h.is_empty())
            .map(|h| PathBuf::from(h).join("Library/Caches/cmux-next/web-slot"))
    })
}

/// live-mode.py's `tree` file.
fn live_mode_tree() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(|h| PathBuf::from(h).join("Library/Caches/cmux-next/live-mode/tree"))
}

fn first_line(file: &Path) -> Option<String> {
    let text = std::fs::read_to_string(file).ok()?;
    Some(text.lines().next()?.trim().to_string())
}

fn same_tree(a: &Path, b: &Path) -> bool {
    a == b
        || std::fs::canonicalize(a)
            .ok()
            .zip(std::fs::canonicalize(b).ok())
            .is_some_and(|(x, y)| x == y)
}

#[cfg(unix)]
fn pid_alive(pid: i32) -> bool {
    // SAFETY: kill with signal 0 only asks whether the process exists.
    pid > 0 && unsafe { libc::kill(pid, 0) } == 0
}

#[cfg(not(unix))]
fn pid_alive(_pid: i32) -> bool {
    false
}

/// The layers running for `root` now, from the files their tools write.
pub fn probe(root: &Path) -> Live {
    let web = web_slot_dir()
        .and_then(|dir| first_line(&dir.join("dev-server.tree")))
        .and_then(|line| line.rsplit_once(':').map(|(tree, _)| PathBuf::from(tree)))
        .is_some_and(|tree| same_tree(&tree, root));
    let rust = rust_live_dir()
        .and_then(|dir| first_line(&dir.join("watch.pid")))
        .and_then(|line| {
            let (pid, tree) = line.split_once(' ')?;
            Some((pid.parse::<i32>().ok()?, PathBuf::from(tree)))
        })
        .is_some_and(|(pid, tree)| pid_alive(pid) && same_tree(&tree, root));
    let swift = live_mode_tree()
        .and_then(|file| first_line(&file))
        .is_some_and(|tree| same_tree(Path::new(&tree), root));
    Live { web, rust, swift }
}

// ---------------------------------------------------------------- the checkout's state

fn git(root: &Path, args: &[&str]) -> Option<String> {
    let out = cmux_process::Command::new("git").arg("-C").arg(root).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// The app FFI closure, as `live_apply.py --ffi-closure` prints it
/// (`cmux_next_route.app_ffi_inputs` and `app_ffi_excluded`).
pub fn ffi_closure(root: &Path) -> Result<FfiClosure, String> {
    let out = cmux_process::Command::new("python3")
        .arg(root.join("scripts/cmux-next/live_apply.py"))
        .args(["--repo".as_ref(), root.as_os_str(), "--ffi-closure".as_ref()])
        .current_dir(root)
        .output()
        .map_err(|error| format!("live_apply.py --ffi-closure: {error}"))?;
    if !out.status.success() {
        return Err(format!(
            "live_apply.py --ffi-closure: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    #[derive(Deserialize)]
    struct Closure {
        inputs: Vec<String>,
        excluded: Vec<String>,
    }
    let closure: Closure = serde_json::from_slice(&out.stdout)
        .map_err(|error| format!("live_apply.py --ffi-closure: {error}"))?;
    Ok(FfiClosure { inputs: closure.inputs, excluded: closure.excluded })
}

/// Each saved path's status against HEAD, and the `-U0` diff of the Swift
/// ones (the only files whose verdict reads lines).
fn saved_files(root: &Path, paths: &[String]) -> Vec<SavedFile> {
    let swift: Vec<&str> = paths
        .iter()
        .filter(|p| p.ends_with(".swift") && root.join(p).exists())
        .map(String::as_str)
        .collect();
    let mut tracked = HashSet::new();
    let mut diffs: HashMap<String, Vec<(char, String)>> = HashMap::new();
    if !swift.is_empty() {
        let mut args = vec!["ls-files", "--"];
        args.extend(&swift);
        for line in git(root, &args).unwrap_or_default().lines() {
            tracked.insert(line.to_string());
        }
        let mut args =
            vec!["diff", "-U0", "--no-ext-diff", "--no-color", "--no-renames", "HEAD", "--"];
        args.extend(&swift);
        diffs = parse_diff(&git(root, &args).unwrap_or_default());
    }
    paths
        .iter()
        .map(|path| {
            let status = if !root.join(path).exists() {
                Status::Deleted
            } else if path.ends_with(".swift") && !tracked.contains(path) {
                Status::Added
            } else {
                Status::Modified
            };
            let lines = if status == Status::Added {
                // An untracked file has no diff: all of it is new.
                std::fs::read_to_string(root.join(path))
                    .unwrap_or_default()
                    .lines()
                    .map(|l| ('+', l.to_string()))
                    .collect()
            } else {
                diffs.remove(path).unwrap_or_default()
            };
            (status, path.clone(), lines)
        })
        .collect()
}

/// path -> (`+` or `-`, text), from a unified diff (`live_apply.parse_diff`).
pub fn parse_diff(text: &str) -> HashMap<String, Vec<(char, String)>> {
    let mut diffs: HashMap<String, Vec<(char, String)>> = HashMap::new();
    let mut current: Option<String> = None;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix("+++ ") {
            current = rest.strip_prefix("b/").map(str::to_string);
            if let Some(path) = &current {
                diffs.entry(path.clone()).or_default();
            }
        } else if line.starts_with("--- ") {
            continue;
        } else if let Some(path) = &current
            && let Some(sign @ ('+' | '-')) = line.chars().next()
        {
            diffs
                .entry(path.clone())
                .or_default()
                .push((sign, line.get(1..).unwrap_or_default().to_string()));
        }
    }
    diffs
}

/// Classifies and routes one burst: the pure part, with what runs given.
pub fn plan(rules: &Rules, files: &[SavedFile], live: Live) -> Vec<Dispatch> {
    let saved: Vec<Saved> = files
        .iter()
        .map(|(status, path, diff)| Saved {
            path: path.clone(),
            verdict: rules.classify(*status, path, diff),
            ffi: rules.ffi.contains(path),
        })
        .collect();
    route::route(&saved, live)
}

fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

fn mtime_secs(path: &Path) -> Option<f64> {
    let modified = std::fs::metadata(path).ok()?.modified().ok()?;
    Some(modified.duration_since(UNIX_EPOCH).ok()?.as_secs_f64())
}

fn round_ms(secs: f64) -> f64 {
    (secs * 1_000_000.0).round() / 1000.0
}

/// The `swap.done` payload for a dispatch that goes out now.
pub fn event(root: &Path, dispatch: &Dispatch, trigger_ms: f64) -> Value {
    let mut out = json!({
        "event": "swap.done",
        "worktree": root.display().to_string(),
        "layer": dispatch.layer.as_str(),
        "ms": trigger_ms,
        "trigger_ms": trigger_ms,
        "state_kept": dispatch.state_kept,
        "paths": dispatch.paths,
    });
    if let Some(error) = &dispatch.error {
        put(&mut out, "error", json!(error));
    }
    if let Some(reason) = &dispatch.reason {
        put(&mut out, "reason", json!(reason));
    }
    out
}

// ---------------------------------------------------------------- rust-live hand-offs

/// A save handed to rust-live, waiting for its receipt.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Pending {
    pub worktree: PathBuf,
    pub layer: String,
    pub paths: Vec<String>,
    /// The burst's latest save (file mtime, epoch seconds).
    pub saved_at: f64,
    pub dispatched_at: f64,
    pub trigger_ms: f64,
}

/// A rust-live receipt path (relative to `cmux-tui/`, `../` for outside
/// it) as a repo-relative one.
fn receipt_path(file: &str) -> String {
    match file.strip_prefix("../") {
        Some(outside) => outside.to_string(),
        None => format!("cmux-tui/{file}"),
    }
}

/// The receipt's identity: a new `last.json` has a new one.
pub fn receipt_key(entry: &Value) -> String {
    format!(
        "{}|{}|{}",
        entry.get("saved_at").and_then(Value::as_f64).unwrap_or(0.0),
        entry.get("swapped_at").and_then(Value::as_f64).unwrap_or(0.0),
        entry.get("outcome").and_then(Value::as_str).unwrap_or(""),
    )
}

/// The `swap.done` events one rust-live receipt answers, and the hand-offs
/// still waiting after it. A hand-off is answered by the first receipt
/// that names one of its paths, or that covers a save at least as new
/// (rust-live takes every change since its last scan in one build).
pub fn settle(pending: Vec<Pending>, entry: &Value, now: f64) -> (Vec<Value>, Vec<Pending>) {
    let files: HashSet<String> = entry
        .get("files")
        .and_then(Value::as_array)
        .map(|files| files.iter().filter_map(Value::as_str).map(receipt_path).collect())
        .unwrap_or_default();
    let saved_at = entry.get("saved_at").and_then(Value::as_f64).unwrap_or(0.0);
    let outcome = entry.get("outcome").and_then(Value::as_str).unwrap_or("failed");
    let daemons: Vec<String> = entry
        .get("daemons")
        .and_then(Value::as_array)
        .map(|d| d.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default();
    let mut events = Vec::new();
    let mut waiting = Vec::new();
    for item in pending {
        // mtime and rust-live's saved_at round differently: 2 ms of slack.
        let answered =
            item.paths.iter().any(|p| files.contains(p)) || saved_at + 0.002 >= item.saved_at;
        if !answered {
            if now - item.dispatched_at > HANDOFF_TIMEOUT_SECS {
                events.push(handoff_event(
                    &item,
                    None,
                    "rust-live made no receipt for this save",
                    now,
                ));
            } else {
                waiting.push(item);
            }
            continue;
        }
        events.push(receipt_event(&item, entry, outcome, &daemons, now));
    }
    (events, waiting)
}

fn handoff_event(item: &Pending, layer: Option<&str>, error: &str, now: f64) -> Value {
    json!({
        "event": "swap.done",
        "worktree": item.worktree.display().to_string(),
        "layer": layer.unwrap_or(&item.layer),
        "ms": round_ms(now - item.saved_at),
        "trigger_ms": item.trigger_ms,
        "state_kept": false,
        "paths": item.paths,
        "error": error,
    })
}

fn receipt_event(
    item: &Pending,
    entry: &Value,
    outcome: &str,
    daemons: &[String],
    now: f64,
) -> Value {
    let layer = if daemons.iter().all(|d| d == "acpmux") && !daemons.is_empty() {
        "acpmux"
    } else {
        "daemon"
    };
    if outcome != "swapped" {
        let error = entry
            .get("reason")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| entry.get("error").and_then(Value::as_str).map(str::to_string))
            .or_else(|| {
                entry.get("errors").and_then(Value::as_array).map(|errors| {
                    errors.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("; ")
                })
            })
            .unwrap_or_default();
        let mut out = handoff_event(item, Some(layer), &format!("{outcome}: {error}"), now);
        put(&mut out, "outcome", json!(outcome));
        put(&mut out, "daemons", json!(daemons));
        return out;
    }
    // rust-live's own save-to-swapped time, from the receipt; the router's
    // view (this save's mtime to now) when the receipt lacks it.
    let ms = entry
        .get("save_to_swapped_secs")
        .and_then(Value::as_f64)
        .map(round_ms)
        .unwrap_or_else(|| round_ms(now - item.saved_at));
    // `server restart` (no app hand-off) ends the daemon's sessions; an
    // app hand-off and acpmux's restart keep them.
    let restarted = entry
        .get("swap")
        .and_then(|swap| swap.get("cmux-tui"))
        .and_then(Value::as_str)
        .is_some_and(|step| step == "server restart");
    json!({
        "event": "swap.done",
        "worktree": item.worktree.display().to_string(),
        "layer": layer,
        "ms": ms,
        "trigger_ms": item.trigger_ms,
        "state_kept": !restarted,
        "paths": item.paths,
        "daemons": daemons,
        "outcome": outcome,
    })
}

// ---------------------------------------------------------------- persisted state

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct StateFile {
    /// Watched checkouts, each with the socket of the daemon that watches it.
    #[serde(default)]
    pub trees: Vec<TreeEntry>,
    #[serde(default)]
    pub pending: Vec<Pending>,
    /// The last rust-live receipt already reported (`receipt_key`).
    #[serde(default)]
    pub reported: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct TreeEntry {
    pub worktree: PathBuf,
    pub socket: PathBuf,
}

fn load_state(dir: &Path) -> StateFile {
    std::fs::read(dir.join("state.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn store_state(dir: &Path, state: &StateFile) {
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let tmp = dir.join(format!("state.json.{}", std::process::id()));
    if let Ok(bytes) = serde_json::to_vec_pretty(state)
        && std::fs::write(&tmp, bytes).is_ok()
    {
        let _ = std::fs::rename(&tmp, dir.join("state.json"));
    }
}

// ---------------------------------------------------------------- the router

type Emit = Arc<dyn Fn(Value) + Send + Sync>;

#[derive(Default)]
struct Stats {
    bursts: u64,
    saves: u64,
    no_app: u64,
    trigger_ms: VecDeque<f64>,
}

struct Tree {
    stop: Sender<Wake>,
    stats: Arc<Mutex<Stats>>,
    started_at: f64,
    error: Arc<Mutex<Option<String>>>,
}

struct Router {
    emit: Option<Emit>,
    socket: PathBuf,
    state: Option<PathBuf>,
    trees: HashMap<PathBuf, Tree>,
    recent: Arc<Mutex<VecDeque<Value>>>,
    /// Serializes `state.json` read-modify-writes between watchers.
    file: Arc<Mutex<()>>,
}

enum Wake {
    Fs(notify::Result<notify::Event>),
    Stop,
}

fn router() -> &'static Mutex<Router> {
    static ROUTER: OnceLock<Mutex<Router>> = OnceLock::new();
    ROUTER.get_or_init(|| {
        Mutex::new(Router {
            emit: None,
            socket: PathBuf::new(),
            state: state_dir(),
            trees: HashMap::new(),
            recent: Arc::new(Mutex::new(VecDeque::new())),
            file: Arc::new(Mutex::new(())),
        })
    })
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// At daemon start: keeps the bus to emit on, and watches again every
/// checkout this socket's daemon watched (rust-live may just have swapped
/// it), reporting the receipts that came while no daemon ran.
pub fn resume(mux: &Arc<Mux>, socket: &Path) {
    let weak: Weak<Mux> = Arc::downgrade(mux);
    let emit: Emit = Arc::new(move |payload: Value| {
        if let Some(mux) = weak.upgrade() {
            mux.emit(crate::MuxEvent::SwapDone(Arc::new(payload)));
        }
    });
    let trees = {
        let mut router = lock(router());
        router.emit = Some(emit);
        router.socket = socket.to_path_buf();
        let Some(dir) = router.state.clone() else { return };
        load_state(&dir).trees
    };
    for entry in trees.into_iter().filter(|t| t.socket == socket) {
        if let Err(error) = start(&entry.worktree) {
            eprintln!("cmux-tui: live auto: {}: {error}", entry.worktree.display());
        }
    }
}

/// `live-auto {op:"start", worktree}`: watches the checkout.
pub fn start(worktree: &Path) -> Result<Value, String> {
    let root = std::fs::canonicalize(worktree)
        .map_err(|error| format!("{}: {error}", worktree.display()))?;
    if !root.join(rules::RULES_FILE).is_file() {
        return Err(format!(
            "{} is not a cmux checkout with {} (update it to a feat-cmux-next with cmux live auto)",
            root.display(),
            rules::RULES_FILE
        ));
    }
    let mut router = lock(router());
    if router.trees.contains_key(&root) {
        drop(router);
        return Ok(status());
    }
    let emit = router.emit.clone().unwrap_or_else(|| Arc::new(|_| {}));
    let recent = router.recent.clone();
    let tee: Emit = Arc::new(move |payload: Value| {
        {
            let mut recent = lock(&recent);
            if recent.len() >= RECENT {
                recent.pop_front();
            }
            recent.push_back(payload.clone());
        }
        emit(payload);
    });
    let (sender, wakes) = channel();
    let stats = Arc::new(Mutex::new(Stats::default()));
    let error = Arc::new(Mutex::new(None));
    let watch = Watch {
        root: root.clone(),
        emit: tee,
        stats: stats.clone(),
        error: error.clone(),
        state: router.state.clone(),
        file: router.file.clone(),
        probe: Arc::new(probe),
        ffi: None,
    };
    let wake = sender.clone();
    std::thread::Builder::new()
        .name("live-auto".into())
        .spawn(move || watch.run(wake, wakes))
        .map_err(|error| format!("live auto thread: {error}"))?;
    router.trees.insert(root.clone(), Tree { stop: sender, stats, started_at: now_secs(), error });
    if let Some(dir) = router.state.clone() {
        let socket = router.socket.clone();
        let _guard = lock(&router.file);
        let mut state = load_state(&dir);
        state.trees.retain(|t| t.worktree != root);
        state.trees.push(TreeEntry { worktree: root, socket });
        store_state(&dir, &state);
    }
    drop(router);
    Ok(status())
}

/// `live-auto {op:"stop", worktree?}`: stops one checkout, or every one.
pub fn stop(worktree: Option<&Path>) -> Value {
    let root = worktree.map(|w| std::fs::canonicalize(w).unwrap_or_else(|_| w.to_path_buf()));
    let mut router = lock(router());
    let names: Vec<PathBuf> =
        router.trees.keys().filter(|k| root.as_ref().is_none_or(|r| *k == r)).cloned().collect();
    for name in &names {
        if let Some(tree) = router.trees.remove(name) {
            let _ = tree.stop.send(Wake::Stop);
        }
    }
    if let Some(dir) = router.state.clone() {
        let _guard = lock(&router.file);
        let mut state = load_state(&dir);
        state.trees.retain(|t| root.as_ref().is_some_and(|r| t.worktree != *r));
        state.pending.retain(|p| root.as_ref().is_some_and(|r| p.worktree != *r));
        store_state(&dir, &state);
    }
    drop(router);
    let mut out = status();
    put(
        &mut out,
        "stopped",
        json!(names.iter().map(|n| n.display().to_string()).collect::<Vec<_>>()),
    );
    out
}

/// Sets `key` on a JSON object; a non-object is left as it is.
fn put(out: &mut Value, key: &str, value: Value) {
    if let Some(map) = out.as_object_mut() {
        map.insert(key.to_owned(), value);
    }
}

/// p50 and p95 of `samples` (nearest rank).
pub fn percentiles(samples: &[f64]) -> (f64, f64) {
    if samples.is_empty() {
        return (0.0, 0.0);
    }
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let rank = |q: f64| {
        let nth = ((q * sorted.len() as f64).ceil() as usize).clamp(1, sorted.len());
        sorted.get(nth.saturating_sub(1)).copied().unwrap_or_default()
    };
    (rank(0.50), rank(0.95))
}

/// `live-auto {op:"status"}`: the watched checkouts, what runs for each,
/// their trigger latency and the latest `swap.done` events.
pub fn status() -> Value {
    let router = lock(router());
    let trees: Vec<Value> = router
        .trees
        .iter()
        .map(|(root, tree)| {
            let stats = lock(&tree.stats);
            let samples: Vec<f64> = stats.trigger_ms.iter().copied().collect();
            let (p50, p95) = percentiles(&samples);
            let live = probe(root);
            json!({
                "worktree": root.display().to_string(),
                "started_at": tree.started_at,
                "live": {"web": live.web, "rust": live.rust, "swift": live.swift},
                "bursts": stats.bursts,
                "saves": stats.saves,
                "no_app": stats.no_app,
                "trigger_ms": {"p50": p50, "p95": p95, "samples": samples.len()},
                "error": *lock(&tree.error),
            })
        })
        .collect();
    let pending = router.state.as_deref().map(load_state).map(|s| s.pending).unwrap_or_default();
    json!({
        "trees": trees,
        "pending": pending,
        "recent": lock(&router.recent).iter().cloned().collect::<Vec<_>>(),
        "debounce_ms": {"quiet": QUIET.as_millis() as u64, "max": MAX_BURST.as_millis() as u64},
    })
}

/// One checkout's watcher thread.
pub struct Watch {
    pub root: PathBuf,
    pub emit: Emit,
    stats: Arc<Mutex<Stats>>,
    error: Arc<Mutex<Option<String>>>,
    pub state: Option<PathBuf>,
    file: Arc<Mutex<()>>,
    pub probe: Arc<dyn Fn(&Path) -> Live + Send + Sync>,
    /// The app FFI closure, when known already (tests); else read at start.
    pub ffi: Option<FfiClosure>,
}

impl Watch {
    fn fail(&self, message: String) {
        eprintln!("cmux-tui: live auto: {}: {message}", self.root.display());
        *lock(&self.error) = Some(message);
    }

    fn run(self, wake: Sender<Wake>, wakes: Receiver<Wake>) {
        // Armed first: a save while the rules load waits in the channel.
        let sender = wake;
        let mut watcher = match notify::recommended_watcher(move |event| {
            let _ = sender.send(Wake::Fs(event));
        }) {
            Ok(watcher) => watcher,
            Err(error) => return self.fail(format!("watch: {error}")),
        };
        if let Err(error) = arm(&mut watcher, &self.root) {
            return self.fail(format!("watch {}: {error}", self.root.display()));
        }
        let receipts = rust_live_dir();
        if let Some(dir) = &receipts {
            let _ = std::fs::create_dir_all(dir);
            let _ = watcher.watch(dir, RecursiveMode::NonRecursive);
        }
        let ffi = match self.ffi.clone() {
            Some(ffi) => ffi,
            None => ffi_closure(&self.root).unwrap_or_else(|error| {
                self.fail(format!("{error}; app FFI inputs are routed as daemon Rust only"));
                FfiClosure::default()
            }),
        };
        let mut rules = match Rules::load(&self.root, ffi) {
            Ok(rules) => rules,
            Err(error) => return self.fail(error),
        };
        // Receipts that came while no daemon ran (rust-live swapped this one).
        self.check_receipt(receipts.as_deref());
        loop {
            let first = match wakes.recv_timeout(Duration::from_secs(60)) {
                Ok(Wake::Stop) | Err(RecvTimeoutError::Disconnected) => return,
                Ok(Wake::Fs(event)) => event,
                Err(RecvTimeoutError::Timeout) => {
                    self.check_receipt(receipts.as_deref());
                    continue;
                }
            };
            let began = Instant::now();
            let mut paths: Vec<PathBuf> = Vec::new();
            let mut receipt = false;
            let mut new_dirs = Vec::new();
            let mut take = |event: notify::Result<notify::Event>| {
                let Ok(event) = event else { return };
                if matches!(event.kind, EventKind::Access(_)) {
                    return;
                }
                for path in event.paths {
                    if receipts.as_deref().is_some_and(|dir| path.parent() == Some(dir)) {
                        receipt |= path.file_name().is_some_and(|n| n == "last.json");
                    } else {
                        if matches!(event.kind, EventKind::Create(_)) && path.is_dir() {
                            new_dirs.push(path.clone());
                        }
                        paths.push(path);
                    }
                }
            };
            take(first);
            // The burst: until QUIET passes with no event, at most MAX_BURST.
            let mut stopped = false;
            loop {
                let left = MAX_BURST.saturating_sub(began.elapsed());
                if left.is_zero() {
                    break;
                }
                match wakes.recv_timeout(QUIET.min(left)) {
                    Ok(Wake::Fs(event)) => take(event),
                    Ok(Wake::Stop) | Err(RecvTimeoutError::Disconnected) => {
                        stopped = true;
                        break;
                    }
                    Err(RecvTimeoutError::Timeout) => break,
                }
            }
            if stopped {
                return;
            }
            for dir in &new_dirs {
                if relevant(&self.root, dir).is_some() {
                    let _ = arm(&mut watcher, dir);
                }
            }
            let mut seen = HashSet::new();
            let rels: Vec<String> = paths
                .iter()
                .filter(|p| !p.is_dir())
                .filter_map(|p| relevant(&self.root, p))
                .filter(|p| seen.insert(p.clone()))
                .collect();
            if !rels.is_empty() {
                self.dispatch(&rules, &rels, began);
                // After the dispatch, never before it: the FFI closure takes
                // seconds to read (live_apply.py --ffi-closure), and only a
                // later save can depend on it.
                let manifest = rels.iter().any(|p| p.ends_with("Cargo.toml"));
                if manifest
                    || rels.iter().any(|p| p == rules::RULES_FILE || p == rules::CLASSES_FILE)
                {
                    let ffi = if manifest {
                        ffi_closure(&self.root).unwrap_or_else(|_| rules.ffi.clone())
                    } else {
                        rules.ffi.clone()
                    };
                    match Rules::load(&self.root, ffi) {
                        Ok(new) => rules = new,
                        Err(error) => self.fail(error),
                    }
                }
            }
            if receipt {
                self.check_receipt(receipts.as_deref());
            }
        }
    }

    /// Classifies, routes and reports one burst; returns its trigger time.
    pub fn dispatch(&self, rules: &Rules, rels: &[String], began: Instant) -> Option<f64> {
        let files = saved_files(&self.root, rels);
        let live = (self.probe)(&self.root);
        let dispatches = plan(rules, &files, live);
        // The latest save in the burst: what the person waits on.
        let saved_at =
            rels.iter().filter_map(|p| mtime_secs(&self.root.join(p))).fold(f64::NAN, f64::max);
        let now = now_secs();
        let since_event = began.elapsed().as_secs_f64();
        // fs event to dispatch: from the last save's mtime when it is known
        // (it counts the event's delivery too), else from the burst's first event.
        let trigger =
            if saved_at.is_finite() && now >= saved_at { now - saved_at } else { since_event };
        let trigger_ms = round_ms(trigger);
        {
            let mut stats = lock(&self.stats);
            stats.bursts += 1;
            stats.saves += rels.len() as u64;
            if dispatches.is_empty() {
                stats.no_app += 1;
            } else {
                if stats.trigger_ms.len() >= SAMPLES {
                    stats.trigger_ms.pop_front();
                }
                stats.trigger_ms.push_back(trigger_ms);
            }
        }
        if dispatches.is_empty() {
            return None;
        }
        let mut handed = Vec::new();
        for dispatch in &dispatches {
            match dispatch.action {
                Action::Observed | Action::Report => {
                    (self.emit)(event(&self.root, dispatch, trigger_ms));
                }
                Action::HandOff => handed.push(Pending {
                    worktree: self.root.clone(),
                    layer: dispatch.layer.as_str().to_string(),
                    paths: dispatch.paths.clone(),
                    saved_at: if saved_at.is_finite() { saved_at } else { now - since_event },
                    dispatched_at: now,
                    trigger_ms,
                }),
            }
        }
        if !handed.is_empty()
            && let Some(dir) = &self.state
        {
            let _guard = lock(&self.file);
            let mut state = load_state(dir);
            state.pending.extend(handed);
            store_state(dir, &state);
        }
        Some(trigger_ms)
    }

    /// Reports a new rust-live receipt to the hand-offs it answers.
    pub fn check_receipt(&self, receipts: Option<&Path>) {
        let (Some(dir), Some(state_dir)) = (receipts, &self.state) else { return };
        let Some(entry) = std::fs::read(dir.join("last.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        else {
            return;
        };
        let key = receipt_key(&entry);
        let events = {
            let _guard = lock(&self.file);
            let mut state = load_state(state_dir);
            let (mine, others): (Vec<Pending>, Vec<Pending>) = std::mem::take(&mut state.pending)
                .into_iter()
                .partition(|p| p.worktree == self.root);
            if mine.is_empty() {
                state.pending = others;
                state.reported = Some(key);
                store_state(state_dir, &state);
                return;
            }
            if state.reported.as_deref() == Some(key.as_str()) {
                // Seen already: only time-outs can come of it.
                let (events, waiting) = settle(mine, &json!({"saved_at": -1.0}), now_secs());
                state.pending = others.into_iter().chain(waiting).collect();
                store_state(state_dir, &state);
                events
            } else {
                let (events, waiting) = settle(mine, &entry, now_secs());
                state.pending = others.into_iter().chain(waiting).collect();
                state.reported = Some(key);
                store_state(state_dir, &state);
                events
            }
        };
        for payload in events {
            (self.emit)(payload);
        }
    }
}

/// Watches `dir` for saves. FSEvents (macOS) takes the whole tree in one
/// stream; inotify needs a watch per folder, so it walks the tree past the
/// skipped folders, and new folders are armed as they appear.
fn arm(watcher: &mut notify::RecommendedWatcher, dir: &Path) -> notify::Result<()> {
    if cfg!(target_os = "macos") {
        return watcher.watch(dir, RecursiveMode::Recursive);
    }
    let mut stack = vec![dir.to_path_buf()];
    let mut first = true;
    while let Some(folder) = stack.pop() {
        match watcher.watch(&folder, RecursiveMode::NonRecursive) {
            Ok(()) => {}
            Err(error) if first => return Err(error),
            Err(_) => continue,
        }
        first = false;
        let Ok(entries) = std::fs::read_dir(&folder) else { continue };
        for entry in entries.flatten() {
            let is_dir = entry.file_type().is_ok_and(|t| t.is_dir());
            let name = entry.file_name();
            if is_dir && !name.to_str().is_some_and(|n| SKIP_DIRS.contains(&n)) {
                stack.push(entry.path());
            }
        }
    }
    Ok(())
}

/// The `live-auto` command.
pub fn command(op: &str, worktree: Option<&str>) -> anyhow::Result<Value> {
    match op {
        "start" => {
            let tree = worktree.ok_or_else(|| anyhow::anyhow!("live-auto start needs worktree"))?;
            start(Path::new(tree)).map_err(anyhow::Error::msg)
        }
        "stop" => Ok(stop(worktree.map(Path::new))),
        "status" => Ok(status()),
        other => anyhow::bail!("live-auto: unknown op {other} (start, stop, status)"),
    }
}
