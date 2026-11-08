//! `server ensure --replace-unresponsive` (cx-jniyz): replace an owner that
//! accepts connections on the session socket but never answers `identify`.
//!
//! Plain `ensure` waits for such an owner (it reads as restoring) and the app
//! retries it every 2 minutes. The app's "Restart cmux-tui" button runs this
//! option instead, after a warning that terminals of a stuck owner may be
//! lost.
//!
//! The owner is found only through the socket, never by a process walk: the
//! kernel names the process that listens on the session socket (macOS
//! `LOCAL_PEERTOKEN`, Linux `SO_PEERCRED`), also for a connection the owner
//! never accepts. The key is the pid and its pid version, so a later process
//! that reuses the pid never matches. The owner is replaced only when:
//! - the listener runs as this user,
//! - one `identify` gets no answer within `PROBE_DEADLINE` (an owner that
//!   answers, also one that reports it is still starting, is kept and
//!   awaited by the normal ensure), or the owner refuses every connection
//!   at its connection limit for that bound (a wedged owner whose connection
//!   threads never end, https://github.com/manaflow-ai/cmux/issues/22311),
//! - the same process still listens after the exit watch is armed.
//!
//! An owner that answers `identify` is still replaced when its `server-stats`
//! name one holder of the workspace registry lock for `WEDGED_HOLD`
//! (`replace_if_wedged`, plain `ensure` too; `server status`, which the app
//! runs first, reports such an owner not running so the app ensures): a
//! lock-order deadlock (#32405,
//! #32621) left owners that answered `identify`, which takes no registry
//! lock, while every workspace change waited forever; the owner outlived app
//! quits and updates, so no new build ever reached it. No healthy owner holds
//! the registry that long: every request holds it for one commit.
//!
//! The caller decides when an owner is stuck: an owner also holds connections
//! unanswered while it restores its session (up to `RESTORE_DEADLINE`), and
//! this probe cannot tell the two apart. Nor can it tell a wedged owner at its
//! connection limit from a healthy one whose clients all stay connected. A
//! stopped listener is the exception (`listener_is_stopped`): plain ensure
//! reports it unavailable at once. The app offers the option only after a
//! plain ensure has failed (`server.restore_timeout`, `server.unavailable`,
//! `server.busy` or no answer), so the restore bound or the busy bound has
//! passed, or the owner is stopped. Replacing a slow restore costs restore
//! time, not terminals: the hosts survive and the next owner adopts them.
//!
//! Stop: SIGTERM and SIGCONT (a stopped process acts on SIGTERM only after it
//! continues), wait for the exit up to `TERM_GRACE`, then SIGKILL and wait up
//! to `KILL_GRACE`. The wait is an exit event (Linux pidfd, macOS kqueue
//! `NOTE_EXIT`), never a timer loop. Only the owner process is signaled: its
//! terminal hosts keep their PTYs and the next owner adopts them. The caller
//! then runs the normal ensure, which starts the new owner.

use std::io;
use std::io::{BufRead, BufReader, Read, Write};
use std::time::{Duration, Instant};

use super::OwnerSpec;

#[cfg(all(test, unix))]
#[path = "replace_tests.rs"]
mod tests;

/// How long one `identify` may stay unanswered before the owner counts as
/// unresponsive. Matches the lifecycle exchange bound.
const PROBE_DEADLINE: Duration = super::ENSURE_DEADLINE;

/// How long one holder of the owner's workspace registry lock makes it a
/// wedged owner. `CMUX_TUI_DEBUG_WEDGED_HOLD_MS` shortens it for tests.
const WEDGED_HOLD: Duration = Duration::from_secs(120);

/// How long the wedge check waits for the owner's answers.
const WEDGE_PROBE_DEADLINE: Duration = Duration::from_secs(2);

fn wedged_hold() -> Duration {
    std::env::var("CMUX_TUI_DEBUG_WEDGED_HOLD_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .map_or(WEDGED_HOLD, Duration::from_millis)
}

/// Wait for the owner to end after SIGTERM before SIGKILL.
const TERM_GRACE: Duration = Duration::from_secs(5);

/// Wait for the owner to end after SIGKILL.
const KILL_GRACE: Duration = Duration::from_secs(5);

/// The listener of the session socket, as the kernel names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Listener {
    pid: u32,
    version: u64,
}

/// An unresponsive owner was stopped.
pub(crate) struct Replaced {
    /// The pid of the stopped owner.
    pub pid: u32,
}

/// Why the owner was not replaced. Each has a JSON error code.
#[derive(Debug)]
pub(crate) enum ReplaceError {
    /// This platform cannot name the socket's listener.
    Unsupported,
    /// The kernel did not name the socket's listener.
    ListenerUnknown,
    /// The listener runs as another user.
    #[cfg_attr(not(unix), allow(dead_code))]
    DifferentUser,
    /// Another process listens now than the one probed.
    ListenerChanged,
    /// The stop signal could not be sent.
    Signal(io::Error),
    /// The owner did not end after SIGKILL.
    StillRunning,
}

impl ReplaceError {
    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::Unsupported => "server.replace_unsupported",
            Self::ListenerUnknown => "server.replace_listener_unknown",
            Self::DifferentUser => "server.replace_different_user",
            Self::ListenerChanged => "server.replace_listener_changed",
            Self::Signal(_) => "server.replace_signal_failed",
            Self::StillRunning => "server.replace_still_running",
        }
    }
}

/// Stops the session's owner when it accepts but does not answer. `Ok(None)`:
/// nothing to replace (no owner, or it answered); the caller's normal ensure
/// handles it.
pub(crate) fn replace_if_unresponsive(spec: &OwnerSpec) -> Result<Option<Replaced>, ReplaceError> {
    let Ok(probe) =
        cmux_tui_core::server::connect_session_socket(&spec.socket, spec.socket_is_derived)
    else {
        return Ok(None);
    };
    // Read on the probed connection; refuse only once the owner is stuck, so
    // a healthy owner never fails here.
    let key = probe.peer_process_key();
    if !unresponsive(spec, probe) {
        return replace_if_wedged(spec);
    }
    stop(spec, key)
}

/// Stops the session's owner when it answers but its workspace registry lock
/// has had one holder for `WEDGED_HOLD` (a deadlocked owner). `Ok(None)`: no
/// owner, an owner that does not report the lock (an older build, or one
/// that does not answer `server-stats` in time), or one that is not wedged.
pub(crate) fn replace_if_wedged(spec: &OwnerSpec) -> Result<Option<Replaced>, ReplaceError> {
    let Ok(probe) =
        cmux_tui_core::server::connect_session_socket(&spec.socket, spec.socket_is_derived)
    else {
        return Ok(None);
    };
    let key = probe.peer_process_key();
    if !is_wedged(probe, Some(&spec.session)) {
        return Ok(None);
    }
    stop(spec, key)
}

/// Replaces a healthy owner that was launched for another NEXT Cloud backend.
/// The owner process is the only thing stopped; its terminal hosts stay alive
/// and the replacement adopts them from the durable registry. `Ok(None)` means
/// the socket disappeared or already reports the requested backend.
pub(crate) fn replace_if_backend_changed(
    spec: &OwnerSpec,
    expected_backend: &str,
) -> Result<Option<Replaced>, ReplaceError> {
    let Ok(probe) =
        cmux_tui_core::server::connect_session_socket(&spec.socket, spec.socket_is_derived)
    else {
        return Ok(None);
    };
    let key = probe.peer_process_key();
    let mut connection = BufReader::new(probe);
    let deadline = Instant::now() + PROBE_DEADLINE;
    let Some(identity) = request(&mut connection, "identify", deadline) else {
        return Ok(None);
    };
    if identity.get("session").and_then(|value| value.as_str()) != Some(spec.session.as_str()) {
        return Ok(None);
    }
    if identity.get("cloud_backend").and_then(|value| value.as_str()) == Some(expected_backend) {
        return Ok(None);
    }
    stop(spec, key)
}

/// Whether the owner on `stream` is wedged: its `server-stats` name one
/// holder of the workspace registry lock for `WEDGED_HOLD`. With `session`,
/// only an owner of that session counts (an owner of another session is
/// never ours to stop). False for no answer within `WEDGE_PROBE_DEADLINE`
/// (a restoring owner parks its connections; a wedged one answers at once)
/// or an owner that does not report the lock.
pub(crate) fn is_wedged(
    stream: Box<dyn cmux_tui_core::platform::transport::Stream>,
    session: Option<&str>,
) -> bool {
    let mut connection = BufReader::new(stream);
    let deadline = Instant::now() + WEDGE_PROBE_DEADLINE;
    if let Some(session) = session {
        let identity = request(&mut connection, "identify", deadline);
        if identity.as_ref().and_then(|value| value.get("session")).and_then(|value| value.as_str())
            != Some(session)
        {
            return false;
        }
    }
    request(&mut connection, "server-stats", deadline)
        .and_then(|stats| stats.pointer("/registry_lock/holder/held_for_us")?.as_u64())
        .is_some_and(|held| Duration::from_micros(held) >= wedged_hold())
}

/// Stops the listener named by `key` (the probed connection's peer).
fn stop(spec: &OwnerSpec, key: Option<String>) -> Result<Option<Replaced>, ReplaceError> {
    let listener = listener_of(key)?;
    require_same_user(spec)?;
    let watch = sys::ExitWatch::arm(listener.pid).map_err(ReplaceError::Signal)?;
    let Some(watch) = watch else {
        // It ended between the probe and the watch.
        return Ok(Some(Replaced { pid: listener.pid }));
    };
    if watch.wait(Instant::now()) {
        return Ok(Some(Replaced { pid: listener.pid }));
    }
    // The watch holds this pid now: the same process must still listen.
    let current =
        cmux_tui_core::server::connect_session_socket(&spec.socket, spec.socket_is_derived)
            .ok()
            .map(|stream| listener_of(stream.peer_process_key()))
            .transpose()?;
    if current != Some(listener) {
        return Err(ReplaceError::ListenerChanged);
    }
    watch.signal(sys::SIGTERM).map_err(ReplaceError::Signal)?;
    watch.signal(sys::SIGCONT).map_err(ReplaceError::Signal)?;
    if watch.wait(Instant::now() + TERM_GRACE) {
        return Ok(Some(Replaced { pid: listener.pid }));
    }
    watch.signal(sys::SIGKILL).map_err(ReplaceError::Signal)?;
    if watch.wait(Instant::now() + KILL_GRACE) {
        return Ok(Some(Replaced { pid: listener.pid }));
    }
    Err(ReplaceError::StillRunning)
}

/// Whether the process listening on the session socket (`key`, from
/// `transport::Stream::peer_process_key`) is stopped: SIGSTOP or a debugger
/// holds it, so it answers nothing and restores nothing until continued.
/// False when the listener or its state is unknown (a restoring owner is
/// never called stopped).
pub(super) fn listener_is_stopped(key: Option<&str>) -> bool {
    listener_of(key.map(str::to_owned)).is_ok_and(|listener| process_is_stopped(listener.pid))
}

#[cfg(target_os = "macos")]
fn process_is_stopped(pid: u32) -> bool {
    /// `SSTOP` from `<sys/proc.h>`.
    const SSTOP: u32 = 4;
    let Ok(pid) = i32::try_from(pid) else { return false };
    // SAFETY: an all-zero proc_bsdinfo is a valid out-buffer.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let Ok(size) = i32::try_from(size_of::<libc::proc_bsdinfo>()) else { return false };
    // SAFETY: the out-buffer is valid for `size` bytes.
    let read =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    read == size && info.pbi_status == SSTOP
}

/// Linux would read the state from `/proc/<pid>/stat`, which the no-process-scan guard keeps out
/// of product code: a stopped owner there waits out the restore bound as before.
#[cfg(not(target_os = "macos"))]
fn process_is_stopped(_pid: u32) -> bool {
    false
}

/// Parses `token:<pid>.<version>` (`transport::Stream::peer_process_key`).
fn listener_of(key: Option<String>) -> Result<Listener, ReplaceError> {
    if !sys::SUPPORTED {
        return Err(ReplaceError::Unsupported);
    }
    let key = key.ok_or(ReplaceError::ListenerUnknown)?;
    let (pid, version) = key
        .strip_prefix("token:")
        .and_then(|rest| rest.split_once('.'))
        .ok_or(ReplaceError::ListenerUnknown)?;
    let pid: u32 = pid.parse().map_err(|_| ReplaceError::ListenerUnknown)?;
    let version: u64 = version.parse().map_err(|_| ReplaceError::ListenerUnknown)?;
    // Never this process, never init or the kernel.
    if pid <= 1 || pid == std::process::id() {
        return Err(ReplaceError::ListenerUnknown);
    }
    Ok(Listener { pid, version })
}

/// One `command` on `connection` and its reply's `data`. `None`: no answer
/// before `deadline`, a refusal, an error reply or an unreadable one.
fn request(
    connection: &mut BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>,
    command: &str,
    deadline: Instant,
) -> Option<serde_json::Value> {
    let remaining =
        deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
    connection.get_ref().set_write_timeout(Some(remaining)).ok()?;
    // `revisions` is opt-in on identify so older strict clients keep their
    // wire shape. The backend handoff probe needs the optional NEXT identity.
    let request = request_value(command);
    writeln!(connection.get_mut(), "{request}").and_then(|()| connection.get_mut().flush()).ok()?;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return None;
        }
        connection.get_ref().set_read_timeout(Some(remaining)).ok()?;
        let mut line = Vec::new();
        let limit = super::identify::RESPONSE_LIMIT as u64 + 2;
        match connection.by_ref().take(limit).read_until(b'\n', &mut line) {
            Ok(0) => return None,
            Ok(_) if !line.ends_with(b"\n") => return None,
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return None,
        }
        if super::identify::is_refusal(&line) {
            return None;
        }
        let mut reply: serde_json::Value = serde_json::from_slice(&line).ok()?;
        // Events the owner sends before the reply are not it.
        if reply.get("id") != Some(&serde_json::json!(1)) {
            continue;
        }
        if reply.get("ok") != Some(&serde_json::json!(true)) {
            return None;
        }
        return reply.get_mut("data").map(serde_json::Value::take);
    }
}

fn request_value(command: &str) -> serde_json::Value {
    if command == "identify" {
        serde_json::json!({"id":1,"cmd":command,"revisions":true})
    } else {
        serde_json::json!({"id":1,"cmd":command})
    }
}

/// How one `identify` on a fresh connection ended.
enum Probe {
    /// An answer (also "still starting"), or the connection closed.
    Answered,
    /// No answer before the deadline.
    Silent,
    /// The owner refused the connection at its connection limit.
    Refused,
}

/// Whether the owner gives no answer for `PROBE_DEADLINE`: one `identify`
/// stays unanswered, or every connection is refused at the connection limit
/// (re-asked on a new connection, since a healthy owner frees a slot as soon
/// as one of its clients leaves). Any answer, also "still starting", or a
/// closed connection is not a stuck owner.
fn unresponsive(
    spec: &OwnerSpec,
    mut stream: Box<dyn cmux_tui_core::platform::transport::Stream>,
) -> bool {
    let deadline = Instant::now() + PROBE_DEADLINE;
    loop {
        // Refusals consume the busy budget, not the next accepted client's
        // identify budget. An owner that frees a slot near that deadline
        // still gets the full silent-probe bound to answer.
        let read_until = Instant::now() + PROBE_DEADLINE;
        match probe(stream, read_until) {
            Probe::Answered => return false,
            Probe::Silent => return true,
            Probe::Refused if Instant::now() >= deadline => return true,
            Probe::Refused => {}
        }
        std::thread::sleep(super::BUSY_POLL_INTERVAL);
        let Ok(next) =
            cmux_tui_core::server::connect_session_socket(&spec.socket, spec.socket_is_derived)
        else {
            // Nothing listens any more: the normal ensure starts an owner.
            return false;
        };
        stream = next;
    }
}

fn probe(stream: Box<dyn cmux_tui_core::platform::transport::Stream>, deadline: Instant) -> Probe {
    let remaining =
        deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
    let mut connection = BufReader::new(stream);
    if let Err(error) = connection.get_ref().set_write_timeout(Some(remaining)) {
        return closed(&mut connection, &error);
    }
    let request = serde_json::json!({"id":1,"cmd":"identify","revisions":true});
    match writeln!(connection.get_mut(), "{request}").and_then(|()| connection.get_mut().flush()) {
        Ok(()) => {}
        // A full send buffer for one short line: the owner reads nothing.
        Err(error) if is_timeout(&error) => return Probe::Silent,
        // A full owner may close before this write lands.
        Err(_) if super::identify::refused_after_write(&mut connection) => return Probe::Refused,
        Err(_) => return Probe::Answered,
    }
    let mut line = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return if line.is_empty() { Probe::Silent } else { Probe::Answered };
        }
        if let Err(error) = connection.get_ref().set_read_timeout(Some(remaining)) {
            return closed(&mut connection, &error);
        }
        // Read in bounded chunks instead of using `read_until`: the latter
        // can perform an unbounded number of successful socket reads while a
        // peer trickles one byte just before each per-read timeout. Refresh
        // the socket timeout before every read so the absolute deadline is
        // enforced even for an unterminated response.
        let available = (super::identify::RESPONSE_LIMIT + 2).saturating_sub(line.len());
        let mut chunk = [0_u8; 4096];
        let read_len = available.min(chunk.len());
        // `read_len` never exceeds the chunk, and `Read` never reports more
        // bytes than the buffer holds; a reader that breaks that contract
        // is not evidence authorizing replacement either.
        let Some(buffer) = chunk.get_mut(..read_len) else {
            return Probe::Answered;
        };
        match connection.read(buffer) {
            Ok(0) => return Probe::Answered,
            Ok(count) => {
                let Some(received) = buffer.get(..count) else {
                    return Probe::Answered;
                };
                let previous_len = line.len();
                line.extend_from_slice(received);
                if line.len() > super::identify::RESPONSE_LIMIT {
                    // Malformed input is not evidence authorizing replacement.
                    return Probe::Answered;
                }
                if let Some(end) = received.iter().position(|byte| *byte == b'\n') {
                    line.truncate(previous_len + end + 1);
                    return if super::identify::is_refusal(&line) {
                        Probe::Refused
                    } else {
                        Probe::Answered
                    };
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) if is_timeout(&error) && line.is_empty() => {}
            Err(error) if is_timeout(&error) => {
                // A partial protocol line is evidence of a live peer, not a
                // silent owner. Never replace a same-user process merely
                // because it sent malformed data and then stalled.
                return Probe::Answered;
            }
            Err(_) => return Probe::Answered,
        }
    }
}

/// A socket timeout failed: a refusal when the owner closed after its
/// refusal line (macOS EINVAL), otherwise a closed connection.
fn closed(
    connection: &mut BufReader<Box<dyn cmux_tui_core::platform::transport::Stream>>,
    error: &io::Error,
) -> Probe {
    if super::identify::refused_after_closed(connection, error) {
        Probe::Refused
    } else {
        Probe::Answered
    }
}

fn is_timeout(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock)
}

/// The listener's uid, from a connection of its own (an explicit `--socket`
/// path is not checked at connect).
fn require_same_user(spec: &OwnerSpec) -> Result<(), ReplaceError> {
    #[cfg(unix)]
    {
        let stream =
            cmux_unix_socket::connect(&spec.socket).map_err(|_| ReplaceError::ListenerChanged)?;
        let uid = cmux_tui_core::platform::unix_peer_uid(&stream)
            .map_err(|_| ReplaceError::ListenerUnknown)?;
        if uid != cmux_tui_core::platform::effective_uid() {
            return Err(ReplaceError::DifferentUser);
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = spec;
        Err(ReplaceError::Unsupported)
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod sys {
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::Instant;

    pub(super) const SUPPORTED: bool = true;
    pub(super) const SIGTERM: i32 = libc::SIGTERM;
    pub(super) const SIGCONT: i32 = libc::SIGCONT;
    pub(super) const SIGKILL: i32 = libc::SIGKILL;

    /// A pidfd: signals reach exactly this process, and it becomes readable
    /// when the process ends.
    pub(super) struct ExitWatch {
        fd: OwnedFd,
    }

    impl ExitWatch {
        /// `Ok(None)`: the process has already ended.
        pub(super) fn arm(pid: u32) -> io::Result<Option<Self>> {
            let pid = libc::pid_t::try_from(pid).map_err(io::Error::other)?;
            // SAFETY: pidfd_open takes a pid and flags and returns a new fd.
            let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
            if fd < 0 {
                let error = io::Error::last_os_error();
                return if error.raw_os_error() == Some(libc::ESRCH) {
                    Ok(None)
                } else {
                    Err(error)
                };
            }
            let fd = i32::try_from(fd).map_err(io::Error::other)?;
            // SAFETY: the syscall returned a new descriptor this value owns.
            Ok(Some(Self { fd: unsafe { OwnedFd::from_raw_fd(fd) } }))
        }

        pub(super) fn signal(&self, signal: i32) -> io::Result<()> {
            // SAFETY: a valid pidfd, a signal number, no siginfo, no flags.
            let result = unsafe {
                libc::syscall(
                    libc::SYS_pidfd_send_signal,
                    self.fd.as_raw_fd(),
                    signal,
                    std::ptr::null::<libc::siginfo_t>(),
                    0,
                )
            };
            if result == 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            // The process already ended: nothing left to signal.
            if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) }
        }

        /// Whether the process ended before `deadline`.
        pub(super) fn wait(&self, deadline: Instant) -> bool {
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let timeout =
                    i32::try_from(remaining.as_nanos().div_ceil(1_000_000)).unwrap_or(i32::MAX);
                let mut poll =
                    libc::pollfd { fd: self.fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
                // SAFETY: one valid pollfd for the lifetime of the call.
                match unsafe { libc::poll(&raw mut poll, 1, timeout) } {
                    0 => return false,
                    result if result > 0 => return true,
                    _ if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted => {}
                    _ => return false,
                }
            }
        }
    }
}

#[cfg(target_vendor = "apple")]
mod sys {
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::Instant;

    pub(super) const SUPPORTED: bool = true;
    pub(super) const SIGTERM: i32 = libc::SIGTERM;
    pub(super) const SIGCONT: i32 = libc::SIGCONT;
    pub(super) const SIGKILL: i32 = libc::SIGKILL;

    /// A kqueue with a `NOTE_EXIT` filter on the process.
    pub(super) struct ExitWatch {
        queue: OwnedFd,
        pid: libc::pid_t,
        /// `NOTE_EXIT` was delivered (it is one-shot): never signal the pid
        /// again, another process may have it now.
        exited: std::cell::Cell<bool>,
    }

    impl ExitWatch {
        /// `Ok(None)`: the process has already ended.
        pub(super) fn arm(pid: u32) -> io::Result<Option<Self>> {
            let pid = libc::pid_t::try_from(pid).map_err(io::Error::other)?;
            // SAFETY: kqueue takes no arguments and returns a new fd.
            let queue = unsafe { libc::kqueue() };
            if queue < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: kqueue returned a new descriptor this value owns.
            let queue = unsafe { OwnedFd::from_raw_fd(queue) };
            let change = libc::kevent {
                ident: pid as libc::uintptr_t,
                filter: libc::EVFILT_PROC,
                flags: libc::EV_ADD | libc::EV_ONESHOT,
                fflags: libc::NOTE_EXIT,
                data: 0,
                udata: std::ptr::null_mut(),
            };
            // SAFETY: one valid change, no event buffer.
            let result = unsafe {
                libc::kevent(
                    queue.as_raw_fd(),
                    &raw const change,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                )
            };
            if result < 0 {
                let error = io::Error::last_os_error();
                return if error.raw_os_error() == Some(libc::ESRCH) {
                    Ok(None)
                } else {
                    Err(error)
                };
            }
            Ok(Some(Self { queue, pid, exited: std::cell::Cell::new(false) }))
        }

        pub(super) fn signal(&self, signal: i32) -> io::Result<()> {
            if self.wait(Instant::now()) {
                return Ok(());
            }
            // SAFETY: kill takes a pid and a signal number.
            if unsafe { libc::kill(self.pid, signal) } == 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) { Ok(()) } else { Err(error) }
        }

        /// Whether the process ended before `deadline`.
        pub(super) fn wait(&self, deadline: Instant) -> bool {
            if self.exited.get() {
                return true;
            }
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let timeout = libc::timespec {
                    tv_sec: libc::time_t::try_from(remaining.as_secs())
                        .unwrap_or(libc::time_t::MAX),
                    tv_nsec: libc::c_long::from(remaining.subsec_nanos()),
                };
                // SAFETY: an all-zero kevent is a valid out-buffer.
                let mut event: libc::kevent = unsafe { std::mem::zeroed() };
                // SAFETY: no changes, one valid out-event, a valid timeout.
                let result = unsafe {
                    libc::kevent(
                        self.queue.as_raw_fd(),
                        std::ptr::null(),
                        0,
                        &raw mut event,
                        1,
                        &raw const timeout,
                    )
                };
                match result {
                    0 => return false,
                    result if result > 0 => {
                        self.exited.set(true);
                        return true;
                    }
                    _ if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted => {}
                    _ => return false,
                }
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
mod sys {
    use std::io;
    use std::time::Instant;

    pub(super) const SUPPORTED: bool = false;
    pub(super) const SIGTERM: i32 = 0;
    pub(super) const SIGCONT: i32 = 0;
    pub(super) const SIGKILL: i32 = 0;

    pub(super) struct ExitWatch;

    impl ExitWatch {
        pub(super) fn arm(_pid: u32) -> io::Result<Option<Self>> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "no exit watch on this platform"))
        }

        pub(super) fn signal(&self, _signal: i32) -> io::Result<()> {
            Err(io::Error::new(io::ErrorKind::Unsupported, "no exit watch on this platform"))
        }

        pub(super) fn wait(&self, _deadline: Instant) -> bool {
            false
        }
    }
}
