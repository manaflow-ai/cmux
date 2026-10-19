//! Termination signals sent to a terminal host (cx-6so.49, L0).
//!
//! A terminal host is the only process that holds its terminal's PTY
//! master: when it ends, the kernel hangs up the shell and its foreground
//! job. A host is therefore ended only by its owner's `Terminate` frame or
//! by its child's exit, never by a stray signal. `SIGTERM`, `SIGHUP`,
//! `SIGINT` and `SIGQUIT` (a plain `kill PID`, a `pkill -f` that matches the
//! bundle path, a cleanup sweep, a hangup of a former session), and the
//! other catchable signals whose default action ends or stops a process
//! ([`SURVIVED_SIGNALS`]), are recorded and otherwise ignored. `SIGKILL` cannot be caught; the owner then names
//! the loss from the missing exit record and these breadcrumbs.
//!
//! In a build with an orphan grace (tagged DEV, staging, debug; cx-t2sqm
//! D1), an orphaned host honors a plain `SIGTERM` from any sender
//! (cx-hostorphan): when no client stream is attached (its owner daemon is
//! gone and none adopted it), the host ends its terminal through the same
//! path as an owner's `Terminate`, so a throwaway build's host does not hold
//! its PTY until reboot. A normal install's host (no orphan grace) and a
//! host its daemon still serves keep the rule above: quitting or updating
//! cmux, a cleanup script or a `pkill` never ends a user's terminal
//! (cx-t2sqm.17).
//!
//! One sender is always honored: a `SIGTERM` from PID 1, the service manager
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
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicI64, AtomicU32, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// The signals a host records and survives: every catchable signal whose
/// default action ends or stops the process (cx-0tgl LB), plus, on Linux,
/// the real-time signals ([`survived_signals`]). `SIGPIPE` stays ignored (the
/// Rust runtime's disposition), so a broken client socket fills no slot.
/// `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGABRT`, `SIGTRAP` and `SIGSYS`
/// stay fatal: they report a bug in the host and must leave a crash report.
pub(crate) const SURVIVED_SIGNALS: [libc::c_int; 14] = [
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
    libc::SIGTSTP,
    libc::SIGTTIN,
    libc::SIGTTOU,
];

/// [`SURVIVED_SIGNALS`] plus the platform's other default-terminating
/// signals. On Linux the real-time range starts at glibc's `SIGRTMIN()`,
/// above the signals it reserves for threads.
fn survived_signals() -> Vec<libc::c_int> {
    let mut signals = SURVIVED_SIGNALS.to_vec();
    #[cfg(target_os = "linux")]
    {
        signals.extend([libc::SIGIO, libc::SIGPWR, libc::SIGSTKFLT]);
        signals.extend(libc::SIGRTMIN()..=libc::SIGRTMAX());
    }
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
    signals.push(libc::SIGEMT);
    signals
}

/// Recorded signals per host process; later ones are only counted.
pub(crate) const MAX_RECORDED_SIGNALS: usize = 32;

struct Slot {
    signal: AtomicI32,
    sender_pid: AtomicI32,
    /// The sender's real user id: still true after the sender exited.
    sender_uid: AtomicU32,
    at_ms: AtomicI64,
    /// Set last by the handler: the slot is complete.
    ready: AtomicI32,
}

static SLOTS: [Slot; MAX_RECORDED_SIGNALS] = [const {
    Slot {
        signal: AtomicI32::new(0),
        sender_pid: AtomicI32::new(0),
        sender_uid: AtomicU32::new(u32::MAX),
        at_ms: AtomicI64::new(0),
        ready: AtomicI32::new(0),
    }
}; MAX_RECORDED_SIGNALS];
static NEXT_SLOT: AtomicUsize = AtomicUsize::new(0);
static WAKE_WRITER: AtomicI32 = AtomicI32::new(-1);
static INSTALLED: OnceLock<()> = OnceLock::new();

struct Breadcrumbs {
    path: PathBuf,
    terminal_id: String,
    incarnation: String,
}

/// How a terminal of this process reacts to the signals the process gets.
/// A host process runs one terminal, or many in a shared host
/// (`shared_host.rs`); a signal to the process reaches every terminal it
/// runs, and each records it in its own breadcrumb file.
pub(crate) struct TerminalSignalHooks {
    /// Ends the terminal (an owner `Terminate`).
    pub(crate) terminate: Box<dyn Fn() + Send + Sync>,
    /// True when no client stream is attached (the owner daemon is gone).
    pub(crate) orphaned: Box<dyn Fn() -> bool + Send + Sync>,
    /// Marks the terminal as ended because its owner is gone.
    pub(crate) mark_owner_gone: Box<dyn Fn() + Send + Sync>,
}

struct Entry {
    hooks: TerminalSignalHooks,
    breadcrumbs: OnceLock<Breadcrumbs>,
    /// Where the next slot to append starts; guarded so one writer runs at
    /// once.
    written: Mutex<usize>,
    /// The terminal was asked to end for the service-manager stop.
    stop_acted: AtomicBool,
    /// The terminal was asked to end for a `SIGTERM` while orphaned.
    orphan_term_acted: AtomicBool,
    /// The slot of the `SIGTERM` that ended it (`usize::MAX`: none), so
    /// only that breadcrumb says `ended`.
    orphan_term_slot: AtomicUsize,
    /// Dropped signals already summarized in its breadcrumb file.
    dropped_reported: AtomicUsize,
    /// A breadcrumb append failed (for example `EFBIG` past
    /// `RLIMIT_FSIZE`): stop writing, so a failing write cannot raise
    /// `SIGXFSZ` again in a loop.
    failed: AtomicBool,
}

/// The terminals this process runs.
static ENTRIES: Mutex<Vec<Arc<Entry>>> = Mutex::new(Vec::new());
/// Set by the handler on a `SIGTERM` from PID 1, outside the slot table, so
/// a service-manager stop is honored after the table is full.
static SERVICE_STOP: AtomicBool = AtomicBool::new(false);
/// Set by the handler on any `SIGTERM`; the writer thread ends each
/// terminal that is orphaned ([`TerminalSignalHooks::orphaned`]).
static TERM_PENDING: AtomicBool = AtomicBool::new(false);

/// A service-manager stop (`SIGTERM` from PID 1) ends the host; every other
/// recorded signal is survived.
pub(crate) fn honors(signal: libc::c_int, sender_pid: libc::pid_t) -> bool {
    signal == libc::SIGTERM && sender_pid == 1
}

/// One terminal's registration; dropping it removes the terminal.
pub(crate) struct Registration(Arc<Entry>);

impl Registration {
    /// Name the breadcrumb file once the terminal's identity is known, and
    /// write any signal recorded before that.
    pub(crate) fn set_breadcrumb_path(
        &self,
        path: PathBuf,
        terminal_id: String,
        incarnation: String,
    ) {
        if !super::super::shared::host_state::shared_host_process() {
            // A shared host attributes panics per thread instead
            // (`host_crash::enter_terminal`).
            super::super::shared::host_crash::install(
                path.with_extension("crash"),
                &terminal_id,
                &incarnation,
            );
        }
        let _ = self.0.breadcrumbs.set(Breadcrumbs { path, terminal_id, incarnation });
        flush_entry(&self.0);
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        let mut entries = ENTRIES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        entries.retain(|entry| !Arc::ptr_eq(entry, &self.0));
        // A shared host stopped by its service manager ends once its last
        // terminal ended (a one-terminal host returns from its loop).
        if entries.is_empty()
            && SERVICE_STOP.load(Ordering::Acquire)
            && super::super::shared::host_state::shared_host_process()
        {
            // Its terminals all ended; their exit records are written.
            // crash-allow: a service-manager stop of a shared host.
            std::process::exit(0);
        }
    }
}

/// Register a terminal of this process: how it ends on a service-manager
/// stop or, orphaned, on a `SIGTERM`.
pub(crate) fn register(hooks: TerminalSignalHooks) -> Registration {
    // A one-terminal host records every signal since its start (they were
    // sent to its terminal); a shared host's later terminal only those
    // after it joined.
    let start = if super::super::shared::host_state::shared_host_process() {
        NEXT_SLOT.load(Ordering::Acquire).min(MAX_RECORDED_SIGNALS)
    } else {
        0
    };
    let entry = Arc::new(Entry {
        hooks,
        breadcrumbs: OnceLock::new(),
        written: Mutex::new(start),
        stop_acted: AtomicBool::new(false),
        orphan_term_acted: AtomicBool::new(false),
        orphan_term_slot: AtomicUsize::new(usize::MAX),
        dropped_reported: AtomicUsize::new(0),
        failed: AtomicBool::new(false),
    });
    ENTRIES.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(entry.clone());
    act_on_service_manager_stop();
    Registration(entry)
}

fn entries() -> Vec<Arc<Entry>> {
    ENTRIES.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
}

/// A `SIGTERM` to an orphaned terminal ends it; one to a terminal its
/// daemon serves is only recorded. Runs on the writer thread.
fn act_on_orphan_term() {
    if !TERM_PENDING.swap(false, Ordering::AcqRel) {
        return;
    }
    // The newest recorded SIGTERM is the one acted on.
    let recorded = NEXT_SLOT.load(Ordering::Acquire).min(MAX_RECORDED_SIGNALS);
    let slot = (0..recorded).rev().find(|index| {
        SLOTS[*index].ready.load(Ordering::Acquire) == 1
            && SLOTS[*index].signal.load(Ordering::Relaxed) == libc::SIGTERM
    });
    for entry in entries() {
        if (entry.hooks.orphaned)() && !entry.orphan_term_acted.swap(true, Ordering::AcqRel) {
            if let Some(index) = slot {
                entry.orphan_term_slot.store(index, Ordering::Release);
            }
            (entry.hooks.mark_owner_gone)();
            (entry.hooks.terminate)();
        }
    }
}

fn act_on_service_manager_stop() {
    if !SERVICE_STOP.load(Ordering::Acquire) {
        return;
    }
    let entries = entries();
    if entries.is_empty() {
        // A host with no terminal (standby, launching, or a shared host
        // whose terminals all ended) just ends.
        // crash-allow: a service-manager stop of a host with no terminal.
        std::process::exit(0);
    }
    for entry in entries {
        if !entry.stop_acted.swap(true, Ordering::AcqRel) {
            (entry.hooks.terminate)();
        }
    }
}

/// The sender's real user id from an `SA_SIGINFO` record.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
unsafe fn siginfo_uid(info: *mut libc::siginfo_t) -> u32 {
    // SAFETY: the caller passes the kernel's non-null siginfo.
    unsafe { (*info).si_uid }
}

/// The sender's real user id from an `SA_SIGINFO` record.
#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "freebsd")))]
unsafe fn siginfo_uid(info: *mut libc::siginfo_t) -> u32 {
    // SAFETY: the caller passes the kernel's non-null siginfo.
    unsafe { (*info).si_uid() }
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
        let sender = if info.is_null() { 0 } else { (*info).si_pid() };
        let sender_uid = if info.is_null() { u32::MAX } else { siginfo_uid(info) };
        if honors(signal, sender) {
            SERVICE_STOP.store(true, Ordering::Release);
        } else if signal == libc::SIGTERM {
            TERM_PENDING.store(true, Ordering::Release);
        }
        let index = NEXT_SLOT.fetch_add(1, Ordering::AcqRel);
        if index < MAX_RECORDED_SIGNALS {
            let slot = &SLOTS[index];
            let mut now = libc::timespec { tv_sec: 0, tv_nsec: 0 };
            libc::clock_gettime(libc::CLOCK_REALTIME, &mut now);
            let at_ms = now.tv_sec.saturating_mul(1000) + now.tv_nsec / 1_000_000;
            slot.signal.store(signal, Ordering::Relaxed);
            slot.sender_pid.store(sender, Ordering::Relaxed);
            slot.sender_uid.store(sender_uid, Ordering::Relaxed);
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
            // A service-manager stop first: naming senders reads /proc.
            act_on_service_manager_stop();
            act_on_orphan_term();
            flush();
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
        for signal in survived_signals() {
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

fn flush() {
    for entry in entries() {
        flush_entry(&entry);
    }
}

fn flush_entry(entry: &Entry) {
    let Some(breadcrumbs) = entry.breadcrumbs.get() else { return };
    if entry.failed.load(Ordering::Acquire) {
        return;
    }
    let mut written = entry.written.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let recorded = NEXT_SLOT.load(Ordering::Acquire);
    let mut lines = String::new();
    while *written < recorded.min(MAX_RECORDED_SIGNALS) {
        let slot = &SLOTS[*written];
        if slot.ready.load(Ordering::Acquire) == 0 {
            break;
        }
        let sender_pid = slot.sender_pid.load(Ordering::Relaxed);
        let at_ms = slot.at_ms.load(Ordering::Relaxed);
        let sender_uid = slot.sender_uid.load(Ordering::Relaxed);
        let line = serde_json::json!({
            "terminal_id": breadcrumbs.terminal_id,
            "incarnation": breadcrumbs.incarnation,
            "signal": slot.signal.load(Ordering::Relaxed),
            "sender_pid": sender_pid,
            // Who sent it (cx-0tgl LA), read while the sender usually still
            // runs: an external killer is named in the loss line.
            "sender": u32::try_from(sender_pid).ok().and_then(|pid| {
                crate::process_identity::describe_sender(pid, u64::try_from(at_ms).unwrap_or(0))
            }),
            "sender_uid": (sender_uid != u32::MAX).then_some(sender_uid),
            "at_ms": at_ms,
            "action": if honors(
                slot.signal.load(Ordering::Relaxed),
                slot.sender_pid.load(Ordering::Relaxed),
            ) || entry.orphan_term_slot.load(Ordering::Acquire) == *written
            {
                "ended"
            } else {
                "ignored"
            },
        });
        lines.push_str(&line.to_string());
        lines.push('\n');
        *written += 1;
    }
    let dropped = recorded.saturating_sub(MAX_RECORDED_SIGNALS);
    let reported = entry.dropped_reported.load(Ordering::Acquire);
    if *written == MAX_RECORDED_SIGNALS && dropped > 0 && dropped >= reported.saturating_mul(2) {
        // Counted, not stored. A summary line each time the count doubles,
        // so frequent signals (a profiling timer, SIGXCPU) cannot grow the
        // file without bound.
        entry.dropped_reported.store(dropped, Ordering::Release);
        let line = serde_json::json!({
            "terminal_id": breadcrumbs.terminal_id,
            "incarnation": breadcrumbs.incarnation,
            "dropped": dropped,
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
        && file.write_all(lines.as_bytes()).is_err()
    {
        entry.failed.store(true, Ordering::Release);
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
