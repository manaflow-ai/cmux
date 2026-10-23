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
    /// Extra daemon arguments, kept for every restart.
    args: Vec<String>,
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

    fn start_with(args: &[&str]) -> Self {
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
            socket: dir.join("mux.sock"),
            dir,
            cleanup: Vec::new(),
        };
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
            .args(&self.args)
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
/// The program prints numbered colored lines. The daemon is stopped
/// (SIGSTOP) so the holder fills up: it reads the PTY until it holds its
/// limit of unsent output and the program blocks. The holder is then
/// SIGKILLed and the daemon continued: the lines the dead holder had read
/// but never sent must still reach the screen, so the history has no gap.
/// Then the program stops in the middle of an SGR sequence, and later in
/// the middle of `é`, and the holder is SIGKILLed at each stop. The live
/// history and screen must be exact, and a daemon restart must show the
/// same screen and the same styled history rows.
#[test]
fn a_holder_killed_holding_unparsed_output_or_mid_sequence_loses_no_byte() {
    let mut daemon = Daemon::start();
    let progress = daemon.dir.join("progress");
    let stop = daemon.dir.join("stop");
    let script = daemon.dir.join("flood.sh");
    fs::write(
        &script,
        format!(
            r#"stty -echo
i=0
while [ ! -e '{stop}' ]; do
  printf '\033[3%dmline %06d \303\251 abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwx\033[0m\n' $((i % 8)) "$i"
  i=$((i + 1))
  echo "$i" > '{progress}'
done
printf 'flood-end\n'
printf 'X\033[38;5;1'
read a
printf '96mRED\303'
read b
printf '\251 END\033[0m\n'
i=0
while [ $i -lt 30 ]; do printf 'tail %02d\n' "$i"; i=$((i + 1)); done
exec sleep 3600
"#,
            stop = stop.display(),
            progress = progress.display(),
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
    screen_contains(&daemon.socket, surface, "line 000001");

    // The daemon stops reading its link: the holder reads the PTY until it
    // holds its limit of unsent output, and then the program blocks in its
    // write. A program whose progress stands still is blocked.
    let daemon_pid = daemon.child.as_ref().unwrap().id() as i32;
    // SAFETY: SIGSTOP of the daemon this test started.
    unsafe { libc::kill(daemon_pid, libc::SIGSTOP) };
    let read_progress = || fs::read_to_string(&progress).unwrap_or_default().trim().to_string();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut last = read_progress();
    let mut still = 0;
    while still < 5 {
        std::thread::sleep(Duration::from_millis(200));
        let now = read_progress();
        still = if now == last { still + 1 } else { 0 };
        last = now;
        assert!(Instant::now() < deadline, "the program never blocked: progress {last}");
    }
    // The holder dies holding output nobody parsed. The program stops at its
    // next line once it can write again.
    fs::write(&stop, b"").unwrap();
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

    let live = history(&daemon.socket, surface);
    let flood = flood_rows(&live);
    assert!(flood.len() > 100, "too little flood history kept: {} rows", flood.len());
    let red = live
        .iter()
        .position(|row| row_text(row) == "XREDé END")
        .unwrap_or_else(|| panic!("no exact `XREDé END` row in the history:\n{}", dump(&live)));
    let runs = live[red]["runs"].as_array().unwrap();
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
    // The holder that runs the terminals now ends with the test.
    probe_holder(&mut daemon, "probe-4");
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

fn dump(rows: &[Value]) -> String {
    let from = rows.len().saturating_sub(40);
    rows[from..].iter().map(row_text).collect::<Vec<_>>().join("\n")
}

/// The flood rows of a history: each is exactly `line N é <letters>` in
/// color N % 8, and N counts up by one, with no row missing or cut.
fn flood_rows(rows: &[Value]) -> Vec<u64> {
    let letters = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwx";
    let mut numbers = Vec::new();
    let mut colors: std::collections::HashMap<u64, Value> = Default::default();
    for row in rows {
        let text = row_text(row);
        if !text.starts_with("line ") {
            continue;
        }
        let number: u64 = text[5..11].parse().unwrap_or_else(|_| panic!("cut row {text:?}"));
        assert_eq!(text, format!("line {number:06} é {letters}"), "a garbled flood row");
        let runs = row["runs"].as_array().unwrap();
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
