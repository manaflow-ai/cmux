//! The app-build path of `cmux app try <PR|branch|sha>`: a whole Release build of a commit that is not
//! in the nightly feed (a PR head, a branch), installed in place of this app with its sessions, settings
//! and sign-in data, and put back by `cmux app try undo`. The Rust form of leo-workspace
//! `dev-build-try --in-place`, so any NIGHTLY does it with no checkout and no GitHub token
//! (cmuxterm-hq docs/design/cmux-next-hot-swap-layers.md, "Move the full-app step into the app's CLI").
//!
//! CI publishes the build (reload-build.yml with `release` and `publish`): `cmux-tui/<commit>/mac-app-release.zip`
//! and the signed `cmux-tui/<commit>/mac-app.json` naming its sha256 (purpose `cmux-mac-app-build`, the same
//! envelope and keys as `mac-live.json`). Here:
//! 1. **Stage** (this process): the zip is downloaded into the store (`apps/<sha256>.zip`, size and sha256
//!    checked), unpacked, its `CMUXCommit` checked against the commit, then given this app's identity (bundle id,
//!    names, version, URL schemes, LSEnvironment, the Sparkle and Iroh keys: every key its state, sign-in and
//!    updates come from), marked [`MARKER`] and sealed ad hoc, verified.
//! 2. **Swap** (a detached `cmux app try __swap SPEC`, a copy of this CLI outside the app, so the app can quit
//!    under it, as when the palette runs this): the app quits with `cmux app quit --keep-sessions`, is moved
//!    aside as the original (`in-place/<App>.app` in the store; an app that is already a try keeps the first
//!    original), the build moves into its path and opens behind, and it must come up within [`START`] and stay
//!    up [`WATCH`], else the app it replaced goes back. The receipt (`last.json`) says which.
//! 3. **Undo** puts the original back the same way. An update (Sparkle) that replaced the try ends it too: the try
//!    carries the app's own version, so the next nightly updates it like any other.
//!
//! The ad hoc seal costs the team-signed Keychain items: the try may start signed out (`cmux login` in it; undo
//! brings the original back still signed in), and macOS may ask again for Accessibility or Screen Recording.

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_json::JsonGet as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::live::{self, Store};

/// The payload's `purpose`.
pub(super) const PURPOSE: &str = "cmux-mac-app-build";
pub(super) const SCHEMA: u64 = 1;
/// The published zip: a Release app is a few hundred megabytes.
pub(super) const ZIP_MAX_BYTES: u64 = 4 << 30;
/// The Info.plist key that marks an in-place try: `{commit, original_commit, original_version}`.
pub(super) const MARKER: &str = "CMUXInPlaceTry";
/// Seconds the swapped app has to come up, then to stay up (dev-build-try IN_PLACE_START, IN_PLACE_WATCH).
pub(super) const START: Duration = Duration::from_secs(90);
pub(super) const WATCH: Duration = Duration::from_secs(30);
/// How long the app has to quit with its sessions kept.
const QUIT_WAIT: Duration = Duration::from_secs(90);
/// The hidden word the detached swap runs under.
pub(super) const SWAP_VERB: &str = "__swap";

/// The keys an app's identity is made of (dev-build-try IDENTITY_KEYS): the try takes exactly the app's own.
const IDENTITY_KEYS: &[&str] = &[
    "CFBundleIdentifier",
    "CFBundleName",
    "CFBundleDisplayName",
    "CFBundleVersion",
    "CFBundleShortVersionString",
    "CFBundleURLTypes",
    "LSEnvironment",
    "CMUXCloudDogfoodEnabled",
    "CMUXLiveCodeBuild",
];
const IDENTITY_PREFIXES: &[&str] = &["SU", "CMUXIroh", "CMUX_IROH_"];

pub(super) fn identity_key(key: &str) -> bool {
    IDENTITY_KEYS.contains(&key) || IDENTITY_PREFIXES.iter().any(|prefix| key.starts_with(prefix))
}

/// The published zip `mac-app.json` names.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(super) struct AppZip {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

/// `cmux-tui/<commit>/mac-app.json`'s payload (CI's `cmux-machine-channel.py --purpose mac-app`).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub(super) struct AppPayload {
    pub schema: u64,
    pub purpose: String,
    pub commit: String,
    #[serde(default)]
    pub configuration: String,
    pub app: AppZip,
    #[serde(default)]
    pub run_id: String,
}

/// The one url a commit's app zip may have.
pub(super) fn zip_url(commit: &str) -> String {
    format!("{}{commit}/mac-app-release.zip", cmux_host::updater::channel::FILES_PREFIX)
}

/// The payload of `body` when a `keys` signature covers it, it is a Mac app build of `commit` and its zip is
/// the commit's own publication with a well-formed sha256 and size; else why not.
pub(super) fn verify(
    body: &[u8],
    keys: &[(String, [u8; 32])],
    commit: &str,
) -> Result<AppPayload, String> {
    let bytes = cmux_host::updater::channel::open_envelope(body, keys)?;
    let payload: AppPayload =
        serde_json::from_slice(&bytes).map_err(|e| format!("the payload does not parse: {e}"))?;
    if payload.schema != SCHEMA {
        return Err(format!("unknown payload schema {}", payload.schema));
    }
    if payload.purpose != PURPOSE {
        return Err(format!("the payload is for {}, not a Mac app build", payload.purpose));
    }
    if payload.commit != commit {
        return Err(format!("the file is {}'s, not {commit}'s", payload.commit));
    }
    if payload.app.url != zip_url(commit) {
        return Err(format!("the app's url is not {}", zip_url(commit)));
    }
    if !cmux_host::updater::channel::lower_hex(&payload.app.sha256, 64) {
        return Err("the app's sha256 is not a sha256".to_owned());
    }
    if payload.app.size == 0 || payload.app.size > ZIP_MAX_BYTES {
        return Err(format!("the app's size {} is out of range", payload.app.size));
    }
    Ok(payload)
}

/// What `mac-app.json` says for `commit`: `Ok(None)` when CI published no app build of it.
pub(super) fn read(commit: &str, base: &str) -> Result<Option<AppPayload>, String> {
    let url = format!("{base}{commit}/mac-app.json");
    match live::get_small(&url, live::LIVE_MAX_BYTES)? {
        None => Ok(None),
        Some(body) => verify(&body, &cmux_host::updater::channel::trusted_keys(), commit).map(Some),
    }
}

// ------------------------------------------------------------------ staging

/// The store's folders this path uses.
fn apps_dir(store: &Store) -> PathBuf {
    store.root.join("apps")
}

fn stage_dir(store: &Store) -> PathBuf {
    store.root.join("stage")
}

/// Where the app an in-place try replaced is kept until undo or the app's next update.
pub(super) fn original_path(store: &Store, app: &Path) -> PathBuf {
    let name = app.file_name().map_or_else(|| "cmux.app".into(), |name| name.to_os_string());
    store.root.join("in-place").join(name)
}

/// The zip of `payload`, from the store when its bytes are already there, else downloaded; size and sha256
/// checked before anything reads it.
fn fetch_zip(store: &Store, payload: &AppPayload, base: &str) -> Result<PathBuf, String> {
    let dir = apps_dir(store);
    fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let zip = dir.join(format!("{}.zip", payload.app.sha256));
    if zip.is_file() && live::sha256_file(&zip)? == payload.app.sha256 {
        return Ok(zip);
    }
    let part = dir.join(format!("{}.zip.part", payload.app.sha256));
    let url = payload.app.url.replacen(cmux_host::updater::channel::FILES_PREFIX, base, 1);
    live::download(&url, &part, ZIP_MAX_BYTES)?;
    let size = fs::metadata(&part).map_err(|e| e.to_string())?.len();
    let got = live::sha256_file(&part)?;
    if size != payload.app.size || got != payload.app.sha256 {
        let _ = fs::remove_file(&part);
        return Err(format!(
            "the downloaded app is {size} bytes with sha256 {got}, not the signed {} bytes with {}",
            payload.app.size, payload.app.sha256
        ));
    }
    fs::rename(&part, &zip).map_err(|e| e.to_string())?;
    // Keep one zip: an older one is this store's own download.
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if entry.path() != zip {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    Ok(zip)
}

fn info_plist(app: &Path) -> Result<plist::Dictionary, String> {
    let path = app.join("Contents/Info.plist");
    plist::Value::from_file(&path)
        .map_err(|e| format!("{}: {e}", path.display()))?
        .into_dictionary()
        .ok_or_else(|| format!("{} is not a dictionary", path.display()))
}

/// The staged build's Info.plist with `source`'s identity: the build's own keys minus every identity key, then
/// `source`'s identity keys, then the marker. Its code and CMUXCommit stay its own.
pub(super) fn reidentified(
    build: &plist::Dictionary,
    source: &plist::Dictionary,
    marker: plist::Dictionary,
) -> plist::Dictionary {
    let mut out = plist::Dictionary::new();
    for (key, value) in build {
        if !identity_key(key) && key != MARKER {
            out.insert(key.clone(), value.clone());
        }
    }
    for (key, value) in source {
        if identity_key(key) {
            out.insert(key.clone(), value.clone());
        }
    }
    out.insert(MARKER.to_owned(), plist::Value::Dictionary(marker));
    out
}

/// Whether the build's CMUXCommit is `commit` (a nightly stamps it short).
pub(super) fn commit_matches(built: Option<&str>, commit: &str) -> bool {
    built.is_some_and(|built| {
        let built = built.trim().to_ascii_lowercase();
        built.len() >= 7
            && built.bytes().all(|b| b.is_ascii_hexdigit())
            && commit.starts_with(&built)
    })
}

fn run(program: &str, args: &[&OsStr]) -> Result<(), String> {
    let output = cmux_process::Command::new(program)
        .args(args)
        .output()
        .map_err(|e| format!("{program}: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!("{program}: {}", String::from_utf8_lossy(&output.stderr).trim()))
    }
}

/// The one `.app` directly under `dir`.
fn only_app(dir: &Path) -> Result<PathBuf, String> {
    let apps: Vec<PathBuf> = fs::read_dir(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "app"))
        .collect();
    match apps.as_slice() {
        [one] => Ok(one.clone()),
        other => Err(format!("the published zip holds {} apps, not one", other.len())),
    }
}

/// A build of `payload` ready to swap in for `app`: downloaded, checked, given the app's identity and sealed.
pub(super) struct Staged {
    /// This try's own folder in the store (removed once the try ends).
    pub root: PathBuf,
    pub app: PathBuf,
    /// The app is itself a try: its original is kept already, and it is only kept until the new one stays up.
    pub replaces_try: bool,
}

pub(super) fn stage(
    store: &Store,
    payload: &AppPayload,
    base: &str,
    target: &Path,
    phases: &mut live::Phases,
) -> Result<Staged, String> {
    let installed = info_plist(target)?;
    let original = original_path(store, target);
    let replaces_try = installed.contains_key(MARKER);
    let source = if replaces_try {
        info_plist(&original).map_err(|_| {
            format!(
                "{} is an in-place try but its original is not kept at {}; reinstall the app, then try again",
                target.display(),
                original.display()
            )
        })?
    } else {
        installed
    };
    let t = Instant::now();
    let zip = fetch_zip(store, payload, base)?;
    phases.add("download", t);
    let t = Instant::now();
    let root = stage_dir(store).join(super::short(&payload.commit));
    if root.exists() {
        fs::remove_dir_all(&root).map_err(|e| format!("{}: {e}", root.display()))?;
    }
    let unpacked = root.join("unpacked");
    fs::create_dir_all(&unpacked).map_err(|e| e.to_string())?;
    run(
        "/usr/bin/ditto",
        &[OsStr::new("-x"), OsStr::new("-k"), zip.as_os_str(), unpacked.as_os_str()],
    )?;
    let app = only_app(&unpacked)?;
    let build = info_plist(&app)?;
    let built = build.get("CMUXCommit").and_then(plist::Value::as_string);
    if !commit_matches(built, &payload.commit) {
        return Err(format!(
            "the published app's CMUXCommit is {}, not {}",
            built.unwrap_or("missing"),
            payload.commit
        ));
    }
    let mut marker = plist::Dictionary::new();
    marker.insert("commit".into(), payload.commit.clone().into());
    for (from, to) in [("CMUXCommit", "original_commit"), ("CFBundleVersion", "original_version")] {
        let value = source.get(from).and_then(plist::Value::as_string).unwrap_or_default();
        marker.insert(to.into(), value.to_owned().into());
    }
    let plist = plist::Value::Dictionary(reidentified(&build, &source, marker));
    plist.to_file_xml(app.join("Contents/Info.plist")).map_err(|e| format!("Info.plist: {e}"))?;
    let _ = run("/usr/bin/xattr", &[OsStr::new("-crs"), app.as_os_str()]);
    run(
        "/usr/bin/codesign",
        &[
            OsStr::new("--force"),
            OsStr::new("--sign"),
            OsStr::new("-"),
            OsStr::new("--timestamp=none"),
            OsStr::new("--generate-entitlement-der"),
            app.as_os_str(),
        ],
    )?;
    run(
        "/usr/bin/codesign",
        &[OsStr::new("--verify"), OsStr::new("--deep"), OsStr::new("--strict"), app.as_os_str()],
    )?;
    phases.add("stage", t);
    Ok(Staged { root, app, replaces_try })
}

// ------------------------------------------------------------------ the detached swap

/// What the detached swap does, written beside it as `swap.json`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(super) struct Spec {
    /// `try` swaps `staged` in; `undo` puts `original` back.
    pub mode: String,
    pub app: PathBuf,
    pub original: PathBuf,
    #[serde(default)]
    pub staged: Option<PathBuf>,
    #[serde(default)]
    pub stage_root: Option<PathBuf>,
    #[serde(default)]
    pub replaces_try: bool,
    pub store: PathBuf,
    /// The app's control socket (`system.identify`'s `socket_path`): the try keeps the app's identity, so it
    /// answers on the same one. Which process is the app comes from there, never a process scan.
    pub socket: PathBuf,
    /// The receipt so far (target, commit, phases): the swap adds its outcome and records it.
    pub receipt: Value,
}

/// Starts the swap in a new session, from a copy of this CLI in the store, and returns at once: the app quits
/// under it.
pub(super) fn spawn(spec: &Spec) -> Result<(), String> {
    let store = &spec.store;
    let worker_dir = store.join("worker");
    fs::create_dir_all(&worker_dir).map_err(|e| e.to_string())?;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let worker = worker_dir.join("cmux");
    let part = worker_dir.join("cmux.part");
    fs::copy(&exe, &part).map_err(|e| format!("{}: {e}", exe.display()))?;
    fs::rename(&part, &worker).map_err(|e| e.to_string())?;
    let spec_path = store.join("swap.json");
    let body = serde_json::to_vec_pretty(spec).map_err(|e| e.to_string())?;
    fs::write(&spec_path, body).map_err(|e| format!("{}: {e}", spec_path.display()))?;
    let log = fs::File::create(store.join("swap.log")).map_err(|e| e.to_string())?;
    let err = log.try_clone().map_err(|e| e.to_string())?;
    let mut command = cmux_process::Command::new(&worker);
    command.args(["app", "try", SWAP_VERB]).arg(&spec_path).new_session().disclaim_responsibility();
    // No inherited CMUX_* variable: the swap talks to the app its spec names, never a terminal's.
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("CMUX_") {
            command.env_remove(&key);
        }
    }
    command.stdin(cmux_process::Stdio::null()).stdout(log).stderr(err);
    let mut child = command.spawn().map_err(|e| format!("{}: {e}", worker.display()))?;
    // It outlives this process on purpose: it quits and replaces the app this CLI runs from.
    child.detach("app try swap outlives the CLI that started it");
    Ok(())
}

/// The pid of `app` when it answers on `socket` (`system.identify`): `None` when nothing answers there or
/// another app does.
pub(super) fn identify(socket: &Path, app: &Path) -> Option<i32> {
    let mut stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
    let answer = super::super::exchange(
        &mut stream,
        "system.identify",
        json!({}),
        super::super::READ_TIMEOUT,
    )
    .ok()?
    .ok()?;
    let path = answer.get_nonempty_str("app_bundle_path")?;
    if Path::new(path) != app {
        return None;
    }
    answer
        .get("pid")
        .and_then(Value::as_i64)
        .and_then(|pid| i32::try_from(pid).ok())
        .filter(|pid| *pid > 0)
}

fn alive(pid: i32) -> bool {
    // SAFETY: kill with signal 0 sends nothing; it only asks whether the pid exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Waits for `pid` to end, at most `bound`.
fn gone_within(pid: i32, bound: Duration) -> bool {
    let deadline = Instant::now() + bound;
    while alive(pid) {
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    true
}

/// Quits `app` with its own `cmux app quit --keep-sessions` (every session kept, no quit sheet); never a kill.
fn quit_keeping_sessions(app: &Path, socket: &Path) -> Result<(), String> {
    let Some(pid) = identify(socket, app) else { return Ok(()) };
    let cli = app.join(live::BIN).join("cmux");
    let mut command = cmux_process::Command::new(&cli);
    command.arg("--app-socket").arg(socket).args(["app", "quit", "--keep-sessions"]);
    let _ = command.output();
    if gone_within(pid, QUIT_WAIT) {
        Ok(())
    } else {
        Err(format!("{} (pid {pid}) did not quit within {} s", app.display(), QUIT_WAIT.as_secs()))
    }
}

fn open_behind(app: &Path) -> Result<(), String> {
    run("/usr/bin/open", &[OsStr::new("-g"), app.as_os_str()])
}

/// Whether the app comes up (answers on its socket) within `start` and the same process still answers
/// `watch` later.
fn stays_up(app: &Path, socket: &Path, start: Duration, watch: Duration) -> bool {
    let deadline = Instant::now() + start;
    let pid = loop {
        if let Some(pid) = identify(socket, app) {
            break pid;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_secs(1));
    };
    std::thread::sleep(watch);
    alive(pid) && identify(socket, app) == Some(pid)
}

/// Moves `from` to `to`; across volumes a copy, then the source removed.
fn move_app(from: &Path, to: &Path) -> Result<(), String> {
    if let Some(parent) = to.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    if fs::rename(from, to).is_ok() {
        return Ok(());
    }
    run("/usr/bin/ditto", &[from.as_os_str(), to.as_os_str()])?;
    fs::remove_dir_all(from).map_err(|e| format!("{}: {e}", from.display()))
}

/// Puts `new` where `app` is, `app` moved to `aside`; `app` comes back when the second move fails.
fn swap_in(app: &Path, new: &Path, aside: &Path) -> Result<(), String> {
    if aside.exists() {
        fs::remove_dir_all(aside).map_err(|e| format!("{}: {e}", aside.display()))?;
    }
    move_app(app, aside)?;
    if let Err(error) = move_app(new, app) {
        if !app.exists() {
            let _ = move_app(aside, app);
        }
        return Err(error);
    }
    let _ = run("/usr/bin/xattr", &[OsStr::new("-cr"), app.as_os_str()]);
    Ok(())
}

/// The detached swap: `cmux app try __swap SPEC`. Writes its outcome as the store's receipt.
pub(super) fn run_swap(spec_path: &Path) -> i32 {
    let spec: Spec = match fs::read(spec_path)
        .map_err(|e| e.to_string())
        .and_then(|body| serde_json::from_slice(&body).map_err(|e| e.to_string()))
    {
        Ok(spec) => spec,
        Err(error) => {
            eprintln!("cmux app try: {}: {error}", spec_path.display());
            return 1;
        }
    };
    let store = Store { root: spec.store.clone() };
    // The try that started this holds the lock until it exits, a moment from now.
    let _lock = match store.lock() {
        Ok(lock) => lock,
        Err(error) => {
            eprintln!("cmux app try: {error}");
            return 1;
        }
    };
    let started = Instant::now();
    let result = match spec.mode.as_str() {
        "undo" => put_back(&spec),
        _ => swap(&spec),
    };
    let mut receipt = spec.receipt.clone();
    super::set(&mut receipt, "swap_secs", json!(started.elapsed().as_secs_f64()));
    super::set(&mut receipt, "at", json!(super::now()));
    let code = match result {
        Ok(note) => {
            super::set(&mut receipt, "ok", json!(true));
            super::set(&mut receipt, "note", json!(note));
            if let Err(error) = store.record(&receipt) {
                eprintln!("cmux app try: {error}");
            }
            0
        }
        Err(error) => {
            super::set(&mut receipt, "ok", json!(false));
            super::set(&mut receipt, "error", json!(error));
            let _ = store.append_history(&receipt);
            eprintln!("cmux app try: {error}");
            1
        }
    };
    let _ = fs::remove_file(spec_path);
    code
}

fn swap(spec: &Spec) -> Result<String, String> {
    let staged = spec.staged.as_deref().ok_or("the swap names no staged build")?;
    let root = spec.stage_root.clone().unwrap_or_else(|| staged.to_path_buf());
    quit_keeping_sessions(&spec.app, &spec.socket)?;
    // The app itself is kept as the original; an earlier try only until this one stays up.
    let aside = if spec.replaces_try { root.join("replaced.app") } else { spec.original.clone() };
    swap_in(&spec.app, staged, &aside)?;
    let up = open_behind(&spec.app).map(|()| stays_up(&spec.app, &spec.socket, START, WATCH));
    if !matches!(up, Ok(true)) {
        let why = match up {
            Err(error) => format!("did not open ({error})"),
            _ => "did not stay up".to_owned(),
        };
        let _ = quit_keeping_sessions(&spec.app, &spec.socket);
        let failed = root.join("failed.app");
        swap_in(&spec.app, &aside, &failed)?;
        let _ = open_behind(&spec.app);
        return Err(format!(
            "the build {why}; the app it replaced is back (the failed build is at {})",
            failed.display()
        ));
    }
    let _ = fs::remove_dir_all(&root);
    Ok(format!(
        "the app it replaced is kept at {}; `cmux app try undo` puts it back",
        spec.original.display()
    ))
}

fn put_back(spec: &Spec) -> Result<String, String> {
    quit_keeping_sessions(&spec.app, &spec.socket)?;
    let undone = spec.store.join("stage").join("undone.app");
    swap_in(&spec.app, &spec.original, &undone)?;
    open_behind(&spec.app)?;
    let _ = fs::remove_dir_all(&undone);
    Ok(format!("{} runs its own build again", spec.app.display()))
}

/// Whether `app` is an in-place try now (an update that replaced it ended it).
pub(super) fn is_try(app: &Path) -> bool {
    info_plist(app).is_ok_and(|plist| plist.contains_key(MARKER))
}

/// The receipt's `commit` of the try the app runs, from its marker.
pub(super) fn try_commit(app: &Path) -> Option<String> {
    let plist = info_plist(app).ok()?;
    let marker = plist.get(MARKER)?.as_dictionary()?;
    marker.get("commit")?.as_string().map(str::to_owned)
}

/// Reads `value`'s `original` path as the receipt names it.
pub(super) fn receipt_original(value: &Value) -> Option<PathBuf> {
    value.get_nonempty_str("original").map(PathBuf::from)
}
