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
//!
//! Run them with `--workspace` and `CMUX_REQUIRE_HOLDER_FIXTURES=1` (the
//! fleet run each agent does itself): the daemon starts the standalone
//! `cmux-holder` from beside its own executable, and only a workspace run
//! builds it (and the `cmux-holder-v3` fixture) there. A package-scoped run
//! (`cargo test -p cmux-tui`) runs these tests on the holder built into
//! `cmux-tui` instead and skips the older-holder adoption test; with the
//! variable set, a missing fixture fails instead. A `cmux-holder` an earlier
//! workspace run left there that is older than its sources (or speaks
//! another wire range) always fails: the run would test an old holder.

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
    /// Extra daemon arguments, kept for every restart.
    args: Vec<String>,
    /// Extra daemon environment for the next restarts.
    env: Vec<(String, String)>,
    dir: PathBuf,
    socket: PathBuf,
    /// Holder and shell pids this test made, ended at drop: a holder
    /// outlives every daemon on purpose.
    cleanup: Vec<i32>,
}

impl Daemon {
    fn start() -> Self {
        Self::start_with(&[])
    }

    fn start_with_env(env: &[(&str, &Path)]) -> Self {
        Self::start_with_args_env(&[], env)
    }

    fn start_with(args: &[&str]) -> Self {
        Self::start_with_args_env(args, &[])
    }

    fn start_with_args_env(args: &[&str], env: &[(&str, &Path)]) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!(
            "cmux-holder-{}-{}",
            std::process::id(),
            stamp % 1_000_000_000
        ));
        fs::create_dir_all(&dir).unwrap();
        let mut daemon = Self {
            child: None,
            args: args.iter().map(ToString::to_string).collect(),
            env: env
                .iter()
                .map(|(key, value)| (key.to_string(), value.to_string_lossy().into_owned()))
                .collect(),
            socket: dir.join("mux.sock"),
            dir,
            cleanup: Vec::new(),
        };
        daemon.restart();
        daemon
    }

    fn restart(&mut self) {
        standalone_holder_is_current();
        let _ = fs::remove_file(&self.socket);
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--session", "holder-test", "--socket"])
            .arg(&self.socket)
            .arg("--state")
            .arg(self.dir.join("state"))
            .args(&self.args)
            .env("CMUX_TUI_CONFIG", self.dir.join("config.json"))
            .env("CMUX_TUI_TERMINAL_HOST_MODEL", "holder")
            .envs(self.env.iter().map(|(key, value)| (key.as_str(), value.as_str())))
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

    /// End `surface`'s shell and its holder when the test ends, whatever
    /// step fails: a holder outlives every daemon on purpose.
    fn track(&mut self, surface: u64) {
        let shell = shell_pid(&self.socket, surface);
        self.cleanup.push(shell);
        let holder = parent_of(shell);
        if holder > 1 && !self.cleanup.contains(&holder) {
            self.cleanup.push(holder);
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
        // Owned by the test from here: a failing step still ends them.
        daemon.track(surface);
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
    let holder = parent_of(shells[0]);
    assert!(holder > 1, "the shell's parent is the holder");

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
    let probe_surface = probe["surface"].as_u64().unwrap();
    daemon.track(probe_surface);
    let new_holder = parent_of(shell_pid(&daemon.socket, probe_surface));
    assert!(new_holder > 1 && new_holder != holder, "a new holder runs the new terminal");

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

/// The daemon holds the custody master of every holder terminal for its
/// whole life; a shell that exits must still end its terminal, with its
/// own status.
#[test]
fn a_holder_shell_that_exits_ends_its_terminal_with_its_status() {
    let mut daemon = Daemon::start();
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/sh", "-c", "read line; echo bye-$line; exit 3"],
            "new_workspace": true, "name": "exit-3", "cols": 80, "rows": 24}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    daemon.track(surface);
    send(&daemon.socket, surface, "now");
    let deadline = Instant::now() + Duration::from_secs(20);
    let resolved = loop {
        let resolved =
            request(&daemon.socket, json!({"cmd": "resolve-terminal", "terminal_id": terminal_id}));
        if resolved["lifecycle"] == "exited" {
            break resolved;
        }
        assert!(Instant::now() < deadline, "the terminal never ended: {resolved}");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(resolved["exit"]["outcome"], json!({"kind": "exit", "code": 3}), "{resolved}");
}

/// A standalone holder that runs but never says `ready` (a startup error,
/// a crash in serve, a macOS major it fails on) must not cost every holder
/// terminal: the daemon starts the holder built into its host executable
/// instead, and keeps using that one.
#[test]
fn a_standalone_holder_that_never_starts_falls_back_to_the_built_in_holder() {
    let daemon = Daemon::start_with_env(&[("CMUX_TUI_HOLDER_EXE", Path::new("/usr/bin/false"))]);
    falls_back_to_the_built_in_holder(daemon, "false");
}

/// Review 2 of holder items 1-3: a standalone holder that hangs before it
/// says `ready` and never exits (a stall in its setup or its first exec)
/// must not block every terminal create for ever under the daemon's
/// connecting lock: the daemon gives up after its ready timeout, kills it
/// and falls back to the built-in holder.
#[test]
fn a_standalone_holder_that_hangs_before_ready_falls_back_to_the_built_in_holder() {
    let stand_in = std::env::temp_dir().join(format!("cmux-hung-holder-{}", std::process::id()));
    fs::write(&stand_in, "#!/bin/sh\nexec sleep 3600\n").unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&stand_in, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let daemon = Daemon::start_with_env(&[("CMUX_TUI_HOLDER_EXE", stand_in.as_path())]);
    let started = Instant::now();
    falls_back_to_the_built_in_holder(daemon, "sleep");
    assert!(
        started.elapsed() < cmux_holder::client::READY_TIMEOUT + Duration::from_secs(20),
        "the creates waited far past the ready timeout: {:?}",
        started.elapsed()
    );
    let _ = fs::remove_file(&stand_in);
}

/// Two terminals start and take input, on a holder that is not the
/// stand-in `stand_in_name` that never started.
fn falls_back_to_the_built_in_holder(mut daemon: Daemon, stand_in_name: &str) {
    for index in 0..2 {
        let created = request(
            &daemon.socket,
            json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
                "name": format!("fallback-{index}"), "cols": 80, "rows": 24}),
        );
        let surface = created["surface"].as_u64().unwrap();
        daemon.track(surface);
        send(&daemon.socket, surface, &format!("built-in-{index}"));
        screen_contains(&daemon.socket, surface, &format!("built-in-{index}"));
        let holder = parent_of(shell_pid(&daemon.socket, surface));
        assert_ne!(exe_name(holder), stand_in_name, "the shell runs on a holder");
    }
}

/// Review 2: closing a tab right after the holder died must not connect,
/// start a holder or re-adopt under the surface's runtime lock (a lock rank
/// panic in a debug daemon, a deadlock against a resize in release). The
/// close answers, the other terminal keeps working on the new holder, and
/// the closed shell ends.
#[test]
fn a_tab_closed_right_after_a_holder_crash_ends_without_a_lock_rank_panic() {
    // Reap at once, as the app's close does after its grace: the reaper
    // ends the closed tab's terminal under its surface's runtime lock.
    let mut daemon = Daemon::start_with(&["--terminal-reap-grace-seconds", "0"]);
    let mut surfaces = Vec::new();
    for index in 0..2 {
        let created = request(
            &daemon.socket,
            json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
                "name": format!("close-{index}"), "cols": 80, "rows": 24}),
        );
        let surface = created["surface"].as_u64().unwrap();
        daemon.track(surface);
        send(&daemon.socket, surface, &format!("ready-{index}"));
        screen_contains(&daemon.socket, surface, &format!("ready-{index}"));
        surfaces.push(surface);
    }
    let closed_shell = shell_pid(&daemon.socket, surfaces[0]);
    let holder = parent_of(closed_shell);
    // SAFETY: SIGKILL of the holder this test's daemon started.
    unsafe { libc::kill(holder, libc::SIGKILL) };
    request(&daemon.socket, json!({"cmd": "close-surface", "surface": surfaces[0]}));
    let deadline = Instant::now() + Duration::from_secs(20);
    while alive(closed_shell) {
        assert!(Instant::now() < deadline, "the closed tab's shell kept running");
        std::thread::sleep(Duration::from_millis(50));
    }
    send(&daemon.socket, surfaces[1], "after-close");
    screen_contains(&daemon.socket, surfaces[1], "after-close");
    // A new terminal's shell is the new holder's child: track it so the
    // test ends that holder too.
    let probe = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true, "name": "probe", "cols": 80, "rows": 24}),
    );
    daemon.track(probe["surface"].as_u64().unwrap());
}

/// Review 2: a daemon restart restores a terminal's modes and screen even
/// after it printed more than the holder's 1 MiB ring: the holder keeps the
/// daemon's newest screen snapshot as the terminal's prologue. The program
/// enters the alternate screen, draws a mark, then prints 2 MiB that never
/// touch the mark's row.
#[test]
fn a_restart_after_two_mib_of_output_keeps_the_alternate_screen() {
    let mut daemon = Daemon::start();
    let script = r#"printf '[?1049h[1;1HALT-MARK'; yes "$(printf '[5;1H')bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | head -c 2200000; printf '[6;1Hflood-done'; exec cat"#;
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/sh", "-c", script], "new_workspace": true,
            "name": "alt-screen", "cols": 80, "rows": 24}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    daemon.track(surface);
    let screen = screen_contains(&daemon.socket, surface, "flood-done");
    assert!(
        screen.contains("ALT-MARK"),
        "the mark is not on the screen:
{screen}"
    );
    // An echo after the flood: the reader went idle once and handed the
    // holder its snapshot before it read this.
    send(&daemon.socket, surface, "synced");
    screen_contains(&daemon.socket, surface, "synced");

    daemon.sigkill();
    daemon.restart();
    let surface = running_surface(&daemon.socket, &terminal_id);
    let screen = screen_contains(&daemon.socket, surface, "flood-done");
    assert!(
        screen.contains("ALT-MARK"),
        "the restart lost the alternate screen set before the ring's oldest byte:
{screen}"
    );
}

/// The replay race at a holder crash (perf lead, holder item 1): a holder
/// that dies while it holds output the daemon has not parsed must lose no
/// byte, and a restart after it must restore the exact screen, also when
/// the holder dies inside an escape sequence or a UTF-8 character.
///
/// The program waits behind a gate file. The daemon is stopped (SIGSTOP),
/// the gate opens and the program prints [`FLOOD_LINES`] numbered colored
/// lines: with nobody reading its link, the holder takes one credit window
/// and reads the rest into its ring. The holder is then SIGKILLed and the
/// daemon continued: every line, the last included, must reach the screen
/// in order. Then the program stops in the middle of an SGR sequence, and
/// later in the middle of `é`, and the holder is SIGKILLed at each stop.
/// The live history and screen must be exact, and a daemon restart must
/// show the same screen and the same styled history rows.
#[test]
fn a_holder_killed_holding_unparsed_output_or_mid_sequence_loses_no_byte() {
    let mut daemon = Daemon::start();
    let gate = daemon.dir.join("gate");
    let tty = daemon.dir.join("tty");
    let flooded = daemon.dir.join("flooded");
    let flood = daemon.dir.join("flood.txt");
    let script = daemon.dir.join("flood.sh");
    let mut lines = String::new();
    for number in 0..FLOOD_LINES {
        lines
            .push_str(&format!("\x1b[3{}mline {number:06} é {FLOOD_LETTERS}\x1b[0m\n", number % 8));
    }
    fs::write(&flood, lines).unwrap();
    fs::write(
        &script,
        format!(
            r#"stty -echo
tty > '{tty}'
printf 'ready\n'
while [ ! -e '{gate}' ]; do sleep 0.05; done
cat '{flood}'
printf 'flood-end\n'
printf 'X\033[38;5;1'
: > '{flooded}'
read a
printf '96mRED\303'
read b
printf '\251 END\033[0m\n'
i=0
while [ $i -lt 30 ]; do printf 'tail %02d\n' "$i"; i=$((i + 1)); done
exec sleep 3600
"#,
            gate = gate.display(),
            tty = tty.display(),
            flooded = flooded.display(),
            flood = flood.display(),
        ),
    )
    .unwrap();
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/sh", script.to_str().unwrap()], "new_workspace": true,
            "name": "replay-race", "cols": 80, "rows": 24}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    daemon.track(surface);
    let shell = shell_pid(&daemon.socket, surface);
    let holder = parent_of(shell);
    screen_contains(&daemon.socket, surface, "ready");

    // The daemon stops reading its link; then the flood starts. The holder
    // sends one credit window (into the socket and its queue) and reads the
    // rest of the PTY's output into its ring: nobody has parsed it.
    let daemon_pid = daemon.child.as_ref().unwrap().id() as i32;
    // SAFETY: SIGSTOP of the daemon this test started.
    unsafe { libc::kill(daemon_pid, libc::SIGSTOP) };
    let read_before = holder_read_bytes(holder);
    fs::write(&gate, b"").unwrap();
    // What the program prints after the gate, as the PTY passes it (ONLCR
    // makes each `\n` a `\r\n`).
    let printed = fs::metadata(&flood).unwrap().len()
        + FLOOD_LINES
        + b"flood-end\r\nX\x1b[38;5;1".len() as u64;
    holder_read_everything(&flooded, &tty, (holder, read_before, printed));
    // SAFETY: SIGKILL of the holder this test's daemon started.
    unsafe { libc::kill(holder, libc::SIGKILL) };
    // SAFETY: SIGCONT of the daemon this test stopped.
    unsafe { libc::kill(daemon_pid, libc::SIGCONT) };

    // `X` comes in the write that ends inside `ESC [ 38;5;1`: once it shows,
    // the parser is inside that sequence, and the program waits for a line.
    screen_contains(&daemon.socket, surface, "flood-end\nX");
    let second = probe_holder(&mut daemon, "probe-2");
    // SAFETY: SIGKILL of the holder this test's daemon started.
    unsafe { libc::kill(second, libc::SIGKILL) };
    request(&daemon.socket, json!({"cmd": "send", "surface": surface, "text": "go\n"}));
    // Now it waits inside the two bytes of `é`: the third holder dies there.
    screen_contains(&daemon.socket, surface, "XRED");
    let third = probe_holder(&mut daemon, "probe-3");
    assert_ne!(third, second, "a new holder took over after the second one died");
    // SAFETY: SIGKILL of the holder this test's daemon started.
    unsafe { libc::kill(third, libc::SIGKILL) };
    request(&daemon.socket, json!({"cmd": "send", "surface": surface, "text": "go\n"}));
    let live_screen = screen_contains(&daemon.socket, surface, "tail 29");
    // The fourth holder runs the terminals from here; it ends with the test.
    let fourth = probe_holder(&mut daemon, "probe-4");
    assert_ne!(fourth, third, "a new holder took over after the third one died");

    let live = history(&daemon.socket, surface);
    let flood = flood_rows(&live);
    assert_eq!(
        flood.last().copied(),
        Some(FLOOD_LINES - 1),
        "the flood's last lines never arrived:\n{}",
        dump(&live)
    );
    assert!(flood.len() > 100, "too little flood history kept: {} rows", flood.len());
    let red = live
        .iter()
        .position(|row| row_text(row) == "XREDé END")
        .unwrap_or_else(|| panic!("no exact `XREDé END` row in the history:\n{}", dump(&live)));
    let runs = content_runs(&live[red]);
    assert_eq!(runs.len(), 2, "X then the red text: {}", live[red]);
    assert_eq!(runs[1]["text"], "REDé END");
    assert_ne!(runs[1]["fg"], runs[0]["fg"], "the split SGR colored the text: {}", live[red]);
    assert!(live_screen.contains("tail 29") && !live_screen.contains("96m"), "{live_screen}");

    // A restart restores the same screen and the same styled rows.
    daemon.sigkill();
    daemon.restart();
    let restored_surface = running_surface(&daemon.socket, &terminal_id);
    let restored_screen = screen_contains(&daemon.socket, restored_surface, "tail 29");
    assert_eq!(restored_screen, live_screen, "the restart changed the screen");
    let restored = history(&daemon.socket, restored_surface);
    assert!(
        restored.iter().any(|row| row_text(row) == "XREDé END"),
        "the restart lost the red row:\n{}",
        dump(&restored)
    );
    let tail = &live[live.len() - restored.len().min(live.len())..];
    for (index, (want, got)) in tail.iter().zip(&restored).enumerate() {
        assert_eq!(got["runs"], want["runs"], "restored history row {index} differs");
    }
}

/// Wait until the replay-race program wrote its whole flood and the holder
/// read every byte of it from the PTY into its ring: the program created
/// `flooded` after its last write, and the holder read it all. On macOS a
/// pty's output queue holds what the master has not read yet, so it reads
/// empty then. On Linux the bytes move to the master's side at once and
/// that queue always reads empty: there the holder's own read count
/// (`rchar` in `/proc/<pid>/io`, while the daemon is stopped and sends it
/// nothing) must have grown by every byte the program `printed` since
/// `read_before`.
fn holder_read_everything(flooded: &Path, tty: &Path, holder_read: (i32, u64, u64)) {
    #[cfg(target_vendor = "apple")]
    let _ = holder_read;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;
    #[cfg(target_vendor = "apple")]
    const TIOCOUTQ: libc::c_ulong = 0x4004_7473; // _IOR('t', 115, int), <sys/ttycom.h>
    #[cfg(not(target_vendor = "apple"))]
    const TIOCOUTQ: libc::Ioctl = libc::TIOCOUTQ;
    let path = fs::read_to_string(tty).expect("the program wrote its tty");
    let slave = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOCTTY)
        .open(path.trim())
        .unwrap_or_else(|error| panic!("open the program's tty {}: {error}", path.trim()));
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let mut queued: libc::c_int = -1;
        // SAFETY: TIOCOUTQ writes one int into a live local.
        let asked = unsafe { libc::ioctl(slave.as_raw_fd(), TIOCOUTQ, &raw mut queued) };
        assert_eq!(asked, 0, "TIOCOUTQ: {}", std::io::Error::last_os_error());
        #[cfg(not(target_vendor = "apple"))]
        {
            let (holder, read_before, printed) = holder_read;
            let read = holder_read_bytes(holder).saturating_sub(read_before);
            if read < printed {
                // Still on the master's side: count it as queued.
                queued = queued.max(i32::try_from(printed - read).unwrap_or(i32::MAX));
            }
        }
        if flooded.exists() && queued == 0 {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "the holder never read the whole flood ({queued} bytes still in the PTY): \
             FLOOD_LINES must fit the credit window plus UNSENT_HIGH_WATER"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Bytes `pid` read with read-like calls (Linux `/proc/<pid>/io` `rchar`);
/// 0 where nothing counts them (macOS uses the PTY's output queue).
fn holder_read_bytes(pid: i32) -> u64 {
    if cfg!(target_vendor = "apple") {
        return 0;
    }
    let io = fs::read_to_string(format!("/proc/{pid}/io")).unwrap_or_default();
    io.lines()
        .find_map(|line| line.strip_prefix("rchar:"))
        .and_then(|count| count.trim().parse().ok())
        .unwrap_or(0)
}

/// Lines of the replay-race flood: 75 bytes each plus the CR the PTY adds
/// (ONLCR), 684,000 bytes in all: more than the holder's credit window
/// (524,288), so the holder holds read-but-unsent bytes when it dies, and
/// about 100 KiB less than that window plus its unsent limit (786,432), so
/// it reads the whole flood into its ring; fewer than the history keeps.
const FLOOD_LINES: u64 = 9_000;
const FLOOD_LETTERS: &str = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwx";

/// Holder item 5: clear-history on a holder terminal is not undone by a
/// daemon restart. The restart restores from the holder (its prologue and
/// ring), which still held the cleared history; the daemon now hands the
/// holder the cleared screen as its prologue.
#[test]
fn a_restart_after_clear_history_does_not_bring_the_history_back() {
    let mut daemon = Daemon::start();
    let script = r#"stty -echo; i=0; while [ $i -lt 200 ]; do echo "old-line-$i"; i=$((i + 1)); done; exec cat"#;
    let created = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/sh", "-c", script], "new_workspace": true,
            "name": "clear-history", "cols": 80, "rows": 24}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    daemon.track(surface);
    screen_contains(&daemon.socket, surface, "old-line-199");
    assert!(history(&daemon.socket, surface).iter().any(|row| row_text(row) == "old-line-0"));
    request(&daemon.socket, json!({"cmd": "clear-history", "surface": surface}));
    send(&daemon.socket, surface, "after-clear");
    screen_contains(&daemon.socket, surface, "after-clear");
    let old = |socket: &Path, surface: u64| {
        let screen = request(socket, json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        screen.contains("old-line-")
            || history(socket, surface).iter().any(|row| row_text(row).contains("old-line-"))
    };
    assert!(!old(&daemon.socket, surface), "clear-history kept the old lines");

    daemon.sigkill();
    daemon.restart();
    let restored = running_surface(&daemon.socket, &terminal_id);
    screen_contains(&daemon.socket, restored, "after-clear");
    assert!(!old(&daemon.socket, restored), "the restart brought the cleared history back");
}

/// A new terminal's shell is the current holder's child: its parent is the
/// holder (and the test ends both at drop).
fn probe_holder(daemon: &mut Daemon, name: &str) -> i32 {
    let probe = request(
        &daemon.socket,
        json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true, "name": name,
            "cols": 80, "rows": 24}),
    );
    let surface = probe["surface"].as_u64().unwrap();
    daemon.track(surface);
    parent_of(shell_pid(&daemon.socket, surface))
}

/// Every retained history row of `surface` (styled runs), oldest first.
fn history(socket: &Path, surface: u64) -> Vec<Value> {
    let mut rows = Vec::new();
    let mut start = 0u64;
    loop {
        let page = request(
            socket,
            json!({"cmd": "read-scrollback", "surface": surface, "start": start, "count": 4096}),
        );
        let got = page["rows"].as_array().cloned().unwrap_or_default();
        let total = page["total"].as_u64().unwrap_or(0);
        start = page["start"].as_u64().unwrap_or(start) + got.len() as u64;
        rows.extend(got.clone());
        if got.is_empty() || start >= total {
            return rows;
        }
    }
}

fn row_text(row: &Value) -> String {
    let runs = row["runs"].as_array().cloned().unwrap_or_default();
    let text: String = runs.iter().map(|run| run["text"].as_str().unwrap_or_default()).collect();
    text.trim_end().to_string()
}

/// A row's runs without the blank run that pads it to the full width.
fn content_runs(row: &Value) -> Vec<Value> {
    let mut runs = row["runs"].as_array().cloned().unwrap_or_default();
    while runs.last().is_some_and(|run| {
        run["text"].as_str().is_some_and(|text| text.trim().is_empty()) && run["bg"].is_null()
    }) {
        runs.pop();
    }
    runs
}

fn dump(rows: &[Value]) -> String {
    let from = rows.len().saturating_sub(40);
    rows[from..].iter().map(row_text).collect::<Vec<_>>().join("\n")
}

/// The flood rows of a history: each is exactly `line N é <letters>` in
/// color N % 8, and N counts up by one, with no row missing or cut.
fn flood_rows(rows: &[Value]) -> Vec<u64> {
    let letters = FLOOD_LETTERS;
    let mut numbers = Vec::new();
    let mut colors: std::collections::HashMap<u64, Value> = Default::default();
    for row in rows {
        let text = row_text(row);
        if !text.starts_with("line ") {
            continue;
        }
        let number: u64 = text[5..11].parse().unwrap_or_else(|_| panic!("cut row {text:?}"));
        assert_eq!(text, format!("line {number:06} é {letters}"), "a garbled flood row");
        let runs = content_runs(row);
        assert_eq!(runs.len(), 1, "a flood row is one run: {row}");
        let color = colors.entry(number % 8).or_insert_with(|| runs[0]["fg"].clone());
        assert_eq!(&runs[0]["fg"], color, "row {number} has the wrong color");
        if let Some(previous) = numbers.last() {
            assert_eq!(number, previous + 1, "the history skips from line {previous} to {number}");
        }
        numbers.push(number);
    }
    numbers
}

/// Holder item 2: the holder is the standalone `cmux-holder` (std and libc,
/// its own wire), and a newer daemon adopts a holder an older cmux build
/// started by the wire version they settle on. A daemon starts the frozen
/// version 3 holder (`cmux-holder-v3`, through `CMUX_TUI_HOLDER_EXE`, as an
/// older build's daemon would have). Then a daemon of this build, which
/// starts its own holder, restarts on the same state: it re-attaches every
/// terminal from the old holder and runs new ones there. When the old
/// holder dies it starts the standalone `cmux-holder` and hands it every
/// master (an older holder passes no ring, so the daemon makes one); when
/// that one dies too, nothing is lost, and a last restart restores every
/// screen.
#[test]
fn a_new_daemon_adopts_an_older_holder_by_its_wire_version() {
    // Both holders are other packages' binaries: a package-scoped run
    // (`cargo test -p cmux-tui`) builds neither, and then this test cannot
    // say anything (it fails instead with REQUIRE_FIXTURES set).
    let (Some(fixture), Some(_)) = (built_binary("cmux-holder-v3"), built_binary("cmux-holder"))
    else {
        assert!(
            !require_fixtures(),
            "cmux-holder-v3 or cmux-holder is not built beside cmux-tui and {REQUIRE_FIXTURES} \
             is set: run the tests with --workspace"
        );
        eprintln!(
            "SKIPPED a_new_daemon_adopts_an_older_holder_by_its_wire_version: cmux-holder-v3 or \
             cmux-holder is not built beside cmux-tui; run the tests with --workspace"
        );
        return;
    };
    built_after_its_sources(&fixture, "cmux-holder-v3");
    let mut daemon = Daemon::start_with_env(&[("CMUX_TUI_HOLDER_EXE", fixture.as_path())]);
    let mut terminals = Vec::new();
    for index in 0..2 {
        let created = request(
            &daemon.socket,
            json!({"cmd": "run", "argv": ["/bin/cat"], "new_workspace": true,
                "name": format!("old-{index}"), "cols": 80, "rows": 24}),
        );
        let surface = created["surface"].as_u64().unwrap();
        daemon.track(surface);
        send(&daemon.socket, surface, &format!("first-{index}"));
        screen_contains(&daemon.socket, surface, &format!("first-{index}"));
        terminals.push(created["terminal_id"].as_str().unwrap().to_string());
    }
    let surface = running_surface(&daemon.socket, &terminals[0]);
    let old_holder = parent_of(shell_pid(&daemon.socket, surface));
    assert_eq!(exe_name(old_holder), "cmux-holder-v3", "the first daemon ran the old holder");

    // A daemon of this build on the same state reaches the old holder.
    daemon.sigkill();
    daemon.env.clear();
    daemon.restart();
    for (index, terminal_id) in terminals.iter().enumerate() {
        let surface = running_surface(&daemon.socket, terminal_id);
        screen_contains(&daemon.socket, surface, &format!("first-{index}"));
        send(&daemon.socket, surface, &format!("restarted-{index}"));
        screen_contains(&daemon.socket, surface, &format!("restarted-{index}"));
    }
    let probe = probe_holder(&mut daemon, "probe-old");
    assert_eq!(probe, old_holder, "a new terminal runs on the old holder too");

    // The old holder dies: the daemon starts the standalone holder of this
    // build and hands it every master.
    // SAFETY: SIGKILL of the holder this test's first daemon started.
    unsafe { libc::kill(old_holder, libc::SIGKILL) };
    for (index, terminal_id) in terminals.iter().enumerate() {
        let surface = running_surface(&daemon.socket, terminal_id);
        send(&daemon.socket, surface, &format!("new-holder-{index}"));
        let screen = screen_contains(&daemon.socket, surface, &format!("new-holder-{index}"));
        assert!(
            screen.contains(&format!("first-{index}"))
                && screen.contains(&format!("restarted-{index}")),
            "terminal {index}: the screen was reset:
{screen}"
        );
    }
    let new_holder = probe_holder(&mut daemon, "probe-new");
    assert_ne!(new_holder, old_holder);
    assert_eq!(exe_name(new_holder), "cmux-holder", "this build's holder is the standalone binary");

    // It dies too: the masters and the rings go to the next one.
    // SAFETY: SIGKILL of the holder this test's daemon started.
    unsafe { libc::kill(new_holder, libc::SIGKILL) };
    for (index, terminal_id) in terminals.iter().enumerate() {
        let surface = running_surface(&daemon.socket, terminal_id);
        send(&daemon.socket, surface, &format!("last-{index}"));
        screen_contains(&daemon.socket, surface, &format!("last-{index}"));
    }
    probe_holder(&mut daemon, "probe-last");
    daemon.sigkill();
    daemon.restart();
    for (index, terminal_id) in terminals.iter().enumerate() {
        let surface = running_surface(&daemon.socket, terminal_id);
        let screen = screen_contains(&daemon.socket, surface, &format!("last-{index}"));
        for line in ["first", "restarted", "new-holder"] {
            assert!(
                screen.contains(&format!("{line}-{index}")),
                "terminal {index}: the restart lost {line}:
{screen}"
            );
        }
    }
}

/// A binary cargo built beside this package's `cmux-tui` (another
/// workspace package's, built for its own integration tests); `None` when
/// this run did not build it (no `--workspace`).
fn built_binary(name: &str) -> Option<PathBuf> {
    let path = Path::new(env!("CARGO_BIN_EXE_cmux-tui")).with_file_name(name);
    path.is_file().then_some(path)
}

/// Set it (to anything) on the fleet run that must test the standalone
/// holder and the older-holder fixture: a missing one fails the tests
/// instead of letting them run on the built-in holder or skip.
const REQUIRE_FIXTURES: &str = "CMUX_REQUIRE_HOLDER_FIXTURES";

fn require_fixtures() -> bool {
    std::env::var_os(REQUIRE_FIXTURES).is_some_and(|value| !value.is_empty())
}

/// The standalone `cmux-holder` the daemon starts from beside `cmux-tui`
/// is this build's: it speaks this build's wire range and is newer than
/// every source of its crate. A package-scoped run does not rebuild it, so
/// one an earlier workspace run left there would be tested instead. Missing
/// is allowed (the built-in holder runs) unless [`REQUIRE_FIXTURES`] is set.
fn standalone_holder_is_current() {
    static CHECKED: std::sync::OnceLock<()> = std::sync::OnceLock::new();
    CHECKED.get_or_init(|| {
        let Some(holder) = built_binary("cmux-holder") else {
            assert!(
                !require_fixtures(),
                "no cmux-holder beside cmux-tui and {REQUIRE_FIXTURES} is set: run the tests \
                 with --workspace"
            );
            return;
        };
        let output = Command::new(&holder).arg("--version").output().unwrap();
        assert_eq!(
            String::from_utf8_lossy(&output.stdout).trim_end(),
            cmux_holder::version_line(),
            "{} speaks another wire range than this build: run the tests with --workspace",
            holder.display()
        );
        built_after_its_sources(&holder, "cmux-holder");
    });
}

/// `binary` is newer than every source file of the workspace crate
/// `crate_dir` (its `src` and its `Cargo.toml`): it was built from them.
fn built_after_its_sources(binary: &Path, crate_dir: &str) {
    let built = fs::metadata(binary).and_then(|meta| meta.modified()).unwrap();
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join(crate_dir);
    for source in walk(&root.join("src")).into_iter().chain([root.join("Cargo.toml")]) {
        let changed = fs::metadata(&source).and_then(|meta| meta.modified()).unwrap();
        assert!(
            changed <= built,
            "{} is older than {}: an earlier run built it; run the tests with --workspace",
            binary.display(),
            source.display()
        );
    }
}

/// The file name of `pid`'s executable.
fn exe_name(pid: i32) -> String {
    #[cfg(target_vendor = "apple")]
    let path = {
        let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        // SAFETY: proc_pidpath writes at most the buffer's length.
        let len = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
        assert!(len > 0, "no executable path for pid {pid}");
        buf.truncate(len as usize);
        PathBuf::from(String::from_utf8_lossy(&buf).into_owned())
    };
    #[cfg(not(target_vendor = "apple"))]
    let path = fs::read_link(format!("/proc/{pid}/exe")).unwrap();
    path.file_name().unwrap().to_string_lossy().into_owned()
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
