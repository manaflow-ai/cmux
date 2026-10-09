//! `remote-link --state-dir`: the mux owner it starts keeps its workspace
//! registry in that state directory, never in the default durable state root
//! (cx-0b8z). Before the fix the owner opened an older default-root session
//! database and failed on its schema.

#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

struct Fixture {
    dir: PathBuf,
    session: String,
}

impl Fixture {
    fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-rlsd-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self { session: format!("rlsd-{}-{}", std::process::id(), stamp % 1_000_000), dir }
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
        command
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
