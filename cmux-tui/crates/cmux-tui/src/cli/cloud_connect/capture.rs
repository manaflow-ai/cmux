//! `claude setup-token` in a pty of our own, with its output passed through to this terminal except
//! the `sk-ant-oat` token: [`TokenFilter`] holds back anything that could start the token, takes the
//! token out, and shows nothing after it. The person still sees the link and the "paste code" step
//! and types into the child as usual; the token itself goes only into the Keychain.

use std::io::Write;
use std::os::fd::RawFd;
use std::os::unix::ffi::OsStrExt as _;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use zeroize::{Zeroize as _, Zeroizing};

use super::TOKEN_PREFIX;

/// The shortest token taken as whole (`sk-ant-oat01-` and a long body): anything shorter was cut.
const MIN_TOKEN: usize = 40;
/// At least this many columns, so the token never wraps onto a second line.
const MIN_COLUMNS: u16 = 200;

/// The token bytes after the prefix: `claude setup-token` tokens are base64url with dashes.
fn token_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'
}

/// The child's output with the token taken out of it.
#[derive(Default)]
pub(in crate::cli) struct TokenFilter {
    /// Bytes not yet shown that may be the start of the token.
    held: Vec<u8>,
    /// The token so far, once its prefix was seen.
    token: Option<Zeroizing<Vec<u8>>>,
    /// The token ended: nothing more is shown or taken.
    done: bool,
}

impl TokenFilter {
    /// The part of `chunk` (and what was held before it) that is safe to show now.
    pub(in crate::cli) fn push(&mut self, chunk: &[u8]) -> Vec<u8> {
        if self.done {
            return Vec::new();
        }
        if self.token.is_some() {
            self.take_token(chunk);
            return Vec::new();
        }
        self.held.extend_from_slice(chunk);
        let prefix = TOKEN_PREFIX.as_bytes();
        if let Some(at) = self.held.windows(prefix.len()).position(|w| w == prefix) {
            let shown = self.held.get(..at).unwrap_or_default().to_vec();
            let mut rest = self.held.split_off(at);
            self.held.clear();
            let mut token = Zeroizing::new(Vec::with_capacity(256));
            token.extend_from_slice(prefix);
            self.token = Some(token);
            self.take_token(rest.get(prefix.len()..).unwrap_or_default());
            rest.zeroize();
            return shown;
        }
        let keep = (1..prefix.len())
            .rev()
            .find(|&k| prefix.get(..k).is_some_and(|p| self.held.ends_with(p)))
            .unwrap_or(0);
        let show = self.held.len() - keep;
        self.held.drain(..show).collect()
    }

    fn take_token(&mut self, bytes: &[u8]) {
        let Some(token) = self.token.as_mut() else { return };
        for &byte in bytes {
            if !token_byte(byte) {
                self.done = true;
                return;
            }
            token.push(byte);
        }
    }

    /// Whether the whole token has been read.
    pub(in crate::cli) fn done(&self) -> bool {
        self.done
    }

    /// At the end: what was still held (it was no token), and the token if one came.
    pub(in crate::cli) fn finish(mut self) -> (Vec<u8>, Option<Zeroizing<String>>) {
        let held = std::mem::take(&mut self.held);
        let token = self.token.take().and_then(|mut bytes| {
            let text = String::from_utf8(std::mem::take(&mut *bytes)).ok()?;
            Some(Zeroizing::new(text))
        });
        (held, token)
    }
}

/// `claude setup-token` on this terminal: the token it prints, which this terminal never shows.
pub(in crate::cli) fn claude_setup_token() -> Result<Zeroizing<String>, String> {
    // SAFETY: isatty only reads the fd's state.
    let tty = unsafe { libc::isatty(libc::STDIN_FILENO) } == 1;
    let _raw = if tty { RawMode::enter(libc::STDIN_FILENO) } else { None };
    let mut stdout = std::io::stdout();
    let program = std::env::var("CMUX_CLAUDE_BIN").ok().filter(|p| !p.is_empty());
    let token = run(
        program.as_deref().unwrap_or("claude"),
        &["setup-token"],
        Some(libc::STDIN_FILENO),
        columns().max(MIN_COLUMNS),
        &mut stdout,
    )?;
    let _ = write!(
        stdout,
        "\r\ncmux: captured the token; it goes into the Keychain and is not shown.\r\n"
    );
    let _ = stdout.flush();
    Ok(token)
}

fn columns() -> u16 {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    // SAFETY: TIOCGWINSZ fills `size` for a terminal fd, or fails without touching it.
    if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut size) } == 0 {
        size.ws_col
    } else {
        0
    }
}

/// `program args` in a new pty `columns` wide: `input_fd` goes to it, its output to `out` with the
/// token taken out; the token is the answer. The child ends with the token: it is stopped (it is
/// our own child, its process group) if it is still running a few seconds later.
pub(in crate::cli) fn run(
    program: &str,
    args: &[&str],
    input_fd: Option<RawFd>,
    columns: u16,
    out: &mut dyn Write,
) -> Result<Zeroizing<String>, String> {
    let (master, slave, slave_path) = open_pty(columns)?;
    // The child opens the pty by its path as a new session's leader, so it becomes its
    // controlling terminal (cmux_process: no other descriptor reaches the child).
    let mut command = cmux_process::Command::new(program);
    command.args(args).new_session().open_stdin_path(&slave_path);
    let spawned = command.spawn();
    // SAFETY: our own fd; the child opened its own.
    unsafe { libc::close(slave) };
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => {
            // SAFETY: our own fd, closed once.
            unsafe { libc::close(master) };
            return Err(if error.kind() == std::io::ErrorKind::NotFound {
                format!("{program} is not installed: install Claude Code, then run this again")
            } else {
                format!("cannot start {program}: {error}")
            });
        }
    };
    let stop = AtomicBool::new(false);
    let mut filter = TokenFilter::default();
    std::thread::scope(|scope| {
        if let Some(fd) = input_fd {
            let stop = &stop;
            scope.spawn(move || forward_input(fd, master, stop));
        }
        let mut buf = Zeroizing::new(vec![0u8; 8192]);
        loop {
            // SAFETY: reads into our own buffer.
            let n = unsafe { libc::read(master, buf.as_mut_ptr().cast(), buf.len()) };
            if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            if n <= 0 {
                break;
            }
            let shown = filter.push(buf.get(..n as usize).unwrap_or_default());
            let _ = out.write_all(&shown);
            let _ = out.flush();
            if filter.done() {
                break;
            }
        }
        stop.store(true, Ordering::SeqCst);
    });
    if filter.done() && !child.exited_within(Duration::from_secs(3)).unwrap_or(false) {
        // Our own child, still running (not reaped, so its pid and group are its own) after it
        // printed the token: end its process group, which new_session made it lead.
        if let Ok(pid) = libc::pid_t::try_from(child.id()) {
            // SAFETY: signals the group of a child this process spawned and has not reaped.
            if unsafe { libc::kill(-pid, libc::SIGTERM) } != 0 {
                // SAFETY: as above; no group yet: the child itself.
                unsafe { libc::kill(pid, libc::SIGTERM) };
            }
        }
        if !child.exited_within(Duration::from_secs(2)).unwrap_or(false) {
            let _ = child.kill();
        }
    }
    let status = child.wait().map_err(|error| error.to_string())?;
    // SAFETY: our own fd, closed once.
    unsafe { libc::close(master) };
    let (rest, token) = filter.finish();
    let _ = out.write_all(&rest);
    let _ = out.flush();
    match token {
        Some(token) if token.len() >= MIN_TOKEN => Ok(token),
        Some(_) => {
            Err("the token claude setup-token printed was cut short; nothing was stored".into())
        }
        None => Err(format!(
            "{program} setup-token ended ({status}) without printing a token; nothing was stored"
        )),
    }
}

fn open_pty(columns: u16) -> Result<(RawFd, RawFd, std::path::PathBuf), String> {
    let mut name = [0 as libc::c_char; 128];
    let mut master: libc::c_int = -1;
    let mut slave: libc::c_int = -1;
    let size = libc::winsize { ws_row: 40, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: openpty fills both fds and the slave's name (a short /dev path); termios may be null.
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            name.as_mut_ptr(),
            std::ptr::null_mut(),
            &size as *const _ as *mut _,
        )
    };
    if opened != 0 {
        return Err(format!(
            "cannot open a terminal for claude: {}",
            std::io::Error::last_os_error()
        ));
    }
    for fd in [master, slave] {
        // SAFETY: sets close-on-exec on our own fds, so the child keeps only its stdio copies.
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    // SAFETY: openpty wrote a NUL-terminated name into `name`.
    let path = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) };
    let path = std::path::PathBuf::from(std::ffi::OsStr::from_bytes(path.to_bytes()));
    Ok((master, slave, path))
}

/// `input` to the child's terminal until `stop`; it looks every 100 ms.
fn forward_input(input: RawFd, master: RawFd, stop: &AtomicBool) {
    let mut buf = Zeroizing::new(vec![0u8; 1024]);
    while !stop.load(Ordering::SeqCst) {
        let mut poll = libc::pollfd { fd: input, events: libc::POLLIN, revents: 0 };
        // SAFETY: one pollfd of ours.
        if unsafe { libc::poll(&mut poll, 1, 100) } <= 0 {
            continue;
        }
        // SAFETY: reads into our own buffer.
        let n = unsafe { libc::read(input, buf.as_mut_ptr().cast(), buf.len()) };
        if n <= 0 {
            return;
        }
        let mut written = 0usize;
        while written < n as usize {
            // SAFETY: writes from our own buffer to our own fd.
            let w = unsafe {
                let rest = buf.get(written..n as usize).unwrap_or_default();
                libc::write(master, rest.as_ptr().cast(), rest.len())
            };
            if w <= 0 {
                return;
            }
            written += w as usize;
        }
    }
}

/// This terminal in raw mode until dropped, so keys reach claude as typed.
struct RawMode {
    fd: RawFd,
    saved: libc::termios,
}

impl RawMode {
    fn enter(fd: RawFd) -> Option<Self> {
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: tcgetattr fills `saved` for a terminal fd.
        if unsafe { libc::tcgetattr(fd, &mut saved) } != 0 {
            return None;
        }
        let mut raw = saved;
        // SAFETY: cfmakeraw edits our copy; tcsetattr applies it.
        unsafe {
            libc::cfmakeraw(&mut raw);
            if libc::tcsetattr(fd, libc::TCSANOW, &raw) != 0 {
                return None;
            }
        }
        Some(Self { fd, saved })
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        // SAFETY: restores the settings read in `enter`.
        unsafe { libc::tcsetattr(self.fd, libc::TCSANOW, &self.saved) };
    }
}
