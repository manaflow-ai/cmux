//! Termination signals sent to a terminal host (cx-6so.49, L0).
//!
//! A terminal host is the only process that holds its terminal's PTY
//! master: when it ends, the kernel hangs up the shell and its foreground
//! job. A host is therefore ended only by its owner's `Terminate` frame or
//! by its child's exit, never by a stray signal. `SIGTERM`, `SIGHUP`,
//! `SIGINT` and `SIGQUIT` (a plain `kill PID`, a `pkill -f` that matches the
//! bundle path, a cleanup sweep, a hangup of a former session), and every
//! other catchable signal whose default action ends a process
//! ([`SURVIVED_SIGNALS`]), are recorded and otherwise ignored. `SIGKILL` cannot be caught; the owner then names
//! the loss from the missing exit record and these breadcrumbs.
//!
//! One sender is honored: a `SIGTERM` from PID 1, the service manager
//! (launchd at logout, systemd stopping the unit or the machine, a container
//! init). The session is going away around the host, so the host ends its
//! terminal through the same bounded path as an owner's `Terminate` and
//! writes the exit record, instead of delaying the shutdown until the
//! manager's `SIGKILL` (systemd's stop timeout, 90 s by default).
//!
//! The handler is async-signal-safe: it stores the signal, the sender PID
//! (`SA_SIGINFO`) and the wall-clock time in a fixed table and writes one
//! byte to a non-blocking pipe. A writer thread appends each recorded signal
//! as one JSON line to `<terminal-id>.signals` next to the host's discovery
//! record once the host knows that path. The table is bounded
//! ([`MAX_RECORDED_SIGNALS`]); later signals are counted, not stored.
//!
//! The PTY child does not inherit any of this: handlers reset to the default
//! on `exec`, and `cmux_pty` resets these dispositions and the signal mask
//! before it execs the shell.

use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI32, AtomicI64, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

/// The signals a host records and survives: every catchable signal whose
/// default action ends the process (cx-0tgl LB). `SIGPIPE` stays ignored (the
/// Rust runtime's disposition), so a broken client socket fills no slot.
/// `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGABRT` and `SIGSYS` stay fatal:
/// they report a bug in the host and must leave a crash report.
pub(crate) const SURVIVED_SIGNALS: [libc::c_int; 11] = [
    libc::SIGTERM,
    libc::SIGHUP,
    libc::SIGINT,
    libc::SIGQUIT,
    libc::SIGUSR1,
    libc::SIGUSR2,
    libc::SIGALRM,
    libc::SIGVTALRM,
    libc::SIGPROF,
    libc::SIGXCPU,
    libc::SIGXFSZ,
];

/// Recorded signals per host process; later ones are only counted.
pub(crate) const MAX_RECORDED_SIGNALS: usize = 32;

struct Slot {
    signal: AtomicI32,
    sender_pid: AtomicI32,
    at_ms: AtomicI64,
    /// Set last by the handler: the slot is complete.
    ready: AtomicI32,
}

static SLOTS: [Slot; MAX_RECORDED_SIGNALS] = [const {
    Slot {
        signal: AtomicI32::new(0),
        sender_pid: AtomicI32::new(0),
        at_ms: AtomicI64::new(0),
        ready: AtomicI32::new(0),
    }
}; MAX_RECORDED_SIGNALS];
static NEXT_SLOT: AtomicUsize = AtomicUsize::new(0);
static WAKE_WRITER: AtomicI32 = AtomicI32::new(-1);
static BREADCRUMBS: OnceLock<Breadcrumbs> = OnceLock::new();
static INSTALLED: OnceLock<()> = OnceLock::new();

struct Breadcrumbs {
    path: PathBuf,
    terminal_id: String,
    incarnation: String,
}

/// Where the next slot to append starts; guarded so one writer runs at once.
static WRITTEN: Mutex<usize> = Mutex::new(0);
/// Ends the host's terminal (an owner `Terminate`), once the host runs one.
static TERMINATE: OnceLock<Box<dyn Fn() + Send + Sync>> = OnceLock::new();
/// Slots already checked for a service-manager `SIGTERM`.
static CHECKED: AtomicUsize = AtomicUsize::new(0);

/// A service-manager stop (`SIGTERM` from PID 1) ends the host; every other
/// recorded signal is survived.
pub(crate) fn honors(signal: libc::c_int, sender_pid: libc::pid_t) -> bool {
    signal == libc::SIGTERM && sender_pid == 1
}

/// Register how the host ends its terminal on a service-manager stop.
pub(crate) fn on_service_manager_stop(terminate: Box<dyn Fn() + Send + Sync>) {
    let _ = TERMINATE.set(terminate);
    act_on_service_manager_stop();
}

fn act_on_service_manager_stop() {
    let recorded = NEXT_SLOT.load(Ordering::Acquire).min(MAX_RECORDED_SIGNALS);
    let mut index = CHECKED.load(Ordering::Acquire);
    while index < recorded {
        let slot = &SLOTS[index];
        if slot.ready.load(Ordering::Acquire) == 0 {
            break;
        }
        if honors(slot.signal.load(Ordering::Relaxed), slot.sender_pid.load(Ordering::Relaxed)) {
            match TERMINATE.get() {
                Some(terminate) => terminate(),
                // A host with no terminal yet (standby, launching) just ends.
                // crash-allow: a service-manager stop of a host with no terminal.
                None if BREADCRUMBS.get().is_none() => std::process::exit(0),
                // A terminal is starting: act once its terminate is registered.
                None => return,
            }
        }
        index += 1;
        CHECKED.store(index, Ordering::Release);
    }
}

#[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
unsafe fn errno_location() -> *mut libc::c_int {
    // SAFETY: returns this thread's errno slot.
    unsafe { libc::__error() }
}

#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "freebsd")))]
unsafe fn errno_location() -> *mut libc::c_int {
    // SAFETY: returns this thread's errno slot.
    unsafe { libc::__errno_location() }
}

extern "C" fn record_signal(
    signal: libc::c_int,
    info: *mut libc::siginfo_t,
    _context: *mut libc::c_void,
) {
    // SAFETY: only async-signal-safe calls follow (atomics, clock_gettime,
    // write); errno is restored before returning.
    unsafe {
        let errno = errno_location();
        let saved = *errno;
        let index = NEXT_SLOT.fetch_add(1, Ordering::AcqRel);
        if index < MAX_RECORDED_SIGNALS {
            let slot = &SLOTS[index];
            let sender = if info.is_null() { 0 } else { (*info).si_pid() };
            let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
            libc::clock_gettime(libc::CLOCK_REALTIME, &mut now);
            let at_ms = now.tv_sec.saturating_mul(1000) + now.tv_nsec / 1_000_000;
            slot.signal.store(signal, Ordering::Relaxed);
            slot.sender_pid.store(sender, Ordering::Relaxed);
            slot.at_ms.store(at_ms, Ordering::Relaxed);
            slot.ready.store(1, Ordering::Release);
        }
        let writer = WAKE_WRITER.load(Ordering::Acquire);
        if writer >= 0 {
            let byte = 1u8;
            let _ = libc::write(writer, (&byte as *const u8).cast(), 1);
        }
        *errno = saved;
    }
}

fn cloexec_pipe() -> std::io::Result<(libc::c_int, libc::c_int)> {
    let mut fds = [-1; 2];
    // SAFETY: fds has room for the two descriptors pipe(2) returns.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    for fd in fds {
        // SAFETY: fd was just returned by pipe(2) and is owned here.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
            let error = std::io::Error::last_os_error();
            // SAFETY: both descriptors are owned here and closed once.
            unsafe {
                libc::close(fds[0]);
                libc::close(fds[1]);
            }
            return Err(error);
        }
    }
    // A full pipe must never block the handler.
    // SAFETY: fds[1] is owned here.
    unsafe {
        let flags = libc::fcntl(fds[1], libc::F_GETFL);
        libc::fcntl(fds[1], libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
    Ok((fds[0], fds[1]))
}

/// Install the host's signal guard. Call once, in the host process, after
/// inherited descriptors are closed and before the PTY child starts.
pub(crate) fn install() -> anyhow::Result<()> {
    if INSTALLED.get().is_some() {
        return Ok(());
    }
    let (reader, writer) = cloexec_pipe()?;
    WAKE_WRITER.store(writer, Ordering::Release);
    std::thread::Builder::new().name("terminal-host-signals".into()).spawn(move || {
        let mut buffer = [0u8; 64];
        loop {
            // SAFETY: reader is owned by this thread for the process lifetime.
            let count = unsafe { libc::read(reader, buffer.as_mut_ptr().cast(), buffer.len()) };
            if count == 0 {
                return;
            }
            if count < 0
                && std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted
            {
                return;
            }
            flush();
            act_on_service_manager_stop();
        }
    })?;
    // SAFETY: a zeroed sigaction with a valid SA_SIGINFO handler and an
    // empty mask; the signals are platform constants.
    unsafe {
        let mut action = std::mem::zeroed::<libc::sigaction>();
        action.sa_sigaction = record_signal as *const () as libc::sighandler_t;
        action.sa_flags = libc::SA_SIGINFO | libc::SA_RESTART;
        if libc::sigemptyset(&mut action.sa_mask) != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        for signal in SURVIVED_SIGNALS {
            if libc::sigaction(signal, &action, std::ptr::null_mut()) != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        // Whatever the launcher left, a host survives `SIGPIPE`; the PTY
        // child gets the default back before it execs.
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    }
    let _ = INSTALLED.set(());
    Ok(())
}

/// Name the breadcrumb file once the host knows its identity, and write any
/// signal recorded before that.
pub(crate) fn set_breadcrumb_path(path: PathBuf, terminal_id: String, incarnation: String) {
    let _ = BREADCRUMBS.set(Breadcrumbs { path, terminal_id, incarnation });
    flush();
}

fn flush() {
    let Some(breadcrumbs) = BREADCRUMBS.get() else { return };
    let mut written = WRITTEN.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let recorded = NEXT_SLOT.load(Ordering::Acquire);
    let mut lines = String::new();
    while *written < recorded.min(MAX_RECORDED_SIGNALS) {
        let slot = &SLOTS[*written];
        if slot.ready.load(Ordering::Acquire) == 0 {
            break;
        }
        let line = serde_json::json!({
            "terminal_id": breadcrumbs.terminal_id,
            "incarnation": breadcrumbs.incarnation,
            "signal": slot.signal.load(Ordering::Relaxed),
            "sender_pid": slot.sender_pid.load(Ordering::Relaxed),
            "at_ms": slot.at_ms.load(Ordering::Relaxed),
            "action": if honors(
                slot.signal.load(Ordering::Relaxed),
                slot.sender_pid.load(Ordering::Relaxed),
            ) {
                "ended"
            } else {
                "ignored"
            },
        });
        lines.push_str(&line.to_string());
        lines.push('\n');
        *written += 1;
    }
    if recorded > MAX_RECORDED_SIGNALS && *written == MAX_RECORDED_SIGNALS {
        // Counted, not stored; one summary line per flush past the cap.
        let line = serde_json::json!({
            "terminal_id": breadcrumbs.terminal_id,
            "incarnation": breadcrumbs.incarnation,
            "dropped": recorded - MAX_RECORDED_SIGNALS,
        });
        lines.push_str(&line.to_string());
        lines.push('\n');
    }
    if lines.is_empty() {
        return;
    }
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&breadcrumbs.path)
    {
        let _ = file.write_all(lines.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_service_manager_term_ends_the_host() {
        assert!(honors(libc::SIGTERM, 1));
        for sender in [0, 2, 4242] {
            assert!(!honors(libc::SIGTERM, sender), "TERM from {sender}");
        }
        for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT] {
            assert!(!honors(signal, 1), "signal {signal} from PID 1");
        }
    }
}
