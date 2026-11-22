//! cx-urd.59: a panic in the session owner must never be lost.
//!
//! The detached owner runs with no stdio, so the default panic message goes
//! nowhere. The owner appends each panic to `owner-panics-<session>.jsonl`
//! at the state root and keeps running (deliberate recoveries, such as the
//! kitty PNG decoder's, still work); the cmux-next app sends new lines to
//! Sentry.

#![cfg(all(unix, debug_assertions))]

use std::fs;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

/// The owner under test, stopped with its terminals even when an assertion fails.
struct Owner {
    child: Child,
    dir: PathBuf,
    session: &'static str,
}

/// A cmux-tui command whose state, config and log stay inside `dir`.
fn command(dir: &std::path::Path) -> Command {
    let mut command = Command::new(bin());
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"));
    command
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = command(&self.dir)
            .args(["server", "stop", "--session", self.session, "--end-terminals", "--socket"])
            .arg(self.dir.join("mux.sock"))
            .output();
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn a_worker_thread_panic_is_logged_and_the_owner_keeps_running() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-op-{}-{stamp}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    let session = "op-panic";
    let child = command(&dir)
        .args(["--headless", "--session", session, "--socket"])
        .arg(dir.join("mux.sock"))
        // Debug builds only: a worker thread panics once the hook is installed.
        .env("CMUX_TUI_TEST_OWNER_PANIC", "thread")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut owner = Owner { child, dir, session };

    let log = owner.dir.join("state").join(format!("owner-panics-{session}.jsonl"));
    let deadline = Instant::now() + Duration::from_secs(30);
    let line = loop {
        if let Some(line) =
            fs::read_to_string(&log).ok().and_then(|text| text.lines().next().map(String::from))
        {
            break line;
        }
        assert!(
            owner.child.try_wait().unwrap().is_none(),
            "the owner exited after a worker-thread panic"
        );
        assert!(Instant::now() < deadline, "no owner panic log at {}", log.display());
        std::thread::sleep(Duration::from_millis(50));
    };
    let record: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(record["session"], session, "{record}");
    assert_eq!(record["message"], "cmux-tui test owner panic", "{record}");
    assert_eq!(record["thread"], "owner-panic-test", "{record}");
    assert_eq!(record["test"], true, "{record}");
    assert!(record["location"].as_str().unwrap_or_default().contains(".rs:"), "{record}");
    assert_eq!(record["owner_pid"].as_u64(), Some(u64::from(owner.child.id())), "{record}");

    // The panic ended only its own thread: the owner still serves.
    std::thread::sleep(Duration::from_millis(500));
    assert!(owner.child.try_wait().unwrap().is_none(), "the owner must keep running");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&log).unwrap().permissions().mode() & 0o777, 0o600);
    }
}
