#![cfg(unix)]
//! A shell's prompt survives a size bounce the shell never sees (close-then-type P0, "EMPTY FRESH SCREEN",
//! STATUS 14237).
//!
//! The terminal clears a prompt that the shell redraws on every grid resize (ghostty-vt
//! `Screen.clearPromptForRedraw`, manaflow-ai/cmux#21341), so the shell's SIGWINCH redraw replaces it. zsh redraws
//! only when the size it reads on SIGWINCH differs from the size it drew at. When the size goes 34 -> 35 -> 34 and
//! zsh handles both SIGWINCHes as one, it reads 34, draws nothing, and the cleared prompt never comes back: the
//! journey's new pane showed an empty screen with the cursor after the prompt (row 0, column 2) for 20 s. A
//! never-merge probe with real zsh (step 8de5abaa191d9dc07acd672b) left the screen blank in 1 of 8 such bounces.
//!
//! This test makes zsh handle the bounce as one SIGWINCH on every run: it stops the shell (SIGSTOP), moves the
//! terminal to 35 columns and back to 34 through the daemon (each size reaches both the terminal host and the
//! daemon's screen), then resumes the shell. The daemon's screen must still show the prompt.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use cmux_tui_core::terminal_host_runtime::{
    TerminalHostLiveness, adopt_terminal_host, load_terminal_host_records,
    remove_stale_terminal_host_record, terminal_host_record_liveness, terminal_host_root,
};

#[path = "support/private_state.rs"]
mod private_state;

const ZSH: &str = "/bin/zsh";
const PROMPT: &str = "J> ";
/// The prompt as the screen read shows it: each row loses its trailing blanks, so the space after `J>` is
/// not in the text.
const SHOWN: &str = "J>";
const SESSION: &str = "fresh-prompt";
const ROWS: u16 = 20;

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

struct Daemon {
    child: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    state: PathBuf,
}

impl Daemon {
    /// A headless daemon whose default shell is zsh, with a home whose `.zshrc` sets the prompt to [`PROMPT`].
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-fresh-prompt-{name}-{}-{stamp}", std::process::id()));
        let home = dir.join("home");
        fs::create_dir_all(&home).unwrap();
        fs::write(home.join(".zshrc"), format!("PS1='{PROMPT}'\n")).unwrap();
        let socket = dir.join("mux.sock");
        let state = dir.join("state");
        let mut command = Command::new(bin());
        command
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            .env_remove("ZDOTDIR")
            .env("HOME", &home)
            .env("SHELL", ZSH)
            .env("CMUX_TUI_HOST_EXE_DIR", dir.join("host-exe"))
            .args(["--headless", "--session", SESSION, "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        private_state::use_private_state(&mut command, &dir);
        let child = command.spawn().unwrap();
        let daemon = Self { child: Some(child), dir, socket, state };
        wait_for_socket(&daemon.socket);
        daemon
    }

    fn host_root(&self) -> PathBuf {
        terminal_host_root(&self.state, SESSION)
    }

    /// The pid of the terminal host's child (the shell) and the host's own grid size.
    fn host_child_and_size(&self) -> Option<(libc::pid_t, (u16, u16))> {
        let mut records = load_terminal_host_records(&self.host_root()).ok()?;
        if records.len() != 1 {
            return None;
        }
        let (path, record) = records.pop()?;
        let host = adopt_terminal_host(record, path).ok()?;
        let pid = host.snapshot.pid.and_then(|pid| libc::pid_t::try_from(pid).ok());
        let size = (host.snapshot.cols, host.snapshot.rows);
        host.disconnect();
        Some((pid?, size))
    }

    fn wait_for_host_size(&self, cols: u16) {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if self.host_child_and_size().is_some_and(|(_, size)| size == (cols, ROWS)) {
                return;
            }
            assert!(Instant::now() < deadline, "the terminal host did not resize to {cols}x{ROWS}");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let records = load_terminal_host_records(&self.host_root()).unwrap_or_default();
        for (path, record) in &records {
            if let Ok(mut host) = adopt_terminal_host(record.clone(), path.clone()) {
                let _ = host.terminate();
                host.disconnect();
            }
        }
        for (path, record) in &records {
            let deadline = Instant::now() + Duration::from_secs(2);
            while terminal_host_record_liveness(path, record).ok()
                != Some(TerminalHostLiveness::Dead)
                && Instant::now() < deadline
            {
                std::thread::sleep(Duration::from_millis(20));
            }
            if terminal_host_record_liveness(path, record).ok() != Some(TerminalHostLiveness::Dead)
            {
                // SAFETY: test teardown owns this dedicated host process; SIGKILL is the last resort after
                // its graceful Terminate timed out.
                let _ = unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) };
            }
            let _ = remove_stale_terminal_host_record(path, record);
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// Resumes the stopped shell even when an assertion fails while it is stopped.
struct Stopped(libc::pid_t);

impl Drop for Stopped {
    fn drop(&mut self) {
        // SAFETY: the pid is the test's own terminal shell, stopped by this test.
        let _ = unsafe { libc::kill(self.0, libc::SIGCONT) };
    }
}

fn wait_for_socket(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if transport::connect(path).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("the daemon did not accept connections at {}", path.display());
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["data"].clone()
}

/// One long-lived control connection: the test's view of the terminal, which owns its size.
struct View {
    writer: Box<dyn transport::Stream>,
    reader: BufReader<Box<dyn transport::Stream>>,
    next_id: u64,
}

impl View {
    fn open(path: &Path, surface: u64, cols: u16) -> Self {
        let stream = transport::connect(path).unwrap();
        let writer = stream.try_clone_box().unwrap();
        let mut view = Self { writer, reader: BufReader::new(stream), next_id: 1 };
        view.send(serde_json::json!({"cmd": "attach-surface", "surface": surface, "cols": cols, "rows": ROWS}));
        view.send(serde_json::json!({
            "cmd": "set-client-sizing", "surface": surface, "enabled": true, "exclusive": true,
        }));
        view
    }

    fn send(&mut self, mut value: serde_json::Value) -> serde_json::Value {
        let id = self.next_id;
        self.next_id += 1;
        value["id"] = serde_json::json!(id);
        writeln!(self.writer, "{value}").unwrap();
        loop {
            let mut line = String::new();
            self.reader.read_line(&mut line).unwrap();
            let response: serde_json::Value = serde_json::from_str(&line).unwrap();
            if response["id"] == serde_json::json!(id) {
                assert_eq!(response["ok"], true, "request failed: {response}");
                return response["data"].clone();
            }
            assert!(response["event"].is_string(), "unexpected control message: {response}");
        }
    }

    fn resize(&mut self, surface: u64, cols: u16) {
        self.send(serde_json::json!({"cmd": "resize-surface", "surface": surface, "cols": cols, "rows": ROWS}));
    }
}

fn screen(path: &Path, surface: u64) -> String {
    request(path, serde_json::json!({"cmd": "read-screen", "surface": surface}))["text"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn wait_for_prompt(path: &Path, surface: u64, within: Duration) -> Result<String, String> {
    let deadline = Instant::now() + within;
    let mut last = String::new();
    while Instant::now() < deadline {
        last = screen(path, surface);
        if last.contains(SHOWN) {
            return Ok(last);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(last)
}

/// The daemon's own screen at `cols` columns: its terminal applied the size the host published.
fn wait_for_daemon_cols(path: &Path, surface: u64, cols: u16) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let state = request(path, serde_json::json!({"cmd": "vt-state", "surface": surface}));
        if state["cols"].as_u64() == Some(u64::from(cols))
            && state["rows"].as_u64() == Some(u64::from(ROWS))
        {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the daemon's screen did not resize to {cols}x{ROWS}: {state}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// The screen stops changing for `quiet` (the shell finished drawing its prompt and its integration's reports).
fn wait_for_quiet(path: &Path, surface: u64, quiet: Duration) {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = screen(path, surface);
    let mut since = Instant::now();
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
        let now = screen(path, surface);
        if now != last {
            last = now;
            since = Instant::now();
        } else if since.elapsed() >= quiet {
            return;
        }
    }
}

fn wait_for_stopped(pid: libc::pid_t) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let stat =
            Command::new("ps").args(["-o", "stat=", "-p", &pid.to_string()]).output().unwrap();
        if String::from_utf8_lossy(&stat.stdout).trim_start().starts_with('T') {
            return;
        }
        assert!(Instant::now() < deadline, "the shell {pid} did not stop");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_prompt_survives_a_size_bounce_its_shell_never_sees() {
    if !Path::new(ZSH).exists() {
        eprintln!("FRESH-PROMPT-SKIP: no {ZSH} on this host");
        return;
    }
    let daemon = Daemon::start("bounce");
    request(
        &daemon.socket,
        serde_json::json!({"cmd": "new-workspace", "name": "fresh", "cols": 34, "rows": ROWS}),
    );
    let tree = request(&daemon.socket, serde_json::json!({"cmd": "list-workspaces"}));
    let surface = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == "fresh")
        .and_then(|workspace| {
            workspace["screens"]
                .as_array()?
                .iter()
                .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
                .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
                .find_map(|tab| tab["surface"].as_u64())
        })
        .unwrap_or_else(|| panic!("list-workspaces has no terminal in the new workspace: {tree}"));

    let first = wait_for_prompt(&daemon.socket, surface, Duration::from_secs(20)).unwrap_or_else(
        |screen| panic!("zsh never drew its prompt {PROMPT:?}; the screen was:\n{screen}"),
    );
    let mut view = View::open(&daemon.socket, surface, 34);
    wait_for_daemon_cols(&daemon.socket, surface, 34);
    daemon.wait_for_host_size(34);
    wait_for_quiet(&daemon.socket, surface, Duration::from_millis(400));
    let (shell, _) = daemon.host_child_and_size().expect("the terminal host and its shell");

    // zsh drew its prompt at 34 columns. Stop it, so the two SIGWINCHes of the bounce reach it as one.
    // SAFETY: the pid is this test's own terminal shell; `Stopped` resumes it on every path.
    assert_eq!(unsafe { libc::kill(shell, libc::SIGSTOP) }, 0, "SIGSTOP the shell {shell}");
    let stopped = Stopped(shell);
    wait_for_stopped(shell);

    view.resize(surface, 35);
    wait_for_daemon_cols(&daemon.socket, surface, 35);
    daemon.wait_for_host_size(35);
    view.resize(surface, 34);
    wait_for_daemon_cols(&daemon.socket, surface, 34);
    daemon.wait_for_host_size(34);
    drop(stopped);

    // zsh reads 34 columns, the size it drew at: from its side nothing changed, and it draws nothing.
    if let Err(shown) = wait_for_prompt(&daemon.socket, surface, Duration::from_secs(3)) {
        panic!(
            "after the size went 34 -> 35 -> 34 while zsh could not answer, the daemon's screen lost the prompt \
             {PROMPT:?} (the terminal cleared it for a redraw zsh never drew).\nbefore:\n{first}\nafter:\n{shown}"
        );
    }
}
