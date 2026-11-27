//! The daemon on the supervisor contract (`cmux-supervise-core`), against real daemons in temp
//! homes, one fault each (hq `docs/design/remote-cloud-durability.md` section 5), in the style
//! the `cmux-fault` harness adopts:
//!
//! - `slow-disk` (F8): every journal fsync takes 10 s. The daemon serves on with zero self-stops,
//!   and its health says so: `supervisor.faultsToday` 0, state `running`.
//! - `kill` (F7, H5): a SIGKILLed daemon wrote no end; the next one counts its death once, with
//!   the death event, and reads it on `_acpmux/status`.
//! - `kill` during a dial (F10): a client that dials while the next daemon holds the home but has
//!   not bound connects within 2 s of that daemon's ready, instead of "no acpmux daemon".
//! - `update-swap` (F9): an update moves the daemon's executable under `backup/` and puts a new
//!   build at the installed path; within 2 s `_acpmux/status` answers from the installed path. A
//!   new build that does not run is dropped and the old daemon serves on.
//!   A swap that failed tries again by itself, and the app's stop of a replaced daemon with
//!   `swapIfReplaced` swaps it instead of stopping it.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amx-sv-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("p")).unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::write(
        dir.join("config.json"),
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
               "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    fs::set_permissions(dir.join("config.json"), fs::Permissions::from_mode(0o600)).unwrap();
    dir
}

fn with_home(mut cmd: Command, dir: &Path) -> Command {
    cmd.env("ACPMUX_HOME", dir).env("ACPMUX_LOGIN_ENV", "0").current_dir(dir.join("p"));
    cmd
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    let mut cmd = with_home(daemon_env::command(dir, daemon_env::Agents::StandIn, &[]), dir);
    cmd.args(args).output().unwrap()
}

fn text(o: &Output) -> String {
    format!(
        "status {:?}\nstdout: {}\nstderr: {}",
        o.status,
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    )
}

fn status(dir: &Path) -> Option<Value> {
    let out = cli(dir, &["--json", "daemon", "status"]);
    out.status.success().then(|| serde_json::from_slice(&out.stdout).ok()).flatten()
}

struct Daemon {
    child: Child,
    lines: std::sync::mpsc::Receiver<String>,
}

impl Daemon {
    /// Wait for a stdout line `want` says is the one, up to `within`.
    fn line(&self, within: Duration, want: impl Fn(&str) -> bool) -> Option<String> {
        let deadline = Instant::now() + within;
        loop {
            let left = deadline.checked_duration_since(Instant::now())?;
            match self.lines.recv_timeout(left) {
                Ok(line) if want(&line) => return Some(line),
                Ok(_) => {}
                Err(_) => return None,
            }
        }
    }

    fn ready(&self, within: Duration) -> Value {
        let line = self
            .line(within, |l| serde_json::from_str::<Value>(l).is_ok_and(|v| v["ready"] == true))
            .expect("the daemon became ready");
        serde_json::from_str(&line).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn_daemon(binary: &Path, dir: &Path, env: &[(&str, &str)]) -> Daemon {
    let mut cmd =
        with_home(daemon_env::command_at(binary, dir, daemon_env::Agents::StandIn, &[]), dir);
    cmd.args(["daemon", "run", "--ready-fd", "1", "--log", "warn"]);
    for (k, v) in env {
        cmd.env(k, v);
    }
    // Its stdout carries the ready line and its log (`log_sink.rs`): both come through `lines`.
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    // A binary another test of this file just copied can still be open for writing in a child
    // forked meanwhile (until its exec closes it): ETXTBSY for a moment, not a fault of the daemon.
    let mut busy = 0;
    let mut child = loop {
        match cmd.spawn() {
            Err(e) if e.raw_os_error() == Some(libc::ETXTBSY) && busy < 100 => {
                busy += 1;
                std::thread::sleep(Duration::from_millis(20));
            }
            spawned => break spawned.unwrap(),
        }
    };
    let stdout = child.stdout.take().unwrap();
    let (tx, lines) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                return;
            }
        }
    });
    Daemon { child, lines }
}

struct Shutdown<'a>(&'a Path);

impl Drop for Shutdown<'_> {
    fn drop(&mut self) {
        let _ = cli(self.0, &["daemon", "shutdown", "--end-agents"]);
        let _ = fs::remove_dir_all(self.0);
    }
}

fn sigkill(pid: u64) {
    // Only a daemon this test started.
    assert_eq!(unsafe { libc::kill(pid as i32, libc::SIGKILL) }, 0);
}

/// fault: slow-disk. Every log fsync takes 10 s; sessions are made and read through it.
#[test]
fn slow_disk_10s_fsync_makes_zero_self_stops_and_the_health_says_so() {
    let _ = HERMETIC;
    let dir = scratch("slow");
    let _shutdown = Shutdown(&dir);
    let daemon = spawn_daemon(daemon_env::bin(), &dir, &[("ACPMUX_TEST_SYNC_DELAY_MS", "10000")]);
    let pid = daemon.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    let started = Instant::now();
    let mut made = 0;
    while started.elapsed() < Duration::from_secs(25) {
        let out = cli(&dir, &["new", "-d", "-n", &format!("s{made}"), "-m", "fake"]);
        assert!(out.status.success() || made > 0, "{}", text(&out));
        made += 1;
        let now = status(&dir).expect("the daemon answers on a slow disk");
        assert_eq!(now["pid"].as_u64(), Some(pid), "the daemon stopped itself: {now}");
    }
    let now = status(&dir).unwrap();
    assert_eq!(now["pid"].as_u64(), Some(pid));
    let supervisor = &now["supervisor"];
    assert_eq!(supervisor["state"], "running", "{now}");
    assert_eq!(supervisor["faultsToday"], 0, "zero self-stops: {supervisor}");
    assert_eq!(supervisor["owner"]["pid"].as_u64(), Some(pid), "{supervisor}");
}

/// fault: kill. The next daemon counts the death once and serves it on its health.
#[test]
fn a_killed_daemon_is_counted_once_as_a_death_by_the_next_one() {
    let dir = scratch("kill");
    let _shutdown = Shutdown(&dir);
    let first = spawn_daemon(daemon_env::bin(), &dir, &[]);
    let pid = first.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    sigkill(pid);
    drop(first);
    let second = spawn_daemon(daemon_env::bin(), &dir, &[]);
    second.ready(Duration::from_secs(60));
    let supervisor = status(&dir).unwrap()["supervisor"].clone();
    assert_eq!(supervisor["faultsToday"], 1, "{supervisor}");
    assert_eq!(supervisor["owner"]["epoch"], 2, "{supervisor}");
    assert_eq!(supervisor["recent"][0]["cause"]["kind"], "died", "{supervisor}");
    let deaths = fs::read_to_string(dir.join("daemon.deaths.jsonl")).unwrap();
    assert_eq!(deaths.lines().count(), 1, "{deaths}");
    assert!(deaths.contains(&format!("\"pid\":{pid}")), "{deaths}");
    // A meant stop is counted, never as a fault, and the start after it counts nothing.
    let stop = cli(&dir, &["daemon", "shutdown"]);
    assert!(stop.status.success(), "{}", text(&stop));
    drop(second);
    let third = spawn_daemon(daemon_env::bin(), &dir, &[]);
    third.ready(Duration::from_secs(60));
    let supervisor = status(&dir).unwrap()["supervisor"].clone();
    assert_eq!(
        (supervisor["faultsToday"].as_u64(), supervisor["stopsToday"].as_u64()),
        (Some(1), Some(2)),
        "{supervisor}"
    );
}

/// fault: kill during a dial. The client dials while the next daemon holds the home and has not
/// bound its socket yet (`ACPMUX_TEST_HOLD_AFTER_LOCK`: 500 ms there).
#[test]
fn a_dial_during_a_restart_connects_within_2s_of_the_next_daemons_ready() {
    let dir = scratch("dial");
    let _shutdown = Shutdown(&dir);
    let first = spawn_daemon(daemon_env::bin(), &dir, &[]);
    let pid = first.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    sigkill(pid);
    drop(first);
    let next = spawn_daemon(daemon_env::bin(), &dir, &[("ACPMUX_TEST_HOLD_AFTER_LOCK", "1")]);
    next.line(Duration::from_secs(30), |l| l == "acpmux-test-lock-held")
        .expect("the next start holds the lock");
    // `process list` never starts a daemon (`connect(false)`): it dials the one there is.
    let mut dial = with_home(daemon_env::command(&dir, daemon_env::Agents::StandIn, &[]), &dir);
    let dial = dial
        .args(["--json", "process", "list"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    next.ready(Duration::from_secs(30));
    let ready_at = Instant::now();
    let out = dial.wait_with_output().unwrap();
    let after_ready = ready_at.elapsed();
    assert!(out.status.success(), "the dial during the restart failed: {}", text(&out));
    assert!(after_ready <= Duration::from_secs(2), "connected {after_ready:?} after ready");
}

/// The daemon binary copied to `<dir>/app/acpmux`, as an app bundle holds it.
fn install(dir: &Path) -> PathBuf {
    let app = dir.join("app");
    fs::create_dir_all(&app).unwrap();
    let exe = app.join("acpmux");
    fs::copy(daemon_env::bin(), &exe).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
    exe
}

/// The update: the old bundle goes under `backup/`, and `new` is put at the installed path.
fn update(dir: &Path, new: impl FnOnce(&Path)) {
    fs::create_dir_all(dir.join("backup")).unwrap();
    fs::rename(dir.join("app"), dir.join("backup/app")).unwrap();
    fs::create_dir_all(dir.join("app")).unwrap();
    new(&dir.join("app/acpmux"));
}

/// fault: update-swap.
#[test]
fn an_update_that_moves_the_executable_answers_from_the_installed_path_within_2s() {
    let dir = scratch("swap");
    let _shutdown = Shutdown(&dir);
    let installed = install(&dir);
    let old = spawn_daemon(&installed, &dir, &[]);
    let old_pid = old.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    assert_eq!(status(&dir).unwrap()["exe"], installed.display().to_string());

    let tmp = dir.join("acpmux.new");
    fs::copy(daemon_env::bin(), &tmp).unwrap();
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).unwrap();
    update(&dir, |at| fs::rename(&tmp, at).unwrap());
    let moved = Instant::now();
    let deadline = moved + Duration::from_secs(20);
    let swapped = loop {
        if let Some(now) = status(&dir)
            && now["exe"] == installed.display().to_string()
            && now["pid"].as_u64() != Some(old_pid)
        {
            break moved.elapsed();
        }
        assert!(Instant::now() < deadline, "still {:?}", status(&dir).map(|s| s["exe"].clone()));
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(
        swapped <= Duration::from_secs(2),
        "answered from the installed path after {swapped:?}"
    );
    let supervisor = status(&dir).unwrap()["supervisor"].clone();
    assert_eq!(supervisor["faultsToday"], 0, "an update is no fault: {supervisor}");
}

/// fault: update-swap with a new build that does not run: the old daemon keeps serving.
#[test]
fn an_update_whose_new_build_does_not_run_keeps_the_old_daemon_serving() {
    let dir = scratch("swapbad");
    let _shutdown = Shutdown(&dir);
    let installed = install(&dir);
    let old = spawn_daemon(&installed, &dir, &[]);
    let old_pid = old.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    update(&dir, |at| {
        fs::write(at, "#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(at, fs::Permissions::from_mode(0o755)).unwrap();
    });
    old.line(Duration::from_secs(20), |l| l.contains("the new build did not take over"))
        .expect("the old daemon logs that it kept serving");
    let now = status(&dir).expect("the old daemon still answers");
    assert_eq!(now["pid"].as_u64(), Some(old_pid), "{now}");
}

/// One JSON-RPC request on a new connection to `socket`, as the app's `AcpmuxStatusClient` sends
/// it: the answer to it (lines the daemon sends first are skipped), or `None` when nothing listens
/// or nothing answered in 10 s.
fn call(socket: &Path, method: &str, params: Value) -> Option<Value> {
    use std::io::Write as _;
    let mut s = std::os::unix::net::UnixStream::connect(socket).ok()?;
    s.set_read_timeout(Some(Duration::from_secs(10))).ok()?;
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
    s.write_all(format!("{line}\n").as_bytes()).ok()?;
    let mut reader = BufReader::new(&s);
    loop {
        let mut reply = String::new();
        if reader.read_line(&mut reply).ok()? == 0 {
            return None;
        }
        if let Ok(v) = serde_json::from_str::<Value>(&reply)
            && v["id"] == 1
        {
            return Some(v);
        }
    }
}

/// The pid of the daemon answering on `socket`, if one does.
fn serving_pid(socket: &Path) -> Option<u64> {
    call(socket, "_acpmux/status", json!({}))?["result"]["pid"].as_u64()
}

/// A new build that answers `--version` but whose take-over start fails until `flag` exists: the
/// update's own swap fails, as on Leo's NIGHTLY at 2026-11-22 23:44Z ("the take-over start never
/// asked to take over"), and the replaced daemon serves on from the backup bundle.
fn update_with_late_build(dir: &Path, flag: &Path) {
    let real = daemon_env::bin().display().to_string();
    let script = format!(
        "#!/bin/sh\nif [ \"$1\" = --version ]; then exec '{real}' --version; fi\n\
         if [ -e '{}' ]; then exec '{real}' \"$@\"; fi\nexit 3\n",
        flag.display()
    );
    update(dir, |at| {
        fs::write(at, script).unwrap();
        fs::set_permissions(at, fs::Permissions::from_mode(0o755)).unwrap();
    });
}

/// Waits up to `within` for a daemon other than `old_pid` to answer on `socket`: the one the swap
/// started. Nothing in this test starts a daemon, so only the swap can.
fn successor(socket: &Path, old_pid: u64, within: Duration) -> Option<(u64, Duration)> {
    let from = Instant::now();
    while from.elapsed() < within {
        if let Some(pid) = serving_pid(socket)
            && pid != old_pid
        {
            return Some((pid, from.elapsed()));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    None
}

/// The app's stop for a daemon whose bundle an update replaced (it cannot hand that daemon this
/// launch's person key, `AcpmuxPersonKey.swift`), with `swapIfReplaced`: the daemon swaps to the
/// installed build make-before-break instead of stopping, so a new daemon serves the home with
/// nothing else starting one. Before, it
/// stopped, and every chat was without a daemon until the app's next one started (4.6 s at
/// 23:44Z).
#[test]
fn a_replaced_daemon_the_app_asks_to_stop_swaps_to_the_installed_build_instead() {
    let dir = scratch("swapask");
    let _shutdown = Shutdown(&dir);
    let installed = install(&dir);
    let old = spawn_daemon(&installed, &dir, &[]);
    let old_pid = old.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    let socket = PathBuf::from(status(&dir).unwrap()["socket"].as_str().unwrap());
    let flag = dir.join("the-new-build-runs");
    update_with_late_build(&dir, &flag);
    old.line(Duration::from_secs(20), |l| l.contains("the new build did not take over"))
        .expect("the update's own swap fails");
    fs::write(&flag, "").unwrap();
    let answer = call(
        &socket,
        "_acpmux/shutdown",
        json!({"reason": "app: person key: acpmux runs a bundle an update replaced, which cannot take this launch's person key",
               "swapIfReplaced": true}),
    )
    .expect("the daemon answers the app's stop");
    assert_eq!(answer["result"]["swapping"], true, "swapped, not stopped: {answer}");
    let (pid, after) = successor(&socket, old_pid, Duration::from_secs(30))
        .expect("the installed build serves the home");
    eprintln!("swap-ask: the installed build (pid {pid}) served {after:?} after the app's ask");
    let stops = fs::read_to_string(dir.join("daemon.stops.json")).unwrap_or_default();
    assert!(!stops.contains("cannot take this launch's person key"), "no app stop: {stops}");
}

/// The update's own swap that failed tries again by itself (`RETRY_AFTER` in `exe_swap.rs`, 5 s
/// first) instead of serving on from the replaced bundle until the next update or the app's stop.
#[test]
fn a_failed_update_swap_tries_again_without_a_new_change() {
    let dir = scratch("swapretry");
    let _shutdown = Shutdown(&dir);
    let installed = install(&dir);
    let old = spawn_daemon(&installed, &dir, &[]);
    let old_pid = old.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    let socket = PathBuf::from(status(&dir).unwrap()["socket"].as_str().unwrap());
    let flag = dir.join("the-new-build-runs");
    update_with_late_build(&dir, &flag);
    old.line(Duration::from_secs(20), |l| l.contains("the new build did not take over"))
        .expect("the update's own swap fails");
    fs::write(&flag, "").unwrap();
    let (pid, after) = successor(&socket, old_pid, Duration::from_secs(30))
        .expect("the swap tried again and the installed build serves the home");
    eprintln!("swap-retry: the installed build (pid {pid}) served {after:?} after the build ran");
}

/// A stand-in for the app: a python3 process (the same executable each launch, as an app bundle
/// relaunched at its path). With `socket`, it connects once and holds the connection, as the
/// relaunched app's panes do; else it only runs.
fn fake_app(socket: Option<&Path>) -> Child {
    let script = "import socket, sys, time\n\
        if len(sys.argv) > 1:\n\
        \x20   s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])\n\
        \x20   s.sendall(b'{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"_acpmux/status\",\"params\":{}}\\n')\n\
        \x20   s.recv(65536)\n\
        time.sleep(600)\n";
    let mut cmd = Command::new("python3");
    cmd.arg("-c").arg(script);
    if let Some(socket) = socket {
        cmd.arg(socket);
    }
    cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().unwrap()
}

fn end_child(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// One connection that only observes (`_meta.acpmux.observer`, as the app's cmux-tui notices
/// watch): once the owner app is gone it keeps nothing, so the daemon's own stop rule is what is
/// tested. It asks `_acpmux/status` every 20 ms and records the longest time without an answer.
struct Probe {
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    thread: std::thread::JoinHandle<(Duration, u64, Option<String>)>,
}

impl Probe {
    fn start(socket: &Path) -> Self {
        use std::io::Write as _;
        let mut s = std::os::unix::net::UnixStream::connect(socket).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut reader = BufReader::new(s.try_clone().unwrap());
        let mut ask =
            move |s: &mut std::os::unix::net::UnixStream, id: u64, method: &str, params: Value| {
                let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
                s.write_all(format!("{line}\n").as_bytes()).map_err(|e| e.to_string())?;
                loop {
                    let mut reply = String::new();
                    if reader.read_line(&mut reply).map_err(|e| e.to_string())? == 0 {
                        return Err("the daemon closed the connection".to_owned());
                    }
                    if let Ok(v) = serde_json::from_str::<Value>(&reply)
                        && v["id"] == id
                    {
                        return Ok(());
                    }
                }
            };
        ask(
            &mut s,
            1,
            "initialize",
            json!({"protocolVersion": 1, "clientInfo": {"name": "probe", "version": "1"},
            "clientCapabilities": {}, "_meta": {"acpmux": {"observer": true}}}),
        )
        .unwrap();
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let stopping = stop.clone();
        let thread = std::thread::spawn(move || {
            let (mut longest, mut answers, mut last, mut id) =
                (Duration::ZERO, 0u64, Instant::now(), 1);
            while !stopping.load(std::sync::atomic::Ordering::Relaxed) {
                id += 1;
                if let Err(error) = ask(&mut s, id, "_acpmux/status", json!({})) {
                    return (longest.max(last.elapsed()), answers, Some(error));
                }
                answers += 1;
                longest = longest.max(last.elapsed());
                last = Instant::now();
                std::thread::sleep(Duration::from_millis(20));
            }
            (longest, answers, None)
        });
        Self { stop, thread }
    }

    /// The longest time between answers, how many came, and the error that ended them, if any.
    fn finish(self) -> (Duration, u64, Option<String>) {
        self.stop.store(true, std::sync::atomic::Ordering::Relaxed);
        self.thread.join().unwrap()
    }
}

/// Waits up to `within` for `child` to exit.
fn exits_within(child: &mut Child, within: Duration) -> Option<std::process::ExitStatus> {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().unwrap() {
            return Some(status);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    None
}

/// Leo, after every app update: "The agent service stopped. [Retry]". The update quits the app
/// and opens the new one; the daemon of idle chats followed the old app's pid and stopped 2 s
/// after it was gone (`owner_exit::OWNER_EXIT_GRACE`), before the new app was up. With the
/// relaunch marker (`acpmux daemon expect-relaunch`, `owner_relaunch.rs`) the daemon serves on
/// through the gap, adopts the relaunched app when it connects, and then follows it: it stops once
/// that app is gone. Its socket answers throughout.
#[test]
fn update_handoff_the_daemon_waits_for_the_relaunched_app_and_follows_it() {
    let dir = scratch("relaunch");
    let _shutdown = Shutdown(&dir);
    let mut old_app = fake_app(None);
    let mut daemon = spawn_daemon(
        daemon_env::bin(),
        &dir,
        &[("ACPMUX_OWNER_APP_PID", &old_app.id().to_string())],
    );
    let pid = daemon.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    let socket = PathBuf::from(status(&dir).unwrap()["socket"].as_str().unwrap());
    let out =
        cli(&dir, &["daemon", "expect-relaunch", "--within", "30", "--reason", "a test update"]);
    assert!(out.status.success(), "{}", text(&out));
    let marker = dir.join("owner-relaunch.json");
    assert!(marker.exists(), "the marker is written: {}", text(&out));
    let probe = Probe::start(&socket);
    // The update quits the app; the new one takes 5 s to come up, past the 2 s grace.
    end_child(&mut old_app);
    std::thread::sleep(Duration::from_secs(5));
    assert!(
        daemon.child.try_wait().unwrap().is_none(),
        "the daemon stopped while a relaunch was expected"
    );
    let quit_to_back = Instant::now();
    let mut new_app = fake_app(Some(&socket));
    while marker.exists() {
        assert!(
            quit_to_back.elapsed() < Duration::from_secs(10),
            "the relaunched app was never adopted"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    eprintln!(
        "update-handoff: relaunched app adopted {:?} after it started",
        quit_to_back.elapsed()
    );
    std::thread::sleep(Duration::from_secs(3));
    let (longest, answers, error) = probe.finish();
    eprintln!("update-handoff: {answers} answers, longest gap {longest:?}, ended by {error:?}");
    assert!(error.is_none(), "the probe lost the daemon: {error:?}");
    assert!(longest < Duration::from_millis(500), "the socket went {longest:?} without an answer");
    assert_eq!(serving_pid(&socket), Some(pid), "the same daemon serves");
    // It follows the new app now: once that app is gone, with nothing to keep it, it stops.
    end_child(&mut new_app);
    let stopped = exits_within(&mut daemon.child, Duration::from_secs(15));
    assert!(stopped.is_some(), "the daemon did not follow the relaunched app");
    let log = fs::read_to_string(dir.join("daemon.log")).unwrap_or_default();
    eprintln!(
        "update-handoff: stop line: {:?}",
        log.lines().filter(|l| l.contains("its app quit")).last()
    );
}

/// Without a marker an owner's exit is a quit: the daemon of idle chats stops 2 s after (the
/// quit-leaves-no-helpers rule stays).
#[test]
fn update_handoff_without_a_marker_a_quit_still_stops_the_daemon() {
    let dir = scratch("noreln");
    let _shutdown = Shutdown(&dir);
    let mut app = fake_app(None);
    let mut daemon =
        spawn_daemon(daemon_env::bin(), &dir, &[("ACPMUX_OWNER_APP_PID", &app.id().to_string())]);
    daemon.ready(Duration::from_secs(60));
    end_child(&mut app);
    let quit = Instant::now();
    assert!(
        exits_within(&mut daemon.child, Duration::from_secs(15)).is_some(),
        "still ran after its app quit"
    );
    eprintln!("update-handoff: no marker: stopped {:?} after the quit", quit.elapsed());
}

/// An update that replaces the daemon's executable after the app relaunched: the successor
/// (`exe_swap.rs`) follows the relaunched app, not the old app's pid it used to inherit. Before,
/// it started already following a dead owner and stopped 2 s after its startup with no non-
/// observer client, while the new app ran. The socket answers across the swap.
#[test]
fn update_handoff_a_swapped_daemon_follows_the_relaunched_app() {
    let dir = scratch("swapown");
    let _shutdown = Shutdown(&dir);
    let installed = install(&dir);
    let mut old_app = fake_app(None);
    let old =
        spawn_daemon(&installed, &dir, &[("ACPMUX_OWNER_APP_PID", &old_app.id().to_string())]);
    let old_pid = old.ready(Duration::from_secs(60))["pid"].as_u64().unwrap();
    let socket = PathBuf::from(status(&dir).unwrap()["socket"].as_str().unwrap());
    // The app quits with Keep Sessions while a client is connected; the new app connects.
    let mut holder = std::os::unix::net::UnixStream::connect(&socket).unwrap();
    {
        use std::io::Write as _;
        holder
            .write_all(
                b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"_acpmux/status\",\"params\":{}}\n",
            )
            .unwrap();
    }
    end_child(&mut old_app);
    std::thread::sleep(Duration::from_millis(500));
    let mut new_app = fake_app(Some(&socket));
    let adopted = old.line(Duration::from_secs(10), |l| l.contains("the owner app is back"));
    drop(holder);
    // Every 20 ms a fresh connection across the swap: the listener's gap.
    let tmp = dir.join("acpmux.new");
    fs::copy(daemon_env::bin(), &tmp).unwrap();
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755)).unwrap();
    update(&dir, |at| fs::rename(&tmp, at).unwrap());
    let (mut longest, mut last, from) = (Duration::ZERO, Instant::now(), Instant::now());
    let mut new_pid = None;
    while from.elapsed() < Duration::from_secs(20) {
        if let Some(pid) = serving_pid(&socket) {
            longest = longest.max(last.elapsed());
            last = Instant::now();
            if pid != old_pid {
                new_pid = Some(pid);
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let new_pid = new_pid.expect("the installed build took over");
    eprintln!(
        "update-handoff: swap {old_pid} -> {new_pid}, longest listener gap {longest:?}; adopted line: {adopted:?}"
    );
    assert!(adopted.is_some(), "the relaunched app was not adopted before the swap");
    assert!(
        longest < Duration::from_millis(500),
        "the listener went {longest:?} without an answer"
    );
    // No client now; the new app runs: the successor stays.
    std::thread::sleep(Duration::from_secs(6));
    let alive = unsafe { libc::kill(new_pid as i32, 0) } == 0;
    assert!(alive, "the swapped daemon stopped while the relaunched app runs");
    // And it stops once that app is gone.
    end_child(&mut new_app);
    let deadline = Instant::now() + Duration::from_secs(15);
    while unsafe { libc::kill(new_pid as i32, 0) } == 0 {
        assert!(Instant::now() < deadline, "the swapped daemon did not follow the relaunched app");
        std::thread::sleep(Duration::from_millis(100));
    }
}
