//! An owner answers health questions while it restores its session.
//!
//! The owner binds its socket before it restores (cx-n3bs) and used to hold
//! every request unanswered until the restore ended, `identify` included. A
//! restore that replayed about 12M journal rows took 26 minutes, so nothing
//! could tell it from a hung owner, and the owner was replaced again and
//! again. Now `identify` answers at once with `lifecycle_ready: false` and
//! the restore's progress, and `server ensure --restore-progress` passes that
//! progress on.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-rp-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("rp-{name}"), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            // The spawned owner inherits this environment.
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// Holds the state root's session coordinator lock, so the owner blocks in
/// the first step of its restore (`registry_open`) until the hold ends, on
/// any build (detached_owner.rs `SlowRestore`).
struct SlowRestore {
    _lock: fs::File,
}

impl SlowRestore {
    fn hold(fixture: &Fixture) -> Self {
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        let locks = fixture.dir.join("state").join("session-locks");
        fs::DirBuilder::new().recursive(true).mode(0o700).create(&locks).unwrap();
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(locks.join(".coordinator.lock"))
            .unwrap();
        // SAFETY: flock on a descriptor this test owns.
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
        Self { _lock: lock }
    }
}

/// A running `server ensure`, killed on drop if the test ends first.
struct EnsureRun(Option<std::process::Child>);

impl EnsureRun {
    fn output(mut self) -> Output {
        self.0.take().expect("ensure child").wait_with_output().unwrap()
    }
}

impl Drop for EnsureRun {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// One client connection to the owner.
struct Client(BufReader<UnixStream>);

impl Client {
    /// Connects once the owner has bound its socket (bounded).
    fn connect(socket: &Path) -> Self {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if let Ok(stream) = UnixStream::connect(socket) {
                return Self(BufReader::new(stream));
            }
            assert!(Instant::now() < deadline, "the owner never bound its socket");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// `identify {revisions: true}`, and how long its answer took; None when
    /// no answer came within `wait`.
    fn identify(&mut self, id: u64, wait: Duration) -> (Option<Value>, Duration) {
        let asked = Instant::now();
        writeln!(self.0.get_mut(), "{}", json!({"id": id, "cmd": "identify", "revisions": true}))
            .unwrap();
        self.0.get_ref().set_read_timeout(Some(wait)).unwrap();
        let mut line = String::new();
        let answer = match self.0.read_line(&mut line) {
            Ok(read) if read > 0 => serde_json::from_str::<Value>(&line).ok(),
            _ => None,
        };
        (answer, asked.elapsed())
    }
}

/// `server ensure --restore-progress` output: the progress lines, then the
/// result as the last line.
fn progress_and_result(output: &Output) -> (Value, Vec<Value>) {
    assert!(
        output.status.success(),
        "server ensure failed: {:?}\nstdout: {}\nstderr: {}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    let mut lines = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .collect::<Vec<_>>();
    let result = lines.pop().expect("a result line");
    (result, lines)
}

/// While the owner restores, `identify` answers within a second with
/// `lifecycle_ready: false` and the restore's phase; a restore that works
/// moves `last_advance_ms`; `server ensure` progress lines carry the phase;
/// and the owner then becomes ready and serves as before. On a build where
/// a restoring owner holds every request, the first identify gets no answer.
#[test]
fn identify_reports_the_restore_while_the_owner_restores() {
    let fixture = Fixture::new("identify");
    let hold = SlowRestore::hold(&fixture);
    let mut ensure = fixture.command("ensure");
    ensure
        .arg("--restore-progress")
        // After the hold, the agent roster step takes 8 s more, advancing
        // every 50 ms (debug-build hook), so the ensure reports it.
        .env("CMUX_TUI_TEST_RESTORE_DELAY_MS", "8000")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let ensure = EnsureRun(Some(ensure.spawn().unwrap()));

    // Blocked in its first step: the answer comes at once all the same.
    let mut client = Client::connect(&fixture.socket);
    let (first, took) = client.identify(1, Duration::from_secs(3));
    eprintln!("restore-progress-identify: first identify answer while restoring after {took:?}");
    let first = first
        .unwrap_or_else(|| panic!("identify got no answer in {took:?} while the owner restores"));
    assert!(took < Duration::from_secs(1), "identify took {took:?}: {first}");
    assert_eq!(first["ok"], true, "{first}");
    let identity = &first["data"];
    assert_eq!(identity["app"], "cmux-tui", "{first}");
    assert_eq!(identity["session"], fixture.session.as_str(), "{first}");
    assert_eq!(identity["lifecycle_ready"], false, "{first}");
    assert!(identity["protocol"].is_u64(), "{first}");
    assert!(identity["pid"].is_u64(), "{first}");
    assert_eq!(identity["daemon_handoff"], 1, "{first}");
    assert_eq!(identity["restore"]["phase"], "registry_open", "{first}");
    assert!(identity["restore"]["elapsed_ms"].is_u64(), "{first}");
    assert!(identity["restore"]["last_advance_ms"].is_u64(), "{first}");

    // Let the restore run into the slowed agent roster step, then watch it advance.
    std::thread::sleep(Duration::from_secs(2));
    drop(hold);
    let deadline = Instant::now() + Duration::from_secs(10);
    let roster = loop {
        let (answer, took) = client.identify(2, Duration::from_secs(1));
        let answer = answer.unwrap_or_else(|| panic!("identify got no answer in {took:?}"));
        if answer["data"]["restore"]["phase"] == "agent_roster" {
            break answer;
        }
        assert!(Instant::now() < deadline, "the restore never reached agent_roster: {answer}");
        std::thread::sleep(Duration::from_millis(50));
    };
    std::thread::sleep(Duration::from_millis(500));
    let (later, _) = client.identify(3, Duration::from_secs(1));
    let later = later.expect("identify during the agent roster step");
    let (before, after) = (&roster["data"]["restore"], &later["data"]["restore"]);
    assert_eq!(after["phase"], "agent_roster", "{later}");
    assert!(
        after["last_advance_ms"].as_u64() > before["last_advance_ms"].as_u64(),
        "a working restore did not advance: {before} then {after}"
    );
    assert!(after["done"].as_u64() > before["done"].as_u64(), "{before} then {after}");
    assert!(after["total"].is_u64(), "{after}");

    // A request other than identify waits for the restored session.
    writeln!(client.0.get_mut(), "{}", json!({"id": 4, "cmd": "ping"})).unwrap();

    let (result, progress) = progress_and_result(&ensure.output());
    assert_eq!(result["status"], "started", "{result}");
    let pid = result["pid"].as_u64().expect("owner pid");
    assert!(!progress.is_empty(), "the ensure reported no restore progress");
    assert!(
        progress.iter().any(|line| line["restore"]["phase"].is_string()),
        "no progress line carries the owner's restore phase: {progress:?}"
    );
    for line in &progress {
        assert_eq!(line["progress"], "restoring", "{line}");
        assert_eq!(line["pid"].as_u64(), Some(pid), "{line}");
    }

    // The held ping is served by the restored session, and the owner is ready.
    client.0.get_ref().set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut line = String::new();
    client.0.read_line(&mut line).unwrap();
    let ping: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(ping["id"], 4, "{ping}");
    assert_eq!(ping["ok"], true, "{ping}");
    let (ready, _) = client.identify(5, Duration::from_secs(10));
    let ready = ready.expect("identify after the restore");
    let identity = &ready["data"];
    assert_eq!(identity["lifecycle_ready"], true, "{ready}");
    assert_eq!(identity["pid"].as_u64(), Some(pid), "{ready}");
    assert!(identity["generation"].as_str().is_some_and(|g| !g.is_empty()), "{ready}");
    assert!(identity.get("restore").is_none(), "a ready owner reports no restore: {ready}");
    let status = fixture.command("status").output().unwrap();
    assert!(status.status.success(), "status: {}", String::from_utf8_lossy(&status.stderr));
}
