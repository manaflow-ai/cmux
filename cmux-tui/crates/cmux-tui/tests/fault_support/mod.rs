//! What the daemon fault tests share: a private folder, a headless owner
//! started as a child of the test (so the test can SIGKILL, SIGSTOP and
//! SIGCONT it), socket requests with deadlines, and reads of the files an
//! owner leaves (registry, WAL, `startup-timings.jsonl`).
#![allow(dead_code)]

use std::fs;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

pub const REGISTRY: &str = "workspace-registry.sqlite3";
/// No journal maintenance (checkpoint, seal) during a test: the rows a test
/// counts stay where it wrote them.
pub const NO_MAINTENANCE: (&str, &str) =
    ("CMUX_TUI_TEST_JOURNAL_MAINTENANCE_INTERVAL_MS", "86400000");

/// The test's own folder below /tmp (short socket paths), removed on drop.
pub struct FaultDir {
    pub root: PathBuf,
}

impl FaultDir {
    pub fn new(label: &str) -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_micros();
        let root = PathBuf::from("/tmp").join(format!(
            "cmux-fi-{label}-{}-{stamp}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(root.join("home")).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        fs::create_dir_all(Self::state_root_of(&root)).unwrap();
        fs::set_permissions(root.join("cmux-tui"), fs::Permissions::from_mode(0o700)).unwrap();
        Self { root }
    }

    fn state_root_of(root: &Path) -> PathBuf {
        root.join("cmux-tui").join("sessions")
    }

    /// The owner's `CMUX_TUI_STATE_DIR`.
    pub fn state_root(&self) -> PathBuf {
        Self::state_root_of(&self.root)
    }

    pub fn socket(&self) -> PathBuf {
        self.root.join("mux.sock")
    }

    pub fn registry(&self, session: &str) -> PathBuf {
        cmux_tui_core::synth_registry::registry_path(&self.state_root(), session)
    }

    pub fn session_dir(&self, session: &str) -> PathBuf {
        self.registry(session).parent().unwrap().to_path_buf()
    }

    /// This binary with the test's state, config, log and home.
    pub fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .env("HOME", self.root.join("home"))
            .env("CMUX_TUI_STATE_DIR", self.state_root())
            .env("CMUX_TUI_CONFIG", self.root.join("config.json"))
            .env("CMUX_TUI_LOG_FILE", self.root.join("client.log"))
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TAG")
            .stdin(Stdio::null());
        command
    }

    /// `cmux-tui server ACTION --json` for `session` on this folder's socket.
    pub fn server(&self, session: &str, action: &str, extra: &[&str]) -> Output {
        self.command()
            .args(["server", action, "--json", "--session", session, "--socket"])
            .arg(self.socket())
            .args(extra)
            .output()
            .unwrap()
    }

    /// Files a start moved aside because it could not open the registry.
    pub fn recovered(&self, session: &str) -> Vec<PathBuf> {
        fs::read_dir(self.session_dir(session).join("registry-recovery"))
            .map(|entries| entries.flatten().map(|entry| entry.path()).collect())
            .unwrap_or_default()
    }
}

impl Drop for FaultDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// A headless owner, a child of this test.
pub struct Owner<'a> {
    pub dir: &'a FaultDir,
    pub session: String,
    pub child: Child,
    pub started: Instant,
    log: PathBuf,
}

impl<'a> Owner<'a> {
    /// Starts an owner with `env` added; returns once it is spawned.
    pub fn spawn(dir: &'a FaultDir, session: &str, env: &[(&str, &str)]) -> Self {
        let socket = dir.socket();
        // A killed owner leaves its socket file behind; only a new one counts.
        let _ = fs::remove_file(&socket);
        let log = dir.root.join(format!("owner-{}.log", unique()));
        let child = dir
            .command()
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .envs(env.iter().copied())
            .stdout(Stdio::null())
            .stderr(fs::File::create(&log).unwrap())
            .spawn()
            .unwrap();
        Self { dir, session: session.into(), child, started: Instant::now(), log }
    }

    /// Starts an owner and waits until it is ready; returns it and how long
    /// it took to listen and to be ready.
    pub fn start(dir: &'a FaultDir, session: &str, env: &[(&str, &str)], bound: Duration) -> Self {
        let mut owner = Self::spawn(dir, session, env);
        owner.wait_ready(bound);
        owner
    }

    pub fn pid(&self) -> i32 {
        i32::try_from(self.child.id()).unwrap()
    }

    pub fn log_text(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    /// Waits for the socket file, bounded. Returns the time since spawn.
    pub fn wait_listening(&mut self, bound: Duration) -> Duration {
        let deadline = Instant::now() + bound;
        while !self.dir.socket().exists() {
            self.assert_alive("binding its socket");
            assert!(Instant::now() < deadline, "no socket within {bound:?}: {}", self.log_text());
            std::thread::sleep(Duration::from_millis(10));
        }
        self.started.elapsed()
    }

    /// Waits until `identify` says `lifecycle_ready`, bounded. Returns the
    /// time since spawn.
    pub fn wait_ready(&mut self, bound: Duration) -> Duration {
        let deadline = Instant::now() + bound;
        self.wait_listening(bound);
        loop {
            self.assert_alive("restoring");
            if let Some(identity) =
                request(&self.dir.socket(), json!({"cmd": "identify"}), Duration::from_secs(2))
                && identity["data"]["lifecycle_ready"] == true
            {
                return self.started.elapsed();
            }
            assert!(Instant::now() < deadline, "not ready within {bound:?}: {}", self.log_text());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    pub fn assert_alive(&mut self, doing: &str) {
        if let Some(status) = self.child.try_wait().unwrap() {
            panic!("the owner exited ({status}) while {doing}: {}", self.log_text());
        }
    }

    pub fn signal(&self, signal: i32) {
        // SAFETY: kill takes a pid and a signal; the pid is this test's child.
        assert_eq!(unsafe { libc::kill(self.pid(), signal) }, 0);
    }

    /// SIGKILL, and reap it.
    pub fn kill9(mut self) {
        self.signal(libc::SIGKILL);
        let _ = self.child.wait();
    }

    /// One request on the socket; the answer's `data`, asserting `ok`.
    pub fn data(&self, request_value: Value) -> Value {
        let reply = request(&self.dir.socket(), request_value.clone(), Duration::from_secs(30))
            .unwrap_or_else(|| panic!("no answer to {request_value}: {}", self.log_text()));
        assert_eq!(reply["ok"], true, "{request_value}: {reply}");
        reply["data"].clone()
    }

    /// Names of the owner's workspaces (`list-workspaces`).
    pub fn workspace_names(&self) -> Vec<String> {
        self.data(json!({"cmd": "list-workspaces"}))["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|workspace| workspace["name"].as_str().map(str::to_string))
            .collect()
    }

    /// `server stop --end-terminals`, then waits for the exit, bounded.
    pub fn stop(mut self) {
        self.stop_in_place();
    }

    fn stop_in_place(&mut self) {
        if self.child.try_wait().unwrap().is_some() {
            return;
        }
        let _ = self.dir.server(&self.session, "stop", &["--end-terminals"]);
        let deadline = Instant::now() + Duration::from_secs(45);
        while self.child.try_wait().unwrap().is_none() {
            if Instant::now() >= deadline {
                let _ = self.child.kill();
                let _ = self.child.wait();
                panic!("the owner did not exit within 45 s of `server stop`");
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Owner<'_> {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_some() {
            return;
        }
        // A frozen owner cannot answer a stop.
        // SAFETY: kill takes a pid and a signal; the pid is this test's child.
        unsafe { libc::kill(self.pid(), libc::SIGCONT) };
        if std::thread::panicking() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        } else {
            self.stop_in_place();
        }
    }
}

fn unique() -> u32 {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

/// One request on a fresh connection; the first answer with its id (events
/// skipped), or `None` when none came within `timeout`.
pub fn request(socket: &Path, mut value: Value, timeout: Duration) -> Option<Value> {
    let id = value.get("id").cloned().unwrap_or_else(|| json!(u64::from(unique()) + 1));
    value["id"] = id.clone();
    let stream = UnixStream::connect(socket).ok()?;
    stream.set_read_timeout(Some(timeout)).ok()?;
    stream.set_write_timeout(Some(timeout)).ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(reader.get_mut(), "{value}").ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 || Instant::now() > deadline {
            return None;
        }
        let reply: Value = serde_json::from_str(&line).ok()?;
        if reply["id"] == id {
            return Some(reply);
        }
    }
}

/// A `cmux.protocol/2` request; its `result`, asserting `ok`.
pub fn v2(socket: &Path, operation: &str, params: Value, key: &str) -> Value {
    let mut scoped = json!({"machine": "current", "session": "current"});
    for (name, value) in params.as_object().into_iter().flatten() {
        scoped[name] = value.clone();
    }
    let reply = request(
        socket,
        json!({"protocol": "cmux.protocol/2", "type": "request", "id": key,
               "operation": operation, "params": scoped, "idempotency_key": key}),
        Duration::from_secs(30),
    )
    .unwrap_or_else(|| panic!("no answer to {operation} {key}"));
    assert_eq!(reply["ok"], true, "{operation}: {reply}");
    reply["result"].clone()
}

/// Creates an empty workspace named `name` and waits for its acknowledgement.
pub fn create_workspace(socket: &Path, name: &str) -> String {
    let created = v2(
        socket,
        "workspace.create",
        json!({"name": name, "initial_content": "empty"}),
        &format!("fi-create-{name}"),
    );
    created["value"]["workspace_id"].as_str().unwrap_or_default().to_string()
}

/// Bytes of the file, 0 when missing.
pub fn file_size(path: &Path) -> u64 {
    fs::metadata(path).map(|metadata| metadata.len()).unwrap_or(0)
}

/// Registry and WAL sizes of `session`.
pub fn registry_sizes(dir: &FaultDir, session: &str) -> (u64, u64) {
    let registry = dir.registry(session);
    let mut wal = registry.as_os_str().to_owned();
    wal.push("-wal");
    (file_size(&registry), file_size(Path::new(&wal)))
}

/// The latest start's line of `startup-timings.jsonl` (cmux-tui-core's
/// `startup_timings`): its total and each lap in ms.
pub fn last_startup(dir: &FaultDir, session: &str) -> Option<Value> {
    let text = fs::read_to_string(
        dir.session_dir(session).join(cmux_tui_core::startup_timings::STARTUP_TIMINGS_FILE),
    )
    .ok()?;
    text.lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .and_then(|line| serde_json::from_str(line).ok())
}

/// One lap of a startup line, in ms (0 when absent).
pub fn lap_ms(startup: &Value, step: &str) -> f64 {
    startup["steps"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|lap| lap["step"] == step)
        .filter_map(|lap| lap["ms"].as_f64())
        .sum()
}

/// Every live journal event id, and the sealed segment ids, read on a
/// read-only connection (an owner may run).
pub fn journal_rows(
    dir: &FaultDir,
    session: &str,
) -> (std::collections::BTreeSet<String>, Vec<String>) {
    let connection = rusqlite::Connection::open_with_flags(
        dir.registry(session),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let mut live = connection.prepare("SELECT event_id FROM session_journal").unwrap();
    let live = live
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut segments = connection
        .prepare("SELECT segment_id FROM journal_segments ORDER BY start_sequence")
        .unwrap();
    let segments = segments
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    (live, segments)
}

/// The agent roster snapshot row: version, cursor and snapshot JSON.
pub fn roster_meta(dir: &FaultDir, session: &str) -> Option<(u64, u64, Value)> {
    let connection = rusqlite::Connection::open_with_flags(
        dir.registry(session),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .ok()?;
    let raw: String = connection
        .query_row("SELECT value FROM meta WHERE key = 'journal_reducer.agent_roster'", [], |row| {
            row.get(0)
        })
        .ok()?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    let snapshot = serde_json::from_str(value["snapshot"].as_str()?).ok()?;
    Some((value["version"].as_u64()?, value["cursor"].as_str()?.parse().ok()?, snapshot))
}

/// Whether `pid` runs and is not a zombie.
pub fn running(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the pid exists.
    if unsafe { libc::kill(pid, 0) } != 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    if let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat"))
        && let Some((_, rest)) = stat.rsplit_once(')')
    {
        return rest.split_whitespace().next() != Some("Z");
    }
    true
}
