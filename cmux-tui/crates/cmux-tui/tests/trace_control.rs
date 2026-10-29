//! `trace-start`, `trace-status` and `trace-stop` on a real daemon:
//! the daemon records into its state root and
//! forwards to its terminal hosts, which record next to their discovery
//! records, or to its holder (`CMUX_TUI_TERMINAL_HOST_MODEL=holder`), which
//! records in its holder-lifetime directory. Every ring is on disk, decodes,
//! and names its role and process.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_trace::Role;
use serde_json::{Value, json};

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    /// The reply to `request`: `Ok(data)` or `Err(error text)`.
    fn call(&mut self, mut request: Value) -> Result<Value, String> {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.writer, "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the socket");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == json!(self.next) && reply.get("ok").is_some() {
                return if reply["ok"] == true {
                    Ok(reply["data"].clone())
                } else {
                    Err(reply["error"].to_string())
                };
            }
        }
    }
}

/// A daemon of this test, with the terminal host model `model` (`None`:
/// the default, a host process per terminal).
struct Daemon {
    child: Child,
    dir: PathBuf,
    client: Client,
    /// Processes the test made that outlive the daemon (the holder).
    cleanup: Vec<i32>,
    /// Directories they wrote outside `dir` (the holder's rings).
    cleanup_dirs: Vec<PathBuf>,
}

impl Daemon {
    fn start(model: Option<&str>) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir =
            PathBuf::from("/tmp").join(format!("cmux-trace-ctl-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("SHELL", "/bin/sh")
            .env_remove("CMUX_TUI_TERMINAL_HOST_MODEL")
            .env_remove("SSH_CONNECTION")
            .env_remove("SSH_CLIENT")
            .env_remove("SSH_TTY")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(model) = model {
            command.env("CMUX_TUI_TERMINAL_HOST_MODEL", model);
        }
        let child = command.spawn().unwrap();
        let deadline = Instant::now() + Duration::from_secs(60);
        let stream = loop {
            if let Ok(stream) = UnixStream::connect(&socket) {
                break stream;
            }
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        };
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let client =
            Client { writer: stream.try_clone().unwrap(), reader: BufReader::new(stream), next: 0 };
        Self { child, dir, client, cleanup: Vec::new(), cleanup_dirs: Vec::new() }
    }

    /// A new workspace running `cat`; its surface.
    fn new_terminal(&mut self) -> u64 {
        let created = self
            .client
            .call(json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
                "name": "traced", "cols": 80, "rows": 24}))
            .unwrap();
        created["surface"].as_u64().unwrap_or_else(|| panic!("no surface: {created}"))
    }

    fn shell_pid(&mut self, surface: u64) -> i32 {
        let resources =
            self.client.call(json!({"cmd": "terminal-resources", "surfaces": [surface]})).unwrap();
        let pid = resources["terminals"][0]["pid"].as_i64();
        pid.unwrap_or_else(|| panic!("no pid: {resources}")) as i32
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Ok(identity) = self.client.call(json!({"cmd": "identify"})) {
            let _ = self.client.call(json!({"cmd": "shutdown-daemon", "pid": identity["pid"],
                "generation": identity["generation"], "force": true, "end_terminals": true}));
        }
        let _ = self.child.wait();
        for pid in &self.cleanup {
            // SAFETY: signals only a process this test's daemon started.
            unsafe { libc::kill(*pid, libc::SIGKILL) };
        }
        for dir in self.cleanup_dirs.iter().chain([&self.dir]) {
            let _ = fs::remove_dir_all(dir);
        }
    }
}

fn process<'a>(reply: &'a Value, role: &str) -> Vec<&'a Value> {
    reply["processes"].as_array().unwrap().iter().filter(|p| p["role"] == role).collect()
}

/// The ring at `path` decodes as a ring of `role` written by `pid`.
fn assert_ring(path: &Path, role: Role, pid: u64) {
    let bytes = fs::read(path).unwrap_or_else(|error| panic!("{}: {error}", path.display()));
    let decoded = cmux_trace::decode(&bytes)
        .unwrap_or_else(|error| panic!("{} does not decode: {error:?}", path.display()));
    assert_eq!(decoded.header.role, role as u16, "{}", path.display());
    assert_eq!(u64::from(decoded.header.pid), pid, "{}", path.display());
}

fn parent_of(pid: i32) -> i32 {
    let out = Command::new("ps").args(["-o", "ppid=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
}

/// The recording ring of holder `pid`: in its holder-lifetime directory
/// beside its socket, in this user's holder socket directory. It appears
/// once the holder's one-shot map thread mapped it.
fn holder_ring(pid: i32) -> PathBuf {
    // SAFETY: getuid cannot fail.
    let sockets = PathBuf::from(format!("/tmp/cmux-hd-{}", unsafe { libc::getuid() }));
    let name = cmux_trace::recording_file_name(Role::Holder, pid as u32);
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let found = fs::read_dir(&sockets).into_iter().flatten().flatten().find_map(|entry| {
            let ring = entry.path().join(&name);
            ring.is_file().then_some(ring)
        });
        if let Some(ring) = found {
            return ring;
        }
        assert!(Instant::now() < deadline, "holder {pid} mapped no {name} in {sockets:?}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// Starts a recording of `frame` and checks the daemon's ring; returns the
/// start reply. `key` is refused without `keys`; a path is not a parameter.
fn start_and_check_the_daemon(daemon: &mut Daemon) -> Value {
    let refused = daemon.client.call(json!({"cmd": "trace-start", "categories": ["key"]}));
    assert!(refused.is_err(), "{refused:?}");
    let started = daemon
        .client
        .call(json!({"cmd": "trace-start", "categories": ["frame"], "path": "/etc"}))
        .unwrap();
    assert_eq!(started["recording"], true, "{started}");
    assert_eq!(started["categories"], json!(["frame"]));

    let daemon_report = process(&started, "daemon");
    assert_eq!(daemon_report.len(), 1, "{started}");
    assert_eq!(daemon_report[0]["state"], "recording", "{started}");
    let daemon_ring = PathBuf::from(daemon_report[0]["recording_path"].as_str().unwrap());
    assert!(daemon_ring.starts_with(daemon.dir.join("state")), "{}", daemon_ring.display());
    assert_ring(&daemon_ring, Role::Daemon, daemon_report[0]["pid"].as_u64().unwrap());
    let total = started["total_bytes"].as_u64().unwrap();
    assert!(total <= started["total_cap_bytes"].as_u64().unwrap(), "{started}");
    started
}

#[test]
fn trace_control_records_the_daemon_and_its_terminal_host() {
    let mut daemon = Daemon::start(None);
    daemon.new_terminal();
    let started = start_and_check_the_daemon(&mut daemon);

    let hosts = process(&started, "terminal-host");
    assert!(!hosts.is_empty(), "no terminal host was asked: {started}");
    for host in &hosts {
        assert_eq!(host["state"], "recording", "{started}");
        let ring = PathBuf::from(host["recording_path"].as_str().unwrap());
        assert!(ring.starts_with(daemon.dir.join("state")), "{}", ring.display());
        assert_ring(&ring, Role::TerminalHost, host["pid"].as_u64().unwrap());
    }
    assert_eq!(
        started["bytes_by_role"]["terminal-host"].as_u64(),
        Some(hosts.len() as u64 * Role::TerminalHost.recording_bytes())
    );

    let again = daemon.client.call(json!({"cmd": "trace-start"})).unwrap();
    assert_eq!(process(&again, "daemon")[0]["error"], "already_recording", "{again}");
    assert_eq!(process(&again, "terminal-host").len(), 0, "a refused start went on: {again}");

    let status = daemon.client.call(json!({"cmd": "trace-status"})).unwrap();
    assert_eq!(status["recording"], true, "{status}");
    assert!(process(&status, "terminal-host").iter().all(|host| host["state"] == "recording"));

    let stopped = daemon.client.call(json!({"cmd": "trace-stop"})).unwrap();
    assert_eq!(stopped["recording"], false, "{stopped}");
    assert!(process(&stopped, "terminal-host").iter().all(|host| host["state"] == "idle"));
    // The rings stay for the exporter after the stop.
    let daemon_ring = process(&started, "daemon")[0]["recording_path"].as_str().unwrap();
    assert!(Path::new(daemon_ring).exists());
}

#[test]
fn trace_control_records_the_daemon_and_its_holder() {
    let mut daemon = Daemon::start(Some("holder"));
    let surface = daemon.new_terminal();
    let holder_pid = parent_of(daemon.shell_pid(surface));
    daemon.cleanup.push(holder_pid);
    let started = start_and_check_the_daemon(&mut daemon);

    let holder = process(&started, "holder");
    assert_eq!(holder.len(), 1, "{started}");
    assert_eq!(holder[0]["state"], "recording", "{started}");
    assert_eq!(started["bytes_by_role"]["holder"].as_u64(), Some(Role::Holder.recording_bytes()));
    assert!(process(&started, "terminal-host").is_empty(), "no host runs: {started}");
    let ring = holder_ring(holder_pid);
    assert_ring(&ring, Role::Holder, holder_pid as u64);
    // The holder-lifetime directory is this test's holder's alone.
    daemon.cleanup_dirs.push(ring.parent().unwrap().to_path_buf());

    let status = daemon.client.call(json!({"cmd": "trace-status"})).unwrap();
    let holder = process(&status, "holder");
    assert_eq!(holder[0]["reason"], "holder_traced", "{status}");
    assert!(status["bytes_by_role"].get("holder").is_none(), "a status maps nothing: {status}");

    let stopped = daemon.client.call(json!({"cmd": "trace-stop"})).unwrap();
    assert_eq!(process(&stopped, "holder")[0]["state"], "idle", "{stopped}");
    assert!(stopped["bytes_by_role"].get("holder").is_none(), "{stopped}");
}
