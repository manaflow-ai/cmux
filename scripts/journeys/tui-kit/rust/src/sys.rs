//! The few C calls the programs need, declared here so the crate has no dependencies: the
//! monotonic clock Python's `time.monotonic()` reads, the terminal size, and signal flags.

use std::os::raw::{c_int, c_long, c_ulong};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[repr(C)]
struct Timespec {
    tv_sec: i64,
    tv_nsec: c_long,
}

#[repr(C)]
#[derive(Default)]
struct Winsize {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}

// nfds_t: unsigned int on macOS, unsigned long on Linux.
#[cfg(target_os = "macos")]
type Nfds = u32;
#[cfg(not(target_os = "macos"))]
type Nfds = c_ulong;

#[repr(C)]
struct Pollfd {
    fd: c_int,
    events: i16,
    revents: i16,
}

extern "C" {
    fn clock_gettime(clock_id: c_int, tp: *mut Timespec) -> c_int;
    fn poll(fds: *mut Pollfd, nfds: Nfds, timeout: c_int) -> c_int;
    #[cfg(target_os = "macos")]
    fn getpriority(which: c_int, who: u32) -> c_int;
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
    fn signal(signum: c_int, handler: extern "C" fn(c_int)) -> usize;
}

// Python 3.9's time.monotonic() is mach_absolute_time on macOS (CLOCK_UPTIME_RAW) and
// CLOCK_MONOTONIC on Linux: the same clock, so the programs' stamps line up with the Python kit's.
#[cfg(target_os = "macos")]
const MONO_CLOCK: c_int = 8;
#[cfg(not(target_os = "macos"))]
const MONO_CLOCK: c_int = 1;

#[cfg(target_os = "macos")]
const TIOCGWINSZ: c_ulong = 0x4008_7468;
#[cfg(not(target_os = "macos"))]
const TIOCGWINSZ: c_ulong = 0x5413;

pub const SIGHUP: c_int = 1;
pub const SIGINT: c_int = 2;
pub const SIGTERM: c_int = 15;
pub const SIGWINCH: c_int = 28;

static QUIT: AtomicBool = AtomicBool::new(false);
static WINCH: AtomicBool = AtomicBool::new(false);

fn start() -> Instant {
    static START: OnceLock<Instant> = OnceLock::new();
    *START.get_or_init(Instant::now)
}

/// Seconds on the monotonic clock (the same clock as Python's `time.monotonic()`).
pub fn monotonic() -> f64 {
    let mut ts = Timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid, writable timespec for the duration of the call.
    let rc = unsafe { clock_gettime(MONO_CLOCK, &mut ts) };
    if rc != 0 {
        return start().elapsed().as_secs_f64();
    }
    ts.tv_sec as f64 + ts.tv_nsec as f64 / 1e9
}

/// Seconds since the Unix epoch (Python's `time.time()`).
pub fn wall() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// The terminal's (columns, rows) on stdout, or None when stdout is no terminal.
pub fn term_size() -> Option<(usize, usize)> {
    let mut ws = Winsize::default();
    // SAFETY: TIOCGWINSZ writes one winsize into the valid `ws`.
    let rc = unsafe { ioctl(1, TIOCGWINSZ, &mut ws as *mut Winsize) };
    if rc != 0 || ws.ws_col == 0 || ws.ws_row == 0 {
        return None;
    }
    Some((usize::from(ws.ws_col), usize::from(ws.ws_row)))
}

extern "C" fn on_quit(_signum: c_int) {
    QUIT.store(true, Ordering::SeqCst);
}

extern "C" fn on_winch(_signum: c_int) {
    WINCH.store(true, Ordering::SeqCst);
}

/// SIGTERM, SIGINT and SIGHUP set the quit flag (the program ends cleanly after the frame it draws);
/// with `winch`, SIGWINCH sets the size flag.
pub fn install_signals(winch: bool) {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        // SAFETY: the handler only stores to an atomic, which is async-signal-safe.
        unsafe {
            signal(sig, on_quit);
        }
    }
    if winch {
        // SAFETY: as above.
        unsafe {
            signal(SIGWINCH, on_winch);
        }
    }
}

/// Waits up to 1 s until `fd` can take a write (POLLOUT); a non-blocking stdout that was full.
pub fn wait_writable(fd: c_int) {
    let mut p = Pollfd {
        fd,
        events: 0x0004,
        revents: 0,
    };
    // SAFETY: one valid pollfd, nfds 1.
    let _ = unsafe { poll(&mut p, 1, 1000) };
}

/// Whether this process is in the Darwin background class: "yes", "no", or "n/a" off macOS
/// (tuikit.py `darwin_bg`).
pub fn darwin_bg() -> &'static str {
    #[cfg(target_os = "macos")]
    {
        // SAFETY: PRIO_DARWIN_PROCESS (4) of this process (0); no pointers.
        let value = unsafe { getpriority(4, 0) };
        if value == -1 {
            return "err";
        }
        if value & 0x1000 != 0 {
            "yes"
        } else {
            "no"
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        "n/a"
    }
}

pub fn quit_requested() -> bool {
    QUIT.load(Ordering::SeqCst)
}

/// Whether a SIGWINCH came since the last call (and clears it).
pub fn take_winch() -> bool {
    WINCH.swap(false, Ordering::SeqCst)
}
