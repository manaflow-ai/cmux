//! `cmux server ensure`: the detached local session owner.
//!
//! These tests drive the same ensure path the interactive client uses, so
//! they cover the contract behind "several `cmux` runs share one session":
//! ensure starts an owner when none runs, reports the running owner
//! afterwards, and concurrent ensures converge on a single owner process.

#![cfg(unix)]

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct EnsureFixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl EnsureFixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-eo-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self { socket: dir.join("mux.sock"), session: format!("eo-{name}"), dir }
    }

    fn command(&self, action: &str) -> Command {
        let mut command = Command::new(bin());
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            // The spawned owner inherits this environment, so its durable
            // state and configuration stay inside the fixture directory.
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    fn run(&self, action: &str) -> serde_json::Value {
        let output = self.command(action).output().unwrap();
        parse_success(action, &output)
    }
}

impl Drop for EnsureFixture {
    fn drop(&mut self) {
        let _ = self.command("stop").output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn parse_success(action: &str, output: &Output) -> serde_json::Value {
    assert!(
        output.status.success(),
        "server {action} failed: {:?}\nstdout: {}\nstderr: {}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn ensure_starts_a_detached_owner_once() {
    let fixture = EnsureFixture::new("start");

    let first = fixture.run("ensure");
    assert_eq!(first["status"], "started", "{first}");
    assert_eq!(first["session"], fixture.session.as_str(), "{first}");
    let pid = first["pid"].as_u64().expect("owner pid");

    // The ensure process exited, so a running owner proves detachment.
    let again = fixture.run("ensure");
    assert_eq!(again["status"], "running", "{again}");
    assert_eq!(again["pid"].as_u64(), Some(pid), "{again}");

    let status = fixture.run("status");
    assert_eq!(status["status"], "running", "{status}");
    assert_eq!(status["pid"].as_u64(), Some(pid), "{status}");

    let stopped = fixture.run("stop");
    assert_eq!(stopped["status"], "stopped", "{stopped}");

    let output = fixture.command("status").output().unwrap();
    assert!(!output.status.success(), "status after stop must fail");
}

#[test]
fn concurrent_ensures_converge_on_one_owner() {
    let fixture = EnsureFixture::new("race");

    let children = (0..4)
        .map(|_| {
            let mut command = fixture.command("ensure");
            command.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
            command.spawn().unwrap()
        })
        .collect::<Vec<_>>();
    let mut pids = Vec::new();
    for child in children {
        let output = child.wait_with_output().unwrap();
        let value = parse_success("ensure", &output);
        pids.push(value["pid"].as_u64().expect("owner pid"));
    }
    pids.sort_unstable();
    pids.dedup();
    assert_eq!(pids.len(), 1, "every ensure must report the same owner: {pids:?}");
}

fn owner_command_line(pid: u64) -> String {
    let output =
        Command::new("ps").args(["-o", "command=", "-p", &pid.to_string()]).output().unwrap();
    assert!(output.status.success(), "ps -p {pid} failed: {output:?}");
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// Reaping is opt-in (`--terminal-reap-grace-seconds`), and the cmux-next app
/// starts its daemon only through `server ensure`, so ensure must hand the
/// grace to the owner it spawns. Without the option the owner never reaps.
#[test]
fn cmux_next_ensure_starts_the_owner_with_the_reap_grace() {
    let fixture = EnsureFixture::new("reap");
    let output =
        fixture.command("ensure").args(["--terminal-reap-grace-seconds", "30"]).output().unwrap();
    let started = parse_success("ensure", &output);
    assert_eq!(started["status"], "started", "{started}");
    let pid = started["pid"].as_u64().expect("owner pid");
    let command_line = owner_command_line(pid);
    assert!(
        command_line.contains("--terminal-reap-grace-seconds 30"),
        "owner argv lacks the reap grace: {command_line}"
    );

    let plain = EnsureFixture::new("noreap");
    let started = plain.run("ensure");
    let pid = started["pid"].as_u64().expect("owner pid");
    let command_line = owner_command_line(pid);
    assert!(
        !command_line.contains("--terminal-reap-grace-seconds"),
        "an owner started without the option must not reap: {command_line}"
    );
}

#[test]
fn cmux_next_ensure_rejects_an_invalid_reap_grace() {
    let fixture = EnsureFixture::new("badreap");
    for value in ["soon", "604801"] {
        let output = fixture
            .command("ensure")
            .args(["--terminal-reap-grace-seconds", value])
            .output()
            .unwrap();
        assert!(!output.status.success(), "ensure accepted reap grace {value:?}");
        assert!(fixture.command("status").output().unwrap().status.code() != Some(0));
    }
}

/// A test harness names its own pid (`--exit-with-pid`): the owner ensure
/// spawns for it stops once that process exits (a crash, a time limit, a
/// cancelled job) instead of running on detached for hours.
#[test]
fn an_owner_ensured_with_exit_with_pid_stops_when_that_process_exits() {
    /// Killed when the test ends however it ends.
    struct Starter(std::process::Child);
    impl Drop for Starter {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let fixture = EnsureFixture::new("exitwith");
    let mut starter = Starter(Command::new("sleep").arg("120").spawn().unwrap());
    let starter_pid = starter.0.id().to_string();
    let output =
        fixture.command("ensure").args(["--exit-with-pid", &starter_pid]).output().unwrap();
    let started = parse_success("ensure", &output);
    assert_eq!(started["status"], "started", "{started}");
    let pid = started["pid"].as_u64().expect("owner pid") as u32;
    let command_line = owner_command_line(u64::from(pid));
    assert!(
        command_line.contains(&format!("--exit-with-pid {starter_pid}:")),
        "owner argv lacks the watched pid: {command_line}"
    );
    assert_eq!(fixture.run("status")["pid"].as_u64(), Some(u64::from(pid)));

    starter.0.kill().unwrap();
    starter.0.wait().unwrap();
    assert!(owner_exits(&fixture, pid), "the owner outlived the process it was started for");

    let output = fixture.command("ensure").args(["--exit-with-pid", "1"]).output().unwrap();
    assert!(!output.status.success(), "ensure accepted --exit-with-pid 1");
}

/// cx-t1ok: a state dir deleted and created again at the same path is a new
/// home. The owner of the deleted state still serves the session socket, so
/// ensure must refuse it, not report its stale state as the requested one.
/// The same state dir keeps the owner (`ensure_starts_a_detached_owner_once`).
#[test]
fn cmux_next_ensure_refuses_the_owner_of_a_recreated_state_dir() {
    let fixture = EnsureFixture::new("recreated");
    let first = fixture.run("ensure");
    assert_eq!(first["status"], "started", "{first}");

    // The owner still writes in its state dir, so removing it in place can
    // race a new file (ENOTEMPTY). Move it away first: the path is then free
    // at once, as after a delete, and the old tree goes best effort.
    let state = fixture.dir.join("state");
    let deleted = fixture.dir.join("state-deleted");
    fs::rename(&state, &deleted).unwrap();
    let _ = fs::remove_dir_all(&deleted);
    fs::create_dir_all(&state).unwrap();

    let output = fixture.command("ensure").output().unwrap();
    assert!(
        !output.status.success(),
        "ensure reused the owner of the deleted state dir: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap_or_else(|_| {
        panic!("stderr is not one JSON error: {}", String::from_utf8_lossy(&output.stderr))
    });
    assert_eq!(error["code"], "server.different_state", "{error}");
    // The refusal names the way out: stop the owner that serves the socket.
    assert!(error["message"].as_str().is_some_and(|m| m.contains("stop")), "{error}");
}

/// Holds the state root's session coordinator lock, so an owner that starts
/// now blocks inside its session restore (it takes that lock to claim the
/// session) until the hold ends: a restore as slow as the test needs, with
/// no hook in the product. Dropping the hold releases the lock.
struct SlowRestore {
    _lock: fs::File,
}

impl SlowRestore {
    fn hold(fixture: &EnsureFixture) -> Self {
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

/// A client connected to the session socket with one identify request sent.
struct PendingIdentify(std::io::BufReader<std::os::unix::net::UnixStream>);

impl PendingIdentify {
    fn send(socket: &std::path::Path) -> Option<Self> {
        use std::io::Write;
        let mut stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
        writeln!(stream, "{}", serde_json::json!({"id": 1, "cmd": "identify"})).ok()?;
        Some(Self(std::io::BufReader::new(stream)))
    }

    /// The identify response, or None when none came within `wait`.
    fn response(&mut self, wait: std::time::Duration) -> Option<serde_json::Value> {
        use std::io::BufRead;
        self.0.get_ref().set_read_timeout(Some(wait)).ok()?;
        let mut line = String::new();
        self.0.read_line(&mut line).ok()?;
        serde_json::from_str(&line).ok()
    }
}

/// Waits (bounded) until the owner holds its socket while it restores: a
/// client connects, and its identify is held (no answer yet) instead of
/// refused. Returns that held client.
fn held_while_restoring(fixture: &EnsureFixture) -> Option<PendingIdentify> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        if let Some(mut client) = PendingIdentify::send(&fixture.socket) {
            return match client.response(std::time::Duration::from_secs(1)) {
                None => Some(client),
                Some(_) => None,
            };
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    None
}

/// The pid of the owner process serving this fixture's socket (its argv
/// names the fixture's unique socket path).
fn owner_pid(fixture: &EnsureFixture) -> Option<u32> {
    let output = Command::new("ps").args(["-axo", "pid=,command="]).output().ok()?;
    let socket = fixture.socket.to_string_lossy().into_owned();
    String::from_utf8_lossy(&output.stdout).lines().find_map(|line| {
        let line = line.trim_start();
        let (pid, command) = line.split_once(' ')?;
        (command.contains("--headless") && command.contains(&socket)).then(|| pid.parse().ok())?
    })
}

/// A running `server ensure` or `server stop`, killed on drop if the test
/// ends before it finishes (a failed assertion must not leave it waiting).
struct ServerRun(Option<std::process::Child>);

impl ServerRun {
    fn output(mut self) -> Output {
        self.0.take().expect("server child").wait_with_output().unwrap()
    }
}

impl Drop for ServerRun {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn spawn_ensure(fixture: &EnsureFixture) -> ServerRun {
    spawn_ensure_with(fixture, &[])
}

fn spawn_ensure_with(fixture: &EnsureFixture, args: &[&str]) -> ServerRun {
    spawn_server(fixture, "ensure", args)
}

fn spawn_server(fixture: &EnsureFixture, action: &str, args: &[&str]) -> ServerRun {
    let mut command = fixture.command(action);
    command.args(args);
    command.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    ServerRun(Some(command.spawn().unwrap()))
}

/// cx-n3bs: an owner whose restore outlasts the 10 s contact bound is not
/// killed, and a second ensure during that restore waits for the same owner
/// instead of starting another. The owner holds its socket for the whole
/// restore, and a client that connected during the restore is served by the
/// restored session (a full identity), not refused.
#[test]
fn ensure_waits_for_a_restoring_owner_and_never_starts_a_second() {
    let fixture = EnsureFixture::new("restoring");
    let restore = SlowRestore::hold(&fixture);
    let started_at = std::time::Instant::now();
    let first = spawn_ensure_with(&fixture, &["--restore-progress"]);

    let held = held_while_restoring(&fixture);
    let second = spawn_ensure_with(&fixture, &["--restore-progress"]);
    // Keep the restore going well past the 10 s contact bound of both
    // ensures, measured from their spawns.
    let hold = std::time::Duration::from_secs(14);
    std::thread::sleep(hold.saturating_sub(started_at.elapsed()));
    drop(restore);

    let (first, first_progress) = progress_and_result(&first.output());
    let (second, second_progress) = progress_and_result(&second.output());
    assert_eq!(first["status"], "started", "{first}");
    assert_eq!(second["status"], "running", "{second}");
    let pid = first["pid"].as_u64().expect("owner pid");
    assert_eq!(second["pid"].as_u64(), Some(pid), "the second ensure found another owner");

    let mut held = held.expect("the owner did not hold its socket while it restored");
    let identity = held
        .response(std::time::Duration::from_secs(10))
        .expect("the client held during the restore got no answer after it");
    assert_eq!(identity["ok"], true, "{identity}");
    let data = &identity["data"];
    assert_eq!(data["app"], "cmux-tui", "{identity}");
    assert_eq!(data["session"], fixture.session.as_str(), "{identity}");
    assert_eq!(data["pid"].as_u64(), Some(pid), "{identity}");
    assert!(data["generation"].as_str().is_some_and(|g| !g.is_empty()), "{identity}");

    // `--restore-progress`: both ensures reported the restoring owner while they
    // waited (the app bounds its wait by these lines), each line before the
    // result line. The spawner knows its owner's pid; the second ensure sees
    // only a live socket that holds its identify, so its pid may be null.
    for (name, lines) in [("first", &first_progress), ("second", &second_progress)] {
        assert!(!lines.is_empty(), "the {name} ensure reported no restore progress");
        for line in lines {
            assert_eq!(line["progress"], "restoring", "{line}");
            assert_eq!(line["session"], fixture.session.as_str(), "{line}");
            if name == "first" {
                assert_eq!(line["pid"].as_u64(), Some(pid), "{line}");
            } else {
                assert!(line["pid"].is_null() || line["pid"].as_u64() == Some(pid), "{line}");
            }
        }
    }
}

/// `server ensure --restore-progress` output: the progress lines, then the result as
/// the last line.
fn progress_and_result(output: &Output) -> (serde_json::Value, Vec<serde_json::Value>) {
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
        .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
        .collect::<Vec<_>>();
    let result = lines.pop().expect("a result line");
    (result, lines)
}

/// cx-n3bs: an owner that held its socket while restoring and then died ends
/// the ensure that started it at once (server.unavailable), not after the
/// 120 s restore bound.
#[test]
fn ensure_fails_fast_when_its_restoring_owner_dies() {
    let fixture = EnsureFixture::new("restoredeath");
    let restore = SlowRestore::hold(&fixture);
    let ensure = spawn_ensure(&fixture);
    let _held = held_while_restoring(&fixture)
        .expect("the owner did not hold its socket while it restored");
    let pid = owner_pid(&fixture).expect("restoring owner pid");
    let killed_at = std::time::Instant::now();
    // SAFETY: signals the owner this test's ensure spawned (its argv names
    // this fixture's unique socket path).
    assert_eq!(unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) }, 0);
    let output = ensure.output();
    let waited = killed_at.elapsed();
    drop(restore);
    assert!(!output.status.success(), "ensure reported a dead owner as ready");
    let error: serde_json::Value = serde_json::from_slice(&output.stderr).unwrap_or_else(|_| {
        panic!("stderr is not one JSON error: {}", String::from_utf8_lossy(&output.stderr))
    });
    assert_eq!(error["code"], "server.unavailable", "{error}");
    assert!(waited < std::time::Duration::from_secs(5), "ensure waited {waited:?}");
}

/// Every line of `bytes` as JSON (a `--json` stop writes its progress lines,
/// then its error, on stderr).
fn json_lines(bytes: &[u8]) -> Vec<serde_json::Value> {
    String::from_utf8_lossy(bytes)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line).unwrap_or_else(|_| panic!("not a JSON line: {line}"))
        })
        .collect()
}

/// Whether the owner process `pid` is gone, waiting for it a bounded time.
fn owner_exits(fixture: &EnsureFixture, pid: u32) -> bool {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        if owner_pid(fixture) != Some(pid) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    false
}

/// A stop's progress lines (stderr, `--json`): each one names the session,
/// the restore phase it saw and a message.
fn assert_stop_progress(fixture: &EnsureFixture, lines: &[serde_json::Value]) {
    assert!(!lines.is_empty(), "the stop reported no restore progress while it waited");
    for line in lines {
        assert_eq!(line["progress"], "restoring", "{line}");
        assert_eq!(line["session"], fixture.session.as_str(), "{line}");
        assert!(matches!(line["phase"].as_str(), Some("restoring" | "starting")), "{line}");
        assert!(line["waited_ms"].is_u64(), "{line}");
        assert!(line["message"].as_str().is_some_and(|m| !m.is_empty()), "{line}");
    }
}

/// `server stop` during a restore that outlasts the 10 s it used to give an
/// owner's identify (d674e3164cc: an owner binds its socket before it
/// restores and holds every connection until the restore ends) waits for the
/// restore, reports it while it waits, and then stops the owner.
#[test]
fn stop_during_a_restore_waits_and_then_stops_the_owner() {
    let fixture = EnsureFixture::new("stoprestoring");
    let restore = SlowRestore::hold(&fixture);
    let ensure = spawn_ensure(&fixture);
    let _held = held_while_restoring(&fixture)
        .expect("the owner did not hold its socket while it restored");
    let pid = owner_pid(&fixture).expect("restoring owner pid");
    let stop_started = std::time::Instant::now();
    let stop = spawn_server(&fixture, "stop", &[]);
    // Keep restoring past the stop's old 10 s identify deadline.
    let hold = std::time::Duration::from_secs(12);
    std::thread::sleep(hold);
    drop(restore);

    let output = stop.output();
    let waited = stop_started.elapsed();
    let stopped = parse_success("stop", &output);
    assert_eq!(stopped["status"], "stopped", "{stopped}");
    assert_eq!(stopped["pid"].as_u64(), Some(u64::from(pid)), "{stopped}");
    assert!(waited >= hold, "the stop returned after {waited:?}, before the restore ended");
    assert_stop_progress(&fixture, &json_lines(&output.stderr));
    assert!(owner_exits(&fixture, pid), "the stop succeeded but its owner still runs");
    // The ensure that started the owner ends too (its result may be either:
    // the stop can end the owner before the ensure reads its identity).
    let _ = ensure.output();
}

/// `server stop` waits for a restoring owner a bounded time
/// (`--restore-wait-seconds`). Past it the stop fails and says why: the
/// owner still restores, in which phase, how long the stop waited, and the
/// command that retries with a longer wait. The owner keeps running and
/// finishes its restore.
#[test]
fn stop_during_a_restore_past_its_wait_says_why() {
    let fixture = EnsureFixture::new("stopbound");
    let restore = SlowRestore::hold(&fixture);
    let ensure = spawn_ensure(&fixture);
    let _held = held_while_restoring(&fixture)
        .expect("the owner did not hold its socket while it restored");
    let pid = owner_pid(&fixture).expect("restoring owner pid");
    let started = std::time::Instant::now();
    let output = fixture.command("stop").args(["--restore-wait-seconds", "3"]).output().unwrap();
    let waited = started.elapsed();

    assert_eq!(
        output.status.code(),
        Some(3),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    assert!(waited >= std::time::Duration::from_secs(3), "the stop gave up after {waited:?}");
    assert!(waited < std::time::Duration::from_secs(10), "the stop waited {waited:?}");
    let mut lines = json_lines(&output.stderr);
    let error = lines.pop().expect("an error line");
    assert_stop_progress(&fixture, &lines);
    assert_eq!(error["code"], "server.stop_restoring", "{error}");
    assert_eq!(error["retryable"], true, "{error}");
    let details = &error["details"];
    assert_eq!(details["reason"], "restoring", "{error}");
    assert_eq!(details["phase"], "restoring", "{error}");
    assert!(details["waited_ms"].as_u64().is_some_and(|ms| ms >= 3000), "{error}");
    let retry = details["retry"].as_str().expect("the error names the retry command");
    assert!(retry.contains(" daemon stop ") && retry.contains("--restore-wait-seconds"), "{error}");
    let message = error["message"].as_str().unwrap_or_default();
    assert!(message.contains(retry), "the message does not name the retry: {error}");

    assert_eq!(owner_pid(&fixture), Some(pid), "a stop that gave up ended its owner");
    drop(restore);
    let ensured = parse_success("ensure", &ensure.output());
    assert_eq!(ensured["status"], "started", "{ensured}");
    assert_eq!(ensured["pid"].as_u64(), Some(u64::from(pid)), "{ensured}");
}
