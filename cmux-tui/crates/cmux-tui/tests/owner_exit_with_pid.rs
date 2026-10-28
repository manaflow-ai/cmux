//! `--headless --exit-with-pid <pid>`: a detached owner bound to the
//! process that started it. A test or CI launcher that is killed before its
//! cleanup runs (`server stop --end-terminals` in a trap) left its owner and
//! terminal hosts running for days, re-parented to init (HQ REPAIR.md
//! "Orphaned cmux-tui holds runner dirs"). A bound owner ends its terminals
//! and exits once that process dies. An owner started without the option
//! outlives whoever started it, by design: the app's daemon keeps the
//! person's terminals across an app quit, crash or relaunch.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

/// How long a bound owner may take to exit once its process died. The owner
/// waits on a kernel exit event (kqueue `NOTE_EXIT`, a Linux pidfd), not a
/// poll, so the time is its own teardown: ending one terminal and closing
/// its session, well under a second on an idle machine. 10 s is the owner's
/// own start contact bound (`ENSURE_DEADLINE`) and leaves room for a loaded
/// CI runner; an owner with no watch never exits, so any bound tells the two
/// apart.
const EXIT_BOUND: Duration = Duration::from_secs(10);

/// How long an unbound owner is watched after its launcher died.
const SURVIVAL_WINDOW: Duration = Duration::from_secs(4);

/// CPU an owner may use over [`SURVIVAL_WINDOW`] after its launcher died.
/// An idle owner uses next to nothing (idle_wakeups.rs holds it to 0.5% of
/// a core); the leaked owners spun at about 390%. Linux `ps` counts whole
/// seconds, so the limit is one second.
const SPIN_LIMIT: Duration = Duration::from_secs(1);

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
    /// The terminal hosts this test's owner started, ended on drop when a
    /// failed test leaves them running (`server stop` cannot reach them once
    /// their owner is gone).
    hosts: std::cell::RefCell<Vec<(u32, Option<u64>)>>,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-bo-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self {
            socket: dir.join("mux.sock"),
            session: format!("bo-{name}"),
            dir,
            hosts: Default::default(),
        }
    }

    fn state(&self) -> PathBuf {
        self.dir.join("state")
    }

    fn server(&self, action: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// A launcher like a CI probe: a shell that starts a headless owner in
    /// the background (bound to the shell's own pid with `bound`), prints
    /// its pid, then stays alive as `sleep` under the same pid until killed.
    fn launch(&self, bound: bool) -> Launched {
        let script = r#"bin=$1; shift
if [ -n "$BIND" ]; then set -- "$@" --exit-with-pid $$; fi
"$bin" "$@" < /dev/null > "$LOG" 2>&1 &
echo $!
exec sleep 600"#;
        let mut shell = Command::new("/bin/sh");
        shell
            .args(["-c", script, "sh", env!("CARGO_BIN_EXE_cmux-tui"), "--headless", "--session"])
            .arg(&self.session)
            .arg("--socket")
            .arg(&self.socket)
            .arg("--state")
            .arg(self.state())
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("LOG", self.dir.join("owner.log"));
        if bound {
            shell.env("BIND", "1");
        }
        let mut child = shell.stdin(Stdio::null()).stdout(Stdio::piped()).spawn().unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let owner = line.trim().parse().expect("the launcher printed no owner pid");
        let launched = Launched { child: Some(child), owner };
        let deadline = Instant::now() + Duration::from_secs(15);
        while transport::connect(&self.socket).is_err() {
            assert!(
                cpu(owner).is_some() && Instant::now() < deadline,
                "the owner did not serve {}: {}",
                self.socket.display(),
                fs::read_to_string(self.dir.join("owner.log")).unwrap_or_default()
            );
            std::thread::sleep(Duration::from_millis(25));
        }
        launched
    }

    /// Starts `/bin/cat` in a new workspace; returns its terminal host pids.
    fn start_terminal(&self) -> Vec<u32> {
        let created = request(
            &self.socket,
            serde_json::json!({
                "id": 1,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": true,
                "name": "bound",
            }),
        )
        .expect("run /bin/cat");
        assert!(created["terminal_id"].is_string(), "{created}");
        let root =
            cmux_tui_core::terminal_host_runtime::terminal_host_root(&self.state(), &self.session);
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let hosts = host_pids(&root);
            if !hosts.is_empty() {
                // With each host's start time, so cleanup never signals a
                // later process that reuses its pid.
                let started =
                    hosts.iter().map(|pid| (*pid, cmux_tui_core::process_started_ms(*pid)));
                self.hosts.borrow_mut().extend(started);
                return hosts;
            }
            assert!(Instant::now() < deadline, "no terminal host record appeared");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.server("stop").arg("--end-terminals").output();
        let hosts = self.hosts.borrow().clone();
        let pids: Vec<u32> = hosts.iter().map(|(pid, _)| *pid).collect();
        for pid in await_exit(&pids, Duration::from_secs(5)).0 {
            let recorded = hosts.iter().find(|(host, _)| *host == pid).and_then(|(_, at)| *at);
            if recorded.is_none() || cmux_tui_core::process_started_ms(pid) != recorded {
                continue;
            }
            // SAFETY: the same process (pid and start time) as a terminal
            // host of this test's own owner, still running.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// The launcher shell this test started, and the owner it started.
struct Launched {
    child: Option<Child>,
    owner: u32,
}

impl Launched {
    /// SIGKILL, as a cancelled CI job ends: no trap or cleanup runs.
    fn kill(&mut self) {
        if let Some(mut child) = self.child.take() {
            child.kill().unwrap();
            child.wait().unwrap();
        }
    }
}

impl Drop for Launched {
    fn drop(&mut self) {
        self.kill();
    }
}

fn host_pids(root: &Path) -> Vec<u32> {
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

fn request(path: &Path, value: serde_json::Value) -> Option<serde_json::Value> {
    let stream = transport::connect(path).ok()?;
    let mut writer = stream.try_clone_box().ok()?;
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").ok()?;
    let mut line = String::new();
    reader.read_line(&mut line).ok()?;
    let response: serde_json::Value = serde_json::from_str(&line).ok()?;
    (response["ok"] == true).then(|| response["data"].clone())
}

/// The CPU time `ps` reports for `pid`, `None` once it is gone. A zombie
/// counts as gone (it has exited; only its parent's reap is left).
fn cpu(pid: u32) -> Option<Duration> {
    let output =
        Command::new("ps").args(["-o", "stat=,time=", "-p", &pid.to_string()]).output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let mut fields = text.split_whitespace();
    if fields.next()?.starts_with('Z') {
        return None;
    }
    Some(parse_cpu_time(fields.next()?))
}

/// `ps -o time=`: `[[dd-]hh:]mm:ss[.ff]` (macOS prints fractions, Linux
/// whole seconds).
fn parse_cpu_time(text: &str) -> Duration {
    let (days, clock) = match text.split_once('-') {
        Some((days, clock)) => (days.parse::<u64>().unwrap(), clock),
        None => (0, text),
    };
    let clock =
        clock.split(':').fold(0.0, |total, part| total * 60.0 + part.parse::<f64>().unwrap());
    Duration::from_secs_f64(days as f64 * 86_400.0 + clock)
}

/// Waits up to `bound` for every pid to be gone: the pids still alive, and
/// the most CPU any of them used between the first and last look.
fn await_exit(pids: &[u32], bound: Duration) -> (Vec<u32>, Duration) {
    let deadline = Instant::now() + bound;
    let first: Vec<Option<Duration>> = pids.iter().map(|pid| cpu(*pid)).collect();
    let mut used = Duration::ZERO;
    loop {
        let mut left = Vec::new();
        for (pid, first) in pids.iter().zip(&first) {
            if let Some(now) = cpu(*pid) {
                used = used.max(now.saturating_sub(first.unwrap_or(now)));
                left.push(*pid);
            }
        }
        if left.is_empty() || Instant::now() >= deadline {
            return (left, used);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn ps_cpu_times_parse_on_macos_and_linux() {
    assert_eq!(parse_cpu_time("0:00.25"), Duration::from_millis(250));
    assert_eq!(parse_cpu_time("12:03.50"), Duration::from_secs_f64(723.5));
    assert_eq!(parse_cpu_time("00:01:02"), Duration::from_secs(62));
    assert_eq!(parse_cpu_time("1-00:00:01"), Duration::from_secs(86_401));
}

#[test]
fn a_bound_owner_exits_and_ends_its_terminals_when_its_launcher_is_killed() {
    let fixture = Fixture::new("bound");
    let mut launched = fixture.launch(true);
    let owner = launched.owner;
    let hosts = fixture.start_terminal();
    launched.kill();
    let started = Instant::now();
    let (left, used) = await_exit(&[owner], EXIT_BOUND);
    assert!(
        left.is_empty(),
        "the bound owner {owner} outlived its killed launcher by {EXIT_BOUND:?}"
    );
    let exited = started.elapsed();
    assert!(used <= SPIN_LIMIT, "the bound owner used {used:?} of CPU while it exited");
    // The owner ended its terminals before it exited: nobody adopts the
    // terminals of an owner whose launcher is gone.
    let (left, _) = await_exit(&hosts, EXIT_BOUND);
    assert!(left.is_empty(), "terminal hosts {left:?} outlived their bound owner");
    eprintln!("bound owner exited {exited:?} after its launcher was killed");
}

#[test]
fn an_owner_bound_to_a_pid_no_process_has_refuses_to_start() {
    let fixture = Fixture::new("gone");
    // A process that has exited and been reaped: its pid names nothing.
    let mut gone = Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
    gone.wait().unwrap();
    let pid = gone.id().to_string();
    let mut owner = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--headless", "--session", &fixture.session, "--socket"])
        .arg(&fixture.socket)
        .arg("--state")
        .arg(fixture.state())
        .args(["--exit-with-pid", &pid])
        .env("CMUX_TUI_CONFIG", fixture.dir.join("config.json"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let status = owner.wait().unwrap();
    assert!(!status.success(), "an owner bound to gone pid {pid} started");
}

#[test]
fn an_unbound_owner_outlives_its_killed_launcher_without_spinning() {
    let fixture = Fixture::new("unbound");
    let mut launched = fixture.launch(false);
    let owner = launched.owner;
    launched.kill();
    let before = cpu(owner).expect("the owner died with its launcher");
    std::thread::sleep(SURVIVAL_WINDOW);
    let after = cpu(owner).expect("an unbound owner must outlive its launcher");
    let used = after.saturating_sub(before);
    assert!(
        used <= SPIN_LIMIT,
        "the orphaned owner used {used:?} of CPU in {SURVIVAL_WINDOW:?} after its launcher died"
    );
    // Still serving: a later client reattaches to the same owner.
    let status = fixture.server("status").output().unwrap();
    let status: serde_json::Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(status["status"], "running", "{status}");
    assert_eq!(status["pid"].as_u64(), Some(u64::from(owner)), "{status}");
}
