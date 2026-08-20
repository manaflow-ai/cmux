//! Transparent PTY tee between a host terminal (for example a Ghostty
//! surface) and a child command, recording byte-level traffic for scoped
//! attach debugging. Pure passthrough: the child runs on its own pty whose
//! termios and winsize (including pixel fields) mirror the host tty, and
//! SIGWINCH-driven resizes propagate.
//!
//! Usage: `cmux-tui-pty-tap [--] <command> [args...]`
//!
//! Environment:
//! - `CMUX_TUI_DEBUG_TAP=<dir>`: log directory (default `/tmp/cmux-tui-tap`).
//! - `CMUX_TUI_TAP_FULL_OUT=1`: hex-log ALL child output. By default only
//!   escape sequences that change terminal state are logged (private mode
//!   set/reset, cursor style, resets, OSC/DCS), which keeps the log small
//!   under continuous full-screen redraws.
//!
//! When stdin is not a tty the child is exec'd directly with no tee, so a
//! wrapper can front every invocation of a binary (daemon start, CLI calls)
//! while only interactive attach clients get tapped.

#[cfg(unix)]
fn main() {
    std::process::exit(unix::run());
}

#[cfg(not(unix))]
fn main() {
    eprintln!("cmux-tui-pty-tap: unix only");
    std::process::exit(1);
}

#[cfg(unix)]
mod unix {
    use std::ffi::CString;
    use std::fs::{File, OpenOptions};
    use std::io::Write;
    use std::os::unix::io::RawFd;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static WINCH: AtomicBool = AtomicBool::new(false);
    static FORWARD_SIGNAL: AtomicI32 = AtomicI32::new(0);

    extern "C" fn on_winch(_: libc::c_int) {
        WINCH.store(true, Ordering::SeqCst);
    }

    extern "C" fn on_forward(signal: libc::c_int) {
        FORWARD_SIGNAL.store(signal, Ordering::SeqCst);
    }

    fn now_ms() -> u128 {
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
    }

    fn hex(bytes: &[u8], max: usize) -> String {
        let mut out = String::with_capacity(bytes.len().min(max) * 2 + 1);
        for byte in bytes.iter().take(max) {
            out.push_str(&format!("{byte:02x}"));
        }
        if bytes.len() > max {
            out.push('+');
        }
        out
    }

    fn printable(bytes: &[u8]) -> String {
        bytes
            .iter()
            .map(|&b| match b {
                0x1b => "\\e".to_string(),
                0x07 => "\\a".to_string(),
                0x20..=0x7e => (b as char).to_string(),
                other => format!("\\x{other:02x}"),
            })
            .collect()
    }

    struct Log {
        file: File,
    }

    impl Log {
        fn line(&mut self, message: &str) {
            let _ = writeln!(self.file, "{} {}", now_ms(), message);
        }
    }

    /// Extracts complete ESC-initiated sequences from a byte stream, across
    /// chunk boundaries. Ground text is ignored.
    struct EscScanner {
        state: ScanState,
        buf: Vec<u8>,
    }

    enum ScanState {
        Ground,
        Esc,
        Csi,
        Str, // OSC/DCS/APC/PM/SOS string until BEL or ST
        StrEsc,
    }

    impl EscScanner {
        fn new() -> Self {
            Self { state: ScanState::Ground, buf: Vec::new() }
        }

        fn feed(&mut self, chunk: &[u8], mut emit: impl FnMut(&[u8])) {
            for &byte in chunk {
                match self.state {
                    ScanState::Ground => {
                        if byte == 0x1b {
                            self.buf.clear();
                            self.buf.push(byte);
                            self.state = ScanState::Esc;
                        }
                    }
                    ScanState::Esc => {
                        self.buf.push(byte);
                        match byte {
                            b'[' => self.state = ScanState::Csi,
                            b']' | b'P' | b'X' | b'^' | b'_' => self.state = ScanState::Str,
                            0x1b => {
                                self.buf.clear();
                                self.buf.push(0x1b);
                            }
                            _ => {
                                emit(&self.buf);
                                self.state = ScanState::Ground;
                            }
                        }
                    }
                    ScanState::Csi => {
                        self.buf.push(byte);
                        if (0x40..=0x7e).contains(&byte) {
                            emit(&self.buf);
                            self.state = ScanState::Ground;
                        } else if self.buf.len() > 256 {
                            emit(&self.buf);
                            self.state = ScanState::Ground;
                        }
                    }
                    ScanState::Str => {
                        if byte == 0x07 {
                            self.buf.push(byte);
                            emit(&self.buf);
                            self.state = ScanState::Ground;
                        } else if byte == 0x1b {
                            self.state = ScanState::StrEsc;
                        } else {
                            self.buf.push(byte);
                            if self.buf.len() > 256 {
                                emit(&self.buf);
                                self.state = ScanState::Ground;
                            }
                        }
                    }
                    ScanState::StrEsc => {
                        if byte == b'\\' {
                            self.buf.extend_from_slice(b"\x1b\\");
                            emit(&self.buf);
                            self.state = ScanState::Ground;
                        } else {
                            emit(&self.buf);
                            self.buf.clear();
                            self.buf.push(0x1b);
                            self.buf.push(byte);
                            self.state = match byte {
                                b'[' => ScanState::Csi,
                                b']' | b'P' | b'X' | b'^' | b'_' => ScanState::Str,
                                _ => {
                                    emit(&self.buf);
                                    ScanState::Ground
                                }
                            };
                        }
                    }
                }
            }
        }
    }

    /// Whether an extracted sequence changes terminal state we care about
    /// (vs per-frame rendering noise like cursor moves and SGR).
    fn interesting(sequence: &[u8]) -> bool {
        if sequence.len() < 2 {
            return false;
        }
        match sequence[1] {
            b'[' => {
                let Some(&last) = sequence.last() else { return false };
                if sequence.get(2) == Some(&b'?') {
                    return true; // every private-mode or DEC query sequence
                }
                matches!(last, b'h' | b'l' | b'p' | b'q' | b's' | b't' | b'u' | b'c' | b'n')
            }
            b']' | b'P' | b'X' | b'^' | b'_' => true, // OSC/DCS/APC/PM/SOS
            b'c' => true,                             // RIS
            _ => false,
        }
    }

    /// Alternating per-frame noise (synchronized update guards) is counted
    /// rather than logged per occurrence.
    fn noisy(sequence: &[u8]) -> bool {
        sequence == b"\x1b[?2026h" || sequence == b"\x1b[?2026l"
    }

    fn exec_child(args: &[String]) -> i32 {
        let program = CString::new(args[0].as_str()).expect("nul in program");
        let argv: Vec<CString> =
            args.iter().map(|a| CString::new(a.as_str()).expect("nul in arg")).collect();
        let mut raw: Vec<*const libc::c_char> = argv.iter().map(|a| a.as_ptr()).collect();
        raw.push(std::ptr::null());
        unsafe { libc::execvp(program.as_ptr(), raw.as_ptr()) };
        eprintln!("cmux-tui-pty-tap: exec {} failed: {}", args[0], std::io::Error::last_os_error());
        127
    }

    pub fn run() -> i32 {
        let mut args: Vec<String> = std::env::args().skip(1).collect();
        if args.first().is_some_and(|a| a == "--") {
            args.remove(0);
        }
        if args.is_empty() {
            eprintln!("usage: cmux-tui-pty-tap [--] <command> [args...]");
            return 2;
        }
        if unsafe { libc::isatty(0) } != 1 {
            return exec_child(&args);
        }

        let dir = std::env::var_os("CMUX_TUI_DEBUG_TAP")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/tmp/cmux-tui-tap"));
        if std::fs::create_dir_all(&dir).is_err() {
            return exec_child(&args);
        }
        let log_path = dir.join(format!("ptytap-{}-{}.log", now_ms(), std::process::id()));
        let Ok(file) = OpenOptions::new().create(true).append(true).open(&log_path) else {
            return exec_child(&args);
        };
        let mut log = Log { file };
        let full_out = std::env::var_os("CMUX_TUI_TAP_FULL_OUT").is_some_and(|v| v == "1");

        // Mirror the host tty onto the child pty: termios and full winsize
        // (rows, cols, and pixel fields, which mouse encoding depends on).
        let mut termios: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(0, &mut termios) } != 0 {
            return exec_child(&args);
        }
        let saved_termios = termios;
        let mut winsize: libc::winsize = unsafe { std::mem::zeroed() };
        if unsafe { libc::ioctl(0, libc::TIOCGWINSZ as libc::c_ulong, &mut winsize) } != 0 {
            return exec_child(&args);
        }
        let mut master: RawFd = -1;
        let mut slave: RawFd = -1;
        let ok = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                &termios as *const libc::termios as *mut libc::termios,
                &winsize as *const libc::winsize as *mut libc::winsize,
            )
        };
        if ok != 0 {
            return exec_child(&args);
        }

        log.line(&format!(
            "[tap] start argv={:?} term={:?} winsize={}x{} px={}x{} log={}",
            args,
            std::env::var("TERM").ok(),
            winsize.ws_col,
            winsize.ws_row,
            winsize.ws_xpixel,
            winsize.ws_ypixel,
            log_path.display()
        ));

        let child = unsafe { libc::fork() };
        if child < 0 {
            return exec_child(&args);
        }
        if child == 0 {
            // Child: own session, pty slave as controlling terminal + stdio.
            unsafe {
                libc::close(master);
                libc::setsid();
                libc::ioctl(slave, libc::TIOCSCTTY as libc::c_ulong, 0);
                libc::dup2(slave, 0);
                libc::dup2(slave, 1);
                libc::dup2(slave, 2);
                if slave > 2 {
                    libc::close(slave);
                }
            }
            std::process::exit(exec_child(&args));
        }
        unsafe { libc::close(slave) };
        log.line(&format!("[tap] child pid={child}"));

        // Raw passthrough on the host side; the child pty carries the
        // canonical termios the child manipulates itself.
        let mut raw = saved_termios;
        unsafe { libc::cfmakeraw(&mut raw) };
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) };

        unsafe {
            libc::signal(libc::SIGWINCH, on_winch as *const () as libc::sighandler_t);
            libc::signal(libc::SIGTERM, on_forward as *const () as libc::sighandler_t);
            libc::signal(libc::SIGHUP, on_forward as *const () as libc::sighandler_t);
            libc::signal(libc::SIGINT, on_forward as *const () as libc::sighandler_t);
        }

        let mut scanner = EscScanner::new();
        let mut out_bytes: u64 = 0;
        let mut noisy_count: u64 = 0;
        let mut buf = [0u8; 8192];
        let mut stdin_open = true;
        loop {
            let forward = FORWARD_SIGNAL.swap(0, Ordering::SeqCst);
            if forward != 0 {
                log.line(&format!("[tap] forwarding signal {forward} to child"));
                unsafe { libc::kill(child, forward) };
            }
            if WINCH.swap(false, Ordering::SeqCst) {
                let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
                if unsafe { libc::ioctl(0, libc::TIOCGWINSZ as libc::c_ulong, &mut ws) } == 0 {
                    unsafe { libc::ioctl(master, libc::TIOCSWINSZ as libc::c_ulong, &ws) };
                    log.line(&format!(
                        "RESIZE {}x{} px={}x{}",
                        ws.ws_col, ws.ws_row, ws.ws_xpixel, ws.ws_ypixel
                    ));
                }
            }
            let mut fds = [
                libc::pollfd {
                    fd: 0,
                    events: if stdin_open { libc::POLLIN } else { 0 },
                    revents: 0,
                },
                libc::pollfd { fd: master, events: libc::POLLIN, revents: 0 },
            ];
            let ready = unsafe { libc::poll(fds.as_mut_ptr(), 2, 100) };
            if ready < 0 {
                let err = std::io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                log.line(&format!("[tap] poll error {err}"));
                break;
            }
            if fds[0].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                let n = unsafe { libc::read(0, buf.as_mut_ptr().cast(), buf.len()) };
                if n > 0 {
                    let chunk = &buf[..n as usize];
                    log.line(&format!(
                        "IN  len={} hex={} |{}|",
                        chunk.len(),
                        hex(chunk, 512),
                        printable(&chunk[..chunk.len().min(200)])
                    ));
                    write_all(master, chunk);
                } else {
                    log.line("[tap] stdin closed");
                    stdin_open = false;
                }
            }
            if fds[1].revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0 {
                let n = unsafe { libc::read(master, buf.as_mut_ptr().cast(), buf.len()) };
                if n <= 0 {
                    log.line(&format!("[tap] child pty closed (n={n})"));
                    break;
                }
                let chunk = &buf[..n as usize];
                out_bytes += chunk.len() as u64;
                if full_out {
                    log.line(&format!("OUT len={} hex={}", chunk.len(), hex(chunk, 4096)));
                }
                scanner.feed(chunk, |sequence| {
                    if !interesting(sequence) {
                        return;
                    }
                    if noisy(sequence) {
                        noisy_count += 1;
                        if noisy_count % 1000 != 1 {
                            return;
                        }
                    }
                    let _ = writeln!(
                        log.file,
                        "{} OUT-CTL |{}| total_out={} noisy={}",
                        now_ms(),
                        printable(sequence),
                        out_bytes,
                        noisy_count
                    );
                });
                write_all(1, chunk);
            }
        }

        unsafe { libc::tcsetattr(0, libc::TCSANOW, &saved_termios) };
        let mut status: libc::c_int = 0;
        unsafe { libc::waitpid(child, &mut status, 0) };
        let code = if libc::WIFEXITED(status) {
            libc::WEXITSTATUS(status)
        } else if libc::WIFSIGNALED(status) {
            128 + libc::WTERMSIG(status)
        } else {
            1
        };
        log.line(&format!("[tap] exit status={status} code={code} total_out={out_bytes}"));
        code
    }

    fn write_all(fd: RawFd, mut bytes: &[u8]) {
        while !bytes.is_empty() {
            let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
            if n < 0 {
                let err = std::io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                return;
            }
            bytes = &bytes[n as usize..];
        }
    }
}
