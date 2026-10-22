//! Prepared terminals (new-terminal-100x): after a new tab, the daemon keeps
//! a spare terminal host whose PTY and shell launcher already run for the
//! same launch (directory, command, environment). The next new tab there
//! takes it: the launcher receives the tab's own ids through the PTY at
//! handout and starts the shell with them. A prepared shell never outlives
//! its daemon.

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

fn temp_dir() -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    PathBuf::from("/tmp").join(format!("cmux-prepared-{}-{stamp}", std::process::id()))
}

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    fn call(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.writer, "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the socket");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == json!(self.next) && reply.get("ok").is_some() {
                assert_eq!(reply["ok"], true, "{request} failed: {reply}");
                return reply["data"].clone();
            }
        }
    }
}

struct Daemon {
    dir: PathBuf,
    child: Child,
    client: Client,
    pane: Value,
    spans: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn start_daemon() -> Daemon {
    let dir = temp_dir();
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let spans = dir.join("spans.jsonl");
    // The daemon's own shell is every new tab's command (no frontend client
    // names one): a script that prints its surface id, then waits.
    let shell = id_shell(&dir);
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_DEBUG_SPANS", &spans)
        .env("SHELL", &shell)
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(60);
    let stream = loop {
        if let Ok(stream) = UnixStream::connect(&socket) {
            break stream;
        }
        assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
        std::thread::sleep(Duration::from_millis(25));
    };
    stream.set_read_timeout(Some(Duration::from_secs(120))).unwrap();
    let mut client =
        Client { writer: stream.try_clone().unwrap(), reader: BufReader::new(stream), next: 0 };
    let base = client.call(json!({"cmd": "new-workspace", "name": "base", "cols": 80, "rows": 24}));
    let tree = client.call(json!({"cmd": "list-workspaces"}));
    let pane = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|ws| ws["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .find(|pane| {
            pane["tabs"].as_array().into_iter().flatten().any(|tab| {
                tab == &base["surface"]
                    || tab["id"] == base["surface"]
                    || tab["surface"] == base["surface"]
            })
        })
        .map(|pane| pane["id"].clone())
        .unwrap_or_else(|| panic!("no pane holds the base surface: {tree}"));
    Daemon { dir, child, client, pane, spans }
}

/// A shell script that prints its own surface id, then waits.
fn id_shell(dir: &Path) -> PathBuf {
    let shell = dir.join("id-shell");
    fs::write(&shell, "#!/bin/sh\nprintf 'id=%s;' \"$CMUX_SURFACE_ID\"\nexec sleep 600\n").unwrap();
    fs::set_permissions(&shell, fs::Permissions::from_mode(0o755)).unwrap();
    shell
}

/// Launchers of prepared shells for `shell` that still run (test-side
/// observation only).
fn prepared_launchers(shell: &Path) -> usize {
    let output = Command::new("pgrep")
        .args(["-f", &format!("__shell-handoff.*{}", shell.display())])
        .output()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).lines().count()
}

/// What the daemon and its hosts logged about prepared shells: span marks
/// that name a spare or a prepare, and every `prepare-errors.log`.
fn prepare_diagnostics(daemon: &Daemon) -> String {
    let mut out = String::new();
    for line in fs::read_to_string(&daemon.spans).unwrap_or_default().lines() {
        if line.contains("prepare") || line.contains("spare.") {
            out.push_str(line);
            out.push('\n');
        }
    }
    let mut dirs = vec![daemon.dir.join("state")];
    while let Some(dir) = dirs.pop() {
        for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.is_dir() {
                dirs.push(path);
            } else if path.file_name().is_some_and(|name| name == "prepare-errors.log") {
                out.push_str(&format!(
                    "{}:\n{}",
                    path.display(),
                    fs::read_to_string(&path).unwrap_or_default()
                ));
            }
        }
    }
    out
}

fn wait_for(what: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn wait_until_prepared(daemon: &Daemon, shell: &Path) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while prepared_launchers(shell) == 0 {
        assert!(
            Instant::now() < deadline,
            "no prepared shell for the tab's launch; the daemon and hosts logged:\n{}",
            prepare_diagnostics(daemon)
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn terminal_id(serial: u64) -> String {
    format!("{:08x}00004000800{:013x}", std::process::id(), serial)
}

fn surface_id(terminal: &str) -> String {
    format!(
        "{}-{}-{}-{}-{}",
        &terminal[..8],
        &terminal[8..12],
        &terminal[12..16],
        &terminal[16..20],
        &terminal[20..]
    )
    .to_uppercase()
}

fn new_tab(daemon: &mut Daemon, cwd: &Path, shell: &Path, terminal: &str) -> Value {
    let pane = daemon.pane.clone();
    daemon.client.call(json!({"cmd": "new-tab", "pane": pane, "terminal_id": terminal,
        "cwd": cwd.display().to_string(), "cols": 80, "rows": 24,
        "env": {"SHELL": shell.display().to_string(), "CMUX_SURFACE_ID": surface_id(terminal)}}))
}

#[test]
fn a_new_tab_where_one_ran_takes_a_prepared_shell_that_gets_its_own_ids() {
    let mut daemon = start_daemon();
    let work = daemon.dir.join("work");
    fs::create_dir_all(&work).unwrap();
    let shell = daemon.dir.join("id-shell");

    let first = terminal_id(0x200);
    new_tab(&mut daemon, &work, &shell, &first);
    wait_until_prepared(&daemon, &shell);

    let second = terminal_id(0x201);
    let created = new_tab(&mut daemon, &work, &shell, &second);
    let surface = created["surface"].clone();
    let expected = format!("id={};", surface_id(&second));
    let mut screen = String::new();
    wait_for("the second tab's shell output", || {
        screen = daemon.client.call(json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        screen.contains("id=")
    });
    assert!(screen.contains(&expected), "the shell did not get its own surface id: {screen:?}");

    let spans = fs::read_to_string(&daemon.spans).unwrap_or_default();
    let handed_off = spans
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .filter(|trace| trace["label"] == "host" && trace["terminal"] == second.as_str())
        .any(|trace| {
            trace["marks"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|mark| mark[0] == "host.prepared_handed_off")
        });
    assert!(
        handed_off,
        "the second tab launched its shell cold instead of taking the prepared one"
    );
}

#[test]
fn prepared_shells_end_with_their_daemon() {
    let mut daemon = start_daemon();
    let work = daemon.dir.join("work");
    fs::create_dir_all(&work).unwrap();
    let shell = daemon.dir.join("id-shell");
    new_tab(&mut daemon, &work, &shell, &terminal_id(0x300));
    wait_until_prepared(&daemon, &shell);

    // The daemon dies without a word; its spares must not outlive it.
    let _ = daemon.child.kill();
    let _ = daemon.child.wait();
    wait_for("the prepared shells to end", || prepared_launchers(&shell) == 0);
}
