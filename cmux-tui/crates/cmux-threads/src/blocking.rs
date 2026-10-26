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
//!
//! A violation records its call site in a 256-site table (plus an overflow
//! count) in every build. In Debug, `CMUX_DAEMON_BLOCKING=panic` (or
//! [`set_mode`]) also panics at the caller's location. Release never panics.

use std::cell::Cell;
use std::panic::Location;
use std::sync::atomic::{AtomicPtr, AtomicU8, AtomicU16, AtomicU64, Ordering};

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
    /// A lock wait above the contention budget ([`crate::lock_wait`]).
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
}

impl AllowReason {
    /// The stable report name.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Shutdown => "shutdown",
            Self::OwnDescriptor => "own-descriptor",
        }
    }

    const fn permits(self, kind: BlockingKind) -> bool {
        match self {
            Self::Shutdown => !matches!(kind, BlockingKind::IpcReply),
            Self::OwnDescriptor => matches!(kind, BlockingKind::FdRead | BlockingKind::FdWrite),
        }
    }
}

/// What a violation does beyond recording its site.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlockingMode {
    /// Record the site and continue (the default while the sweep runs).
    Record,
    /// Record the site, then panic at the caller's location. Debug builds only;
    /// Release treats it as [`BlockingMode::Record`].
    Panic,
}

/// The environment variable that selects [`BlockingMode::Panic`] when its
/// value is `panic`.
pub const MODE_ENV: &str = "CMUX_DAEMON_BLOCKING";

const MODE_UNSET: u8 = 0;
const MODE_RECORD: u8 = 1;
const MODE_PANIC: u8 = 2;

static MODE: AtomicU8 = AtomicU8::new(MODE_UNSET);

/// Sets the process-wide violation mode, replacing the [`MODE_ENV`] value.
pub fn set_mode(mode: BlockingMode) {
    let raw = match mode {
        BlockingMode::Record => MODE_RECORD,
        BlockingMode::Panic => MODE_PANIC,
    };
    MODE.store(raw, Ordering::Relaxed);
}

/// The violation mode in effect. Read from [`MODE_ENV`] on first use.
pub fn mode() -> BlockingMode {
    let raw = match MODE.load(Ordering::Relaxed) {
        MODE_UNSET => {
            let from_env = match std::env::var(MODE_ENV) {
                Ok(value) if value == "panic" => MODE_PANIC,
                _ => MODE_RECORD,
            };
            // A concurrent set_mode wins over the environment.
            match MODE.compare_exchange(MODE_UNSET, from_env, Ordering::Relaxed, Ordering::Relaxed)
            {
                Ok(_) => from_env,
                Err(current) => current,
            }
        }
        raw => raw,
    };
    if raw == MODE_PANIC && cfg!(debug_assertions) {
        BlockingMode::Panic
    } else {
        BlockingMode::Record
    }
}

/// Per-thread restriction state in one word, so the check is one TLS read and
/// one AND. Bits 0-15: the kinds denied now, derived from the fields above
/// them. Bit 16: blocking disallowed. Bits 17-18: the active allowance.
#[derive(Clone, Copy)]
struct ThreadState(u32);

impl ThreadState {
    const DISALLOWED: u32 = 1 << 16;
    const ALLOW_SHIFT: u32 = 17;

    fn new(disallowed: bool, allowance: Option<AllowReason>) -> Self {
        let denied = BlockingKind::ALL
            .into_iter()
            .filter(|kind| disallowed && !allowance.is_some_and(|reason| reason.permits(*kind)))
            .fold(0, |mask, kind| mask | u32::from(kind.bit()));
        let allowance_bits = match allowance {
            None => 0,
            Some(AllowReason::Shutdown) => 1,
            Some(AllowReason::OwnDescriptor) => 2,
        };
        let disallowed_bit = if disallowed { Self::DISALLOWED } else { 0 };
        Self(denied | disallowed_bit | (allowance_bits << Self::ALLOW_SHIFT))
    }

    const fn disallowed(self) -> bool {
        self.0 & Self::DISALLOWED != 0
    }

    const fn allowance(self) -> Option<AllowReason> {
        match (self.0 >> Self::ALLOW_SHIFT) & 0b11 {
            1 => Some(AllowReason::Shutdown),
            2 => Some(AllowReason::OwnDescriptor),
            _ => None,
        }
    }

    fn with_allowance(self, reason: AllowReason) -> Self {
        Self::new(self.disallowed(), Some(reason))
    }

    fn with_disallowed(self) -> Self {
        Self::new(true, self.allowance())
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
    scoped_state(|_| ThreadState::new(true, None), f)
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
/// feeds this detector and the request-path counters.
#[inline]
pub fn assert_blocking_allowed_at(kind: BlockingKind, location: &'static Location<'static>) {
    if !STATE.with(Cell::get).permits(kind) {
        violation(kind, location);
    }
}

/// Runs the blocking call `f` in a checked scope of `kind` (Chrome's
/// `ScopedBlockingCall`). The scope is the call: wrap only the blocking work.
#[inline]
#[track_caller]
pub fn scoped_blocking_call<R>(kind: BlockingKind, f: impl FnOnce() -> R) -> R {
    assert_blocking_allowed(kind);
    f()
}

#[cold]
#[inline(never)]
fn violation(kind: BlockingKind, location: &'static Location<'static>) {
    SITES.record(location, kind);
    // Chrome's DCHECK: fails only in Panic mode, and Release compiles it out.
    debug_assert!(
        mode() == BlockingMode::Record || std::thread::panicking(),
        "cmux_threads: blocking call ({}) at {location} on thread '{}', which disallows blocking",
        kind.as_str(),
        std::thread::current().name().unwrap_or("<unnamed>"),
    );
}

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

struct SiteSlot {
    location: AtomicPtr<Location<'static>>,
    kinds: AtomicU16,
    count: AtomicU64,
}

impl SiteSlot {
    const fn new() -> Self {
        Self {
            location: AtomicPtr::new(std::ptr::null_mut()),
            kinds: AtomicU16::new(0),
            count: AtomicU64::new(0),
        }
    }
}

/// A fixed open-addressed table of call sites. A slot is claimed once by a
/// compare-exchange of its location and never freed, so recording takes no
/// lock and allocates nothing.
struct SiteTable<const N: usize> {
    slots: [SiteSlot; N],
    overflow: AtomicU64,
}

impl<const N: usize> SiteTable<N> {
    const fn new() -> Self {
        Self { slots: [const { SiteSlot::new() }; N], overflow: AtomicU64::new(0) }
    }

    fn record(&self, location: &'static Location<'static>, kind: BlockingKind) {
        let wanted = std::ptr::from_ref(location).cast_mut();
        let start = site_hash(location) % N;
        for probe in 0..N {
            let slot = &self.slots[(start + probe) % N];
            let mut current = slot.location.load(Ordering::Acquire);
            if current.is_null() {
                current = match slot.location.compare_exchange(
                    std::ptr::null_mut(),
                    wanted,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => wanted,
                    Err(winner) => winner,
                };
            }
            // SAFETY: a non-null slot location is a `&'static Location` stored above.
            if same_site(unsafe { &*current }, location) {
                slot.kinds.fetch_or(kind.bit(), Ordering::Relaxed);
                slot.count.fetch_add(1, Ordering::Relaxed);
                return;
            }
        }
        self.overflow.fetch_add(1, Ordering::Relaxed);
    }

    fn snapshot(&self) -> BlockingSnapshot {
        let mut sites: Vec<BlockingSite> = self
            .slots
            .iter()
            .filter_map(|slot| {
                let location = slot.location.load(Ordering::Acquire);
                if location.is_null() {
                    return None;
                }
                // SAFETY: a non-null slot location is a `&'static Location`.
                let location = unsafe { &*location };
                Some(BlockingSite {
                    file: location.file(),
                    line: location.line(),
                    column: location.column(),
                    kinds: BlockingKinds(slot.kinds.load(Ordering::Relaxed)),
                    count: slot.count.load(Ordering::Relaxed),
                })
            })
            .collect();
        sites.sort_by(|a, b| {
            b.count.cmp(&a.count).then_with(|| (a.file, a.line).cmp(&(b.file, b.line)))
        });
        BlockingSnapshot { sites, overflow: self.overflow.load(Ordering::Relaxed) }
    }
}

/// Locations of one call site can be distinct statics (inlined generics), so
/// sites compare and hash by content.
fn same_site(a: &Location<'_>, b: &Location<'_>) -> bool {
    a.line() == b.line() && a.column() == b.column() && a.file() == b.file()
}

fn site_hash(location: &Location<'_>) -> usize {
    // FNV-1a over file, line and column.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let line_column = (u64::from(location.line()) << 32) | u64::from(location.column());
    for byte in location.file().bytes().chain(line_column.to_le_bytes()) {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash as usize
}

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

    #[test]
    fn own_descriptor_permits_only_descriptor_kinds() {
        let state = ThreadState::new(true, Some(AllowReason::OwnDescriptor));
        assert!(state.permits(BlockingKind::FdRead));
        assert!(state.permits(BlockingKind::FdWrite));
        assert!(!state.permits(BlockingKind::Fs));
        assert!(!state.permits(BlockingKind::IpcReply));
        assert!(ThreadState(0).permits(BlockingKind::IpcReply));
        assert!(!ThreadState::new(true, None).permits(BlockingKind::FdRead));
        assert!(
            !ThreadState::new(true, Some(AllowReason::Shutdown)).permits(BlockingKind::IpcReply)
        );
    }

    #[track_caller]
    fn here() -> &'static Location<'static> {
        Location::caller()
    }

    #[test]
    fn site_table_merges_kinds_and_counts_overflow() {
        let table = SiteTable::<2>::new();
        let first = here();
        let second = here();
        let third = here();
        table.record(first, BlockingKind::Fs);
        table.record(first, BlockingKind::Sleep);
        table.record(second, BlockingKind::Recv);
        table.record(third, BlockingKind::Join);
        table.record(third, BlockingKind::Join);
        let snapshot = table.snapshot();
        assert_eq!(snapshot.sites.len(), 2);
        assert_eq!(snapshot.overflow, 2);
        let first_site = snapshot.site(first.file(), first.line()).expect("first");
        assert_eq!(first_site.count, 2);
        assert_eq!(
            first_site.kinds.iter().collect::<Vec<_>>(),
            vec![BlockingKind::Fs, BlockingKind::Sleep]
        );
        assert_eq!(snapshot.sites[0], *first_site);
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
