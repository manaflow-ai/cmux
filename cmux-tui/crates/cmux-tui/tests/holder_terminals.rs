//! Terminals on the holder (`CMUX_TUI_TERMINAL_HOST_MODEL=holder`,
//! terminal-host-model-DESIGN.md): no host process per terminal, and no
//! shell dies when the daemon or the holder does.
//!
//! One daemon runs 4 terminals (`cat`) on the holder. Then:
//! 1. no terminal-host record exists: no host process was started;
//! 2. SIGKILL the daemon and start it again on the same state: every
//!    terminal is running again with its whole screen (replayed from the
//!    holder's ring) and takes input;
//! 3. SIGKILL the holder: every shell lives, the daemon starts a new holder
//!    and hands it every master, input and output still work and no screen
//!    resets;
//! 4. SIGKILL the daemon again: the new holder's terminals come back with
//!    their whole screen: the daemon handed the new holder a VT replay of
//!    each screen (its prologue) with the master, and the output since.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const TERMINALS: usize = 4;

fn request(socket: &Path, mut body: Value) -> Value {
    let stream = UnixStream::connect(socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    body["id"] = json!(1);
    (&stream).write_all(format!("{body}\n").as_bytes()).unwrap();
    let mut reader = BufReader::new(&stream);
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0, "daemon closed the socket for {body}");
        let reply: Value = serde_json::from_str(&line).unwrap();
        if reply["id"] == json!(1) && reply.get("ok").is_some() {
            assert_eq!(reply["ok"], true, "{body} failed: {reply}");
            return reply["data"].clone();
        }
    }
}

struct Daemon {
    child: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    /// Holder and shell pids this test made, ended at drop: a holder
    /// outlives every daemon on purpose.
    cleanup: Vec<i32>,
}

impl Daemon {
    fn start() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!(
            "cmux-holder-{}-{}",
            std::process::id(),
            stamp % 1_000_000_000
        ));
        fs::create_dir_all(&dir).unwrap();
        let mut daemon =
            Self { child: None, socket: dir.join("mux.sock"), dir, cleanup: Vec::new() };
        daemon.restart();
        daemon
    }

    fn restart(&mut self) {
        let _ = fs::remove_file(&self.socket);
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--session", "holder-test", "--socket"])
            .arg(&self.socket)
            .arg("--state")
            .arg(self.dir.join("state"))
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_TUI_TERMINAL_HOST_MODEL", "holder")
            .env("SHELL", "/bin/sh")
            .env_remove("SSH_CONNECTION")
            .env_remove("SSH_CLIENT")
            .env_remove("SSH_TTY")
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        self.child = Some(child);
        let deadline = Instant::now() + Duration::from_secs(60);
        while UnixStream::connect(&self.socket).is_err() {
            assert!(Instant::now() < deadline, "the daemon never listened");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn sigkill(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.sigkill();
        for pid in self.cleanup.drain(..) {
            // SAFETY: SIGKILL of a holder or shell this test's daemon started.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn screen_contains(socket: &Path, surface: u64, marker: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let text = request(socket, json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if text.contains(marker) {
            return text;
        }
        assert!(Instant::now() < deadline, "surface {surface} never showed {marker:?}:\n{text}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The live surface of `terminal_id`, once its terminal runs.
fn running_surface(socket: &Path, terminal_id: &str) -> u64 {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let resolved =
            request(socket, json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            return surface;
        }
        assert!(
            Instant::now() < deadline,
            "terminal {terminal_id} is not running again: {resolved}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn shell_pid(socket: &Path, surface: u64) -> i32 {
    let resources = request(socket, json!({"cmd": "terminal-resources", "surfaces": [surface]}));
    resources["terminals"][0]["pid"].as_i64().unwrap_or_else(|| panic!("no pid: {resources}"))
        as i32
}

fn parent_of(pid: i32) -> i32 {
    let out = Command::new("ps").args(["-o", "ppid=", "-p", &pid.to_string()]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only probes a pid this test's daemon started.
    unsafe { libc::kill(pid, 0) == 0 }
}

#[test]
fn shells_on_the_holder_survive_a_holder_crash_and_a_daemon_crash() {
    let mut daemon = Daemon::start();
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let created = request(
            &daemon.socket,
            json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
                "name": format!("holder-{index}"), "cols": 80, "rows": 24}),
        );
        let surface = created["surface"].as_u64().unwrap();
        let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
        request(
            &daemon.socket,
            json!({"cmd": "send", "surface": surface, "text": format!("first-{index}\n")}),
        );
        screen_contains(&daemon.socket, surface, &format!("first-{index}"));
        terminals.push((terminal_id, surface));
    }

    // 1. No terminal-host process: none wrote a record into the host root.
    let host_records: Vec<_> = walk(&daemon.dir.join("state"))
        .into_iter()
        .filter(|path| {
            path.parent().is_some_and(|dir| dir.to_string_lossy().contains("terminal-hosts"))
        })
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    assert!(host_records.is_empty(), "terminal hosts were started: {host_records:?}");

    let shells: Vec<i32> =
        terminals.iter().map(|(_, surface)| shell_pid(&daemon.socket, *surface)).collect();
    daemon.cleanup.extend(&shells);
    let holder = parent_of(shells[0]);
    assert!(holder > 1, "the shell's parent is the holder");
    daemon.cleanup.push(holder);

    // 2. The daemon crashes and starts again on the same state: every
    // terminal comes back with its whole screen from the holder's ring.
    daemon.sigkill();
    for (index, shell) in shells.iter().enumerate() {
        assert!(alive(*shell), "terminal {index}: its shell died with the daemon");
    }
    daemon.restart();
    let mut surfaces = Vec::new();
    for (index, (terminal_id, _)) in terminals.iter().enumerate() {
        let surface = running_surface(&daemon.socket, terminal_id);
        screen_contains(&daemon.socket, surface, &format!("first-{index}"));
        send(&daemon.socket, surface, &format!("after-daemon-{index}"));
        screen_contains(&daemon.socket, surface, &format!("after-daemon-{index}"));
        surfaces.push(surface);
    }

    // 3. The holder crashes: no shell dies, the daemon starts a new holder
    // and hands it every master, and input and output still work.
    // SAFETY: SIGKILL of the holder this test's daemon started.
    unsafe { libc::kill(holder, libc::SIGKILL) };
    for (index, (surface, shell)) in surfaces.iter().zip(&shells).enumerate() {
        assert!(alive(*shell), "terminal {index}: its shell died with the holder");
        send(&daemon.socket, *surface, &format!("after-holder-{index}"));
    }
    for (index, surface) in surfaces.iter().enumerate() {
        let screen = screen_contains(&daemon.socket, *surface, &format!("after-holder-{index}"));
        assert!(
            screen.contains(&format!("first-{index}")),
            "terminal {index}: its screen was reset"
        );
    }
    // A new terminal's shell is the new holder's child (and its pid ends it at drop).
    let probe = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true, "name": "probe", "cols": 80, "rows": 24}),
    );
    let probe_shell = shell_pid(&daemon.socket, probe["surface"].as_u64().unwrap());
    daemon.cleanup.push(probe_shell);
    let new_holder = parent_of(probe_shell);
    assert!(new_holder > 1 && new_holder != holder, "a new holder runs the new terminal");
    daemon.cleanup.push(new_holder);

    // 4. The daemon crashes again: the new holder lists every terminal it
    // took over, and they come back with what they printed since.
    daemon.sigkill();
    daemon.restart();
    for (index, (terminal_id, _)) in terminals.iter().enumerate() {
        let surface = running_surface(&daemon.socket, terminal_id);
        let screen = screen_contains(&daemon.socket, surface, &format!("after-holder-{index}"));
        // The screen from before the holder crash comes from the prologue
        // the daemon handed the new holder.
        assert!(
            screen.contains(&format!("first-{index}"))
                && screen.contains(&format!("after-daemon-{index}")),
            "terminal {index}: the screen before the holder crash is gone:\n{screen}"
        );
        send(&daemon.socket, surface, &format!("last-{index}"));
        screen_contains(&daemon.socket, surface, &format!("last-{index}"));
    }
}

fn send(socket: &Path, surface: u64, line: &str) {
    request(socket, json!({"cmd": "send", "surface": surface, "text": format!("{line}\n")}));
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir(dir) else { return out };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            out.extend(walk(&path));
        } else {
            out.push(path);
        }
    }
    out
}
