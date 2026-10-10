//! A daemon that cannot open its saved session keeps the files: it moves the
//! registry and its sidecars to `registry-recovery/` and exits with that
//! path, and never starts an empty session on top of them.

#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const REGISTRY: &str = "workspace-registry.sqlite3";

struct StateDir(PathBuf);

impl Drop for StateDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn state_dir(label: &str) -> StateDir {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-rr-{label}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    StateDir(dir)
}

/// A cmux-tui command whose state, config and log stay inside `dir`.
fn command(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"));
    command
}

/// Starts a headless owner and waits for it to exit (or to serve), capturing
/// its output. A healthy owner keeps running; one that cannot open its
/// registry exits on its own.
fn start_owner(dir: &Path, session: &str) -> (Option<Output>, bool) {
    let socket = dir.join("mux.sock");
    // A stopped owner can leave its socket file behind; only a new one counts.
    let _ = fs::remove_file(&socket);
    let mut child = command(dir)
        .args(["--headless", "--session", session, "--socket"])
        .arg(&socket)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if child.try_wait().unwrap().is_some() {
            return (Some(child.wait_with_output().unwrap()), false);
        }
        if socket.exists() {
            stop_owner(dir, session);
            let _ = child.wait();
            return (None, true);
        }
        assert!(Instant::now() < deadline, "the owner neither served nor exited");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn stop_owner(dir: &Path, session: &str) {
    let _ = command(dir)
        .args(["server", "stop", "--session", session, "--end-terminals", "--socket"])
        .arg(dir.join("mux.sock"))
        .output();
}

/// The session directory a first, healthy start created.
fn session_dir(dir: &Path) -> PathBuf {
    fs::read_dir(dir.join("state").join("sessions"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.join(REGISTRY).is_file())
        .expect("a healthy start creates its registry")
}

/// Every file moved under `registry-recovery/`, by name.
fn recovered(session_dir: &Path) -> Vec<(String, Vec<u8>)> {
    let Ok(batches) = fs::read_dir(session_dir.join("registry-recovery")) else {
        return Vec::new();
    };
    let mut files = Vec::new();
    for batch in batches {
        for file in fs::read_dir(batch.unwrap().path()).unwrap() {
            let file = file.unwrap();
            files.push((
                file.file_name().to_string_lossy().into_owned(),
                fs::read(file.path()).unwrap(),
            ));
        }
    }
    files
}

#[test]
fn an_orphaned_journal_is_kept_instead_of_starting_an_empty_session() {
    let dir = state_dir("orphan");
    let session = "rr-orphan";
    assert!(start_owner(&dir.0, session).1, "the first start serves");
    let session_dir = session_dir(&dir.0);
    // The main file is gone; its WAL still holds committed frames.
    fs::remove_file(session_dir.join(REGISTRY)).unwrap();
    let wal = session_dir.join(format!("{REGISTRY}-wal"));
    fs::write(&wal, b"committed frames the main file never received").unwrap();

    let (output, served) = start_owner(&dir.0, session);

    assert!(!served, "the owner must not serve an empty session over the journal");
    let output = output.unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!output.status.success());
    assert!(stderr.contains("registry-recovery"), "{stderr}");
    assert!(!session_dir.join(REGISTRY).exists(), "no empty registry in place: {stderr}");
    assert!(!wal.exists());
    assert!(recovered(&session_dir).iter().any(|(name, bytes)| {
        name == &format!("{REGISTRY}-wal")
            && bytes == b"committed frames the main file never received"
    }));
    // With the journal kept aside, the next start serves a new session.
    assert!(start_owner(&dir.0, session).1);
}

#[test]
fn an_unreadable_registry_is_kept_with_its_sidecars() {
    let dir = state_dir("corrupt");
    let session = "rr-corrupt";
    assert!(start_owner(&dir.0, session).1, "the first start serves");
    let session_dir = session_dir(&dir.0);
    let garbage = vec![0x5a_u8; 8192];
    fs::write(session_dir.join(REGISTRY), &garbage).unwrap();
    fs::write(session_dir.join(format!("{REGISTRY}-shm")), b"shared memory index").unwrap();

    let (output, served) = start_owner(&dir.0, session);

    assert!(!served);
    let output = output.unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("registry-recovery"), "{stderr}");
    let kept = recovered(&session_dir);
    assert!(kept.iter().any(|(name, bytes)| name == REGISTRY && bytes == &garbage), "{stderr}");
    assert!(kept.iter().any(|(name, _)| name == &format!("{REGISTRY}-shm")));
    assert!(start_owner(&dir.0, session).1);
}
