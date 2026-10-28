//! `server ensure --exit-with-pid <pid>`: a detached owner bound to the
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
            // The spawned owner inherits this environment, so its durable
            // state and configuration stay inside the fixture directory.
            .env("CMUX_TUI_STATE_DIR", self.state())
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"));
        command
    }

    /// A launcher like check-daemon-capabilities.sh: a shell that runs
    /// `server ensure` (bound to the shell's own pid with `bound`), says
    /// `ready`, then stays alive as `sleep` under the same pid until killed.
    fn launch(&self, bound: bool) -> Launched {
        let out = self.dir.join("ensure.json");
        let script = r#"bin=$1; shift
if [ -n "$BIND" ]; then set -- "$@" --exit-with-pid $$; fi
"$bin" "$@" > "$OUT" 2> "$OUT.err"
echo ready
exec sleep 600"#;
        let command = self.server("ensure");
        let program = command.get_program().to_owned();
        let args: Vec<_> = command.get_args().map(ToOwned::to_owned).collect();
        let mut shell = Command::new("/bin/sh");
        shell.arg("-c").arg(script).arg("sh").arg(program).args(args).env("OUT", &out);
        for (key, value) in command.get_envs() {
            if let Some(value) = value {
                shell.env(key, value);
            }
        }
        if bound {
            shell.env("BIND", "1");
        }
        let mut child = shell.stdin(Stdio::null()).stdout(Stdio::piped()).spawn().unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let launcher = Launcher(Some(child));
        assert_eq!(line.trim(), "ready", "the launcher died before ensure finished");
        let ensured = fs::read(&out).unwrap();
        let ensured: serde_json::Value = serde_json::from_slice(&ensured).unwrap_or_else(|_| {
            panic!(
                "server ensure failed: {}\nstderr: {}",
                String::from_utf8_lossy(&ensured),
                fs::read_to_string(format!("{}.err", out.display())).unwrap_or_default()
            )
        });
        assert_eq!(ensured["status"], "started", "{ensured}");
        let owner = ensured["pid"].as_u64().and_then(|pid| u32::try_from(pid).ok());
        Launched { launcher, owner: owner.expect("owner pid") }
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
        for pid in await_exit(&pids, Duration::from_secs(5)) {
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

/// The launcher shell this test started, and the owner its ensure spawned.
struct Launcher(Option<Child>);

struct Launched {
    launcher: Launcher,
    owner: u32,
}

impl Launcher {
    /// SIGKILL, as a cancelled CI job ends: no trap or cleanup runs.
    fn kill(&mut self) {
        if let Some(mut child) = self.0.take() {
            child.kill().unwrap();
            child.wait().unwrap();
        }
    }
}

impl Drop for Launcher {
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

/// `ps` for one pid: its state and CPU time, `None` once it is gone. A
/// zombie counts as gone (it has exited; only its parent's reap is left).
fn ps(pid: u32) -> Option<(String, Duration)> {
    let output =
        Command::new("ps").args(["-o", "stat=,time=", "-p", &pid.to_string()]).output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let mut fields = text.split_whitespace();
    let stat = fields.next()?.to_string();
    if stat.starts_with('Z') {
        return None;
    }
    Some((stat, parse_cpu_time(fields.next()?)))
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

fn alive(pid: u32) -> bool {
    ps(pid).is_some()
}

/// Waits up to `bound` for every pid to be gone; returns those still alive.
fn await_exit(pids: &[u32], bound: Duration) -> Vec<u32> {
    let deadline = Instant::now() + bound;
    loop {
        let left: Vec<u32> = pids.iter().copied().filter(|pid| alive(*pid)).collect();
        if left.is_empty() || Instant::now() >= deadline {
            return left;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Waits up to `bound` for `pid` to be gone: whether it went, and the CPU
/// it used from the first look to the last look that found it alive.
fn await_owner_exit(pid: u32, bound: Duration) -> (bool, Duration) {
    let deadline = Instant::now() + bound;
    let mut first = None;
    let mut last = Duration::ZERO;
    loop {
        let Some((_, cpu)) = ps(pid) else {
            return (true, last.saturating_sub(first.unwrap_or(last)));
        };
        first.get_or_insert(cpu);
        last = cpu;
        if Instant::now() >= deadline {
            return (false, last.saturating_sub(first.unwrap_or(last)));
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
    let Launched { mut launcher, owner } = fixture.launch(true);
    let hosts = fixture.start_terminal();
    launcher.kill();
    let started = Instant::now();
    let (exited, used) = await_owner_exit(owner, EXIT_BOUND);
    assert!(exited, "the bound owner {owner} outlived its killed launcher by {EXIT_BOUND:?}");
    let exited = started.elapsed();
    assert!(used <= SPIN_LIMIT, "the bound owner used {used:?} of CPU while it exited");
    // The owner ended its terminals before it exited: nobody adopts the
    // terminals of an owner whose launcher is gone.
    let left = await_exit(&hosts, EXIT_BOUND);
    assert!(left.is_empty(), "terminal hosts {left:?} outlived their bound owner");
    eprintln!("bound owner exited {exited:?} after its launcher was killed");
}

#[test]
fn ensure_refuses_to_bind_an_owner_to_a_pid_no_process_has() {
    let fixture = Fixture::new("gone");
    // A process that has exited and been reaped: its pid names nothing.
    let mut gone = Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().unwrap();
    let pid = gone.id();
    gone.wait().unwrap();
    let output = fixture.server("ensure").args(["--exit-with-pid", &pid.to_string()]).output();
    let output = output.unwrap();
    assert!(
        !output.status.success(),
        "ensure bound an owner to pid {pid}, which no process has: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    assert!(fixture.server("status").output().unwrap().status.code() != Some(0));
}

#[test]
fn an_unbound_owner_outlives_its_killed_launcher_without_spinning() {
    let fixture = Fixture::new("unbound");
    let Launched { mut launcher, owner } = fixture.launch(false);
    launcher.kill();
    let (_, before) = ps(owner).expect("the owner died with its launcher");
    std::thread::sleep(SURVIVAL_WINDOW);
    let (_, after) = ps(owner).expect("an unbound owner must outlive its launcher");
    let used = after.saturating_sub(before);
    assert!(
        used <= SPIN_LIMIT,
        "the orphaned owner used {used:?} of CPU in {SURVIVAL_WINDOW:?} after its launcher died"
    );
    // Still serving: a later client reattaches to the same owner.
    let again = fixture.server("ensure").output().unwrap();
    let again: serde_json::Value = serde_json::from_slice(&again.stdout).unwrap();
    assert_eq!(again["status"], "running", "{again}");
    assert_eq!(again["pid"].as_u64(), Some(u64::from(owner)), "{again}");
}
