//! `remote-link --state-dir`: the mux owner it starts keeps its workspace
//! registry in that state directory, never in the default durable state root
//! (cx-0b8z). Before the fix the owner opened an older default-root session
//! database and failed on its schema.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

struct Fixture {
    dir: PathBuf,
    session: String,
}

impl Fixture {
    /// A directory and session of its own. The clock alone does not make the
    /// key unique: macOS `SystemTime` has microsecond resolution, so tests
    /// that start together shared one fixture and one session daemon.
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let index = NEXT.fetch_add(1, Ordering::Relaxed);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_micros() % 1_000_000;
        let key = format!("{}-{index}-{stamp}", std::process::id());
        let dir = PathBuf::from("/tmp").join(format!("cmux-rlsd-{key}"));
        fs::create_dir_all(&dir).unwrap();
        // Owner-only whatever the caller's umask: remote-link refuses a state
        // directory below a group-writable parent (a Testbox shell is 002).
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::create_dir(dir.join("home")).unwrap();
        fs::set_permissions(dir.join("home"), fs::Permissions::from_mode(0o700)).unwrap();
        Self { session: format!("rlsd-{key}"), dir }
    }

    fn default_state(&self) -> PathBuf {
        self.dir.join("default-state")
    }

    fn remote_state(&self) -> PathBuf {
        self.dir.join("remote-state")
    }

    /// The environment every spawned process inherits: the default durable
    /// state root and the config stay inside the fixture.
    fn command(&self) -> Command {
        let mut command = Command::new(bin());
        let home = self.dir.join("home");
        command
            .env("HOME", &home)
            .env("XDG_STATE_HOME", home.join("state"))
            .env("XDG_CONFIG_HOME", home.join("config"))
            .env_remove("XDG_RUNTIME_DIR")
            .env("CMUX_TUI_STATE_DIR", self.default_state())
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env_remove("CMUX_REMOTE_STATE_DIR")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_MUX_SOCKET");
        command
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self
            .command()
            .args(["remote", "stop", "--session", &self.session, "--state-dir"])
            .arg(self.remote_state())
            .stdin(Stdio::null())
            .output();
        let _ = self
            .command()
            .args(["server", "stop", "--json", "--session", &self.session])
            .stdin(Stdio::null())
            .output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn registries_under(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else if path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3") {
                found.push(path);
            }
        }
    }
    found
}

#[test]
fn remote_link_state_dir_holds_the_mux_owner_registry() {
    let fixture = Fixture::new();
    let mut link = fixture
        .command()
        .args(["remote-link", "--stdio", "--session", &fixture.session, "--state-dir"])
        .arg(fixture.remote_state())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    // The link proxies stdio until the sidecar closes; the registry exists as
    // soon as the mux owner it starts has opened its session.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut registries = Vec::new();
    while Instant::now() < deadline {
        registries = registries_under(&fixture.remote_state());
        registries.extend(registries_under(&fixture.default_state()));
        if !registries.is_empty() || link.try_wait().unwrap().is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = link.kill();
    let _ = link.wait();

    let daemon_log = registries_under(&fixture.remote_state()).is_empty().then(|| {
        let mut log = String::new();
        let mut pending = vec![fixture.remote_state()];
        while let Some(directory) = pending.pop() {
            for entry in fs::read_dir(&directory).into_iter().flatten().flatten() {
                let path = entry.path();
                if path.is_dir() {
                    pending.push(path);
                } else if path.file_name().is_some_and(|name| name == "daemon.log") {
                    log.push_str(&fs::read_to_string(&path).unwrap_or_default());
                }
            }
        }
        log
    });
    assert!(
        registries_under(&fixture.default_state()).is_empty(),
        "the mux owner opened the default state root instead of --state-dir: {registries:?}"
    );
    assert!(
        !registries_under(&fixture.remote_state()).is_empty(),
        "no registry under --state-dir; daemon log:\n{}",
        daemon_log.unwrap_or_default()
    );
}

fn find_named(root: &Path, name: &str) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else if path.file_name().is_some_and(|file| file == name) {
                found.push(path);
            }
        }
    }
    found
}

impl Fixture {
    /// A default-root registry for the session, as an older remote-link left it.
    fn seed_default_root(&self) -> PathBuf {
        let socket = self.dir.join("seed.sock");
        let output = self
            .command()
            .args(["server", "ensure", "--json", "--session", &self.session, "--socket"])
            .arg(&socket)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(output.status.success(), "seed ensure: {output:?}");
        let output = self
            .command()
            .args(["server", "stop", "--json", "--session", &self.session, "--socket"])
            .arg(&socket)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(output.status.success(), "seed stop: {output:?}");
        let registries = registries_under(&self.default_state());
        assert_eq!(registries.len(), 1, "{registries:?}");
        registries[0].clone()
    }

    /// One `remote-link --state-dir` start; waits until its mux owner has a
    /// registry, then stops the link, the sidecar and the mux owner.
    fn link_once(&self) {
        self.link_once_without_stop();
        self.stop_daemons();
    }

    /// One `remote-link --state-dir` start; its daemons keep running.
    fn link_once_without_stop(&self) {
        let mut link = self
            .command()
            .args(["remote-link", "--stdio", "--session", &self.session, "--state-dir"])
            .arg(self.remote_state())
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline
            && find_named(&self.remote_state(), "mux.sock").is_empty()
            && link.try_wait().unwrap().is_none()
        {
            std::thread::sleep(Duration::from_millis(100));
        }
        let _ = link.kill();
        let _ = link.wait();
    }

    /// Stops the sidecar and the state-dir mux owner of this fixture.
    fn stop_daemons(&self) {
        let _ = self
            .command()
            .args(["remote", "stop", "--session", &self.session, "--state-dir"])
            .arg(self.remote_state())
            .stdin(Stdio::null())
            .output();
        for socket in find_named(&self.remote_state(), "mux.sock") {
            let _ = self
                .command()
                .args(["server", "stop", "--json", "--session", &self.session, "--socket"])
                .arg(&socket)
                .stdin(Stdio::null())
                .output();
        }
    }
}

fn meta(path: &Path, key: &str) -> Option<String> {
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    rusqlite::OptionalExtension::optional(connection.query_row(
        "SELECT value FROM meta WHERE key = ?1",
        [key],
        |row| row.get::<_, String>(0),
    ))
    .unwrap()
}

fn workspace_rows(path: &Path) -> i64 {
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    connection.query_row("SELECT COUNT(*) FROM workspaces", [], |row| row.get(0)).unwrap()
}

fn file_bytes(path: &Path) -> Vec<u8> {
    fs::read(path).unwrap()
}

/// cx-0b8z: workspaces of an older default-root session do not vanish when
/// the link gains an explicit state directory. The first start copies that
/// registry once into `<state-dir>/workspace`; the original stays unchanged,
/// and a later start never copies again.
#[test]
fn an_empty_state_dir_imports_the_default_root_session_once() {
    let fixture = Fixture::new();
    let source = fixture.seed_default_root();
    let registry_id = meta(&source, "registry_id").expect("seeded registry id");
    let source_rows = workspace_rows(&source);
    let source_bytes = file_bytes(&source);

    fixture.link_once();
    let targets = registries_under(&fixture.remote_state());
    assert_eq!(targets.len(), 1, "no imported registry under --state-dir: {targets:?}");
    let target = &targets[0];
    assert_eq!(meta(target, "registry_id").as_deref(), Some(registry_id.as_str()));
    assert_eq!(workspace_rows(target), source_rows, "the imported workspaces are missing");
    assert_eq!(file_bytes(&source), source_bytes, "the default-root registry changed");

    // A mark the second start must keep: it never copies over the store.
    {
        let connection = rusqlite::Connection::open(target).unwrap();
        connection
            .execute("INSERT INTO meta(key, value) VALUES('import_probe', 'kept')", [])
            .unwrap();
    }
    fixture.link_once();
    assert_eq!(
        meta(target, "import_probe").as_deref(),
        Some("kept"),
        "a second start copied again"
    );
    assert_eq!(file_bytes(&source), source_bytes);
}

/// A state directory whose store has data is never overwritten by an import.
#[test]
fn a_state_dir_with_a_store_is_not_overwritten_by_an_import() {
    let fixture = Fixture::new();
    let source = fixture.seed_default_root();
    let source_id = meta(&source, "registry_id").unwrap();
    // The state directory's own store, from an earlier link.
    let output = fixture
        .command()
        .args(["server", "ensure", "--json", "--session", &fixture.session, "--socket"])
        .arg(fixture.dir.join("own.sock"))
        .env("CMUX_TUI_STATE_DIR", fixture.remote_state().join("workspace"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "own ensure: {output:?}");
    let _ = fixture
        .command()
        .args(["server", "stop", "--json", "--session", &fixture.session, "--socket"])
        .arg(fixture.dir.join("own.sock"))
        .env("CMUX_TUI_STATE_DIR", fixture.remote_state().join("workspace"))
        .stdin(Stdio::null())
        .output();
    let own = registries_under(&fixture.remote_state());
    assert_eq!(own.len(), 1, "{own:?}");
    let own_id = meta(&own[0], "registry_id").unwrap();
    assert_ne!(own_id, source_id);

    fixture.link_once();
    assert_eq!(meta(&own[0], "registry_id").as_deref(), Some(own_id.as_str()));
}

/// Processes whose command line names `dir`.
fn processes_under(dir: &Path) -> Vec<String> {
    let output = Command::new("ps").args(["-axo", "pid=,command="]).output().unwrap();
    let marker = dir.to_string_lossy().into_owned();
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| line.contains(&marker))
        .map(str::to_owned)
        .collect()
}

/// A fixture stops every daemon it started: the state-dir mux owner serves
/// a socket in the state dir, not the session's default socket.
#[test]
fn no_daemon_outlives_a_fixture() {
    let fixture = Fixture::new();
    let dir = fixture.dir.clone();
    fixture.link_once_without_stop();
    assert!(!processes_under(&dir).is_empty(), "the link started no daemon");
    drop(fixture);
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && !processes_under(&dir).is_empty() {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(processes_under(&dir), Vec::<String>::new(), "a daemon outlived its fixture");
}
