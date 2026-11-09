//! A late OSC 10/11 color reply from the host terminal is never typed into a
//! pane (W5-Q, bench round 4 screen friction 4).
//!
//! At start the client asks its host terminal for the default colors
//! (`host_colors.rs`) and waits a short time. A host that answers later
//! (a loaded machine, a slow link) sent the reply into the client's normal
//! input. The input parser read `ESC ]` as Alt+] and the rest as typed text,
//! so the first pane's shell showed `10;rgb:...` as input and rang the bell
//! (a false `Bell` unread).
//!
//! The test attaches the real client on a pty, waits until it reads input,
//! then writes both reply forms (ST and BEL terminated) as the host would,
//! followed by a typed command. The command's output proves the input
//! reached the shell; the reply text must not.

#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const DEADLINE: Duration = Duration::from_secs(45);
/// The last input mode the client enables before it reads input.
const INPUT_MODES_ENABLED: &[u8] = b"\x1b[?2004h";
/// The host's late answers to `ESC]10;? ST ESC]11;? ST`, one with each
/// terminator.
const LATE_REPLIES: &[u8] = b"\x1b]10;rgb:fdfd/ffff/f1f1\x1b\\\x1b]11;rgb:2727/2828/2222\x07";

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    session: String,
}

impl Fixture {
    fn new(session: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-hc-{}-{stamp}", std::process::id()));
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

    /// One legacy socket request; `None` while no daemon answers.
    fn request(&self, request: Value) -> Option<Value> {
        let stream = UnixStream::connect(&self.socket).ok()?;
        stream.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
        let mut stream = BufReader::new(stream);
        writeln!(stream.get_mut(), "{request}").ok()?;
        loop {
            let mut line = String::new();
            if stream.read_line(&mut line).ok()? == 0 {
                return None;
            }
            let reply: Value = serde_json::from_str(&line).ok()?;
            if reply["id"] == request["id"] {
                return Some(reply["data"].clone());
            }
        }
    }

    fn has_tui_client(&self) -> bool {
        let Some(data) = self.request(json!({"id": 1, "cmd": "list-clients"})) else {
            return false;
        };
        data.as_array()
            .or_else(|| data["clients"].as_array())
            .is_some_and(|clients| clients.iter().any(|client| client["kind"] == "tui"))
    }

    /// The surface of the first tab of the first workspace.
    fn first_surface(&self) -> Option<u64> {
        let tree = self.request(json!({"id": 2, "cmd": "list-workspaces"}))?;
        tree["workspaces"]
            .as_array()?
            .iter()
            .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
            .find_map(|tab| tab["surface"].as_u64())
    }

    fn screen(&self, surface: u64) -> String {
        self.request(json!({"id": 3, "cmd": "read-screen", "surface": surface}))
            .and_then(|data| data["text"].as_str().map(str::to_owned))
            .unwrap_or_default()
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
    child: Child,
    output: Arc<Mutex<Vec<u8>>>,
    stderr: PathBuf,
    master: File,
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
        Self { child, output, stderr, master }
    }

    fn printed(&self, needle: &[u8]) -> bool {
        self.output.lock().unwrap().windows(needle.len()).any(|window| window == needle)
    }

    /// The last bytes the client drew, for a failure message.
    fn output_tail(&self) -> String {
        let output = self.output.lock().unwrap();
        let start = output.len().saturating_sub(2000);
        String::from_utf8_lossy(output.get(start..).unwrap_or_default()).into_owned()
    }

    fn stderr(&self) -> String {
        String::from_utf8_lossy(&fs::read(&self.stderr).unwrap_or_default()).into_owned()
    }

    /// Writes `bytes` as the host terminal would: one write, so the client
    /// reads them together, as it reads a real host's reply.
    fn host_writes(&mut self, bytes: &[u8]) {
        self.master.write_all(bytes).unwrap();
        self.master.flush().unwrap();
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn wait_for(what: &str, client: &Client, ready: impl FnMut() -> bool) {
    wait_showing(what, client, ready, String::new);
}

/// [`wait_for`] whose failure message also shows `shown()` (the pane's
/// screen) and the end of what the client drew.
fn wait_showing(
    what: &str,
    client: &Client,
    mut ready: impl FnMut() -> bool,
    shown: impl Fn() -> String,
) {
    let deadline = Instant::now() + DEADLINE;
    while !ready() {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for {what}\npane screen:\n{}\nclient stderr:\n{}\nclient output \
             (last 2000 bytes):\n{:?}",
            shown(),
            client.stderr(),
            client.output_tail()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[test]
fn w5q_tui_never_types_a_late_host_color_reply_into_a_pane() {
    let fixture = Fixture::new("host-color-replies");
    fixture.server("ensure", &[]);
    let mut client = Client::start(&fixture);
    wait_for("the client to take the terminal", &client, || client.printed(INPUT_MODES_ENABLED));
    wait_for("the client to attach", &client, || fixture.has_tui_client());
    let mut surface = None;
    wait_for("the first pane", &client, || {
        surface = fixture.first_surface();
        surface.is_some()
    });
    let surface = surface.unwrap_or_default();

    // The late replies, then Enter: a reply typed as input would run as a
    // command line here, and its text would stay on the screen.
    client.host_writes(LATE_REPLIES);
    client.host_writes(b"\r");
    // Typed input still reaches the shell: the arithmetic proves the line
    // ran, since the echoed command line has no `42`.
    client.host_writes(b"echo w5q-$((40+2))\r");
    wait_showing(
        "the typed command to run",
        &client,
        || fixture.screen(surface).contains("w5q-42"),
        || fixture.screen(surface),
    );
    let screen = fixture.screen(surface);
    for leaked in ["rgb:", "fdfd", "2727", "10;", "11;"] {
        assert!(
            !screen.contains(leaked),
            "the host's color reply reached the pane as typed input ({leaked:?}):\n{screen}"
        );
    }
}

/// W5-Q review (PR B finding 3): keys typed right after Alt+], in the same
/// read, reach the pane: `cat -v` in the pane shows each one. The client once
/// waited for an OSC reply's end after `ESC ]` and then dropped the rest of
/// the read (`a`, the Up key, a repeated Alt+], a typed `12`). Alt+] is the
/// default `next-screen` key, so the client takes each Alt+] itself (one
/// screen here: nothing moves) and the pane gets only the keys after it; a
/// repeated Alt+] read as Alt+] and a plain `]` would show a `]`.
#[test]
fn w5q_tui_types_every_key_after_alt_right_bracket() {
    let fixture = Fixture::new("alt-right-bracket");
    fixture.server("ensure", &[]);
    let mut client = Client::start(&fixture);
    wait_for("the client to take the terminal", &client, || client.printed(INPUT_MODES_ENABLED));
    wait_for("the client to attach", &client, || fixture.has_tui_client());
    let mut surface = None;
    wait_for("the first pane", &client, || {
        surface = fixture.first_surface();
        surface.is_some()
    });
    let surface = surface.unwrap_or_default();
    // No echo: a raw `ESC ]` echoed to the pane's screen would start an OSC
    // there. `cat -v` prints each line it reads with `^[` for ESC.
    // `cat-ready` shows only once `stty -echo` ran (the echoed line has `cat%s`).
    client.host_writes(b"stty -echo; printf 'cat%s\\n' -ready; exec cat -v\r");
    wait_showing(
        "cat -v to run",
        &client,
        || fixture.screen(surface).contains("cat-ready"),
        || fixture.screen(surface),
    );
    // Each case is one write, so the client reads it in one read.
    let cases: [(&[u8], &str); 4] = [
        (b"k1:\x1b]a\r", "k1:a"),
        (b"k2:\x1b]\x1b[A\r", "k2:^[[A"),
        (b"k3:\x1b]\x1b]\x1b]\r", "k3:"),
        (b"k4:\x1b]12x\r", "k4:12x"),
    ];
    for (typed, _) in cases {
        client.host_writes(typed);
    }
    client.host_writes(b"k5:end\r");
    wait_showing(
        "the typed lines to reach cat",
        &client,
        || fixture.screen(surface).contains("k5:end"),
        || fixture.screen(surface),
    );
    let screen = fixture.screen(surface);
    for (typed, shown) in cases {
        assert!(
            screen.lines().any(|line| line.trim_end() == shown),
            "{typed:?} did not reach the pane as {shown:?}:\n{screen}"
        );
    }
}

/// A close-on-exec pty pair of 100x30 cells: the client gets the slave, the
/// test the master. A pty opened without a size is 0x0, and the client then
/// lays out no pane cells, so nothing typed shows on a pane's screen.
fn open_pty() -> (File, OwnedFd) {
    let mut master: libc::c_int = -1;
    let mut slave: libc::c_int = -1;
    let mut size = libc::winsize { ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: `openpty` writes two descriptors into the out params on success
    // and only reads `size`.
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &raw mut size,
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
