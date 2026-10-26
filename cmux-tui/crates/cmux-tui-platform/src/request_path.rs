//! Blocking work on a request handler's thread, counted where it happens.
//!
//! Chromium's model (base/threading/scoped_blocking_call.h): a blocking
//! primitive announces itself with the location of its caller, and the
//! thread's scope decides what that costs. Here a request handler runs inside
//! a [`RequestPathScope`]; a blocking primitive calls [`note`] with its
//! [`BlockingKind`]. Every wrapper between the primitive and the code that
//! asked for it is `#[track_caller]`, so the noted site is that code's
//! `file:line`, not the wrapper's.
//!
//! Outside a scope a note is one thread-local load. Inside one it adds one
//! relaxed atomic to the scope's [`RequestPathStats`]; only the `record` and
//! `panic:<kinds>` modes also fill the 128-entry site ring and print a
//! `REQUEST_PATH_IO kind=<kind> site=<file:line>` line on stderr. A
//! `panic:` kind panics only in builds with debug assertions (debug and test).
//! Nothing here allocates on the note path.

use std::cell::RefCell;
use std::fmt;
use std::io::Write as _;
use std::marker::PhantomData;
use std::panic::Location;
use std::sync::Arc;
use std::sync::atomic::{AtomicPtr, AtomicU8, AtomicU64, AtomicUsize, Ordering};

/// What a request-path note says the thread blocked on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum BlockingKind {
    /// A SQLite read or write (the registry connection).
    Sqlite,
    /// A wait for the session journal writer: its receipt or queue space.
    JournalWait,
    /// Starting a process (a terminal or its host).
    ProcessSpawn,
    /// A file write or fsync.
    FsWrite,
    /// A wait for a terminal host's answer.
    HostWait,
    /// A timed sleep.
    Sleep,
    /// A process table read (`/proc`, sysctl, proc_pidinfo).
    ProcScan,
    /// Running a child process to completion (git).
    ChildProcess,
    /// A network round trip.
    Network,
    /// A registry connection lock held for 1 ms or more.
    LockHoldOver1ms,
}

const KIND_COUNT: usize = BlockingKind::ALL.len();

impl BlockingKind {
    /// Every kind, in `server-stats` order.
    pub const ALL: [Self; 10] = [
        Self::Sqlite,
        Self::JournalWait,
        Self::ProcessSpawn,
        Self::FsWrite,
        Self::HostWait,
        Self::Sleep,
        Self::ProcScan,
        Self::ChildProcess,
        Self::Network,
        Self::LockHoldOver1ms,
    ];

    /// The wire and `CMUX_TUI_REQUEST_PATH_IO` name.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Sqlite => "sqlite",
            Self::JournalWait => "journal_wait",
            Self::ProcessSpawn => "process_spawn",
            Self::FsWrite => "fs_write",
            Self::HostWait => "host_wait",
            Self::Sleep => "sleep",
            Self::ProcScan => "proc_scan",
            Self::ChildProcess => "child_process",
            Self::Network => "network",
            Self::LockHoldOver1ms => "lock_hold_over_1ms",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.name() == name)
    }

    fn from_index(index: u8) -> Option<Self> {
        Self::ALL.get(usize::from(index)).copied()
    }

    const fn bit(self) -> u16 {
        1 << self as u8
    }
}

impl fmt::Display for BlockingKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.name())
    }
}

/// How a scope treats its notes: counted always; `record` also keeps the
/// site ring and prints each note; `panic:<kinds>` records and panics on the
/// listed kinds in debug and test builds.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RequestPathMode {
    record: bool,
    panic_on: u16,
}

/// A `CMUX_TUI_REQUEST_PATH_IO` value this build does not understand.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RequestPathModeError {
    UnknownMode(String),
    UnknownKind(String),
    EmptyPanicList,
}

impl fmt::Display for RequestPathModeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownMode(value) => {
                write!(formatter, "unknown mode {value:?}; expected record or panic:<kinds>")
            }
            Self::UnknownKind(kind) => write!(formatter, "unknown blocking kind {kind:?}"),
            Self::EmptyPanicList => formatter.write_str("panic: names no blocking kind"),
        }
    }
}

impl std::error::Error for RequestPathModeError {}

impl RequestPathMode {
    /// Count only (the default).
    pub const OFF: Self = Self { record: false, panic_on: 0 };
    /// Count, keep the site ring and print each note.
    pub const RECORD: Self = Self { record: true, panic_on: 0 };

    /// Record, and panic on a note of any of `kinds` (debug and test builds).
    pub fn panic_on(kinds: &[BlockingKind]) -> Self {
        Self { record: true, panic_on: kinds.iter().fold(0, |mask, kind| mask | kind.bit()) }
    }

    /// `record`, or `panic:<kind>,<kind>,...`. An empty value is off.
    pub fn parse(value: &str) -> Result<Self, RequestPathModeError> {
        let value = value.trim();
        if value.is_empty() {
            return Ok(Self::OFF);
        }
        if value == "record" {
            return Ok(Self::RECORD);
        }
        let Some(list) = value.strip_prefix("panic:") else {
            return Err(RequestPathModeError::UnknownMode(value.to_string()));
        };
        let kinds = list
            .split(',')
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(|name| {
                BlockingKind::parse(name)
                    .ok_or_else(|| RequestPathModeError::UnknownKind(name.to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        if kinds.is_empty() {
            return Err(RequestPathModeError::EmptyPanicList);
        }
        Ok(Self::panic_on(&kinds))
    }

    pub const fn records(self) -> bool {
        self.record
    }

    /// The kinds this mode panics on in builds with debug assertions.
    pub fn panic_kinds(self) -> Vec<BlockingKind> {
        BlockingKind::ALL.into_iter().filter(|kind| self.panics_on(*kind)).collect()
    }

    const fn panics_on(self, kind: BlockingKind) -> bool {
        self.panic_on & kind.bit() != 0
    }
}

/// Entries the site ring keeps; older notes are overwritten.
pub const SITE_RING_LEN: usize = 128;

#[derive(Default)]
struct RingSlot {
    site: AtomicPtr<Location<'static>>,
    kind: AtomicU8,
}

/// One noted site, newest first in [`RequestPathStats::sites`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NotedSite {
    pub kind: BlockingKind,
    pub site: &'static Location<'static>,
}

/// The counters a daemon's request scopes write to. One per daemon (the
/// `Mux` owns it); tests make their own.
pub struct RequestPathStats {
    mode: RequestPathMode,
    handler_runs: AtomicU64,
    counts: [AtomicU64; KIND_COUNT],
    ring: [RingSlot; SITE_RING_LEN],
    ring_next: AtomicUsize,
}

impl RequestPathStats {
    pub fn new(mode: RequestPathMode) -> Arc<Self> {
        Arc::new(Self {
            mode,
            handler_runs: AtomicU64::new(0),
            counts: std::array::from_fn(|_| AtomicU64::new(0)),
            ring: std::array::from_fn(|_| RingSlot::default()),
            ring_next: AtomicUsize::new(0),
        })
    }

    pub fn mode(&self) -> RequestPathMode {
        self.mode
    }

    /// Outermost scopes entered: one per handler run.
    pub fn handler_runs(&self) -> u64 {
        self.handler_runs.load(Ordering::Relaxed)
    }

    /// Notes of `kind` since the daemon started.
    pub fn count(&self, kind: BlockingKind) -> u64 {
        self.counts[kind as usize].load(Ordering::Relaxed)
    }

    /// The recorded sites, newest first (empty unless the mode records). A
    /// read racing a write may pair a slot's new site with its old kind.
    pub fn sites(&self) -> Vec<NotedSite> {
        let written = self.ring_next.load(Ordering::Acquire);
        (0..written.min(SITE_RING_LEN))
            .filter_map(|age| {
                let slot = &self.ring[(written - 1 - age) % SITE_RING_LEN];
                let site = slot.site.load(Ordering::Acquire);
                // SAFETY: the ring stores only pointers taken from `&'static Location`.
                let site: &'static Location<'static> = unsafe { site.as_ref() }?;
                let kind = BlockingKind::from_index(slot.kind.load(Ordering::Relaxed))?;
                Some(NotedSite { kind, site })
            })
            .collect()
    }

    /// Count one note; true when the mode panics on it.
    fn noted(&self, kind: BlockingKind, site: &'static Location<'static>) -> bool {
        self.counts[kind as usize].fetch_add(1, Ordering::Relaxed);
        if !self.mode.record {
            return false;
        }
        let slot = &self.ring[self.ring_next.fetch_add(1, Ordering::AcqRel) % SITE_RING_LEN];
        slot.kind.store(kind as u8, Ordering::Relaxed);
        slot.site.store(std::ptr::from_ref(site).cast_mut(), Ordering::Release);
        let _ = writeln!(
            std::io::stderr().lock(),
            "REQUEST_PATH_IO kind={kind} site={}:{}",
            site.file(),
            site.line()
        );
        self.mode.panics_on(kind)
    }
}

thread_local! {
    static ACTIVE: RefCell<Option<Arc<RequestPathStats>>> = const { RefCell::new(None) };
}

/// The current thread runs a request handler until this drops. Scopes nest:
/// the innermost one gets the notes, and only an outermost entry counts as a
/// handler run.
#[must_use = "the scope ends when it drops"]
pub struct RequestPathScope {
    previous: Option<Arc<RequestPathStats>>,
    /// The scope belongs to its thread.
    _thread: PhantomData<*const ()>,
}

impl RequestPathScope {
    pub fn enter(stats: &Arc<RequestPathStats>) -> Self {
        let previous = ACTIVE.with(|active| active.replace(Some(stats.clone())));
        if !previous.as_ref().is_some_and(|outer| Arc::ptr_eq(outer, stats)) {
            stats.handler_runs.fetch_add(1, Ordering::Relaxed);
        }
        Self { previous, _thread: PhantomData }
    }
}

impl Drop for RequestPathScope {
    fn drop(&mut self) {
        let previous = self.previous.take();
        // Thread teardown may have destroyed the slot already.
        let _ = ACTIVE.try_with(|active| *active.borrow_mut() = previous);
    }
}

/// True while the current thread runs inside a [`RequestPathScope`].
#[inline]
pub fn in_scope() -> bool {
    ACTIVE.try_with(|active| active.borrow().is_some()).unwrap_or(false)
}

/// Note blocking work of `kind` at the caller's location. Mark every wrapper
/// between the blocking primitive and its public call `#[track_caller]`.
#[track_caller]
#[inline]
pub fn note(kind: BlockingKind) {
    note_at(kind, Location::caller());
}

/// [`note`] at a site recorded earlier (a lock hold measured at its release).
#[inline]
pub fn note_at(kind: BlockingKind, site: &'static Location<'static>) {
    let refused = ACTIVE
        .try_with(|active| active.borrow().as_ref().is_some_and(|stats| stats.noted(kind, site)))
        .unwrap_or(false);
    // `CMUX_TUI_REQUEST_PATH_IO=panic:<kinds>` refuses these kinds in debug
    // and test builds; a release build only records them.
    debug_assert!(
        !refused,
        "REQUEST_PATH_IO panic: {kind} on a request thread at {}:{}",
        site.file(),
        site.line()
    );
}

#[cfg(test)]
#[path = "request_path_tests.rs"]
mod tests;
