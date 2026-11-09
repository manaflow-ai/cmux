//! Terminal hosts no live session owns (Leo 2026-11-09: "well those need to
//! get auto cleaned up..."). Real `__terminal-host` processes: an owner of
//! one session starts terminals and stops with SIGTERM (its hosts keep
//! running, as when an app quits), then an owner of another session of the
//! same state root starts. Its reaper (cmux-tui-core `mux/unowned_hosts.rs`)
//! ends the stopped session's hosts after the grace, never a host of a
//! session a live owner holds, and its own restore neither waits on them nor
//! on hosts of its own it cannot place.
//!
//! Debug seams: `CMUX_TUI_TEST_UNOWNED_HOST_GRACE_MS` and
//! `CMUX_TUI_TEST_UNOWNED_HOST_INTERVAL_MS`.
//!
//! Numbers (restore time with N such hosts):
//! `CMUX_TEST_UNOWNED_HOST_BENCH=1 cargo test -p cmux-tui --test unowned_terminal_hosts
//! unowned_hosts_restore_time -- --nocapture`.

#![cfg(unix)]

mod fault_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

use cmux_tui_core::terminal_host_runtime::{
    TerminalHostLiveness, TerminalHostRecord, adopt_terminal_host, load_terminal_host_records,
    terminal_host_record_liveness, terminal_host_root,
};
use fault_support::{FaultDir, request};
use serde_json::{Value, json};

const BOUND: Duration = Duration::from_secs(60);
/// A shell that ignores SIGHUP: its host's Terminate waits out the hangup
/// grace (2 s) before SIGTERM ends it, as an editor or agent that saves
/// first does.
const SLOW_TO_END: [&str; 3] = ["/bin/sh", "-c", "trap '' HUP; exec /bin/cat"];

/// A headless owner of `session` on its own socket in `dir`.
struct Owner<'a> {
    dir: &'a FaultDir,
    /// Its `CMUX_TUI_STATE_DIR`.
    state_root: PathBuf,
    session: String,
    socket: PathBuf,
    child: Option<Child>,
    log: PathBuf,
}

impl<'a> Owner<'a> {
    fn spawn(dir: &'a FaultDir, session: &str, env: &[(&str, &str)]) -> Self {
        Self::spawn_in(dir, dir.state_root(), session, env)
    }

    fn spawn_in(
        dir: &'a FaultDir,
        state_root: PathBuf,
        session: &str,
        env: &[(&str, &str)],
    ) -> Self {
        let socket = dir.root.join(format!("{session}.sock"));
        let _ = fs::remove_file(&socket);
        let log = dir.root.join(format!("{session}-{}.log", std::process::id()));
        let child = dir
            .command()
            .env_remove("CMUX_BUNDLE_ID")
            .env("CMUX_TUI_HOST_EXE_DIR", dir.root.join("host-exe"))
            .env("SHELL", "/bin/sh")
            .env("CMUX_TUI_STATE_DIR", &state_root)
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .envs(env.iter().copied())
            .stdout(Stdio::null())
            .stderr(fs::OpenOptions::new().create(true).append(true).open(&log).unwrap())
            .spawn()
            .unwrap();
        Self { dir, state_root, session: session.into(), socket, child: Some(child), log }
    }

    /// Spawns the owner and returns it once `identify` says ready, with the
    /// time that took.
    fn start(dir: &'a FaultDir, session: &str, env: &[(&str, &str)]) -> (Self, Duration) {
        Self::start_in(dir, dir.state_root(), session, env)
    }

    fn start_in(
        dir: &'a FaultDir,
        state_root: PathBuf,
        session: &str,
        env: &[(&str, &str)],
    ) -> (Self, Duration) {
        let started = Instant::now();
        let mut owner = Self::spawn_in(dir, state_root, session, env);
        let deadline = started + BOUND;
        loop {
            if let Some(status) = owner.child.as_mut().unwrap().try_wait().unwrap() {
                panic!("owner {session} exited ({status}): {}", owner.log_text());
            }
            if let Some(identity) =
                request(&owner.socket, json!({"cmd": "identify"}), Duration::from_secs(2))
                && identity["data"]["lifecycle_ready"] == true
            {
                return (owner, started.elapsed());
            }
            assert!(Instant::now() < deadline, "owner {session} not ready: {}", owner.log_text());
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn log_text(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    fn data(&self, value: Value) -> Value {
        let reply = request(&self.socket, value.clone(), Duration::from_secs(30))
            .unwrap_or_else(|| panic!("no answer to {value}: {}", self.log_text()));
        assert_eq!(reply["ok"], true, "{value}: {reply}");
        reply["data"].clone()
    }

    fn host_root(&self) -> PathBuf {
        terminal_host_root(&self.state_root, &self.session)
    }

    /// `count` terminals running `argv`, each in a workspace of its own;
    /// returns once each has a live host.
    fn run_terminals(&self, count: usize, argv: &[&str]) -> Vec<String> {
        let ids = (0..count)
            .map(|index| {
                let created = self.data(json!({
                    "cmd": "run", "argv": argv, "new_workspace": true,
                    "name": format!("{}-{index}", self.session),
                }));
                created["terminal_id"].as_str().unwrap().to_string()
            })
            .collect();
        wait_for_live_hosts(&self.host_root(), count);
        ids
    }

    /// SIGTERM: the owner exits and its hosts keep running for the next
    /// owner of the session, as when the app quits.
    fn stop_keeping_hosts(&mut self) {
        let mut child = self.child.take().unwrap();
        // SAFETY: kill takes a pid and a signal; the pid is this test's child.
        unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) };
        let deadline = Instant::now() + BOUND;
        while child.try_wait().unwrap().is_none() {
            assert!(Instant::now() < deadline, "owner {} did not exit", self.session);
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = fs::remove_file(&self.socket);
    }
}

impl Drop for Owner<'_> {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        end_hosts(&self.host_root());
    }
}

/// Ends what is left of a test's hosts under `root`.
fn end_hosts(root: &Path) {
    for (path, record) in load_terminal_host_records(root).unwrap_or_default() {
        if let Ok(mut host) = adopt_terminal_host(record.clone(), path.clone()) {
            let _ = host.terminate();
            host.disconnect();
        }
        if terminal_host_record_liveness(&path, &record).ok() != Some(TerminalHostLiveness::Dead) {
            // SAFETY: the test's own host process; last resort after Terminate.
            unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) };
        }
    }
}

fn live_hosts(root: &Path) -> Vec<(PathBuf, TerminalHostRecord)> {
    load_terminal_host_records(root)
        .unwrap_or_default()
        .into_iter()
        .filter(|(path, record)| {
            terminal_host_record_liveness(path, record).ok() == Some(TerminalHostLiveness::Live)
        })
        .collect()
}

fn wait_for_live_hosts(root: &Path, count: usize) -> Vec<(PathBuf, TerminalHostRecord)> {
    let deadline = Instant::now() + BOUND;
    loop {
        let hosts = live_hosts(root);
        if hosts.len() == count {
            return hosts;
        }
        assert!(Instant::now() < deadline, "{} live hosts, expected {count}", hosts.len());
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// A short grace and interval for the reaper of the owner under test.
const FAST_REAP: [(&str, &str); 2] = [
    ("CMUX_TUI_TEST_UNOWNED_HOST_GRACE_MS", "1500"),
    ("CMUX_TUI_TEST_UNOWNED_HOST_INTERVAL_MS", "250"),
];

/// A normal install's hosts (NIGHTLY: no orphan grace of their own), as on
/// the machine where they ran for weeks.
const NIGHTLY: (&str, &str) = ("CMUX_BUNDLE_ID", "com.cmuxterm.app.nightly");

#[test]
fn unowned_hosts_of_a_session_no_owner_runs_end_after_the_grace() {
    let dir = FaultDir::new("unowned-reap");
    let mut gone = Owner::start(&dir, "gone-session", &[NIGHTLY]).0;
    gone.run_terminals(3, &["/bin/cat"]);
    gone.stop_keeping_hosts();
    let gone_root = gone.host_root();
    assert_eq!(live_hosts(&gone_root).len(), 3, "the stopped owner's hosts ended with it");

    let (current, _) = Owner::start(&dir, "current-session", &FAST_REAP);
    let deadline = Instant::now() + Duration::from_secs(30);
    while !live_hosts(&gone_root).is_empty() {
        assert!(
            Instant::now() < deadline,
            "{} hosts of a session no owner runs still live 30 s after a 1.5 s grace: {}",
            live_hosts(&gone_root).len(),
            current.log_text()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(current.log_text().contains("no live session owned it"), "{}", current.log_text());
}

#[test]
fn unowned_hosts_never_include_a_session_a_live_owner_holds() {
    let dir = FaultDir::new("unowned-live");
    let live = Owner::start(&dir, "live-session", &[NIGHTLY]).0;
    let terminals = live.run_terminals(2, &["/bin/cat"]);
    let before = wait_for_live_hosts(&live.host_root(), 2);

    let (current, _) = Owner::start(&dir, "current-session", &FAST_REAP);
    // Many passes past the grace.
    std::thread::sleep(Duration::from_secs(5));
    let after = wait_for_live_hosts(&live.host_root(), 2);
    let pids = |hosts: &[(PathBuf, TerminalHostRecord)]| {
        let mut pids = hosts.iter().map(|(_, record)| record.host_pid).collect::<Vec<_>>();
        pids.sort_unstable();
        pids
    };
    assert_eq!(pids(&before), pids(&after), "a live session's host was replaced");
    for terminal_id in terminals {
        let resolved = live.data(json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
        assert_eq!(resolved["lifecycle"], "running", "{resolved}");
    }
    assert!(!current.log_text().contains("no live session owned it"), "{}", current.log_text());
}

#[test]
fn unowned_hosts_leave_a_rowless_live_host_of_this_session_to_recovery() {
    let dir = FaultDir::new("unowned-own");
    let mut own = Owner::start(&dir, "own-session", &FAST_REAP).0;
    let terminal_id = own.run_terminals(1, &["/bin/cat"]).remove(0);
    own.stop_keeping_hosts();
    let registry = dir.registry("own-session");
    for suffix in ["", "-wal", "-shm"] {
        let _ = fs::remove_file(format!("{}{suffix}", registry.display()));
    }
    let host = wait_for_live_hosts(&own.host_root(), 1).remove(0).1;

    let (own, _) = Owner::start(&dir, "own-session", &FAST_REAP);
    std::thread::sleep(Duration::from_secs(4));
    let resolved = own.data(json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
    assert_eq!(resolved["lifecycle"], "running", "{resolved}");
    let after = wait_for_live_hosts(&own.host_root(), 1).remove(0).1;
    assert_eq!(after.host_pid, host.host_pid, "the recovered terminal got a new host");
}

/// The app's per-build layout below `dir`: `<base>/cmux/tags/<tag>/tui`,
/// private as the app makes it.
fn tag_state_root(dir: &FaultDir, tag: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt as _;
    let base = dir.root.join("as");
    let root = base.join("cmux").join("tags").join(tag).join("tui");
    fs::create_dir_all(&root).unwrap();
    for folder in [base.clone(), base.join("cmux"), root.clone()] {
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o700)).unwrap();
    }
    root
}

#[test]
fn unowned_hosts_of_other_builds_state_roots_end_unless_their_owner_runs() {
    let dir = FaultDir::new("unowned-builds");
    // A build whose owner still runs: its guard is held.
    let running =
        Owner::start_in(&dir, tag_state_root(&dir, "running"), "cmux-app-running", &[NIGHTLY]).0;
    running.run_terminals(2, &["/bin/cat"]);
    let running_before = wait_for_live_hosts(&running.host_root(), 2);
    // A build that is never launched again: its owner quit, its hosts stay.
    let mut gone =
        Owner::start_in(&dir, tag_state_root(&dir, "gone"), "cmux-app-gone", &[NIGHTLY]).0;
    gone.run_terminals(3, &["/bin/cat"]);
    gone.stop_keeping_hosts();
    let gone_root = gone.host_root();
    // One of them dies without its cleanup: its record is stale.
    let (_, killed) = wait_for_live_hosts(&gone_root, 3).remove(0);
    // SAFETY: the test's own host process.
    unsafe { libc::kill(killed.host_pid as libc::pid_t, libc::SIGKILL) };
    wait_for_live_hosts(&gone_root, 2);

    let (current, _) =
        Owner::start_in(&dir, tag_state_root(&dir, "current"), "cmux-app-current", &FAST_REAP);
    let deadline = Instant::now() + Duration::from_secs(30);
    while !load_terminal_host_records(&gone_root).unwrap_or_default().is_empty() {
        assert!(
            Instant::now() < deadline,
            "another build's root still has {} records ({} live) 30 s after a 1.5 s grace: {}",
            load_terminal_host_records(&gone_root).unwrap_or_default().len(),
            live_hosts(&gone_root).len(),
            current.log_text()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    let running_after = wait_for_live_hosts(&running.host_root(), 2);
    let pids = |hosts: &[(PathBuf, TerminalHostRecord)]| {
        let mut pids = hosts.iter().map(|(_, record)| record.host_pid).collect::<Vec<_>>();
        pids.sort_unstable();
        pids
    };
    assert_eq!(pids(&running_before), pids(&running_after), "a running build's host was ended");
}

#[test]
fn unowned_hosts_of_a_session_whose_guard_is_missing_are_never_ended() {
    let dir = FaultDir::new("unowned-noguard");
    let mut gone = Owner::start(&dir, "gone-session", &[NIGHTLY]).0;
    gone.run_terminals(2, &["/bin/cat"]);
    gone.stop_keeping_hosts();
    // Without its guard file no lease can keep the session from starting
    // and adopting its hosts while they are judged.
    for entry in fs::read_dir(dir.state_root().join("session-locks")).unwrap().flatten() {
        let name = entry.file_name().into_string().unwrap();
        if name.starts_with("gone-session-") {
            fs::remove_file(entry.path()).unwrap();
        }
    }
    let (current, _) = Owner::start(&dir, "current-session", &FAST_REAP);
    std::thread::sleep(Duration::from_secs(5));
    assert_eq!(live_hosts(&gone.host_root()).len(), 2, "{}", current.log_text());
}

#[test]
fn unowned_hosts_grace_starts_over_after_their_owner_ran_in_between() {
    const GRACE: [(&str, &str); 2] = [
        ("CMUX_TUI_TEST_UNOWNED_HOST_GRACE_MS", "4000"),
        ("CMUX_TUI_TEST_UNOWNED_HOST_INTERVAL_MS", "250"),
    ];
    let dir = FaultDir::new("unowned-between");
    let mut gone = Owner::start(&dir, "gone-session", &[NIGHTLY]).0;
    let terminals = gone.run_terminals(1, &["/bin/cat"]);
    gone.stop_keeping_hosts();
    let gone_root = gone.host_root();

    // The reaper sees the host and saves its time, then stops in the grace.
    let mut current = Owner::start(&dir, "current-session", &GRACE).0;
    std::thread::sleep(Duration::from_millis(1500));
    current.stop_keeping_hosts();
    assert_eq!(live_hosts(&gone_root).len(), 1, "ended within its grace");

    // The host's own session comes back, adopts and uses it, and quits.
    let mut back = Owner::start(&dir, "gone-session", &[NIGHTLY]).0;
    let resolved = back.data(json!({"cmd": "resolve-terminal", "terminal_id": terminals[0]}));
    let deadline = Instant::now() + BOUND;
    let mut resolved = resolved;
    while resolved["lifecycle"] != "running" {
        assert!(Instant::now() < deadline, "not adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(50));
        resolved = back.data(json!({"cmd": "resolve-terminal", "terminal_id": terminals[0]}));
    }
    if let Some(surface) = resolved["surface"].as_u64() {
        back.data(json!({"cmd": "send", "surface": surface, "text": "still here\n"}));
    }
    back.stop_keeping_hosts();
    // Past the first saved time plus the grace.
    std::thread::sleep(Duration::from_secs(3));

    let current = Owner::start(&dir, "current-session", &GRACE).0;
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(
        live_hosts(&gone_root).len(),
        1,
        "the grace did not start over after the host's owner used it: {}",
        current.log_text()
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    while !live_hosts(&gone_root).is_empty() {
        assert!(Instant::now() < deadline, "never ended: {}", current.log_text());
        std::thread::sleep(Duration::from_millis(100));
    }
    drop(back);
}

/// Makes every host under `root` one its session cannot place on its next
/// start: the registry is gone and the record names no workspace, so the
/// start ends it instead of recovering it (cx-0tgl LC).
fn unplace_hosts(dir: &FaultDir, session: &str, root: &Path) {
    let registry = dir.registry(session);
    for suffix in ["", "-wal", "-shm"] {
        let _ = fs::remove_file(format!("{}{suffix}", registry.display()));
    }
    for (path, _) in load_terminal_host_records(root).unwrap() {
        let mut record: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        record["workspace_key"] = json!("");
        fs::write(&path, serde_json::to_vec(&record).unwrap()).unwrap();
    }
}

#[test]
fn unowned_hosts_a_start_answers_before_it_ends_hosts_it_cannot_place() {
    const HOSTS: usize = 4;
    let dir = FaultDir::new("unowned-unplaced");
    let mut first = Owner::start(&dir, "own-session", &[]).0;
    first.run_terminals(HOSTS, &SLOW_TO_END);
    first.stop_keeping_hosts();
    unplace_hosts(&dir, "own-session", &first.host_root());

    let (second, ready) = Owner::start(&dir, "own-session", &[]);
    // Ended one after another inline, each Terminate waits out its shell's
    // 2 s hangup grace: 8 s or more before the first answer.
    assert!(
        ready < Duration::from_secs(4),
        "the start answered after {ready:?}: it ended {HOSTS} hosts it could not place first"
    );
    let deadline = Instant::now() + BOUND;
    while !live_hosts(&second.host_root()).is_empty() {
        assert!(Instant::now() < deadline, "hosts the start could not place still run");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Restore time with N hosts no owner of this start can own: hosts of
/// another session that no owner runs, and hosts of this session it cannot
/// place. Prints one JSON line per case, also appended to
/// `.build/artifacts/unowned-hosts-bench.jsonl` at the repository root (a
/// fleet step returns it with `--artifact`); set CMUX_TEST_UNOWNED_HOST_BENCH=1.
#[test]
fn unowned_hosts_restore_time() {
    if std::env::var("CMUX_TEST_UNOWNED_HOST_BENCH").as_deref() != Ok("1") {
        return;
    }
    let artifacts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/artifacts");
    fs::create_dir_all(&artifacts).unwrap();
    let report = artifacts.join("unowned-hosts-bench.jsonl");
    let _ = fs::remove_file(&report);
    let record = |line: Value| {
        println!("unowned-hosts-bench: {line}");
        let mut file = fs::OpenOptions::new().create(true).append(true).open(&report).unwrap();
        std::io::Write::write_all(&mut file, format!("{line}\n").as_bytes()).unwrap();
    };
    for count in [0, 10, 50] {
        let dir = FaultDir::new("unowned-bench-other");
        let mut gone = Owner::start(&dir, "gone-session", &[NIGHTLY]).0;
        gone.run_terminals(count, &["/bin/cat"]);
        gone.stop_keeping_hosts();
        let (current, ready) = Owner::start(&dir, "current-session", &[]);
        record(json!({"case": "other_session", "hosts": count, "ready_ms": ready.as_millis()}));
        drop(current);
        drop(gone);

        let dir = FaultDir::new("unowned-bench-own");
        let mut first = Owner::start(&dir, "own-session", &[]).0;
        first.run_terminals(count, &["/bin/cat"]);
        first.stop_keeping_hosts();
        unplace_hosts(&dir, "own-session", &first.host_root());
        let (second, ready) = Owner::start(&dir, "own-session", &[]);
        record(json!({"case": "own_unplaceable", "hosts": count, "ready_ms": ready.as_millis()}));
        drop(second);
        drop(first);
    }
}
