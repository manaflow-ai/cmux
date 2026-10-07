//! End to end on Linux: the real `cmux-host run` under a temporary root,
//! a fake metadata service (a local HTTP listener) and a fake session host
//! script. Asserts the bind order from the action log, a second clone, a
//! park, adoption after an agent restart, and a crash restart.
#![cfg(target_os = "linux")]

use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use cmux_host::status::Status;

/// Serves the token and instance-id endpoints with the current id.
fn metadata_server(id: Arc<Mutex<String>>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buf = [0u8; 2048];
            let n = stream.read(&mut buf).unwrap_or(0);
            let request = String::from_utf8_lossy(&buf[..n]).into_owned();
            let body = if request.starts_with("PUT /latest/api/token ") {
                "test-token".to_owned()
            } else if request.starts_with("GET /latest/meta-data/instance-id ")
                && request.contains("X-aws-ec2-metadata-token: test-token")
            {
                id.lock().unwrap().clone()
            } else {
                let _ = stream.write_all(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
                continue;
            };
            let response =
                format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}", body.len());
            let _ = stream.write_all(response.as_bytes());
        }
    });
    addr
}

struct Harness {
    _dir: tempfile::TempDir,
    root: PathBuf,
    home: PathBuf,
    bin: PathBuf,
    daemon_log: PathBuf,
    metadata: String,
    id: Arc<Mutex<String>>,
}

impl Harness {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        let home = dir.path().join("home");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(home.join(".local/state/cmux/remote/sessions/cloud/auth")).unwrap();
        fs::write(home.join(".local/state/cmux/remote/sessions/cloud/auth/identity.json"), "{}")
            .unwrap();
        let bin = dir.path().join("bin/cmux-tui");
        fs::create_dir_all(bin.parent().unwrap()).unwrap();
        let daemon_log = dir.path().join("daemon.log");
        fs::write(
            &bin,
            "#!/bin/sh\nd=$(dirname \"$0\")/..\necho \"$$ $*\" >> \"$d/daemon.log\"\nenv > \"$d/daemon.env\"\ntrap 'kill $! 2>/dev/null; exit 0' TERM\nsleep 600 &\nwait\n",
        )
        .unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        let id = Arc::new(Mutex::new("vm-a".to_owned()));
        let metadata = metadata_server(id.clone());
        Self { root, home, bin, daemon_log, metadata, id, _dir: dir }
    }

    /// A Cloud machine's host config: the Freestyle edge carrier on 0.0.0.0.
    fn with_cloud_edge(self) -> Self {
        fs::create_dir_all(self.at("/etc/cmux")).unwrap();
        fs::write(
            self.at("/etc/cmux/host.json"),
            r#"{"remoteWs": {"bind": "0.0.0.0:1337", "carrier": "freestyle-edge"}}"#,
        )
        .unwrap();
        fs::set_permissions(self.at("/etc/cmux/host.json"), fs::Permissions::from_mode(0o644))
            .unwrap();
        self
    }

    fn start(&self, log: &Path) -> Child {
        let out = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.root.parent().unwrap().join("agent.out"))
            .unwrap();
        let me = String::from_utf8(Command::new("id").arg("-un").output().unwrap().stdout).unwrap();
        Command::new(env!("CARGO_BIN_EXE_cmux-host"))
            .arg("run")
            .arg("--root")
            .arg(&self.root)
            .args([
                "--metadata",
                &self.metadata,
                "--metadata-attempts",
                "2",
                "--daemon-user",
                me.trim(),
            ])
            .arg("--daemon-home")
            .arg(&self.home)
            .arg("--daemon-bin")
            .arg(&self.bin)
            .arg("--no-announce")
            .arg("--action-log")
            .arg(log)
            // Service-manager variables must not reach the session host.
            .env("INVOCATION_ID", "test-invocation")
            // Must not reach the session host: the entry comes from host.json.
            .env("CMUX_TUI_REMOTE_WS_BIND", "0.0.0.0:9")
            .env("CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER", "1")
            // System layout: server.json is /etc/cmux/server.json (under the root).
            .env("CMUX_SERVER_MODE", "system")
            .env_remove("NOTIFY_SOCKET")
            // The agent's and the fake session host's output go to a file,
            // never to the test harness's pipes (an orphaned `sleep` would
            // hold them open).
            .stdin(Stdio::null())
            .stdout(Stdio::from(out.try_clone().unwrap()))
            .stderr(Stdio::from(out))
            .spawn()
            .unwrap()
    }

    fn at(&self, abs: &str) -> PathBuf {
        self.root.join(abs.trim_start_matches('/'))
    }

    fn status(&self) -> Option<Status> {
        Status::from_json(&fs::read_to_string(self.at("/run/cmux-host/status.json")).ok()?)
    }

    /// The driver's write after create: wakes the agent through inotify.
    fn clone_to(&self, id: &str) {
        *self.id.lock().unwrap() = id.to_owned();
        fs::write(self.at("/run/cmux/instance-id"), id).unwrap();
    }
}

fn lines(log: &Path) -> Vec<String> {
    fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .map(|l| l.split_once(' ').map_or(l, |(_, rest)| rest).to_owned())
        .collect()
}

/// Test-side wait: re-checks the condition until a deadline.
fn wait_until(what: &str, mut ok: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !ok() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        thread::sleep(Duration::from_millis(20));
    }
}

fn index(lines: &[String], from: usize, line: &str) -> usize {
    lines[from..]
        .iter()
        .position(|l| l == line)
        .map(|i| i + from)
        .unwrap_or_else(|| panic!("missing {line:?} after {from} in {lines:#?}"))
}

fn alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
        && !fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default().contains(") Z ")
}

/// An agent process killed on drop (a failed assertion never leaks it).
struct AgentProc(Child);

impl Drop for AgentProc {
    fn drop(&mut self) {
        if matches!(self.0.try_wait(), Ok(None)) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        if let Some(pid) = self.status().and_then(|s| s.daemon_pid)
            && alive(pid)
        {
            kill_group(pid);
        }
    }
}

/// SIGKILLs a process group. The session host runs under `setsid`, so its
/// pid is its group: the fake host's `sleep 600` dies with it.
fn kill_group(pid: u32) {
    // SAFETY: kill of a process group this test started.
    unsafe { libc::kill(-(pid as libc::pid_t), libc::SIGKILL) };
}

/// A process that looks like a terminal host of the test user
/// (`.../cmux-tui __terminal-host`): `sh` with that argv runs the script
/// file `__terminal-host`. Killed with its group on drop.
struct FakeTerminalHost(Child);

impl FakeTerminalHost {
    fn start(dir: &Path) -> Self {
        use std::os::unix::process::CommandExt;
        fs::create_dir_all(dir).unwrap();
        fs::write(dir.join("__terminal-host"), "sleep 600\n").unwrap();
        let child = Command::new("/bin/sh")
            .arg0(dir.join("cmux-tui"))
            .arg("__terminal-host")
            .current_dir(dir)
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        Self(child)
    }

    fn pid(&self) -> u32 {
        self.0.id()
    }
}

impl Drop for FakeTerminalHost {
    fn drop(&mut self) {
        kill_group(self.0.id());
        let _ = self.0.wait();
    }
}

fn terminate(agent: &mut AgentProc) {
    // SAFETY: plain kill of our own child.
    unsafe { libc::kill(agent.0.id() as libc::pid_t, libc::SIGTERM) };
    let status = agent.0.wait().unwrap();
    assert!(status.success(), "agent exit {status}");
}

#[test]
fn agent_binds_parks_adopts_and_restarts() {
    let h = Harness::new().with_cloud_edge();
    let log = h.root.parent().unwrap().join("actions.log");
    let mut agent = AgentProc(h.start(&log));

    // First bind, in the contract order.
    wait_until("first spawn", || lines(&log).iter().any(|l| l == "spawn-daemon"));
    let l = lines(&log);
    let reseed = index(&l, 0, "reseed id=vm-a");
    let mark = index(&l, reseed, "mark-clone-started");
    let drop = index(&l, mark, "drop-remote-identity");
    let write = index(&l, drop, "write-bound id=vm-a");
    let spawn = index(&l, write, "spawn-daemon");
    index(&l, spawn, "rekey id=vm-a");
    assert_eq!(fs::read_to_string(h.at("/etc/cmux/daemon-instance-id")).unwrap(), "vm-a\n");
    assert!(!h.home.join(".local/state/cmux/remote/sessions/cloud/auth").exists());
    wait_until("rekey job", || h.at("/etc/machine-id").is_file());
    wait_until("daemon argv", || {
        fs::read_to_string(&h.daemon_log).unwrap_or_default().contains("server start")
    });
    let argv = fs::read_to_string(&h.daemon_log).unwrap();
    assert!(
        argv.contains(
            "server start --session cloud --remote-ws 0.0.0.0:1337 --remote-ws-insecure-bind --remote-ws-trusted-carrier"
        ),
        "{argv}"
    );
    wait_until("status", || h.status().is_some_and(|s| s.daemon_pid.is_some()));
    let first_pid = h.status().unwrap().daemon_pid.unwrap();
    let env = fs::read_to_string(h.daemon_log.with_file_name("daemon.env")).unwrap();
    assert!(env.lines().any(|l| l == "TERM_PROGRAM=ghostty"), "{env}");
    assert!(!env.contains("INVOCATION_ID"), "{env}");
    assert!(!env.contains("CMUX_SERVER_MODE"), "{env}");
    assert!(!env.contains("CMUX_TUI_REMOTE_WS"), "{env}");
    let out = fs::read_to_string(h.root.parent().unwrap().join("agent.out")).unwrap();
    assert!(out.contains("trusted-carrier") && out.contains("cx-wx2"), "{out}");
    // /run/cmux belongs to the session host's user (it writes `bound`).
    {
        use std::os::unix::fs::MetadataExt;
        let meta = fs::metadata(h.at("/run/cmux")).unwrap();
        // SAFETY: geteuid has no preconditions.
        assert_eq!(meta.uid(), unsafe { libc::geteuid() });
        assert_eq!(meta.mode() & 0o777, 0o755);
    }

    // server.json written: roles hear ConfigChanged.
    fs::write(h.at("/etc/cmux/server.json"), "{}").unwrap();
    wait_until("config event", || lines(&log).iter().any(|l| l == "notify event=config-changed"));

    // A clone: new id via the driver file. The old host is stopped first.
    h.clone_to("vm-b");
    wait_until("second bind", || lines(&log).iter().any(|l| l == "write-bound id=vm-b"));
    let l = lines(&log);
    let term = index(&l, write, "terminate-daemon");
    let reseed_b = index(&l, term, "reseed id=vm-b");
    let drop_b = index(&l, reseed_b, "drop-remote-identity");
    let commit_b = index(&l, drop_b, "commit-bind id=vm-b");
    index(&l, commit_b, "spawn-daemon");
    assert_eq!(l.iter().filter(|x| x.starts_with("reseed id=")).count(), 2, "{l:#?}");
    wait_until("old host gone", || !alive(first_pid));

    // Security review P2-3: a terminal host of the same user that is not
    // recorded under this daemon home (another test's, on a shared box)
    // survives the park; a recorded one is stopped.
    let scratch = h.root.parent().unwrap();
    let foreign = FakeTerminalHost::start(&scratch.join("foreign"));
    let ours = FakeTerminalHost::start(&scratch.join("ours"));
    let records = h.home.join(".local/state/cmux-tui/sessions/cloud/terminal-hosts-t");
    fs::create_dir_all(&records).unwrap();
    fs::write(records.join("h.json"), format!("{{\"host_pid\":{}}}", ours.pid())).unwrap();

    // Park: the bake writes its id; host stopped, no spawn after.
    fs::write(h.at("/etc/cmux/bake-instance-id"), "vm-b\n").unwrap();
    wait_until("parked", || h.status().is_some_and(|s| s.parked && s.daemon == "down"));
    let l = lines(&log);
    let park = index(&l, 0, "park-housekeeping");
    index(&l, park, "stop-terminal-hosts");
    wait_until("recorded terminal host stopped", || !alive(ours.pid()));
    assert!(alive(foreign.pid()), "the park stopped a terminal host outside this daemon home");
    let wakes = h.status().unwrap().wakes;
    h.clone_to("vm-b"); // another wake while parked: still no spawn
    wait_until("parked wake", || h.status().is_some_and(|s| s.wakes > wakes));
    assert!(!lines(&log)[park..].iter().any(|x| x == "spawn-daemon"));
    assert!(h.status().unwrap().parked);

    // A clone of the parked snapshot binds again.
    h.clone_to("vm-c");
    wait_until("third bind", || h.status().is_some_and(|s| !s.parked && s.daemon_pid.is_some()));
    let pid = h.status().unwrap().daemon_pid.unwrap();
    terminate(&mut agent);
    assert!(alive(pid), "the session host survives an agent restart");

    // Restart: adopt, do not spawn a second host.
    let log2 = h.root.parent().unwrap().join("actions2.log");
    let mut agent = AgentProc(h.start(&log2));
    wait_until("adopt", || lines(&log2).iter().any(|l| l == &format!("adopt-daemon pid={pid}")));
    wait_until("status after adopt", || h.status().is_some_and(|s| s.daemon_pid == Some(pid)));
    assert!(
        !lines(&log2).iter().any(|l| l == "spawn-daemon" || l.starts_with("reseed id=")),
        "{:#?}",
        lines(&log2)
    );

    // Crash: the adopted host dies (with its `sleep`); the agent restarts it.
    kill_group(pid);
    wait_until("restart", || h.status().is_some_and(|s| s.daemon_pid.is_some_and(|p| p != pid)));
    terminate(&mut agent);
}

/// Without host.json the session host binds loopback with enrolled auth,
/// even when the agent's environment asks for the trusted carrier.
#[test]
fn without_a_host_config_the_session_host_is_loopback_and_enrolled() {
    let h = Harness::new();
    let log = h.root.parent().unwrap().join("actions.log");
    let mut agent = AgentProc(h.start(&log));
    wait_until("daemon argv", || {
        fs::read_to_string(&h.daemon_log).unwrap_or_default().contains("server start")
    });
    let argv = fs::read_to_string(&h.daemon_log).unwrap();
    assert!(argv.contains("server start --session cloud --remote-ws 127.0.0.1:1337"), "{argv}");
    assert!(!argv.contains("trusted-carrier") && !argv.contains("insecure-bind"), "{argv}");
    let env = fs::read_to_string(h.daemon_log.with_file_name("daemon.env")).unwrap();
    assert!(!env.contains("CMUX_TUI_REMOTE_WS"), "{env}");
    terminate(&mut agent);
}

/// A host.json that asks for the trusted carrier without the edge carrier
/// field is refused: the session host falls back to loopback, enrolled.
#[test]
fn a_refused_host_config_falls_back_to_loopback() {
    let h = Harness::new();
    fs::create_dir_all(h.at("/etc/cmux")).unwrap();
    fs::write(h.at("/etc/cmux/host.json"), r#"{"remoteWs": {"bind": "0.0.0.0:1337"}}"#).unwrap();
    let log = h.root.parent().unwrap().join("actions.log");
    let mut agent = AgentProc(h.start(&log));
    wait_until("daemon argv", || {
        fs::read_to_string(&h.daemon_log).unwrap_or_default().contains("server start")
    });
    let argv = fs::read_to_string(&h.daemon_log).unwrap();
    assert!(argv.contains("--remote-ws 127.0.0.1:1337"), "{argv}");
    assert!(!argv.contains("0.0.0.0"), "{argv}");
    let out = fs::read_to_string(h.root.parent().unwrap().join("agent.out")).unwrap();
    assert!(out.contains("host.json refused"), "{out}");
    terminate(&mut agent);
}

/// A host.json that others can write is refused even when it names the
/// edge carrier: the session host falls back to loopback.
#[test]
fn a_shared_writable_host_config_is_refused() {
    let h = Harness::new().with_cloud_edge();
    fs::set_permissions(h.at("/etc/cmux/host.json"), fs::Permissions::from_mode(0o666)).unwrap();
    let log = h.root.parent().unwrap().join("actions.log");
    let mut agent = AgentProc(h.start(&log));
    wait_until("daemon argv", || {
        fs::read_to_string(&h.daemon_log).unwrap_or_default().contains("server start")
    });
    let argv = fs::read_to_string(&h.daemon_log).unwrap();
    assert!(argv.contains("--remote-ws 127.0.0.1:1337"), "{argv}");
    assert!(!argv.contains("trusted-carrier"), "{argv}");
    let out = fs::read_to_string(h.root.parent().unwrap().join("agent.out")).unwrap();
    assert!(out.contains("host.json refused") && out.contains("writable"), "{out}");
    terminate(&mut agent);
}
