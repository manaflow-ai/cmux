//! An update of the session daemon from build N to build N+1, where N+1
//! bumps the agent roster reducer version, on a registry of millions of
//! journal records. Leo, 2026-11-09: "for these kinds of things, updates
//! need to be able to autorepair instead of getting the user to do this or
//! that to fix or troubleshoot".
//!
//! The registry is the synthetic generator's (`cmux_tui_core::synth_registry`,
//! built from this tree, so its roster snapshot is build N's): mostly
//! `personal.session.put`, some legacy `terminal.output`, about 1% `agent.*`
//! hook events, the first half sealed into segments, and the roster snapshot
//! at the head at build N's reducer version, as build N leaves it.
//!
//! - Baseline: build N serves the registry; it stops as the app's update
//!   stops it; build N+1 starts and re-folds the roster.
//! - Premigrate: build N serves while a client keeps writing to it, and
//!   build N+1's `server premigrate-registry` folds the roster beside it; build N
//!   answers every probe (about 1 s apart) and keeps its pid. Then build N
//!   stops and build N+1 starts on the premigrated registry.
//!
//! In both, while build N+1 starts, `server ensure` runs every few seconds as
//! the app runs it and never replaces the owner, and an action the person
//! made before the owner answered is held and replayed exactly once after it
//! answers (`cmux_daemon_conn_core::offline`, the app's rule). After a
//! premigrate the new owner adopts the side file (its log says so) and
//! folds only the tail. The restore finishes on its own: the roster
//! snapshot reaches N+1's version at the journal head, and its entries are
//! the generator's fold of the same records.
//!
//! Not a regular test: run by `scripts/e2e/update-premigrate.sh`, which
//! builds both binaries. By hand:
//!
//! ```sh
//! CMUX_E2E_OLD_BIN=/w/cmux-tui-n CMUX_E2E_NEW_BIN=/w/cmux-tui-n1 \
//!   CMUX_E2E_RECORDS=300000 CMUX_E2E_DIR=/w/e2e \
//!   cargo test --release -p cmux-tui --test update_premigrate_e2e -- --ignored --nocapture
//! ```
//!
//! Environment: `CMUX_E2E_OLD_BIN` (build N, default this tree's binary),
//! `CMUX_E2E_NEW_BIN` (build N+1, required), `CMUX_E2E_RECORDS` (default
//! 3000000), `CMUX_E2E_DIR` (default the temp dir), `CMUX_E2E_NEW_VERSION`
//! (N+1's reducer version, default N's plus one), `CMUX_E2E_PAYLOAD_BYTES`
//! (one session put, default 1024), `CMUX_E2E_DEADLINE_S` (each wait,
//! default 3600), `CMUX_E2E_RESULT_FILE` (the summary line is written there
//! too), `CMUX_E2E_CACHE` (a folder that keeps the generated registry for the
//! next run with the same generator and options), `CMUX_E2E_LEGACY_SEGMENTS=1`
//! (the sealed segments lose the indexes a seal writes, as in a registry
//! sealed by a build before them: see [`strip_segment_indexes`]).

#![cfg(target_os = "linux")]

use std::fs;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_daemon_conn_core::offline;
use cmux_tui_core::synth_registry::{SynthOptions, generate, registry_path};
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

const SESSION: &str = "update-e2e";
/// The app's interval between `server ensure` runs is minutes; a few
/// seconds here meets every phase of the start.
const ENSURE_EVERY: Duration = Duration::from_secs(3);
/// How often the old owner is probed while the premigrate runs.
const PROBE_EVERY: Duration = Duration::from_secs(1);
/// One probe of the old owner fails past this.
const PROBE_BOUND: Duration = Duration::from_secs(10);
/// Output cleanup is its own change; it never starts during this test.
const NEVER_MS: &str = "86400000";

struct Settings {
    old_bin: PathBuf,
    new_bin: PathBuf,
    records: u64,
    root: PathBuf,
    new_version: Option<u64>,
    payload_bytes: usize,
    deadline: Duration,
    result_file: Option<PathBuf>,
    /// Where generated registries are kept between runs (`CMUX_E2E_CACHE`).
    cache: Option<PathBuf>,
    /// Debugging only: the premigrate scenario is skipped.
    baseline_only: bool,
    /// The sealed segments have no kind maps and no kept reducer rows.
    legacy_segments: bool,
}

impl Settings {
    fn from_env() -> Self {
        let var = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        let number = |name: &str| {
            var(name).map(|value| {
                value
                    .replace('_', "")
                    .parse::<u64>()
                    .unwrap_or_else(|_| panic!("{name}={value} is not a number"))
            })
        };
        Self {
            old_bin: var("CMUX_E2E_OLD_BIN")
                .map_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_cmux-tui")), PathBuf::from),
            new_bin: PathBuf::from(
                var("CMUX_E2E_NEW_BIN").expect("CMUX_E2E_NEW_BIN names build N+1 (see the doc)"),
            ),
            records: number("CMUX_E2E_RECORDS").unwrap_or(3_000_000),
            root: var("CMUX_E2E_DIR").map_or_else(std::env::temp_dir, PathBuf::from),
            new_version: number("CMUX_E2E_NEW_VERSION"),
            payload_bytes: number("CMUX_E2E_PAYLOAD_BYTES").unwrap_or(1024) as usize,
            deadline: Duration::from_secs(number("CMUX_E2E_DEADLINE_S").unwrap_or(3600)),
            result_file: var("CMUX_E2E_RESULT_FILE").map(PathBuf::from),
            cache: var("CMUX_E2E_CACHE").map(PathBuf::from),
            baseline_only: var("CMUX_E2E_BASELINE_ONLY").is_some_and(|value| value == "1"),
            legacy_segments: var("CMUX_E2E_LEGACY_SEGMENTS").is_some_and(|value| value == "1"),
        }
    }
}

/// One owner's files: its state below `dir`, its socket in a short folder
/// of its own below /tmp (a socket path has at most 107 bytes).
struct Site {
    dir: PathBuf,
    socket_dir: PathBuf,
}

impl Site {
    fn new(root: &Path, label: &str) -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = root.join(format!("update-e2e-{}-{label}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::create_dir_all(dir.join("state")).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let socket_dir = PathBuf::from("/tmp").join(format!(
            "cmux-ue-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&socket_dir);
        fs::create_dir_all(&socket_dir).unwrap();
        fs::set_permissions(&socket_dir, fs::Permissions::from_mode(0o700)).unwrap();
        Self { dir, socket_dir }
    }

    /// A copy of `from`'s state (the generated registry) in a site of its own.
    fn copy_of(from: &Site, root: &Path, label: &str) -> Self {
        Self::with_state(&from.state_root(), root, label)
    }

    /// A site whose state is a copy of the folder `state`.
    fn with_state(state: &Path, root: &Path, label: &str) -> Self {
        let site = Self::new(root, label);
        fs::remove_dir_all(site.state_root()).unwrap();
        copy_tree(state, &site.state_root());
        site
    }

    /// Writes the synthetic registry into this site; the generator's report.
    fn generate(&self, options: &SynthOptions) -> Value {
        let started = Instant::now();
        let report = generate(&self.state_root(), options)
            .unwrap_or_else(|error| panic!("generating the registry failed: {error:#}"))
            .to_json();
        eprintln!("e2e: generated in {:.0} s: {report}", started.elapsed().as_secs_f64());
        report
    }

    fn state_root(&self) -> PathBuf {
        self.dir.join("state")
    }

    fn socket(&self) -> PathBuf {
        self.socket_dir.join("mux.sock")
    }

    fn registry(&self) -> PathBuf {
        registry_path(&self.state_root(), SESSION)
    }

    /// `bin` with this site's state, config, log and home.
    fn command(&self, bin: &Path) -> Command {
        let mut command = Command::new(bin);
        command
            .env("HOME", self.dir.join("home"))
            .env("CMUX_TUI_STATE_DIR", self.state_root())
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_TUI_LOG_FILE", self.dir.join("client.log"))
            .env("CMUX_TUI_TEST_OUTPUT_CLEANUP_DELAY_MS", NEVER_MS)
            .env("CMUX_TUI_TEST_JOURNAL_MAINTENANCE_INTERVAL_MS", NEVER_MS)
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TAG")
            .stdin(Stdio::null());
        command
    }

    /// `bin server ACTION --json` on this site's socket.
    fn server(&self, bin: &Path, action: &str) -> (bool, Value, String) {
        let output = self
            .command(bin)
            .args(["server", action, "--json", "--session", SESSION, "--socket"])
            .arg(self.socket())
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        let value = last_json(&stdout).or_else(|| last_json(&stderr)).unwrap_or(Value::Null);
        (output.status.success(), value, format!("{stdout}{stderr}"))
    }
}

impl Drop for Site {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
        let _ = fs::remove_dir_all(&self.socket_dir);
    }
}

/// Copies the folder `from` to the new path `to` (a reflink where the disk can).
fn copy_tree(from: &Path, to: &Path) {
    let copied = Instant::now();
    let status =
        Command::new("cp").args(["-a", "--reflink=auto"]).arg(from).arg(to).status().unwrap();
    assert!(status.success(), "copying {} failed", from.display());
    eprintln!("e2e: copied {} in {:.1} s", from.display(), copied.elapsed().as_secs_f64());
}

/// The generated registry in a site of its own, and the generator's report.
/// With `CMUX_E2E_CACHE`, the registry is kept there and reused while the
/// generator, the reducer, the journal format and the options are the same
/// (generating 12M rows takes about 22 min); other templates there go.
fn template_registry(settings: &Settings, options: &SynthOptions) -> (Site, Value) {
    let Some(cache) = &settings.cache else {
        let site = Site::new(&settings.root, "template");
        let report = site.generate(options);
        return (site, report);
    };
    let options_text = format!("{options:?}");
    let mut key = Sha256::new();
    for source in [
        include_str!("../../cmux-tui-core/src/workspace_registry/synth.rs"),
        include_str!("../../cmux-tui-core/src/journal_reducers.rs"),
        include_str!("../../cmux-tui-core/src/workspace_registry/session_journal.rs"),
        options_text.as_str(),
    ] {
        key.update(source.as_bytes());
        key.update([0]);
    }
    let name = format!(
        "template-{}",
        key.finalize().iter().take(8).map(|byte| format!("{byte:02x}")).collect::<String>()
    );
    let entry = cache.join(&name);
    if entry.join("done").is_file() {
        let report = serde_json::from_slice(&fs::read(entry.join("report.json")).unwrap()).unwrap();
        eprintln!("e2e: using the cached registry {}", entry.display());
        return (Site::with_state(&entry.join("state"), &settings.root, "template"), report);
    }
    fs::create_dir_all(cache).unwrap();
    for old in fs::read_dir(cache).unwrap().flatten() {
        if old.file_name().to_string_lossy().starts_with("template-") {
            fs::remove_dir_all(old.path()).unwrap();
        }
    }
    let site = Site::new(&settings.root, "template");
    let report = site.generate(options);
    fs::create_dir_all(&entry).unwrap();
    copy_tree(&site.state_root(), &entry.join("state"));
    fs::write(entry.join("report.json"), report.to_string()).unwrap();
    fs::write(entry.join("done"), b"").unwrap();
    (site, report)
}

/// The last line of `text` that is a JSON object.
fn last_json(text: &str) -> Option<Value> {
    text.lines().rev().find_map(|line| {
        serde_json::from_str::<Value>(line.trim()).ok().filter(|value| value.is_object())
    })
}

/// A headless owner, a child of this test.
struct Owner<'a> {
    site: &'a Site,
    child: Child,
    started: Instant,
    log: PathBuf,
    label: String,
}

impl<'a> Owner<'a> {
    fn spawn(site: &'a Site, bin: &Path, label: &str) -> Self {
        let _ = fs::remove_file(site.socket());
        let log = site.dir.join(format!("owner-{label}.log"));
        let child = site
            .command(bin)
            .args(["--headless", "--session", SESSION, "--socket"])
            .arg(site.socket())
            .stdout(Stdio::null())
            .stderr(fs::File::create(&log).unwrap())
            .spawn()
            .unwrap();
        Self { site, child, started: Instant::now(), log, label: label.into() }
    }

    fn pid(&self) -> u64 {
        u64::from(self.child.id())
    }

    fn log_tail(&self) -> String {
        let text = fs::read_to_string(&self.log).unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        lines[lines.len().saturating_sub(40)..].join("\n")
    }

    fn assert_alive(&mut self, doing: &str) {
        if let Some(status) = self.child.try_wait().unwrap() {
            panic!("owner {} exited ({status}) while {doing}:\n{}", self.label, self.log_tail());
        }
    }

    /// `identify`'s data when the owner answers within `bound`.
    fn identify(&self, bound: Duration) -> Option<Value> {
        request(&self.site.socket(), json!({"cmd": "identify"}), bound)
            .filter(|reply| reply["ok"] == true)
            .map(|reply| reply["data"].clone())
    }

    /// Waits until the owner says `lifecycle_ready`; returns the time since spawn.
    fn wait_ready(&mut self, deadline: Duration) -> Duration {
        let until = self.started + deadline;
        loop {
            self.assert_alive("starting");
            if let Some(identity) = self.identify(Duration::from_secs(2))
                && identity["lifecycle_ready"] == true
            {
                assert_eq!(identity["pid"].as_u64(), Some(self.pid()), "another owner answered");
                return self.started.elapsed();
            }
            assert!(Instant::now() < until, "owner {} not ready:\n{}", self.label, self.log_tail());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn workspace_names(&self) -> Vec<String> {
        let reply = request(
            &self.site.socket(),
            json!({"cmd": "list-workspaces"}),
            Duration::from_secs(30),
        )
        .unwrap_or_else(|| panic!("no answer to list-workspaces:\n{}", self.log_tail()));
        assert_eq!(reply["ok"], true, "list-workspaces: {reply}");
        reply["data"]["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|workspace| workspace["name"].as_str().map(str::to_string))
            .collect()
    }

    /// Stops the owner as the app's update does (`server stop`, terminals
    /// kept for the next owner), from build `bin`, and waits for its exit.
    fn hand_off(mut self, bin: &Path) {
        let (ok, value, text) = self.site.server(bin, "stop");
        assert!(ok, "server stop failed: {value} {text}");
        let until = Instant::now() + Duration::from_secs(120);
        while self.child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < until, "owner {} did not exit after server stop", self.label);
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Owner<'_> {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn next_id() -> u64 {
    static NEXT: AtomicU32 = AtomicU32::new(1);
    u64::from(NEXT.fetch_add(1, Ordering::Relaxed))
}

/// One request on a fresh connection: the first reply with its id, or
/// `None` when the socket refuses or no reply came within `bound`.
fn request(socket: &Path, value: Value, bound: Duration) -> Option<Value> {
    exchange(socket, value, bound).ok()
}

/// Why a request got no reply, as the app's `DaemonError` names it.
fn exchange(socket: &Path, mut value: Value, bound: Duration) -> Result<Value, &'static str> {
    let id = value.get("id").cloned().unwrap_or_else(|| json!(next_id()));
    value["id"] = id.clone();
    let stream = UnixStream::connect(socket).map_err(|_| "connectFailed")?;
    stream.set_read_timeout(Some(bound)).map_err(|_| "connectFailed")?;
    stream.set_write_timeout(Some(bound)).map_err(|_| "connectFailed")?;
    let mut reader = BufReader::new(stream);
    writeln!(reader.get_mut(), "{value}").map_err(|_| "connectionClosed")?;
    let until = Instant::now() + bound;
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => return Err("connectionClosed"),
            Ok(_) => {}
            Err(_) => return Err("timedOut"),
        }
        if Instant::now() > until {
            return Err("timedOut");
        }
        let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
        if reply["id"] == id {
            return Ok(reply);
        }
    }
}

/// A `cmux.protocol/2` `workspace.create` of an empty workspace.
fn create_workspace(name: &str, key: &str) -> Value {
    json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": key,
        "operation": "workspace.create",
        "params": {"machine": "current", "session": "current", "name": name,
                   "initial_content": "empty"},
        "idempotency_key": key,
    })
}

fn read_only(registry: &Path) -> Connection {
    Connection::open_with_flags(registry, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap()
}

/// Makes the sealed segments look sealed by a build before the seal-time
/// indexes (the 2026-11-09 registry): no kind map (`journal_segment_kinds`),
/// no kept reducer rows (`journal_segment_reducer_records`), and no backfill
/// markers, so the next read that needs them backfills or decodes whole
/// segments. Only while no owner runs. Returns the rows it removed.
fn strip_segment_indexes(registry: &Path) -> u64 {
    let connection = Connection::open(registry).unwrap();
    let mut removed = 0;
    for table in ["journal_segment_kinds", "journal_segment_reducer_records"] {
        removed += connection.execute(&format!("DELETE FROM {table}"), []).unwrap() as u64;
    }
    connection
        .execute(
            "DELETE FROM meta WHERE key IN (
               'journal_segment_kinds_backfill', 'journal_segment_kinds_backfill_through',
               'journal_segment_kinds_backfill_end', 'journal_segment_reducer_records_backfill'
             )",
            [],
        )
        .unwrap();
    connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
    removed
}

/// Rows in the seal-time segment indexes: kind maps and kept reducer rows.
fn segment_index_rows(registry: &Path) -> (u64, u64) {
    let connection = read_only(registry);
    let count = |table: &str| -> u64 {
        connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| row.get::<_, i64>(0))
            .map_or(0, |count| count as u64)
    };
    (count("journal_segment_kinds"), count("journal_segment_reducer_records"))
}

/// In legacy mode, strips the segment indexes before `label` and says what
/// was there: build N (this tree) may have backfilled some while it served.
fn legacy_point(settings: &Settings, site: &Site, label: &str) {
    if settings.legacy_segments {
        let rows = segment_index_rows(&site.registry());
        let removed = strip_segment_indexes(&site.registry());
        eprintln!(
            "e2e: legacy segments before {label}: had {rows:?} index rows, removed {removed}"
        );
    }
}

/// The highest journal sequence, live or sealed (`query_journal_head`).
fn journal_head(registry: &Path) -> u64 {
    read_only(registry)
        .query_row(
            "SELECT MAX(COALESCE((SELECT MAX(sequence) FROM session_journal), 0),
                        COALESCE((SELECT MAX(end_sequence) FROM journal_segments), 0))",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map(|head| head as u64)
        .unwrap()
}

/// Whether the roster is marked stale (`journal_reducer_rebuild.agent_roster`):
/// a start served a roster migrated from an older reducer version and has
/// not finished rebuilding it from the whole journal. Such a roster is saved
/// at the new version already, so version and cursor alone do not say the
/// catch-up is done.
fn roster_rebuild_pending(registry: &Path) -> bool {
    read_only(registry)
        .query_row(
            "SELECT 1 FROM meta WHERE key = 'journal_reducer_rebuild.agent_roster'",
            [],
            |_| Ok(()),
        )
        .is_ok()
}

/// The roster snapshot row: version, cursor and its entries.
fn roster(registry: &Path) -> Option<(u64, u64, Value)> {
    let raw: String = read_only(registry)
        .query_row("SELECT value FROM meta WHERE key = 'journal_reducer.agent_roster'", [], |row| {
            row.get(0)
        })
        .ok()?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    let snapshot: Value = serde_json::from_str(value["snapshot"].as_str()?).ok()?;
    Some((
        value["version"].as_u64()?,
        value["cursor"].as_str()?.parse().ok()?,
        snapshot["entries"].clone(),
    ))
}

/// `server ensure` as the app runs it, every [`ENSURE_EVERY`], from the
/// moment the new owner listens until it is stopped.
struct EnsureLoop {
    stop: Arc<AtomicBool>,
    runs: Arc<Mutex<Vec<(bool, Value, String)>>>,
    thread: Option<JoinHandle<()>>,
}

impl EnsureLoop {
    fn start(site: &Site, bin: &Path) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let runs = Arc::new(Mutex::new(Vec::new()));
        let mut command = site.command(bin);
        command
            .args(["server", "ensure", "--json", "--session", SESSION, "--socket"])
            .arg(site.socket());
        let thread = {
            let (stop, runs) = (stop.clone(), runs.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::Relaxed) {
                    let output = command.output().unwrap();
                    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
                    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
                    let value =
                        last_json(&stdout).or_else(|| last_json(&stderr)).unwrap_or(Value::Null);
                    runs.lock().unwrap().push((output.status.success(), value, stderr));
                    let pause = Instant::now() + ENSURE_EVERY;
                    while Instant::now() < pause && !stop.load(Ordering::Relaxed) {
                        std::thread::sleep(Duration::from_millis(50));
                    }
                }
            })
        };
        Self { stop, runs, thread: Some(thread) }
    }

    /// Stops the loop and asserts that every run found `pid` and replaced
    /// nothing. Returns how many ran.
    fn finish(mut self, pid: u64) -> usize {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
        let runs = self.runs.lock().unwrap();
        for (ok, value, stderr) in runs.iter() {
            assert!(ok, "server ensure failed while the new owner started: {value} {stderr}");
            assert_eq!(value["status"], "running", "server ensure did not find the owner: {value}");
            assert_eq!(
                value["pid"].as_u64(),
                Some(pid),
                "server ensure answered another owner: {value}"
            );
            assert!(
                value.get("replaced_pid").is_none(),
                "server ensure replaced the owner: {value}"
            );
        }
        runs.len()
    }
}

/// An action the person made before the new owner answered: held by the
/// app's rule while the owner does not answer, replayed once it does.
struct HeldAction {
    name: String,
    key: String,
    held: Vec<offline::Held>,
    /// The app's clock the hold and the sweeps read.
    clock: Instant,
    replays: u32,
    landed: bool,
}

impl HeldAction {
    fn new(label: &str) -> Self {
        Self {
            name: format!("held-during-start-{label}"),
            key: format!("e2e-held-{label}"),
            held: Vec::new(),
            clock: Instant::now(),
            replays: 0,
            landed: false,
        }
    }

    /// The person's first try, made after the old owner exited and before
    /// the new one is spawned (the app's state between the two): nothing
    /// listens, so it must be held, never land or be dropped.
    fn try_first(&mut self, socket: &Path) {
        let now = self.clock.elapsed().as_millis() as u64;
        match exchange(socket, create_workspace(&self.name, &self.key), Duration::from_millis(500))
        {
            Ok(reply) => panic!("the action reached an owner before the new one started: {reply}"),
            Err(kind) => {
                assert_eq!(
                    offline::disposition(kind, false),
                    offline::Disposition::Hold,
                    "the app would drop an action that met {kind}"
                );
                // Nothing listened, so the daemon never had it: a replay,
                // not a settle from the daemon's state.
                assert!(!offline::maybe_sent(kind), "an action that met {kind} may have landed");
                self.held.push(offline::Held {
                    id: self.key.clone(),
                    held_at_ms: now,
                    replaying: false,
                    sent: false,
                    settling: false,
                });
            }
        }
    }

    /// The app's sweep at `now_ms` with `reachable`: replays the action once
    /// when the sweep says so; never expires it.
    fn sweep(&mut self, owner: &Owner<'_>, reachable: bool) {
        let now = self.clock.elapsed().as_millis() as u64;
        let sweep = offline::sweep(&self.held, now, reachable, offline::HOLD_BOUND_MS);
        assert!(sweep.expire.is_empty(), "the held action expired before the owner answered");
        assert!(sweep.unsure.is_empty() && sweep.settle.is_empty(), "an unsent action settles");
        for id in sweep.replay {
            assert_eq!(id, self.key);
            self.held.iter_mut().for_each(|held| held.replaying = true);
            self.replays += 1;
            let reply = exchange(
                &owner.site.socket(),
                create_workspace(&self.name, &self.key),
                Duration::from_secs(30),
            )
            .unwrap_or_else(|kind| panic!("the replay failed ({kind}):\n{}", owner.log_tail()));
            assert_eq!(reply["ok"], true, "the replay was refused: {reply}");
            self.held.clear();
            self.landed = true;
        }
    }

    fn assert_once(&self, owner: &Owner<'_>) {
        assert!(self.landed, "the held action never landed");
        assert_eq!(self.replays, 1, "the held action replayed {} times", self.replays);
        let count = owner.workspace_names().iter().filter(|name| **name == self.name).count();
        assert_eq!(count, 1, "the held action made {count} workspaces");
    }
}

/// What a start of build N+1 took.
struct Start {
    ready: Duration,
    catch_up: Duration,
    ensures: usize,
}

/// Starts build N+1 on `site` as the app does after an update and follows
/// it to a roster at `version` through `head`.
fn start_new(
    settings: &Settings,
    site: &Site,
    label: &str,
    (old_version, version): (u64, u64),
    expected_entries: &Value,
    premigrated: bool,
) -> Start {
    let registry = site.registry();
    let head = journal_head(&registry);
    // Build N+1 starts on build N's roster: an older version, or the start
    // would fold nothing and the update would test nothing.
    let saved = roster(&registry).map(|(saved, _, _)| saved);
    assert_eq!(saved, Some(old_version), "owner {label} would start on a roster of {saved:?}");
    assert!(
        old_version < version,
        "build N+1's roster {version} is not past build N's {old_version}"
    );
    let mut action = HeldAction::new(label);
    let _ = fs::remove_file(site.socket());
    action.try_first(&site.socket());
    let mut owner = Owner::spawn(site, &settings.new_bin, label);
    // The app's ensure runs once the new owner holds the socket (before, it
    // would start an owner of its own).
    let until = owner.started + settings.deadline;
    while !site.socket().exists() {
        owner.assert_alive("binding its socket");
        assert!(Instant::now() < until, "owner {label} never listened:\n{}", owner.log_tail());
        action.sweep(&owner, false);
        std::thread::sleep(Duration::from_millis(10));
    }
    let ensures = EnsureLoop::start(site, &settings.new_bin);
    let ready = loop {
        owner.assert_alive("restoring");
        let identity = owner.identify(Duration::from_secs(2));
        if identity.as_ref().is_some_and(|identity| identity["lifecycle_ready"] == true) {
            break owner.started.elapsed();
        }
        action.sweep(&owner, false);
        assert!(Instant::now() < until, "owner {label} not ready:\n{}", owner.log_tail());
        std::thread::sleep(Duration::from_millis(20));
    };
    action.sweep(&owner, true);
    eprintln!("e2e: {label}: ready in {:.2} s", ready.as_secs_f64());
    let catch_up = loop {
        owner.assert_alive("folding the roster");
        if let Some((saved, cursor, _)) = roster(&registry)
            && saved == version
            && cursor >= head
            && !roster_rebuild_pending(&registry)
        {
            break owner.started.elapsed();
        }
        assert!(
            Instant::now() < until,
            "owner {label}: the roster never reached version {version} at {head} with no \
             rebuild pending: {:?}, rebuild pending {}\n{}",
            roster(&registry).map(|(saved, cursor, _)| (saved, cursor)),
            roster_rebuild_pending(&registry),
            owner.log_tail()
        );
        std::thread::sleep(Duration::from_millis(250));
    };
    eprintln!("e2e: {label}: roster caught up in {:.2} s", catch_up.as_secs_f64());
    // A premigrated registry is adopted, not re-folded; a plain one is not.
    let adopted = fs::read_to_string(&owner.log)
        .unwrap_or_default()
        .lines()
        .find(|line| line.contains("adopted premigrated agent roster"))
        .map(str::to_string);
    assert_eq!(
        adopted.is_some(),
        premigrated,
        "owner {label}: adopted the premigrated roster: {adopted:?}\n{}",
        owner.log_tail()
    );
    if let Some(line) = &adopted {
        eprintln!("e2e: {label}: {line}");
    }
    // A few more ensures after the catch-up, then the verdict.
    std::thread::sleep(ENSURE_EVERY * 2);
    owner.assert_alive("serving after its restore");
    let ensures = ensures.finish(owner.pid());
    assert!(ensures > 0, "no server ensure ran");
    action.assert_once(&owner);
    let (_, _, entries) = roster(&registry).unwrap();
    assert_eq!(&entries, expected_entries, "{label}: the re-folded roster differs from the fold");
    owner.hand_off(&settings.new_bin);
    Start { ready, catch_up, ensures }
}

/// Starts build N on `site`, checks it answers and its roster is current.
fn start_old<'a>(settings: &Settings, site: &'a Site, label: &str) -> Owner<'a> {
    let mut owner = Owner::spawn(site, &settings.old_bin, label);
    let ready = owner.wait_ready(settings.deadline);
    let names = owner.workspace_names();
    assert!(!names.is_empty(), "build N lost the workspaces");
    eprintln!("e2e: {label}: build N ready in {:.2} s", ready.as_secs_f64());
    owner
}

/// One connection kept open, as the app's attached client keeps its own.
struct Attached {
    reader: BufReader<UnixStream>,
}

impl Attached {
    fn open(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).expect("attaching to build N");
        stream.set_read_timeout(Some(PROBE_BOUND)).unwrap();
        stream.set_write_timeout(Some(PROBE_BOUND)).unwrap();
        Self { reader: BufReader::new(stream) }
    }

    /// `identify` on this connection: the pid that answered.
    fn pid(&mut self) -> Option<u64> {
        let id = json!(format!("attached-{}", next_id()));
        writeln!(self.reader.get_mut(), "{}", json!({"id": id, "cmd": "identify"})).ok()?;
        loop {
            let mut line = String::new();
            if self.reader.read_line(&mut line).ok()? == 0 {
                return None;
            }
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
            if reply["id"] == id {
                return reply["data"]["pid"].as_u64();
            }
        }
    }
}

/// What build N+1's premigrate took while build N served and a client wrote.
/// An attached client (one connection, opened before the premigrate) is
/// answered by build N on every probe and after the premigrate ends: the
/// handoff comes only after that.
fn premigrate(settings: &Settings, site: &Site, old: &mut Owner<'_>, version: u64) -> Duration {
    let old_pid = old.pid();
    let stop = Arc::new(AtomicBool::new(false));
    let socket = site.socket();
    let mut attached = Attached::open(&socket);
    assert_eq!(attached.pid(), Some(old_pid), "the attached client reached another owner");
    let prober = {
        let stop = stop.clone();
        std::thread::spawn(move || {
            let mut probes = 0_u32;
            let mut slowest = Duration::ZERO;
            while !stop.load(Ordering::Relaxed) {
                let asked = Instant::now();
                let identity = request(&socket, json!({"cmd": "identify"}), PROBE_BOUND)
                    .unwrap_or_else(|| panic!("build N did not answer probe {probes}"));
                assert_eq!(
                    identity["data"]["pid"].as_u64(),
                    Some(old_pid),
                    "build N's pid changed"
                );
                assert_eq!(
                    attached.pid(),
                    Some(old_pid),
                    "the attached client lost build N during probe {probes}"
                );
                // The client keeps writing: one workspace per probe.
                let key = format!("e2e-live-{probes}");
                let created = request(
                    &socket,
                    create_workspace(&format!("live {probes}"), &key),
                    PROBE_BOUND,
                )
                .unwrap_or_else(|| panic!("build N did not answer write {probes}"));
                assert_eq!(created["ok"], true, "build N refused a write: {created}");
                slowest = slowest.max(asked.elapsed());
                probes += 1;
                std::thread::sleep(PROBE_EVERY.saturating_sub(asked.elapsed()));
            }
            (probes, slowest, attached)
        })
    };
    let started = Instant::now();
    let output = site
        .command(&settings.new_bin)
        .args(["server", "premigrate-registry", "--json", "--session", SESSION, "--state-dir"])
        .arg(site.state_root())
        .args(["--max-seconds", &settings.deadline.as_secs().to_string()])
        .output()
        .unwrap();
    let took = started.elapsed();
    stop.store(true, Ordering::Relaxed);
    let probed = prober.join();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "server premigrate-registry failed: {stdout}{stderr}");
    let (probes, slowest, mut attached) =
        probed.unwrap_or_else(|_| panic!("build N stopped answering"));
    old.assert_alive("serving during the premigrate");
    assert_eq!(
        attached.pid(),
        Some(old_pid),
        "the attached client lost build N when the premigrate ended"
    );
    drop(attached);
    assert_eq!(
        old.identify(PROBE_BOUND).and_then(|identity| identity["pid"].as_u64()),
        Some(old_pid)
    );
    let report = last_json(&stdout).unwrap_or(Value::Null);
    eprintln!(
        "e2e: premigrate: {:.2} s, build N answered {probes} probes (slowest {:.0} ms) and \
         its attached client throughout: {report}",
        took.as_secs_f64(),
        slowest.as_secs_f64() * 1000.0,
    );
    // The whole roster folded, at N+1's version, into the side file the new
    // owner adopts.
    assert_eq!(report["status"], "done", "the premigrate did not finish: {report}");
    let roster = &report["agent_roster"];
    assert_eq!(roster["complete"], true, "{report}");
    assert_eq!(roster["version"].as_u64(), Some(version), "{report}");
    let side_file = PathBuf::from(roster["side_file"].as_str().unwrap_or_default());
    assert!(side_file.is_file(), "no side file at {}", side_file.display());
    assert!(probes > 0 || took < PROBE_EVERY, "build N was never probed");
    took
}

#[test]
#[ignore = "end to end: builds a registry of many GB; run by scripts/e2e/update-premigrate.sh"]
fn an_update_that_bumps_the_roster_reducer_repairs_itself() {
    let settings = Settings::from_env();
    fs::create_dir_all(&settings.root).unwrap();
    let records = settings.records;
    // About 1% agent events. The generator cycles 24 terminals through
    // sessions of 8 events (start, 3 turns, end); a count that ends every
    // lane on a session end leaves no live agent (12M rows: 120000 events,
    // an empty roster). Two events past a whole cycle leave each lane
    // working.
    let cycle = 24 * 8;
    let agent_events = (records / 100 / cycle).max(1) * cycle + 24 * 2;
    let output_rows = records / 10;
    let session_puts = records - agent_events - output_rows;

    let options = SynthOptions {
        session: SESSION.into(),
        session_puts,
        agent_events,
        output_bytes: output_rows * 4096,
        workspaces: 4,
        payload_bytes: settings.payload_bytes,
        seal: true,
        roster_version_bump: false,
        batch_rows: 20_000,
        progress: false,
    };
    let (template, generated) = template_registry(&settings, &options);
    let old_version = generated["roster_version"].as_u64().unwrap();
    let new_version = settings.new_version.unwrap_or(old_version + 1);
    assert!(
        new_version > old_version,
        "build N+1 must bump the roster reducer past build N's {old_version}, not to {new_version}"
    );
    let (_, _, entries) = roster(&template.registry()).unwrap();
    assert!(
        entries.as_object().is_some_and(|entries| !entries.is_empty()),
        "the fold has no agents"
    );

    legacy_point(&settings, &template, "the scenarios");
    // Premigrate's copy first: the baseline runs on the template itself.
    let warm_site =
        (!settings.baseline_only).then(|| Site::copy_of(&template, &settings.root, "premigrate"));

    let old = start_old(&settings, &template, "baseline-n");
    old.hand_off(&settings.new_bin);
    legacy_point(&settings, &template, "baseline-n1");
    let baseline =
        start_new(&settings, &template, "baseline-n1", (old_version, new_version), &entries, false);
    drop(template);

    let warm = warm_site.map(|warm_site| {
        let mut old = start_old(&settings, &warm_site, "premigrate-n");
        if settings.legacy_segments {
            // Build N serves: what it backfilled stays (an older build would not have).
            let rows = segment_index_rows(&warm_site.registry());
            eprintln!("e2e: legacy segments at the premigrate: {rows:?} index rows");
        }
        let took = premigrate(&settings, &warm_site, &mut old, new_version);
        old.hand_off(&settings.new_bin);
        legacy_point(&settings, &warm_site, "premigrate-n1");
        (
            took,
            start_new(
                &settings,
                &warm_site,
                "premigrate-n1",
                (old_version, new_version),
                &entries,
                true,
            ),
        )
    });

    let seconds = |value: Option<Duration>| {
        value.map_or_else(|| "skipped".to_string(), |value| format!("{:.2}", value.as_secs_f64()))
    };
    let summary = format!(
        "E2E-RESULT records={records} baseline_ready_s={} baseline_catchup_s={} premigrate_s={} \
         warm_ready_s={} warm_catchup_s={}",
        seconds(Some(baseline.ready)),
        seconds(Some(baseline.catch_up)),
        seconds(warm.as_ref().map(|(took, _)| *took)),
        seconds(warm.as_ref().map(|(_, start)| start.ready)),
        seconds(warm.as_ref().map(|(_, start)| start.catch_up)),
    );
    eprintln!(
        "e2e: registry {} bytes, journal head {}, {} sealed segments, roster {old_version} -> \
         {new_version}, server ensure ran {} + {} times",
        generated["registry_bytes"],
        generated["journal_head"],
        generated["segments"],
        baseline.ensures,
        warm.as_ref().map_or(0, |(_, start)| start.ensures),
    );
    let versions = format!(
        "E2E-ROSTER old={old_version} new={new_version} legacy_segments={}",
        u8::from(settings.legacy_segments)
    );
    println!("{versions}");
    println!("{summary}");
    if let Some(path) = &settings.result_file {
        fs::write(path, format!("{versions}\n{summary}\n")).unwrap();
    }
}
