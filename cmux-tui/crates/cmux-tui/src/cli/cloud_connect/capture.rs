//! `claude setup-token` in a pty of our own, with its output passed through to this terminal except
//! the `sk-ant-oat` token: [`TokenFilter`] holds back anything that could start the token, takes the
//! token out, and shows nothing after it. The person still sees the link and the "paste code" step
//! and types into the child as usual; the token itself goes only into the Keychain.

use std::io::Write;
use std::os::fd::{AsRawFd as _, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

pub(in crate::cli) use acpmux::claude_token::pty::TokenFilter;
use acpmux::claude_token::pty::{MIN_COLUMNS, MIN_TOKEN, command, open_pty, stop, write_all};
use zeroize::Zeroizing;

/// `claude setup-token` on this terminal: the token it prints, which this terminal never shows.
pub(in crate::cli) fn claude_setup_token() -> Result<Zeroizing<String>, String> {
    // SAFETY: isatty only reads the fd's state.
    let tty = unsafe { libc::isatty(libc::STDIN_FILENO) } == 1;
    let _raw = if tty { RawMode::enter(libc::STDIN_FILENO) } else { None };
    let mut stdout = std::io::stdout();
    let program = acpmux::claude_token::pty::program();
    let token = run(
        &program.to_string_lossy(),
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

/// `program setup-token` in a new pty `columns` wide (`acpmux::claude_token::pty::command`, as
/// the daemon's one-click runs it): `input_fd` goes to it, its output to `out` with the token taken
/// out; the token is the answer. The child ends with the token: its process group is stopped if it
/// is still running a few seconds later.
pub(in crate::cli) fn run(
    program: &str,
    input_fd: Option<RawFd>,
    columns: u16,
    out: &mut dyn Write,
) -> Result<Zeroizing<String>, String> {
    let (master, slave, slave_path) = open_pty(columns)?;
    // Claude Code opens the browser itself here: the person is at this terminal.
    let spawned = command(std::path::Path::new(program), &slave_path, false).spawn();
    drop(slave);
    let mut child = match spawned {
        Ok(child) => child,
        Err(error) => {
            return Err(if error.kind() == std::io::ErrorKind::NotFound {
                format!("{program} is not installed: install Claude Code, then run this again")
            } else {
                format!("cannot start {program}: {error}")
            });
        }
    };
    let master_fd = master.as_raw_fd();
    let stopping = AtomicBool::new(false);
    let mut filter = TokenFilter::default();
    std::thread::scope(|scope| {
        if let Some(fd) = input_fd {
            let stopping = &stopping;
            scope.spawn(move || forward_input(fd, master_fd, stopping));
        }
        let mut buf = Zeroizing::new(vec![0u8; 8192]);
        loop {
            // SAFETY: reads into our own buffer.
            let n = unsafe { libc::read(master_fd, buf.as_mut_ptr().cast(), buf.len()) };
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
        stopping.store(true, Ordering::SeqCst);
    });
    if filter.done() && !child.exited_within(Duration::from_secs(3)).unwrap_or(false) {
        // Our own child, still running after it printed the token: end its process group.
        stop(&mut child);
    }
    let status = child.wait().map_err(|error| error.to_string())?;
    drop(master);
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

/// `input` to the child's terminal until `stop`; it looks every 100 ms.
fn forward_input(input: RawFd, master: RawFd, stopping: &AtomicBool) {
    let mut buf = Zeroizing::new(vec![0u8; 1024]);
    while !stopping.load(Ordering::SeqCst) {
        let mut poll = libc::pollfd { fd: input, events: libc::POLLIN, revents: 0 };
        // SAFETY: one pollfd of ours.
        if unsafe { libc::poll(&mut poll, 1, 100) } <= 0 {
            continue;
        }
        // SAFETY: reads into our own buffer.
        let n = unsafe { libc::read(input, buf.as_mut_ptr().cast(), buf.len()) };
        if n <= 0 || !write_all(master, buf.get(..n as usize).unwrap_or_default()) {
            return;
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
