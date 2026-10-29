//! The blocking detector: Chrome's `ThreadRestrictions` and `ScopedBlockingCall`
//! for the daemon.
//!
//! Chromium: base/threading/thread_restrictions.h (`DisallowBlocking`,
//! `ScopedAllowBlocking` with a private constructor and a friend list),
//! base/threading/scoped_blocking_call.h (one tight scope around each blocking
//! call, made by the blocking API itself, not by its callers) and
//! mojo/public/cpp/bindings/sync_call_restrictions.h (sync IPC has no friend).
//!
//! - [`disallow_blocking`] marks the current thread (request and echo threads).
//! - Every blocking primitive goes through [`assert_blocking_allowed`], usually
//!   through a wrapper in [`crate::checked`] or [`scoped_blocking_call`].
//! - [`allow_blocking`] takes an [`AllowReason`]: the friend list. Its
//!   `OwnDescriptor` row can only be made in this crate, by [`own_fd_read`],
//!   [`own_fd_write`] and [`own_fd_write_all`], so it is never thread-wide,
//!   and it covers only the one descriptor the thread registered with
//!   [`register_own_descriptor`] before it disallowed blocking.
//! - [`BlockingKind::IpcReply`] has no allowance: a cross-process round trip on
//!   a disallowed thread is always a violation.
//! - [`with_sync_primitives_disallowed`] (Chrome's
//!   `ScopedDisallowBaseSyncPrimitives`) lets a thread block on I/O but not
//!   wait for other work ([`BlockingKind::is_sync_primitive`]): each
//!   [`crate::work`] item runs under it, as Chrome's task_tracker.cc runs a
//!   `MayBlock()` task without `WithBaseSyncPrimitives()`. Such a wait is a
//!   `lane-sync` site ([`BlockingSite::lane_sync`]), recorded and never a
//!   panic, as the app records its lane-sync sites.
//!
//! A violation records its call site in a 256-site table (plus an overflow
//! count) in every build. Debug also panics at the caller's location, as
//! Chrome's `DCHECK` does (base/threading/scoped_blocking_call.cc), unless
//! `CMUX_DAEMON_BLOCKING=record` (or [`set_mode`]) turns that off. Release
//! never panics.
//!
//! `CMUX_DAEMON_BLOCKING_REPORT=<dir>` (or [`set_report_dir`]) also appends one
//! JSON line per (site, kind, thread) to `<dir>/blocking-<pid>.jsonl`, before a
//! Panic-mode panic, sites past a full table included. A test suite or bench
//! run with it set leaves the MQ-13 list of every process it started, the ones
//! that panicked or were killed included;
//! `cmux-tui/scripts/daemon-blocking-sweep.py` runs the suites and groups it.
//!
//! The first violation at each site also goes to the process's first-sighting
//! feed ([`take_first_sites`]), which the daemon pushes to the app's hang
//! reports as `server-diagnostic-site` events.

use std::cell::Cell;
use std::panic::Location;

mod feed;
mod report;
mod sites;

pub use feed::{FirstSite, note_hang_site, take_first_sites};
pub use report::{REPORT_ENV, ReportError, report_path, set_report_dir};

use sites::{SiteTable, note_violation};

/// What a blocking call waits on. The names are stable: `server.blocking`
/// reports them and the app's reports group by them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum BlockingKind {
    /// File-system access: open, read, write, metadata, directory walks, fsync.
    Fs = 0,
    /// Starting a child process.
    ProcessSpawn = 1,
    /// Waiting for a child process (`wait`, `output`, `status`).
    ProcessWait = 2,
    /// Waiting on a channel receive.
    Recv = 3,
    /// Joining a thread.
    Join = 4,
    /// Waiting on a condition variable.
    CondvarWait = 5,
    /// Sleeping.
    Sleep = 6,
    /// A SQLite statement or connection-lock wait.
    Sqlite = 7,
    /// Driving a future to completion on this thread.
    BlockOn = 8,
    /// A cross-process round trip (holder, terminal host, browser host). No
    /// [`AllowReason`] permits it on a disallowed thread.
    IpcReply = 9,
    /// A read of the thread's own descriptor ([`own_fd_read`]).
    FdRead = 10,
    /// A write to the thread's own descriptor ([`own_fd_write`]).
    FdWrite = 11,
    /// A contended lock wait (a failed try) on a thread that disallows
    /// blocking ([`crate::lock_wait`]).
    LockWait = 12,
    /// A wait on work that runs at a lower QoS than the waiter.
    PriorityInversion = 13,
}

impl BlockingKind {
    /// Every kind, in raw-value order.
    pub const ALL: [Self; 14] = [
        Self::Fs,
        Self::ProcessSpawn,
        Self::ProcessWait,
        Self::Recv,
        Self::Join,
        Self::CondvarWait,
        Self::Sleep,
        Self::Sqlite,
        Self::BlockOn,
        Self::IpcReply,
        Self::FdRead,
        Self::FdWrite,
        Self::LockWait,
        Self::PriorityInversion,
    ];

    /// The stable report name.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Fs => "fs",
            Self::ProcessSpawn => "process-spawn",
            Self::ProcessWait => "process-wait",
            Self::Recv => "recv",
            Self::Join => "join",
            Self::CondvarWait => "condvar-wait",
            Self::Sleep => "sleep",
            Self::Sqlite => "sqlite",
            Self::BlockOn => "block-on",
            Self::IpcReply => "ipc-reply",
            Self::FdRead => "fd-read",
            Self::FdWrite => "fd-write",
            Self::LockWait => "lock-wait",
            Self::PriorityInversion => "priority-inversion",
        }
    }

    /// Whether the kind waits for another thread to act: a channel receive,
    /// a join or a condition-variable wait (Chrome's base sync primitives:
    /// `WaitableEvent`, `ConditionVariable`, `PlatformThread::Join`). A work
    /// item may block on I/O but not on these.
    pub const fn is_sync_primitive(self) -> bool {
        matches!(self, Self::Recv | Self::Join | Self::CondvarWait)
    }

    const fn bit(self) -> u16 {
        1 << self as u8
    }
}

/// The friend list: every reason a disallowed thread may block. A new row
/// needs a review; `rg -c 'AllowReason::' cmux-tui/crates` outside this crate
/// is the INV-4 count.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AllowReason {
    /// The daemon is shutting down: flushing state and joining workers on a
    /// request thread that no longer serves input (Chrome's
    /// `PermanentThreadAllowance::AllowBlocking`). Permits every kind except
    /// [`BlockingKind::IpcReply`].
    Shutdown,
    /// An echo or reader thread blocks on the descriptor it owns: that wait is
    /// the thread's job. Call-scoped and made only by [`own_fd_read`],
    /// [`own_fd_write`] and [`own_fd_write_all`] on the descriptor named by the
    /// thread's [`register_own_descriptor`] token; it permits only
    /// [`BlockingKind::FdRead`] and [`BlockingKind::FdWrite`].
    #[non_exhaustive]
    OwnDescriptor,
    /// A failure-injection seam, set only by a test through the environment,
    /// delays on purpose (Chrome's `ScopedAllowBlockingForTesting`,
    /// base/threading/thread_restrictions.h). Permits only
    /// [`BlockingKind::Sleep`].
    FailureInjection,
}

impl AllowReason {
    /// The stable report name.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Shutdown => "shutdown",
            Self::OwnDescriptor => "own-descriptor",
            Self::FailureInjection => "failure-injection",
        }
    }

    const fn permits(self, kind: BlockingKind) -> bool {
        match self {
            Self::Shutdown => !matches!(kind, BlockingKind::IpcReply),
            Self::OwnDescriptor => matches!(kind, BlockingKind::FdRead | BlockingKind::FdWrite),
            Self::FailureInjection => matches!(kind, BlockingKind::Sleep),
        }
    }
}

mod mode;
pub use mode::{BlockingMode, MODE_ENV, mode, set_mode, with_mode};

/// Per-thread restriction state in one word, so the check is one TLS read and
/// one AND. Bits 0-15: the kinds denied now, derived from the fields above
/// them. Bit 16: blocking disallowed. Bits 17-18: the active allowance. Bit
/// 19: sync primitives disallowed.
#[derive(Clone, Copy)]
struct ThreadState(u32);

impl ThreadState {
    const DISALLOWED: u32 = 1 << 16;
    const ALLOW_SHIFT: u32 = 17;
    const SYNC_DISALLOWED: u32 = 1 << 19;

    fn new(disallowed: bool, sync_disallowed: bool, allowance: Option<AllowReason>) -> Self {
        let denied = BlockingKind::ALL
            .into_iter()
            .filter(|kind| disallowed || (sync_disallowed && kind.is_sync_primitive()))
            .filter(|kind| !allowance.is_some_and(|reason| reason.permits(*kind)))
            .fold(0, |mask, kind| mask | u32::from(kind.bit()));
        let allowance_bits = match allowance {
            None => 0,
            Some(AllowReason::Shutdown) => 1,
            Some(AllowReason::OwnDescriptor) => 2,
            Some(AllowReason::FailureInjection) => 3,
        };
        let disallowed_bit = if disallowed { Self::DISALLOWED } else { 0 };
        let sync_bit = if sync_disallowed { Self::SYNC_DISALLOWED } else { 0 };
        Self(denied | disallowed_bit | sync_bit | (allowance_bits << Self::ALLOW_SHIFT))
    }

    const fn disallowed(self) -> bool {
        self.0 & Self::DISALLOWED != 0
    }

    const fn sync_disallowed(self) -> bool {
        self.0 & Self::SYNC_DISALLOWED != 0
    }

    const fn allowance(self) -> Option<AllowReason> {
        match (self.0 >> Self::ALLOW_SHIFT) & 0b11 {
            1 => Some(AllowReason::Shutdown),
            2 => Some(AllowReason::OwnDescriptor),
            3 => Some(AllowReason::FailureInjection),
            _ => None,
        }
    }

    fn with_allowance(self, reason: AllowReason) -> Self {
        Self::new(self.disallowed(), self.sync_disallowed(), Some(reason))
    }

    fn with_disallowed(self) -> Self {
        Self::new(true, self.sync_disallowed(), self.allowance())
    }

    #[inline]
    const fn permits(self, kind: BlockingKind) -> bool {
        self.0 & kind.bit() as u32 == 0
    }
}

thread_local! {
    static STATE: Cell<ThreadState> = const { Cell::new(ThreadState(0)) };
}

/// Restores the thread state when a scope ends, unwinding included.
struct RestoreState(ThreadState);

impl Drop for RestoreState {
    fn drop(&mut self) {
        STATE.with(|state| state.set(self.0));
    }
}

fn scoped_state<R>(next: impl FnOnce(ThreadState) -> ThreadState, f: impl FnOnce() -> R) -> R {
    let previous = STATE.with(Cell::get);
    let _restore = RestoreState(previous);
    STATE.with(|state| state.set(next(previous)));
    f()
}

/// Forbids blocking on the current thread for the rest of its life (Chrome's
/// `DisallowBlocking`). Call it first thing on request and echo threads.
pub fn disallow_blocking() {
    STATE.with(|state| state.set(state.get().with_disallowed()));
}

/// Forbids blocking on the current thread while `f` runs (Chrome's
/// `ScopedDisallowBlocking`), for work items that must not block. The
/// innermost scope wins: an outer allowance does not apply inside `f`.
pub fn with_blocking_disallowed<R>(f: impl FnOnce() -> R) -> R {
    scoped_state(|_| ThreadState::new(true, false, None), f)
}

/// Forbids waits for other work ([`BlockingKind::is_sync_primitive`]) on the
/// current thread while `f` runs, other blocking still allowed (Chrome's
/// `ScopedDisallowBaseSyncPrimitives`). Each [`crate::work`] item runs under
/// it. Such a wait records a `lane-sync` site and never panics. The innermost
/// scope wins: an outer allowance does not apply inside `f`.
pub fn with_sync_primitives_disallowed<R>(f: impl FnOnce() -> R) -> R {
    scoped_state(|state| ThreadState::new(state.disallowed(), true, None), f)
}

/// Whether waits for other work are disallowed on the current thread
/// (ignoring allowances): inside a [`crate::work`] item.
pub fn is_sync_primitives_disallowed() -> bool {
    STATE.with(Cell::get).sync_disallowed()
}

/// Whether blocking is disallowed on the current thread (ignoring allowances).
pub fn is_blocking_disallowed() -> bool {
    STATE.with(Cell::get).disallowed()
}

/// The allowance active on the current thread, if any.
pub fn current_allowance() -> Option<AllowReason> {
    STATE.with(Cell::get).allowance()
}

/// Runs `f` with `reason`'s allowance on this thread, then restores the
/// previous state. `AllowReason::OwnDescriptor` cannot be named outside this
/// crate; use [`own_fd_read`] or [`own_fd_write`].
pub fn allow_blocking<R>(reason: AllowReason, f: impl FnOnce() -> R) -> R {
    scoped_state(|state| state.with_allowance(reason), f)
}

/// Checks that the current thread may make a `kind` blocking call. On a
/// thread that never called [`disallow_blocking`], this is one TLS read.
#[inline]
#[track_caller]
pub fn assert_blocking_allowed(kind: BlockingKind) {
    if !STATE.with(Cell::get).permits(kind) {
        violation(kind, Location::caller());
    }
}

/// [`assert_blocking_allowed`] at a site the caller captured. The daemon's
/// request-path notes (`cmux_tui_platform::request_path`) check each blocking
/// primitive here with the site they record, so one note at a primitive
/// feeds this detector and the request-path counters. It returns what it
/// found, for a layer that acts on a violation beyond recording it
/// (cmux-blocking writes one stall record per site when the thread driving a
/// tokio runtime blocks).
#[inline]
pub fn assert_blocking_allowed_at(
    kind: BlockingKind,
    location: &'static Location<'static>,
) -> BlockingCheck {
    if STATE.with(Cell::get).permits(kind) {
        BlockingCheck::Allowed
    } else {
        BlockingCheck::Violation { first_at_site: violation(kind, location) }
    }
}

/// What [`assert_blocking_allowed_at`] found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockingCheck {
    /// The current thread may make the call.
    Allowed,
    /// A violation, recorded in the site table like any other. `first_at_site`
    /// is true for the first violation recorded at this site in the process
    /// (false once the table is full).
    Violation { first_at_site: bool },
}

/// Runs the blocking call `f` in a checked scope of `kind` (Chrome's
/// `ScopedBlockingCall`). The scope is the call: wrap only the blocking work.
#[inline]
#[track_caller]
pub fn scoped_blocking_call<R>(kind: BlockingKind, f: impl FnOnce() -> R) -> R {
    assert_blocking_allowed(kind);
    f()
}

/// Records the violation; true when it is the first at its site. A thread
/// that only disallows sync primitives (a work item) records a `lane-sync`
/// site and never panics.
#[cold]
#[inline(never)]
fn violation(kind: BlockingKind, location: &'static Location<'static>) -> bool {
    let lane_sync = !STATE.with(Cell::get).disallowed();
    let first_at_site = note_violation(&SITES, report::site_report(), kind, location, lane_sync);
    if first_at_site {
        send_first_site(kind, location, lane_sync);
    }
    // Chrome's DCHECK: fails only in Panic mode, and Release compiles it out.
    debug_assert!(
        lane_sync || mode() == BlockingMode::Record || std::thread::panicking(),
        "cmux_threads: blocking call ({}) at {location} on thread '{}', which disallows blocking",
        kind.as_str(),
        std::thread::current().name().unwrap_or("<unnamed>"),
    );
    first_at_site
}

/// Records a [`BlockingKind::PriorityInversion`] site at `location`: a
/// thread waited on work sent from a thread of lower QoS ([`crate::sync`]).
/// Record only, in every mode and on every thread, as a lane-sync site is:
/// the wait is allowed, the QoS pairing is the finding.
#[cfg(debug_assertions)]
#[cold]
#[inline(never)]
pub(crate) fn note_priority_inversion(location: &'static Location<'static>) {
    let kind = BlockingKind::PriorityInversion;
    if note_violation(&SITES, report::site_report(), kind, location, false) {
        send_first_site(kind, location, false);
    }
}

/// The table's first violation at `location`, to the first-sighting feed.
fn send_first_site(kind: BlockingKind, location: &'static Location<'static>, lane_sync: bool) {
    feed::send(FirstSite::Blocking {
        file: location.file(),
        line: location.line(),
        column: location.column(),
        kind,
        lane_sync,
    });
}

/// Records a [`BlockingKind::LockWait`] site at `location` when the current
/// thread may not wait for a lock: a lock timed by its caller waited past
/// the budget ([`crate::lock_wait::note_timed_lock_wait`]). Record only, in
/// every mode, as a priority-inversion site is: the wait is over, and
/// whether it passed the budget depends on scheduling.
#[cold]
#[inline(never)]
pub(crate) fn note_long_lock_wait(location: &'static Location<'static>) {
    if !STATE.with(Cell::get).permits(BlockingKind::LockWait) {
        note_violation(&SITES, report::site_report(), BlockingKind::LockWait, location, false);
    }
}

#[cfg(debug_assertions)]
mod long_wait;
#[cfg(debug_assertions)]
pub(crate) use long_wait::{denies, note_long_wait};

#[cfg(unix)]
const NO_OWN_FD: std::os::fd::RawFd = -1;

#[cfg(unix)]
thread_local! {
    static OWN_FD: Cell<std::os::fd::RawFd> = const { Cell::new(NO_OWN_FD) };
}

/// The current thread's registration of the descriptor it owns, made by
/// [`register_own_descriptor`]. It borrows the descriptor, so the number
/// cannot be closed and reused while it is registered, and it stays on its
/// thread. Dropping it ends the registration.
#[cfg(unix)]
#[must_use = "the registration ends when the token drops"]
pub struct OwnDescriptorToken<'fd> {
    /// The registration this one replaced, or `None` when it was refused.
    previous: Option<std::os::fd::RawFd>,
    _fd: std::marker::PhantomData<std::os::fd::BorrowedFd<'fd>>,
    _thread: std::marker::PhantomData<*const ()>,
}

#[cfg(unix)]
impl OwnDescriptorToken<'_> {
    /// Whether the registration took effect.
    pub const fn is_registered(&self) -> bool {
        self.previous.is_some()
    }
}

#[cfg(unix)]
impl Drop for OwnDescriptorToken<'_> {
    fn drop(&mut self) {
        if let Some(previous) = self.previous {
            OWN_FD.with(|own| own.set(previous));
        }
    }
}

/// Registers `fd` as the descriptor the current thread owns, so
/// [`own_fd_read`] and [`own_fd_write`] may block on it after the thread
/// disallows blocking. This is thread setup: call it before
/// [`disallow_blocking`]. On a thread that already disallows blocking (a
/// request thread), the registration is refused and records a
/// [`BlockingKind::FdRead`] violation at the caller, so a request thread
/// cannot grant itself a wait on a holder or host socket.
#[cfg(unix)]
#[track_caller]
pub fn register_own_descriptor(fd: std::os::fd::BorrowedFd<'_>) -> OwnDescriptorToken<'_> {
    use std::os::fd::AsRawFd;
    let previous = if STATE.with(Cell::get).disallowed() {
        violation(BlockingKind::FdRead, Location::caller());
        None
    } else {
        Some(OWN_FD.with(|own| own.replace(fd.as_raw_fd())))
    };
    OwnDescriptorToken {
        previous,
        _fd: std::marker::PhantomData,
        _thread: std::marker::PhantomData,
    }
}

/// Checks a `kind` call on `fd`: the [`AllowReason::OwnDescriptor`] allowance
/// applies only when `fd` is the thread's registered descriptor.
#[cfg(unix)]
#[inline]
#[track_caller]
fn assert_own_descriptor_allowed(fd: std::os::fd::BorrowedFd<'_>, kind: BlockingKind) {
    use std::os::fd::AsRawFd;
    let owned = OWN_FD.with(Cell::get) == fd.as_raw_fd();
    if !(owned && AllowReason::OwnDescriptor.permits(kind)) {
        assert_blocking_allowed(kind);
    }
}

/// Reads the descriptor the current thread registered with
/// [`register_own_descriptor`], under the call-scoped
/// [`AllowReason::OwnDescriptor`] allowance. Any other descriptor is checked
/// like any blocking read. One `read(2)`; `EINTR` is returned to the caller
/// like `std::io::Read::read`.
#[cfg(unix)]
#[track_caller]
pub fn own_fd_read(fd: std::os::fd::BorrowedFd<'_>, buf: &mut [u8]) -> std::io::Result<usize> {
    use std::os::fd::AsRawFd;
    assert_own_descriptor_allowed(fd, BlockingKind::FdRead);
    // SAFETY: `fd` is open for the borrow and `buf` is writable for its length.
    let n = unsafe { libc::read(fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
    usize::try_from(n).map_err(|_| std::io::Error::last_os_error())
}

/// Writes to the descriptor the current thread registered with
/// [`register_own_descriptor`], under the call-scoped
/// [`AllowReason::OwnDescriptor`] allowance. Any other descriptor is checked
/// like any blocking write. One `write(2)`.
#[cfg(unix)]
#[track_caller]
pub fn own_fd_write(fd: std::os::fd::BorrowedFd<'_>, buf: &[u8]) -> std::io::Result<usize> {
    use std::os::fd::AsRawFd;
    assert_own_descriptor_allowed(fd, BlockingKind::FdWrite);
    // SAFETY: `fd` is open for the borrow and `buf` is readable for its length.
    let n = unsafe { libc::write(fd.as_raw_fd(), buf.as_ptr().cast(), buf.len()) };
    usize::try_from(n).map_err(|_| std::io::Error::last_os_error())
}

/// Writes all of `buf` to the descriptor the current thread owns, retrying
/// `EINTR` like `std::io::Write::write_all`.
#[cfg(unix)]
#[track_caller]
pub fn own_fd_write_all(fd: std::os::fd::BorrowedFd<'_>, mut buf: &[u8]) -> std::io::Result<()> {
    while !buf.is_empty() {
        match own_fd_write(fd, buf) {
            Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
            Ok(n) => buf = &buf[n..],
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

/// The kinds seen at one site.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct BlockingKinds(u16);

impl BlockingKinds {
    /// Whether `kind` was seen.
    pub const fn contains(self, kind: BlockingKind) -> bool {
        self.0 & kind.bit() != 0
    }

    /// The kinds seen, in raw-value order.
    pub fn iter(self) -> impl Iterator<Item = BlockingKind> {
        BlockingKind::ALL.into_iter().filter(move |kind| self.contains(*kind))
    }
}

/// One call site that blocked where blocking is disallowed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlockingSite {
    pub file: &'static str,
    pub line: u32,
    pub column: u32,
    pub kinds: BlockingKinds,
    pub count: u64,
    /// Whether a work item's wait for other work reached the site (the
    /// `lane-sync` context, [`with_sync_primitives_disallowed`]).
    pub lane_sync: bool,
}

/// The recorded sites, most frequent first, and the violations that found the
/// table full.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BlockingSnapshot {
    pub sites: Vec<BlockingSite>,
    pub overflow: u64,
}

impl BlockingSnapshot {
    /// The site at `file:line`, if recorded.
    pub fn site(&self, file: &str, line: u32) -> Option<&BlockingSite> {
        self.sites.iter().find(|site| site.file == file && site.line == line)
    }
}

/// The number of distinct sites the process records before counting overflow.
pub const SITE_CAPACITY: usize = 256;

/// The process's recorded violation sites.
pub fn snapshot() -> BlockingSnapshot {
    SITES.snapshot()
}

static SITES: SiteTable<SITE_CAPACITY> = SiteTable::new();

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn on_disallowed_thread<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> R {
        set_mode(BlockingMode::Record);
        std::thread::Builder::new()
            .name("blocking-test".into())
            .spawn(move || {
                disallow_blocking();
                f()
            })
            .expect("spawn test thread")
            .join()
            .expect("test thread")
    }

    fn count_at(line: u32) -> u64 {
        snapshot().site(file!(), line).map_or(0, |site| site.count)
    }

    #[test]
    fn disallowed_thread_records_one_site() {
        let line = on_disallowed_thread(|| {
            let line = line!() + 1;
            assert_blocking_allowed(BlockingKind::Fs);
            line
        });
        let snapshot = snapshot();
        let site = snapshot.site(file!(), line).expect("site recorded");
        assert_eq!(site.count, 1);
        assert!(site.kinds.contains(BlockingKind::Fs));
        assert_eq!(site.kinds.iter().collect::<Vec<_>>(), vec![BlockingKind::Fs]);
    }

    #[test]
    fn ordinary_thread_records_nothing() {
        set_mode(BlockingMode::Record);
        let line = std::thread::spawn(|| {
            let line = line!() + 1;
            assert_blocking_allowed(BlockingKind::Fs);
            line
        })
        .join()
        .expect("test thread");
        assert_eq!(count_at(line), 0);
    }

    #[test]
    fn shutdown_allowance_permits_all_but_ipc_reply() {
        let (fs_line, ipc_line) = on_disallowed_thread(|| {
            allow_blocking(AllowReason::Shutdown, || {
                assert_eq!(current_allowance(), Some(AllowReason::Shutdown));
                let fs_line = line!() + 1;
                assert_blocking_allowed(BlockingKind::Fs);
                let ipc_line = line!() + 1;
                assert_blocking_allowed(BlockingKind::IpcReply);
                (fs_line, ipc_line)
            })
        });
        assert_eq!(count_at(fs_line), 0);
        assert_eq!(count_at(ipc_line), 1);
    }

    #[test]
    fn failure_injection_allowance_permits_only_sleep() {
        let (sleep_line, fs_line) = on_disallowed_thread(|| {
            allow_blocking(AllowReason::FailureInjection, || {
                assert_eq!(current_allowance(), Some(AllowReason::FailureInjection));
                let sleep_line = line!() + 1;
                assert_blocking_allowed(BlockingKind::Sleep);
                let fs_line = line!() + 1;
                assert_blocking_allowed(BlockingKind::Fs);
                (sleep_line, fs_line)
            })
        });
        assert_eq!(count_at(sleep_line), 0);
        assert_eq!(count_at(fs_line), 1);
    }

    #[test]
    fn allowance_ends_with_its_scope_even_on_panic() {
        let line = on_disallowed_thread(|| {
            let unwound = std::panic::catch_unwind(|| {
                allow_blocking(AllowReason::Shutdown, || panic!("inside allowance"));
            });
            assert!(unwound.is_err());
            assert_eq!(current_allowance(), None);
            assert!(is_blocking_disallowed());
            let line = line!() + 1;
            assert_blocking_allowed(BlockingKind::Sleep);
            line
        });
        assert_eq!(count_at(line), 1);
    }

    #[test]
    fn scoped_disallow_restores_the_thread() {
        set_mode(BlockingMode::Record);
        let (inside, after) = std::thread::spawn(|| {
            let inside = with_blocking_disallowed(|| {
                assert!(is_blocking_disallowed());
                let line = line!() + 1;
                assert_blocking_allowed(BlockingKind::Recv);
                line
            });
            assert!(!is_blocking_disallowed());
            let after = line!() + 1;
            assert_blocking_allowed(BlockingKind::Recv);
            (inside, after)
        })
        .join()
        .expect("test thread");
        assert_eq!(count_at(inside), 1);
        assert_eq!(count_at(after), 0);
    }

    #[test]
    fn scoped_disallow_wins_over_an_outer_allowance() {
        let (inside, after) = on_disallowed_thread(|| {
            allow_blocking(AllowReason::Shutdown, || {
                let inside = with_blocking_disallowed(|| {
                    assert_eq!(current_allowance(), None);
                    let line = line!() + 1;
                    assert_blocking_allowed(BlockingKind::Fs);
                    line
                });
                assert_eq!(current_allowance(), Some(AllowReason::Shutdown));
                let after = line!() + 1;
                assert_blocking_allowed(BlockingKind::Fs);
                (inside, after)
            })
        });
        assert_eq!(count_at(inside), 1);
        assert_eq!(count_at(after), 0);
    }

    /// Runs `f` on a named thread that registers `own` (one end of a socket
    /// pair) as its descriptor, then disallows blocking.
    #[cfg(unix)]
    fn on_echo_thread<R: Send + 'static>(
        own: std::os::unix::net::UnixStream,
        peer: std::os::unix::net::UnixStream,
        f: impl FnOnce(std::os::fd::BorrowedFd<'_>, std::os::fd::BorrowedFd<'_>) -> R + Send + 'static,
    ) -> R {
        use std::os::fd::AsFd;
        set_mode(BlockingMode::Record);
        std::thread::Builder::new()
            .name("blocking-echo-test".into())
            .spawn(move || {
                let token = register_own_descriptor(own.as_fd());
                assert!(token.is_registered());
                disallow_blocking();
                f(own.as_fd(), peer.as_fd())
            })
            .expect("spawn test thread")
            .join()
            .expect("test thread")
    }

    #[cfg(unix)]
    #[test]
    fn own_descriptor_io_is_permitted_and_call_scoped() {
        use std::io::{Read, Write};
        let (own, mut peer) = std::os::unix::net::UnixStream::pair().expect("socket pair");
        peer.write_all(b"echo").expect("seed");
        let peer_for_thread = peer.try_clone().expect("clone peer");
        let (read_back, own_lines, after) = on_echo_thread(own, peer_for_thread, |own, _| {
            let mut buf = [0u8; 8];
            let read_line = line!() + 1;
            let n = own_fd_read(own, &mut buf).expect("read");
            let write_line = line!() + 1;
            own_fd_write_all(own, &buf[..n]).expect("write");
            assert_eq!(current_allowance(), None);
            let after = line!() + 1;
            assert_blocking_allowed(BlockingKind::FdRead);
            (buf[..n].to_vec(), [read_line, write_line], after)
        });
        assert_eq!(read_back, b"echo");
        let mut echoed = [0u8; 4];
        peer.read_exact(&mut echoed).expect("echo back");
        assert_eq!(&echoed, b"echo");
        assert_eq!(count_at(after), 1);
        for line in own_lines {
            assert_eq!(count_at(line), 0, "own descriptor I/O at line {line} recorded a site");
        }
    }

    #[cfg(unix)]
    #[test]
    fn own_fd_io_on_an_unregistered_descriptor_is_a_violation() {
        use std::io::Write;
        let (own, peer) = std::os::unix::net::UnixStream::pair().expect("socket pair");
        let mut own_writer = own.try_clone().expect("clone own");
        own_writer.write_all(b"reply").expect("seed");
        let (read_line, write_line) = on_echo_thread(own, peer, |_, foreign| {
            let mut buf = [0u8; 8];
            let read_line = line!() + 1;
            let n = own_fd_read(foreign, &mut buf).expect("read");
            assert_eq!(&buf[..n], b"reply");
            let write_line = line!() + 1;
            own_fd_write_all(foreign, b"request").expect("write");
            (read_line, write_line)
        });
        let snapshot = snapshot();
        let read_site = snapshot.site(file!(), read_line).expect("foreign read recorded");
        assert_eq!(read_site.count, 1);
        assert_eq!(read_site.kinds.iter().collect::<Vec<_>>(), vec![BlockingKind::FdRead]);
        let write_site = snapshot.site(file!(), write_line).expect("foreign write recorded");
        assert_eq!(write_site.kinds.iter().collect::<Vec<_>>(), vec![BlockingKind::FdWrite]);
    }

    #[cfg(unix)]
    #[test]
    fn a_disallowed_thread_cannot_register_a_descriptor() {
        use std::io::Write;
        use std::os::fd::AsFd;
        let (socket, mut peer) = std::os::unix::net::UnixStream::pair().expect("socket pair");
        peer.write_all(b"x").expect("seed");
        let (register_line, read_line) = on_disallowed_thread(move || {
            let register_line = line!() + 1;
            let token = register_own_descriptor(socket.as_fd());
            assert!(!token.is_registered());
            let mut buf = [0u8; 1];
            let read_line = line!() + 1;
            own_fd_read(socket.as_fd(), &mut buf).expect("read");
            (register_line, read_line)
        });
        assert_eq!(count_at(register_line), 1);
        assert_eq!(count_at(read_line), 1);
    }

    #[cfg(unix)]
    #[test]
    fn dropping_the_token_ends_the_registration() {
        use std::io::Write;
        use std::os::fd::AsFd;
        set_mode(BlockingMode::Record);
        let (socket, mut peer) = std::os::unix::net::UnixStream::pair().expect("socket pair");
        peer.write_all(b"x").expect("seed");
        let read_line = std::thread::spawn(move || {
            drop(register_own_descriptor(socket.as_fd()));
            disallow_blocking();
            let mut buf = [0u8; 1];
            let read_line = line!() + 1;
            own_fd_read(socket.as_fd(), &mut buf).expect("read");
            read_line
        })
        .join()
        .expect("test thread");
        assert_eq!(count_at(read_line), 1);
    }

    /// A thread's panic mode panics there, leaves other threads in the
    /// process mode, and ends with its scope, also when it unwinds.
    #[test]
    #[cfg(debug_assertions)]
    fn with_mode_is_per_thread_and_scoped() {
        set_mode(BlockingMode::Record);
        let panicked = std::thread::spawn(|| {
            let panicked = std::panic::catch_unwind(|| {
                with_mode(BlockingMode::Panic, || {
                    assert_eq!(mode(), BlockingMode::Panic);
                    with_blocking_disallowed(|| assert_blocking_allowed(BlockingKind::Sleep));
                });
            })
            .is_err();
            panicked && mode() == BlockingMode::Record
        })
        .join()
        .expect("test thread");
        assert!(panicked, "the violation panics and the override ends with its scope");
        assert_eq!(mode(), BlockingMode::Record);
    }

    /// Sync primitives disallowed (a work item): the
    /// waits for other work are denied, any other blocking is allowed, a
    /// Shutdown allowance permits them, and disallowing keeps the sync bit.
    #[test]
    fn sync_primitives_disallowed_denies_only_waits_for_other_work() {
        let state = ThreadState::new(false, true, None);
        let denied: Vec<_> =
            BlockingKind::ALL.into_iter().filter(|kind| !state.permits(*kind)).collect();
        assert_eq!(denied, vec![BlockingKind::Recv, BlockingKind::Join, BlockingKind::CondvarWait]);
        assert!(!state.disallowed());
        let allowed = ThreadState::new(false, true, Some(AllowReason::Shutdown));
        assert!(allowed.permits(BlockingKind::Recv));
        assert!(state.with_disallowed().sync_disallowed(), "disallowing keeps the sync bit");
        assert!(!state.with_disallowed().permits(BlockingKind::Fs));
    }

    /// A lane-sync wait records its site and never panics, in panic mode
    /// too; a disallowed scope inside it wins until it returns.
    #[test]
    fn a_lane_sync_wait_records_without_panicking() {
        set_mode(BlockingMode::Record);
        let (recv, fs, inner, after) = std::thread::spawn(|| {
            with_mode(BlockingMode::Panic, || {
                let (recv, fs, inner) = with_sync_primitives_disallowed(|| {
                    assert!(is_sync_primitives_disallowed());
                    let recv = line!() + 1;
                    assert_blocking_allowed(BlockingKind::Recv);
                    let fs = line!() + 1;
                    assert_blocking_allowed(BlockingKind::Fs);
                    let inner = with_blocking_disallowed(|| {
                        assert!(!is_sync_primitives_disallowed());
                        is_blocking_disallowed()
                    });
                    (recv, fs, inner)
                });
                assert!(!is_sync_primitives_disallowed());
                let after = line!() + 1;
                assert_blocking_allowed(BlockingKind::Recv);
                (recv, fs, inner, after)
            })
        })
        .join()
        .expect("the lane-sync wait does not panic");
        let snapshot = snapshot();
        let site = snapshot.site(file!(), recv).expect("lane-sync site");
        assert_eq!(site.count, 1);
        assert!(site.lane_sync);
        assert_eq!(count_at(fs), 0);
        assert!(inner);
        assert_eq!(count_at(after), 0);
    }

    /// A violation on a thread that disallows blocking is not a lane-sync
    /// site, inside a sync-primitive scope too.
    #[test]
    fn a_disallowed_thread_violation_is_not_lane_sync() {
        let line = on_disallowed_thread(|| {
            with_sync_primitives_disallowed(|| {
                let line = line!() + 1;
                assert_blocking_allowed(BlockingKind::Recv);
                line
            })
        });
        let snapshot = snapshot();
        let site = snapshot.site(file!(), line).expect("site recorded");
        assert!(!site.lane_sync);
    }

    #[test]
    fn own_descriptor_permits_only_descriptor_kinds() {
        let state = ThreadState::new(true, false, Some(AllowReason::OwnDescriptor));
        assert!(state.permits(BlockingKind::FdRead));
        assert!(state.permits(BlockingKind::FdWrite));
        assert!(!state.permits(BlockingKind::Fs));
        assert!(!state.permits(BlockingKind::IpcReply));
        assert!(ThreadState(0).permits(BlockingKind::IpcReply));
        assert!(!ThreadState::new(true, false, None).permits(BlockingKind::FdRead));
        assert!(
            !ThreadState::new(true, false, Some(AllowReason::Shutdown))
                .permits(BlockingKind::IpcReply)
        );
    }

    #[test]
    fn kind_names_are_stable_and_distinct() {
        let names: Vec<_> = BlockingKind::ALL.iter().map(|kind| kind.as_str()).collect();
        let mut unique = names.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), names.len());
        assert_eq!(BlockingKind::IpcReply.as_str(), "ipc-reply");
        for (raw, kind) in BlockingKind::ALL.iter().enumerate() {
            assert_eq!(*kind as usize, raw);
        }
    }

    /// One check in its own frame, so each iteration does the TLS read: an
    /// inlined check in a loop lets LLVM hoist the load out of it. The cost
    /// measured is an upper bound (it adds a call and a return).
    #[inline(never)]
    fn one_check(kind: BlockingKind) {
        assert_blocking_allowed(kind);
    }

    /// Best of five runs of `CALLS` checks, in ns per check.
    fn ns_per_check() -> f64 {
        const CALLS: u32 = 2_000_000;
        (0..5)
            .map(|_| {
                let start = Instant::now();
                for _ in 0..CALLS {
                    one_check(std::hint::black_box(BlockingKind::Fs));
                }
                start.elapsed().as_secs_f64() * 1e9 / f64::from(CALLS)
            })
            .fold(f64::INFINITY, f64::min)
    }

    /// The allowed path is one TLS read: < 5 ns per check in the optimized
    /// build the daemon ships (`cargo test --release`).
    #[test]
    #[cfg_attr(debug_assertions, ignore = "timing bound holds for --release")]
    fn allowed_fast_path_is_under_five_ns() {
        let ordinary = ns_per_check();
        let allowed = std::thread::spawn(|| {
            disallow_blocking();
            allow_blocking(AllowReason::Shutdown, ns_per_check)
        })
        .join()
        .expect("bench thread");
        eprintln!("fast path: ordinary {ordinary:.2} ns, allowed {allowed:.2} ns");
        assert!(ordinary < 5.0, "ordinary thread check took {ordinary:.2} ns");
        assert!(allowed < 5.0, "allowed check took {allowed:.2} ns");
    }
}
