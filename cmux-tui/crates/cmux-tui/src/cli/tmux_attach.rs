//! `cmux tmux attach [TARGET]`: one tmux pane, rendered by the terminal the
//! command runs in, through tmux control mode
//! (plans/feat-control-mode-terminals/DESIGN.md, P1 LocalTmux, first slice).
//!
//! ```text
//! cmux tmux attach [SESSION | SESSION:WINDOW.PANE | %PANE]
//! ```
//!
//! An experiment, off unless `CMUX_TUI_TMUX_CONTROL_MODE=1`; the managed
//! policy or the tester wave's `DisabledFeatures: ["tmux-control-mode"]`
//! turns it off again (`crate::feature_flags::tmux_control_mode_enabled`).
//!
//! The person never types `tmux -CC`. A hidden gateway runs `tmux -C
//! attach-session` on a pipe (`-CC` differs only by the DCS wrapper and tty
//! echo, which a pipe has no use for) and parses its line protocol. The
//! attached unit is one tmux pane, never a window or its splits: the terminal
//! gets the pane's full history from `capture-pane -S - -E -` (the iTerm2
//! model), then only that pane's `%output`, so the terminal's own scrollback,
//! find and selection work on the pane, not on tmux's curses screen. Keys go
//! back as `send-keys -H`, the terminal's size as `refresh-client -C`.
//! Typing Enter `~` `.` detaches (closing the terminal does too); the pane
//! stays alive in the tmux server. The command ends, and the shell it ran in
//! comes back, when the pane, its session or the server goes away.
//!
//! Not yet (later slices of the design): a manual-IO Ghostty surface pushed
//! onto the pane instead of the calling terminal, the pane's terminal modes
//! (alternate screen, mouse, cursor style) at attach, and the opt-in view of
//! the raw control stream.

use std::io::{BufRead, BufReader, Write};
use std::process::ChildStdin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread::Scope;

use cmux_process::{Child, Command, Stdio};

use serde_json::json;

use super::wire;

const USAGE: &str = "\
Usage: cmux tmux attach [SESSION | SESSION:WINDOW.PANE | %PANE]

Render one tmux pane in this terminal through tmux control mode, with this
terminal's own scrollback, find and selection. With no target, the most
recently used session's active pane. Enter ~ . detaches; the pane keeps
running in tmux.

Experiment: set CMUX_TUI_TMUX_CONTROL_MODE=1 to turn it on.
";

/// `cmux tmux attach …` from the full argv. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    let (verb, rest) = match command.as_slice() {
        [scope, verb, rest @ ..] if scope == "tmux" => (verb.as_str(), rest),
        [scope] if scope == "tmux" => ("", &[][..]),
        _ => return None,
    };
    if verb != "attach" || super::has_help_option(&command) {
        print!("{USAGE}");
        return Some(if verb == "attach" || verb.is_empty() { 0 } else { 2 });
    }
    let env = |name: &str| std::env::var(name).ok();
    if !crate::feature_flags::tmux_control_mode_enabled(&env) {
        return Some(wire::print_local_error(
            &json!({
                "code": "feature.off",
                "message": "cmux tmux attach is an experiment: set CMUX_TUI_TMUX_CONTROL_MODE=1 to turn it on",
            }),
            global.output,
            2,
        ));
    }
    let target = match rest {
        [] => None,
        [target] if !target.starts_with('-') => Some(target.clone()),
        _ => {
            return Some(wire::print_local_error(
                &json!({"code": "usage.invalid", "message": "tmux attach takes at most one target"}),
                global.output,
                2,
            ));
        }
    };
    Some(match attach(&Tmux::default(), target.as_deref()) {
        Ok(()) => 0,
        Err(message) => wire::print_local_error(
            &json!({"code": "tmux.attach_failed", "message": message}),
            global.output,
            1,
        ),
    })
}

/// How to run tmux: the default server, or a named socket (`-L`, tests).
#[derive(Clone, Default)]
struct Tmux {
    socket: Option<String>,
}

impl Tmux {
    fn command(&self) -> Command {
        let mut command = Command::new("tmux");
        if let Some(socket) = &self.socket {
            command.args(["-L", socket]);
        }
        // tmux refuses to attach from inside one of its own panes unless
        // TMUX is unset; the gateway is a client of its own, not nested.
        command.env_remove("TMUX");
        command
    }

    /// One tmux command's stdout, or why it failed.
    fn output(&self, args: &[&str]) -> Result<String, String> {
        let output = self
            .command()
            .args(args)
            .stdin(Stdio::null())
            .output()
            .map_err(|error| format!("tmux: {error}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("tmux {}: {}", args.join(" "), stderr.trim()));
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }
}

/// The pane a target names, with what attaching needs to know about it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Pane {
    id: String,
    session: String,
    window: String,
}

const PANE_FORMAT: &str = "#{pane_id} #{session_id} #{window_id}";

fn resolve(tmux: &Tmux, target: Option<&str>) -> Result<Pane, String> {
    let mut args = vec!["display-message", "-p"];
    if let Some(target) = target {
        args.extend(["-t", target]);
    }
    args.push(PANE_FORMAT);
    parse_pane(&tmux.output(&args)?).ok_or_else(|| "tmux named no pane".to_string())
}

fn parse_pane(line: &str) -> Option<Pane> {
    let mut words = line.split_whitespace();
    let pane = Pane {
        id: words.next().filter(|word| word.starts_with('%'))?.to_string(),
        session: words.next().filter(|word| word.starts_with('$'))?.to_string(),
        window: words.next().filter(|word| word.starts_with('@'))?.to_string(),
    };
    Some(pane)
}

fn pane_alive(tmux: &Tmux, pane: &str) -> bool {
    tmux.output(&["display-message", "-p", "-t", pane, "#{pane_id}"])
        .is_ok_and(|id| id.trim() == pane)
}

/// The pane's whole history and screen with its colors, and where its cursor is.
struct Snapshot {
    text: String,
    cursor_x: u16,
    cursor_y: u16,
    height: u16,
}

fn snapshot(tmux: &Tmux, pane: &str) -> Result<Snapshot, String> {
    let text =
        tmux.output(&["capture-pane", "-p", "-e", "-J", "-S", "-", "-E", "-", "-t", pane])?;
    let place = tmux.output(&[
        "display-message",
        "-p",
        "-t",
        pane,
        "#{cursor_x} #{cursor_y} #{pane_height}",
    ])?;
    let mut numbers = place.split_whitespace().map(|word| word.parse::<u16>().unwrap_or(0));
    Ok(Snapshot {
        text,
        cursor_x: numbers.next().unwrap_or(0),
        cursor_y: numbers.next().unwrap_or(0),
        height: numbers.next().unwrap_or(0),
    })
}

/// What one line of the control stream means for an attached pane.
#[derive(Debug, PartialEq, Eq)]
enum Event {
    /// `%output %N VALUE`, unescaped.
    Output { pane: String, bytes: Vec<u8> },
    /// A window's panes changed (`%layout-change`) or it closed: the pane may be gone.
    WindowChanged { window: String },
    /// `%exit`: this client is detached, or the server went away.
    Exit,
    /// A command's reply or a notification the attach does not use.
    Other,
}

/// The control-mode line protocol: replies fenced by `%begin`/`%end` (or
/// `%error`), notifications outside them. A notification never appears
/// inside a reply, so one flag is the whole state.
#[derive(Default)]
struct Parser {
    in_reply: bool,
}

impl Parser {
    fn line(&mut self, line: &[u8]) -> Event {
        let line = line.strip_suffix(b"\n").unwrap_or(line);
        let line = line.strip_suffix(b"\r").unwrap_or(line);
        if self.in_reply {
            if line.starts_with(b"%end ") || line.starts_with(b"%error ") {
                self.in_reply = false;
            }
            return Event::Other;
        }
        if line.starts_with(b"%begin ") {
            self.in_reply = true;
            return Event::Other;
        }
        let (name, rest) = match line.iter().position(|byte| *byte == b' ') {
            Some(space) => (&line[..space], &line[space + 1..]),
            None => (line, &[][..]),
        };
        match name {
            b"%output" => {
                let space = rest.iter().position(|byte| *byte == b' ').unwrap_or(rest.len());
                let value = rest.get(space + 1..).unwrap_or_default();
                Event::Output {
                    pane: String::from_utf8_lossy(&rest[..space]).into_owned(),
                    bytes: unescape(value),
                }
            }
            b"%layout-change" | b"%window-close" | b"%unlinked-window-close" => {
                let window = rest.split(|byte| *byte == b' ').next().unwrap_or_default();
                Event::WindowChanged { window: String::from_utf8_lossy(window).into_owned() }
            }
            b"%exit" => Event::Exit,
            _ => Event::Other,
        }
    }
}

/// `%output` values escape bytes below a space, and the backslash, as `\ooo`.
fn unescape(value: &[u8]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(value.len());
    let mut index = 0;
    while index < value.len() {
        let octal = value.get(index + 1..index + 4).filter(|digits| {
            value[index] == b'\\' && digits.iter().all(|digit| (b'0'..=b'7').contains(digit))
        });
        match octal {
            Some(digits) => {
                let byte = digits.iter().fold(0u32, |sum, digit| sum * 8 + u32::from(digit - b'0'));
                bytes.push(byte as u8);
                index += 4;
            }
            None => {
                bytes.push(value[index]);
                index += 1;
            }
        }
    }
    bytes
}

/// `send-keys -H` commands that type `bytes` into `pane`, a bounded run of keys each.
fn send_keys(pane: &str, bytes: &[u8]) -> String {
    let mut commands = String::new();
    for chunk in bytes.chunks(128) {
        commands.push_str("send-keys -H -t ");
        commands.push_str(pane);
        for byte in chunk {
            commands.push_str(&format!(" {byte:02x}"));
        }
        commands.push('\n');
    }
    commands
}

/// Finds Enter `~` `.` in typed bytes, as ssh does; the bytes before it still go to the pane.
#[derive(Default)]
struct DetachKey {
    state: u8,
}

impl DetachKey {
    /// How many of `bytes` to send, and whether the detach key was typed.
    fn scan(&mut self, bytes: &[u8]) -> (usize, bool) {
        for (index, byte) in bytes.iter().enumerate() {
            self.state = match (self.state, byte) {
                (_, b'\r' | b'\n') => 1,
                (1, b'~') => 2,
                (2, b'.') => return (index.saturating_sub(1), true),
                _ => 0,
            };
        }
        (bytes.len(), false)
    }
}

/// A `tmux -C` client and the events its stream carries. Its reader runs in
/// the caller's scope and ends when the client does.
struct Gateway {
    child: Child,
    input: Arc<Mutex<ChildStdin>>,
    events: Receiver<Event>,
}

impl Gateway {
    fn start<'scope>(
        scope: &'scope Scope<'scope, '_>,
        tmux: &Tmux,
        session: &str,
    ) -> Result<Self, String> {
        let mut child = tmux
            .command()
            .args(["-C", "attach-session", "-t", session])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("tmux -C: {error}"))?;
        let input = child.stdin.take().ok_or("tmux -C has no stdin")?;
        let output = child.stdout.take().ok_or("tmux -C has no stdout")?;
        let (sender, events) = channel();
        scope.spawn(move || read_stream(BufReader::new(output), &sender));
        Ok(Self { child, input: Arc::new(Mutex::new(input)), events })
    }

    fn send(&self, commands: &str) -> bool {
        let Ok(mut input) = self.input.lock() else { return false };
        input.write_all(commands.as_bytes()).and_then(|()| input.flush()).is_ok()
    }

    /// Detaches this client; the pane and its session keep running.
    fn close(mut self) {
        self.send("detach-client\n");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while std::time::Instant::now() < deadline {
            if !matches!(self.child.try_wait(), Ok(None)) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Every line of the stream as an event, then `Exit` when it ends.
fn read_stream(mut output: impl BufRead, events: &Sender<Event>) {
    let mut parser = Parser::default();
    let mut line = Vec::new();
    loop {
        line.clear();
        match output.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                if events.send(parser.line(&line)).is_err() {
                    return;
                }
            }
        }
    }
    let _ = events.send(Event::Exit);
}

fn attach(tmux: &Tmux, target: Option<&str>) -> Result<(), String> {
    use std::os::fd::AsRawFd;

    let stdin = std::io::stdin();
    let fd = stdin.as_raw_fd();
    if unsafe { libc::isatty(fd) } != 1 {
        return Err("cmux tmux attach needs a terminal".into());
    }
    let pane = resolve(tmux, target)?;
    // Every thread of the attach is joined before it returns: the reader ends
    // with the gateway, the key and size watchers with `stop`.
    let stop = AtomicBool::new(false);
    std::thread::scope(|scope| {
        let gateway = Gateway::start(scope, tmux, &pane.session)?;
        let result = stream(scope, tmux, &pane, &gateway, fd, &stop);
        stop.store(true, Ordering::Relaxed);
        gateway.close();
        result
    })
}

/// Snapshot, then the pane's live output until detach or until the pane,
/// its session or the server goes away.
fn stream<'scope>(
    scope: &'scope Scope<'scope, '_>,
    tmux: &Tmux,
    pane: &Pane,
    gateway: &Gateway,
    fd: i32,
    stop: &'scope AtomicBool,
) -> Result<(), String> {
    let (cols, rows) = terminal_size(fd).unwrap_or((80, 24));
    gateway.send(&format!("refresh-client -C {cols}x{rows}\n"));
    // Output that arrives before the capture is in the capture; drop it.
    while gateway.events.recv_timeout(std::time::Duration::from_millis(100)).is_ok() {}
    let snapshot = snapshot(tmux, &pane.id)?;
    let raw = RawMode::enter(fd)?;
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(&snapshot_bytes(&snapshot, rows));
    let _ = stdout.flush();

    let (typed_sender, typed) = channel::<Typed>();
    let keys_sender = typed_sender.clone();
    scope.spawn(move || watch_keys(fd, stop, &keys_sender));
    scope.spawn(move || watch_size(fd, (cols, rows), stop, &typed_sender));
    let mut detach = DetachKey::default();
    loop {
        // Typed bytes and resizes are rare next to output; a short wait keeps both live.
        while let Ok(typed) = typed.try_recv() {
            match typed {
                Typed::Bytes(bytes) => {
                    let (send, detached) = detach.scan(&bytes);
                    if send > 0 {
                        gateway.send(&send_keys(&pane.id, &bytes[..send]));
                    }
                    if detached {
                        drop(raw);
                        return Ok(());
                    }
                }
                Typed::Size(cols, rows) => {
                    gateway.send(&format!("refresh-client -C {cols}x{rows}\n"));
                }
                Typed::Closed => {
                    drop(raw);
                    return Ok(());
                }
            }
        }
        match gateway.events.recv_timeout(std::time::Duration::from_millis(10)) {
            Ok(Event::Output { pane: id, bytes }) if id == pane.id => {
                let _ = stdout.write_all(&bytes);
                let _ = stdout.flush();
            }
            Ok(Event::WindowChanged { window }) if window == pane.window => {
                if !pane_alive(tmux, &pane.id) {
                    break;
                }
            }
            Ok(Event::Exit) | Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            Ok(_) | Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
    drop(raw);
    Ok(())
}

/// The snapshot as terminal bytes: the screen cleared, every line of history
/// and screen, then the cursor where the pane has it.
fn snapshot_bytes(snapshot: &Snapshot, rows: u16) -> Vec<u8> {
    let text = snapshot.text.strip_suffix('\n').unwrap_or(&snapshot.text);
    let lines = text.split('\n').count();
    let mut bytes = b"\x1b[0m\x1b[H\x1b[2J".to_vec();
    bytes.extend_from_slice(text.replace('\n', "\r\n").as_bytes());
    // The pane's screen is its last `height` lines; they end at the bottom
    // row when the history filled the terminal, else at the last line written.
    let bottom = lines.min(usize::from(rows));
    let top = bottom.saturating_sub(usize::from(snapshot.height));
    let row = top + usize::from(snapshot.cursor_y) + 1;
    let column = usize::from(snapshot.cursor_x) + 1;
    bytes.extend_from_slice(format!("\x1b[0m\x1b[{row};{column}H").as_bytes());
    bytes
}

enum Typed {
    Bytes(Vec<u8>),
    Size(u16, u16),
    Closed,
}

/// Reads the terminal's keys until the attach ends. A `poll` with a short
/// timeout instead of a blocking read lets `stop` end it.
fn watch_keys(fd: i32, stop: &AtomicBool, typed: &Sender<Typed>) {
    let mut buffer = [0u8; 4096];
    while !stop.load(Ordering::Relaxed) {
        let mut ready = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        if unsafe { libc::poll(&mut ready, 1, 50) } <= 0 {
            continue;
        }
        let read = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if read <= 0 {
            let _ = typed.send(Typed::Closed);
            return;
        }
        let bytes = buffer[..read as usize].to_vec();
        if typed.send(Typed::Bytes(bytes)).is_err() {
            return;
        }
    }
}

/// Watches the terminal's size (an ioctl, no process) until the attach ends.
fn watch_size(fd: i32, mut size: (u16, u16), stop: &AtomicBool, typed: &Sender<Typed>) {
    while !stop.load(Ordering::Relaxed) {
        std::thread::sleep(std::time::Duration::from_millis(200));
        let Some(now) = terminal_size(fd) else { continue };
        if now != size {
            size = now;
            if typed.send(Typed::Size(now.0, now.1)).is_err() {
                return;
            }
        }
    }
}

fn terminal_size(fd: i32) -> Option<(u16, u16)> {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    let ok = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } == 0;
    (ok && size.ws_col > 0 && size.ws_row > 0).then_some((size.ws_col, size.ws_row))
}

/// The terminal in raw mode until dropped.
struct RawMode {
    fd: i32,
    saved: libc::termios,
}

impl RawMode {
    fn enter(fd: i32) -> Result<Self, String> {
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(fd, &mut saved) } != 0 {
            return Err("cannot read the terminal's mode".into());
        }
        let mut raw = saved;
        unsafe { libc::cfmakeraw(&mut raw) };
        if unsafe { libc::tcsetattr(fd, libc::TCSANOW, &raw) } != 0 {
            return Err("cannot put the terminal in raw mode".into());
        }
        Ok(Self { fd, saved })
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        let mut stdout = std::io::stdout();
        let _ = stdout.write_all(b"\x1b[0m\x1b[?25h\r\n");
        let _ = stdout.flush();
        unsafe { libc::tcsetattr(self.fd, libc::TCSANOW, &self.saved) };
    }
}

#[cfg(test)]
#[path = "tmux_attach_tests.rs"]
mod tests;
