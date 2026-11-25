//! Nothing a test starts outlives the test process (cx-leo45).
//!
//! A fixture that stops its daemon with SIGKILL, panics before its teardown,
//! or is killed by nextest's time limit leaves the daemon's terminal hosts
//! running: a host is durable on purpose (a restarted daemon adopts it), and
//! a debug build's host waits its 10 minute orphan grace before it ends its
//! PTY. A full `cmux-tui-rust-check.sh test` run left 11 hosts, 11 shells and
//! 11 PTYs behind this way (landq gate 20261104T222336, a968's e011a4c1).
//!
//! Every `cmux-tui` process started under a test names that test process in
//! `CMUX_TUI_TEST_OWNER` (`cmux_tui_core::test_owner`); a daemon then ends its
//! terminals and stops when it exits (as `--exit-with-pid`), and a terminal
//! host ends its terminal when it exits, also after its daemon is gone. These
//! tests stand in a `sleep` for the test process and kill it.
#![cfg(any(target_vendor = "apple", target_os = "linux"))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

/// The variable that names the test process (`cmux_tui_core::test_owner`).
const TEST_OWNER_ENV: &str = "CMUX_TUI_TEST_OWNER";

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

/// A stand-in test process, a daemon started for it, and its terminals. The
/// teardown kills all of them, so a failing assertion leaks nothing either.
struct Fixture {
    owner: Child,
    daemon: Child,
    socket: PathBuf,
    state: PathBuf,
    dir: PathBuf,
    hosts: Vec<u32>,
}

impl Fixture {
    /// A daemon for the stand-in test process (named in its environment)
    /// with two terminals running `sleep`.
    fn start(name: &str) -> Self {
        Self::start_with(name, true, "sleep 600")
    }

    /// A daemon with two terminals running `script` (`{dir}` is the
    /// fixture's folder). `named`: the stand-in test process is named in the
    /// daemon's environment; otherwise the daemon names its own test process.
    fn start_with(name: &str, named: bool, script: &str) -> Self {
        let owner = Command::new("/bin/sleep")
            .arg("600")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let started = cmux_tui_core::server::Starter::current(owner.id())
            .expect("the stand-in test process runs");
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        // Short: the socket path must stay under the macOS limit.
        let dir = PathBuf::from("/tmp").join(format!(
            "cmux-towner-{name}-{}-{}",
            std::process::id(),
            stamp % 1_000_000_000
        ));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let mut daemon = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        daemon
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if named {
            daemon.env(TEST_OWNER_ENV, format!("{}:{}", started.pid, started.started_ms));
        } else {
            daemon.env_remove(TEST_OWNER_ENV);
        }
        let daemon = daemon.spawn().unwrap();
        let script = script.replace("{dir}", &dir.display().to_string());
        let mut fixture = Self { owner, daemon, socket, state, dir, hosts: Vec::new() };
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        while transport::connect(&fixture.socket).is_err() {
            assert!(
                Instant::now() < deadline,
                "daemon did not create {}",
                fixture.socket.display()
            );
            std::thread::sleep(Duration::from_millis(25));
        }
        for index in 0..2 {
            let created = request(
                &fixture.socket,
                serde_json::json!({
                    "cmd": "run",
                    "argv": ["/bin/sh", "-c", script],
                    "new_workspace": true,
                    "name": format!("owned-{index}"),
                }),
            );
            assert_eq!(created["ok"], true, "run a terminal: {created}");
        }
        let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
        loop {
            fixture.hosts = fixture.host_pids();
            if fixture.hosts.len() == 2 {
                break;
            }
            assert!(Instant::now() < deadline, "two host records: {:?}", fixture.hosts);
            std::thread::sleep(Duration::from_millis(25));
        }
        fixture
    }

    fn host_pids(&self) -> Vec<u32> {
        let root = cmux_tui_core::terminal_host_runtime::terminal_host_root(&self.state, "main");
        fs::read_dir(root)
            .ok()
            .into_iter()
            .flatten()
            .filter_map(Result::ok)
            .filter_map(|entry| fs::read(entry.path()).ok())
            .filter_map(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .filter_map(|record| record["host_pid"].as_u64())
            .filter_map(|pid| u32::try_from(pid).ok())
            .collect()
    }

    /// The stand-in test process exits.
    fn end_owner(&mut self) {
        let _ = self.owner.kill();
        let _ = self.owner.wait();
    }

    /// The hosts still running after `limit`, waiting for them to exit.
    fn hosts_left_after(&self, limit: Duration) -> Vec<u32> {
        let deadline = Instant::now() + test_timeout(limit);
        loop {
            let left: Vec<u32> =
                self.hosts.iter().copied().filter(|pid| process_runs(*pid)).collect();
            if left.is_empty() || Instant::now() >= deadline {
                return left;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        for pid in self.hosts.iter().filter(|pid| process_runs(**pid)) {
            // SAFETY: the pid came from this test's own host records.
            unsafe { libc::kill(*pid as libc::pid_t, libc::SIGKILL) };
        }
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
        let _ = self.owner.kill();
        let _ = self.owner.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// Whether `pid` runs: not gone and not a zombie waiting for its parent.
fn process_runs(pid: u32) -> bool {
    // SAFETY: signal zero only checks for existence.
    if unsafe { libc::kill(pid as libc::pid_t, 0) } != 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    {
        fs::read_to_string(format!("/proc/{pid}/stat")).ok().is_some_and(|stat| {
            stat.rsplit_once(')').and_then(|(_, rest)| rest.split_whitespace().next()) != Some("Z")
        })
    }
    #[cfg(target_vendor = "apple")]
    {
        Command::new("/bin/ps")
            .args(["-o", "state=", "-p", &pid.to_string()])
            .output()
            .ok()
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
            .is_some_and(|state| !state.is_empty() && !state.starts_with('Z'))
    }
}

/// One request on a fresh connection; the whole response.
fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

/// The test process exits with its daemon still running: the daemon ends its
/// terminals and stops.
#[test]
fn a_daemon_started_for_a_test_process_ends_its_terminals_and_stops_when_it_exits() {
    let mut fixture = Fixture::start("daemon");
    fixture.end_owner();

    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    let status = loop {
        if let Some(status) = fixture.daemon.try_wait().unwrap() {
            break Some(status);
        }
        if Instant::now() >= deadline {
            break None;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(status.is_some(), "the daemon still runs after its test process exited");
    let left = fixture.hosts_left_after(Duration::from_secs(10));
    assert!(left.is_empty(), "terminal hosts outlived the test process: {left:?}");
}

/// The daemon is killed first (a fixture's SIGKILL, or a daemon the test ran
/// in its own process), then the test process exits: each orphaned host ends
/// its terminal at once instead of after its orphan grace.
#[test]
fn terminal_hosts_end_with_the_test_process_after_their_daemon_was_killed() {
    let mut fixture = Fixture::start("hosts");
    let _ = fixture.daemon.kill();
    let _ = fixture.daemon.wait();
    let left = fixture.hosts_left_after(Duration::from_secs(1));
    assert_eq!(left.len(), 2, "the hosts outlive their daemon (durable terminals)");

    fixture.end_owner();
    let left = fixture.hosts_left_after(Duration::from_secs(10));
    assert!(left.is_empty(), "terminal hosts outlived the test process: {left:?}");
}

/// Under nextest, a daemon a test starts with no owner named names the test
/// process itself, and its terminals inherit that (the walk-free lookup in
/// `cmux_tui_core::test_owner::adopt`: the test leads its process group).
#[test]
fn under_nextest_a_daemon_names_the_test_process_that_started_it() {
    if std::env::var_os("NEXTEST_RUN_ID").is_none() {
        eprintln!("skipped: not run by cargo nextest");
        return;
    }
    let fixture = Fixture::start_with(
        "adopt",
        false,
        "echo \"$CMUX_TUI_TEST_OWNER\" > {dir}/owner-$$.tmp && mv {dir}/owner-$$.tmp {dir}/owner-$$; sleep 600",
    );
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let named = loop {
        let named: Vec<String> = fs::read_dir(&fixture.dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                name.starts_with("owner-") && !name.ends_with(".tmp")
            })
            .filter_map(|entry| fs::read_to_string(entry.path()).ok())
            .collect();
        if named.len() == 2 || Instant::now() >= deadline {
            break named;
        }
        std::thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(named.len(), 2, "both shells wrote their owner: {named:?}");
    let ours = cmux_tui_core::server::Starter::current(std::process::id()).unwrap();
    for value in named {
        assert_eq!(
            value.trim(),
            format!("{}:{}", ours.pid, ours.started_ms),
            "a terminal names this test process"
        );
    }
}
