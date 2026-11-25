//! The interactive client follows its session daemon across `server restart`
//! and exits with a message on `server stop` (cmux-tui round 1, friction 10:
//! the client quit silently with exit 0 on `cmux daemon restart`).
//!
//! The test starts a session owner, attaches the real `cmux-tui` client on a
//! pty, restarts the owner, and requires the client to stay running and to
//! register again with the replacement daemon. Then it stops the session and
//! requires the client to exit cleanly and say that the session stopped.

#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const DEADLINE: Duration = Duration::from_secs(45);
/// The last input mode the client enables before it reads input.
const INPUT_MODES_ENABLED: &[u8] = b"\x1b[?2004h";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(session: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-dr-{}-{stamp}", std::process::id()));
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(dir.join("config.json"), "{}").unwrap();
        Self { socket: dir.join("mux.sock"), session: session.into(), dir }
    }

    fn env(&self, command: &mut Command) {
        command
            .env("HOME", self.dir.join("home"))
            .env("CFFIXED_USER_HOME", self.dir.join("home"))
            .env("CMUX_TUI_STATE_DIR", self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("XDG_DATA_HOME", self.dir.join("data"))
            .env("XDG_CONFIG_HOME", self.dir.join("config"))
            .env("CMUX_TUI_SHELL_INTEGRATION", "none")
            .env("SHELL", "/bin/sh")
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_SOCKET_PATH");
    }

    fn server(&self, action: &str, extra: &[&str]) -> Value {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", action, "--json", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .args(extra);
        self.env(&mut command);
        let output = command.output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(output.status.success(), "server {action} failed: {stdout} {stderr}");
        let last = stdout.lines().rfind(|line| line.starts_with('{')).unwrap_or_default();
        serde_json::from_str(last)
            .unwrap_or_else(|_| panic!("server {action} printed no JSON: {stdout:?} {stderr:?}"))
    }

    /// The `kind` of every control client of the running daemon, or `None`
    /// while no daemon answers.
    fn client_kinds(&self) -> Option<Vec<String>> {
        let stream = UnixStream::connect(&self.socket).ok()?;
        stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
        let mut stream = BufReader::new(stream);
        writeln!(stream.get_mut(), "{}", json!({"id": 1, "cmd": "list-clients"})).ok()?;
        loop {
            let mut line = String::new();
            if stream.read_line(&mut line).ok()? == 0 {
                return None;
            }
            let reply: Value = serde_json::from_str(&line).ok()?;
            if reply["id"] != 1 {
                continue;
            }
            let data = &reply["data"];
            let clients = data.as_array().or_else(|| data["clients"].as_array())?;
            return Some(
                clients
                    .iter()
                    .filter_map(|client| client["kind"].as_str().map(str::to_string))
                    .collect(),
            );
        }
    }

    fn has_tui_client(&self) -> bool {
        self.client_kinds().is_some_and(|kinds| kinds.iter().any(|kind| kind == "tui"))
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["server", "stop", "--end-terminals", "--session", &self.session, "--socket"])
            .arg(&self.socket);
        self.env(&mut command);
        let _ = command.output();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// The client on a pty, with a thread draining its output so it never blocks
/// on a full terminal.
struct Client {
    child: Mutex<Option<Child>>,
    output: Arc<Mutex<Vec<u8>>>,
    stderr: PathBuf,
    _master: File,
}

impl Client {
    fn start(fixture: &Fixture) -> Self {
        let (master, slave) = open_pty();
        let stderr = fixture.dir.join("client-stderr.txt");
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(["--session", &fixture.session, "--socket"])
            .arg(&fixture.socket)
            .current_dir(fixture.dir.join("home"))
            .env("TERM", "xterm-256color")
            .stdin(Stdio::from(slave.try_clone().unwrap()))
            .stdout(Stdio::from(slave.try_clone().unwrap()))
            .stderr(Stdio::from(File::create(&stderr).unwrap()));
        fixture.env(&mut command);
        let child = command.spawn().expect("cmux-tui client must start");
        drop(slave);
        let output = Arc::new(Mutex::new(Vec::new()));
        let mut reader = master.try_clone().unwrap();
        let sink = output.clone();
        std::thread::spawn(move || {
            let mut buffer = [0u8; 8192];
            while let Ok(count) = reader.read(&mut buffer) {
                if count == 0 {
                    break;
                }
                sink.lock().unwrap().extend_from_slice(&buffer[..count]);
            }
        });
        Self { child: Mutex::new(Some(child)), output, stderr, _master: master }
    }

    fn printed(&self, needle: &[u8]) -> bool {
        self.output.lock().unwrap().windows(needle.len()).any(|window| window == needle)
    }

    fn running(&self) -> bool {
        let mut child = self.child.lock().unwrap();
        child.as_mut().is_some_and(|child| child.try_wait().unwrap().is_none())
    }

    fn stderr(&self) -> String {
        let bytes = fs::read(&self.stderr).unwrap_or_default();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// Waits for the client to exit, or kills it after `deadline`.
    fn wait(&self, deadline: Duration) -> Option<ExitStatus> {
        let mut child = self.child.lock().unwrap().take()?;
        let (done, exited) = mpsc::channel();
        let pid = child.id();
        let waiter = std::thread::spawn(move || {
            let status = child.wait().unwrap();
            let _ = done.send(status);
        });
        match exited.recv_timeout(deadline) {
            Ok(status) => {
                let _ = waiter.join();
                Some(status)
            }
            Err(_) => {
                // SAFETY: the waiter still owns this unreaped child.
                unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
                let _ = waiter.join();
                None
            }
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn wait_for(what: &str, client: &Client, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + DEADLINE;
    while !ready() {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {what}\nclient stderr:\n{}",
            client.stderr()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn tui_daemon_reconnect_follows_restart_and_exits_on_stop() {
    let fixture = Fixture::new("daemon-reconnect");
    let old = fixture.server("ensure", &[]);
    let client = Client::start(&fixture);
    wait_for("the client to take the terminal", &client, || client.printed(INPUT_MODES_ENABLED));
    wait_for("the client to attach", &client, || fixture.has_tui_client());

    let restarted = fixture.server("restart", &[]);
    assert_ne!(restarted["pid"], old["pid"], "restart kept the old owner: {restarted}");
    // The client stays and registers with the replacement daemon.
    wait_for("the client to reconnect", &client, || {
        assert!(client.running(), "the client exited on restart:\n{}", client.stderr());
        fixture.has_tui_client()
    });
    assert!(client.running(), "the client exited after reconnecting:\n{}", client.stderr());

    fixture.server("stop", &["--end-terminals"]);
    let status = client.wait(DEADLINE).unwrap_or_else(|| {
        panic!("the client still ran {DEADLINE:?} after the stop:\n{}", client.stderr())
    });
    let stderr = client.stderr();
    assert!(status.success(), "the client failed after the stop ({status}):\n{stderr}");
    assert!(
        stderr.contains("session daemon-reconnect stopped"),
        "the client did not say the session stopped:\n{stderr}"
    );
}

/// A close-on-exec pty pair: the client gets the slave, the test the master.
fn open_pty() -> (File, OwnedFd) {
    let mut master: libc::c_int = -1;
    let mut slave: libc::c_int = -1;
    // SAFETY: `openpty` writes two descriptors into the out params on success.
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(opened, 0, "openpty: {}", std::io::Error::last_os_error());
    for descriptor in [master, slave] {
        // SAFETY: both descriptors are open and owned here.
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
        assert!(flags >= 0, "F_GETFD: {}", std::io::Error::last_os_error());
        // SAFETY: as above, with the flags read a moment ago.
        assert_eq!(unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) }, 0);
    }
    // SAFETY: both descriptors are fresh, owned, and valid.
    unsafe { (File::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) }
}

/// The session's state directories under the fixture's state root.
fn session_state_dirs(fixture: &Fixture) -> Vec<String> {
    let prefix = format!("{}-", fixture.session);
    fs::read_dir(fixture.dir.join("state"))
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .filter(|name| name.starts_with(&prefix))
                .collect()
        })
        .unwrap_or_default()
}

/// Seeds `table` of the sqlite store `path` with one row, as the Chief and
/// conversation stores keep theirs next to the session registry.
fn seed_store(path: &std::path::Path, table: &str, row: &str) {
    let db = rusqlite::Connection::open(path).unwrap();
    db.execute_batch(&format!(
        "CREATE TABLE IF NOT EXISTS {table}(id TEXT); INSERT INTO {table} VALUES('{row}');"
    ))
    .unwrap();
}

fn store_row(path: &std::path::Path, table: &str) -> Option<String> {
    let db =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)
            .ok()?;
    db.query_row(&format!("SELECT id FROM {table}"), [], |row| row.get::<_, String>(0)).ok()
}

fn terminal_host_dirs(fixture: &Fixture) -> Vec<String> {
    fs::read_dir(fixture.dir.join("state"))
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.file_name().to_string_lossy().into_owned())
                .filter(|name| name.starts_with("terminal-hosts-"))
                .collect()
        })
        .unwrap_or_default()
}

/// Bench round 4 item 10 (W5-R): `daemon stop --end-terminals` with a TUI
/// attached left the session's launch snapshot (written at the stop) and
/// its terminal-host records: nothing is left to resume, so the stop
/// removes that terminal and resume state. Only that: the Chief store and
/// the conversations in the same session directory stay (review 6731023492,
/// item 3). A plain stop keeps everything: `agent resume` and the next owner
/// need it.
#[test]
fn w5r_stop_with_end_terminals_removes_terminal_state_and_keeps_chiefs_and_conversations() {
    let fixture = Fixture::new("w5r-state");
    fixture.server("ensure", &[]);
    let client = Client::start(&fixture);
    wait_for("the client to take the terminal", &client, || client.printed(INPUT_MODES_ENABLED));
    wait_for("the client to attach", &client, || fixture.has_tui_client());

    fixture.server("stop", &[]);
    assert!(client.wait(DEADLINE).is_some(), "the client still ran after the stop");
    let kept = session_state_dirs(&fixture);
    let [session_dir] = kept.as_slice() else {
        panic!("a plain stop did not keep one session state directory: {kept:?}")
    };
    let session_dir = fixture.dir.join("state").join(session_dir);
    assert!(
        session_dir.join("launch-snapshot.json").is_file(),
        "a plain stop removed the launch snapshot"
    );

    fixture.server("ensure", &[]);
    let client = Client::start(&fixture);
    wait_for("the client to take the terminal", &client, || client.printed(INPUT_MODES_ENABLED));
    wait_for("the client to attach", &client, || fixture.has_tui_client());
    seed_store(&session_dir.join("chiefs.sqlite3"), "w5r_chief", "chief-survives");
    seed_store(&session_dir.join("conversations.sqlite3"), "w5r_conversation", "conv-survives");

    let stopped = fixture.server("stop", &["--end-terminals"]);
    assert!(client.wait(DEADLINE).is_some(), "the client still ran after the stop");
    assert!(
        !session_dir.join("launch-snapshot.json").exists(),
        "stop --end-terminals left the launch snapshot: {stopped}"
    );
    let hosts = terminal_host_dirs(&fixture);
    assert!(hosts.is_empty(), "stop --end-terminals left terminal-host records {hosts:?}");
    assert_eq!(
        store_row(&session_dir.join("chiefs.sqlite3"), "w5r_chief").as_deref(),
        Some("chief-survives"),
        "stop --end-terminals removed the Chief store: {stopped}"
    );
    assert_eq!(
        store_row(&session_dir.join("conversations.sqlite3"), "w5r_conversation").as_deref(),
        Some("conv-survives"),
        "stop --end-terminals removed the conversations: {stopped}"
    );
    assert_eq!(stopped["removed_terminal_state"], true, "{stopped}");
}
