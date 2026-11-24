//! Priority by interactivity, one policy for every Rust process of cmux.
//!
//! Leo (2026-11-24): "i want all our resizing at any cpu to be able to happen in lockstep. [...] isn't there a
//! thing where we can dynamically adjust priorities of things based off of how interactive they are? [...] maybe we
//! need to absolutely do that far better far more often and examine other places where we could actually put
//! certain things higher, certain things a bit lower."
//!
//! Three pieces, all small:
//!
//! - [`InteractionState`]: when the person last dragged, typed, scrolled or moved focus. A kind counts as active
//!   for its decay ([`decay`], 300-500 ms) after its last [`note`](InteractionState::note), then it is over by
//!   itself: nothing is ever left lowered, and no timer or loop is needed to bring work back (the next
//!   [`policy`] call after the decay answers the idle class).
//! - [`policy`]: a pure table, [`WorkClass`] x interacting-or-not -> [`Qos`].
//! - [`apply_current_thread`] / [`Scoped`]: set the calling thread's QoS (macOS `pthread_set_qos_class_self_np`;
//!   Linux `nice` of the thread) and put it back on drop. Best effort: a refused call leaves the thread as it was.
//!
//! Work that serves what the person touches right now (input, the frame, the focused pane) is
//! user-interactive whether or not they are interacting; work that nobody watches yields while they interact
//! (the policy's lower classes) and is back at its idle class once the decay passes.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// What the person is doing to the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum InteractionKind {
    /// A divider, window, sidebar or pane drag (a resize in flight).
    Drag = 0,
    /// Keys to a terminal or text field.
    Typing = 1,
    /// A scroll wheel, trackpad or scrollbar drag.
    Scroll = 2,
    /// The focused pane or window changed.
    Focus = 3,
}

const KINDS: usize = 4;

impl InteractionKind {
    pub const ALL: [Self; KINDS] = [Self::Drag, Self::Typing, Self::Scroll, Self::Focus];

    /// Raw value (the C ABI's `kind`); `None` for an unknown one.
    pub const fn from_raw(raw: u32) -> Option<Self> {
        match raw {
            0 => Some(Self::Drag),
            1 => Some(Self::Typing),
            2 => Some(Self::Scroll),
            3 => Some(Self::Focus),
            _ => None,
        }
    }
}

/// How long a kind stays active after its last note: long enough to bridge the gap between two events of one
/// gesture (a drag's frames, keys of a burst), short enough that background work waits at most this long. Every
/// value is below 500 ms, so a lowered class is never lowered for longer than that after the last input.
pub const fn decay(kind: InteractionKind) -> Duration {
    Duration::from_millis(match kind {
        InteractionKind::Drag => 400,
        InteractionKind::Typing => 500,
        InteractionKind::Scroll => 300,
        InteractionKind::Focus => 300,
    })
}

/// The last time of each kind, lock-free: a note is one atomic store, a check four loads.
pub struct InteractionState {
    epoch: Instant,
    /// Milliseconds since `epoch` plus one; 0 is "never".
    last: [AtomicU64; KINDS],
}

impl Default for InteractionState {
    fn default() -> Self {
        Self::new()
    }
}

impl InteractionState {
    pub fn new() -> Self {
        Self::with_epoch(Instant::now())
    }

    /// A state whose clock starts at `epoch` (tests pass their own instants).
    pub fn with_epoch(epoch: Instant) -> Self {
        Self { epoch, last: [const { AtomicU64::new(0) }; KINDS] }
    }

    #[allow(
        clippy::indexing_slicing,
        reason = "InteractionKind has exactly KINDS variants, so its discriminant is always in range"
    )]
    fn slot(&self, kind: InteractionKind) -> &AtomicU64 {
        &self.last[kind as usize]
    }

    fn stamp(&self, now: Instant) -> u64 {
        u64::try_from(now.saturating_duration_since(self.epoch).as_millis()).unwrap_or(u64::MAX - 1)
            + 1
    }

    /// The person did `kind` at `now`. Never moves a kind's time backwards.
    pub fn note(&self, kind: InteractionKind, now: Instant) {
        self.slot(kind).fetch_max(self.stamp(now), Ordering::AcqRel);
    }

    /// Whether `kind` is active at `now`: noted within its decay.
    pub fn is_kind_active(&self, kind: InteractionKind, now: Instant) -> bool {
        let last = self.slot(kind).load(Ordering::Acquire);
        if last == 0 {
            return false;
        }
        let at = self.epoch + Duration::from_millis(last - 1);
        now.saturating_duration_since(at) < decay(kind)
    }

    /// Whether any kind is active at `now`.
    pub fn is_interacting(&self, now: Instant) -> bool {
        InteractionKind::ALL.iter().any(|kind| self.is_kind_active(*kind, now))
    }
}

/// The process's state: the daemon notes the commands of a person's connection into it, the app's FFI notes the
/// events it sees.
pub fn global() -> &'static InteractionState {
    static STATE: OnceLock<InteractionState> = OnceLock::new();
    STATE.get_or_init(InteractionState::new)
}

/// Notes `kind` now in the process's state.
pub fn note(kind: InteractionKind) {
    global().note(kind, Instant::now());
}

/// Whether the person is interacting now, per the process's state.
pub fn is_interacting() -> bool {
    global().is_interacting(Instant::now())
}

/// What a piece of work is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum WorkClass {
    /// Reading and routing the person's input (keys, pointer, resize commands).
    Input = 0,
    /// Producing the frame: layout, resize, paint, present.
    Frame = 1,
    /// Output and state of the pane the person is working in.
    FocusedPane = 2,
    /// Output of panes on screen that are not focused.
    VisiblePane = 3,
    /// Output of panes off screen.
    BackgroundPane = 4,
    /// Parsing agent output into chat and activity.
    AgentOutputParse = 5,
    /// Building or backfilling search and history indexes.
    Index = 6,
    /// Syncing to disk, cloud or other machines (journal checkpoints, uploads).
    Sync = 7,
    /// Cleanup, pruning, migration: nobody waits for it.
    Maintenance = 8,
}

impl WorkClass {
    pub const ALL: [Self; 9] = [
        Self::Input,
        Self::Frame,
        Self::FocusedPane,
        Self::VisiblePane,
        Self::BackgroundPane,
        Self::AgentOutputParse,
        Self::Index,
        Self::Sync,
        Self::Maintenance,
    ];

    /// Raw value (the C ABI's `class`); `None` for an unknown one.
    pub fn from_raw(raw: u32) -> Option<Self> {
        Self::ALL.get(usize::try_from(raw).ok()?).copied()
    }
}

/// A QoS level. The raw value is macOS's `qos_class_t`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Qos {
    Background,
    Utility,
    Default,
    UserInitiated,
    UserInteractive,
}

impl Qos {
    /// macOS `qos_class_t` raw value (`QOS_CLASS_*`); the same numbers on every platform so the app reads one table.
    pub const fn raw(self) -> u32 {
        match self {
            Self::UserInteractive => 0x21,
            Self::UserInitiated => 0x19,
            Self::Default => 0x15,
            Self::Utility => 0x11,
            Self::Background => 0x09,
        }
    }

    /// Linux `nice` value of the level. Raising above the process's own nice needs privilege, so the levels at or
    /// above `Default` all ask for 0 and a refused call changes nothing.
    pub const fn nice(self) -> i32 {
        match self {
            Self::UserInteractive | Self::UserInitiated | Self::Default => 0,
            Self::Utility => 5,
            Self::Background => 19,
        }
    }
}

/// The table: the QoS of `class` at `now`. Pure.
///
/// | class | idle | interacting |
/// |---|---|---|
/// | Input, Frame | user-interactive | user-interactive |
/// | FocusedPane | user-initiated | user-interactive |
/// | VisiblePane | default | user-initiated |
/// | BackgroundPane | utility | background |
/// | AgentOutputParse | default | utility |
/// | Index, Sync | utility | background |
/// | Maintenance | background | background |
pub fn policy(class: WorkClass, state: &InteractionState, now: Instant) -> Qos {
    policy_for(class, state.is_interacting(now))
}

/// [`policy`] with the interaction already decided.
pub const fn policy_for(class: WorkClass, interacting: bool) -> Qos {
    use Qos::{Background, Default, UserInitiated, UserInteractive, Utility};
    match (class, interacting) {
        (WorkClass::Input | WorkClass::Frame, _) => UserInteractive,
        (WorkClass::FocusedPane, false) => UserInitiated,
        (WorkClass::FocusedPane, true) => UserInteractive,
        (WorkClass::VisiblePane, false) => Default,
        (WorkClass::VisiblePane, true) => UserInitiated,
        (WorkClass::BackgroundPane | WorkClass::Index | WorkClass::Sync, false) => Utility,
        (WorkClass::BackgroundPane | WorkClass::Index | WorkClass::Sync, true) => Background,
        (WorkClass::AgentOutputParse, false) => Default,
        (WorkClass::AgentOutputParse, true) => Utility,
        (WorkClass::Maintenance, _) => Background,
    }
}

/// [`policy`] against the process's state, now.
pub fn qos_for(class: WorkClass) -> Qos {
    policy_for(class, is_interacting())
}

/// What a thread had before [`apply_current_thread`].
#[derive(Debug, Clone, Copy)]
pub struct Previous {
    #[cfg(target_vendor = "apple")]
    qos: libc::qos_class_t,
    #[cfg(all(target_os = "linux", not(target_vendor = "apple")))]
    nice: Option<libc::c_int>,
}

/// Sets the calling thread's QoS and returns what it had. Off macOS and Linux this sets nothing.
pub fn apply_current_thread(qos: Qos) -> Previous {
    #[cfg(target_vendor = "apple")]
    {
        use libc::qos_class_t as Q;
        let mut previous = Q::QOS_CLASS_UNSPECIFIED;
        let mut relative = 0;
        // SAFETY: valid out pointers for this thread's own QoS.
        unsafe {
            libc::pthread_get_qos_class_np(libc::pthread_self(), &mut previous, &mut relative)
        };
        let class = match qos {
            Qos::UserInteractive => Q::QOS_CLASS_USER_INTERACTIVE,
            Qos::UserInitiated => Q::QOS_CLASS_USER_INITIATED,
            Qos::Default => Q::QOS_CLASS_DEFAULT,
            Qos::Utility => Q::QOS_CLASS_UTILITY,
            Qos::Background => Q::QOS_CLASS_BACKGROUND,
        };
        set_apple(class);
        Previous { qos: previous }
    }
    #[cfg(all(target_os = "linux", not(target_vendor = "apple")))]
    {
        let tid = thread_id();
        let previous = get_nice(tid);
        // Only ever lowers priority, and only when the thread can be put back: raising priority again needs
        // CAP_SYS_NICE or RLIMIT_NICE, and a lowered thread that could not return would starve.
        let lowered = previous.filter(|p| *p < qos.nice() && can_restore(*p));
        if lowered.is_some() {
            set_nice(tid, qos.nice());
        }
        Previous { nice: lowered }
    }
    #[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
    {
        let _ = qos;
        Previous {}
    }
}

/// Puts the calling thread back to `previous`.
pub fn restore_current_thread(previous: Previous) {
    #[cfg(target_vendor = "apple")]
    {
        let class = match previous.qos {
            libc::qos_class_t::QOS_CLASS_UNSPECIFIED => libc::qos_class_t::QOS_CLASS_DEFAULT,
            other => other,
        };
        set_apple(class);
    }
    #[cfg(all(target_os = "linux", not(target_vendor = "apple")))]
    if let Some(nice) = previous.nice {
        // Lowering a nice value back needs CAP_SYS_NICE or RLIMIT_NICE; without them this stays refused and the
        // thread keeps the lower priority, which is why Linux callers scope only whole worker threads or passes.
        set_nice(thread_id(), nice);
    }
    #[cfg(not(any(target_vendor = "apple", target_os = "linux")))]
    let _ = previous;
}

#[cfg(target_vendor = "apple")]
fn set_apple(class: libc::qos_class_t) {
    // SAFETY: sets the calling thread's own QoS class; no pointers.
    unsafe { libc::pthread_set_qos_class_self_np(class, 0) };
}

#[cfg(all(target_os = "linux", not(target_vendor = "apple")))]
fn thread_id() -> libc::id_t {
    // SAFETY: plain syscall on the calling thread.
    unsafe { libc::syscall(libc::SYS_gettid) as libc::id_t }
}

#[cfg(all(target_os = "linux", not(target_vendor = "apple")))]
fn get_nice(tid: libc::id_t) -> Option<libc::c_int> {
    // SAFETY: errno is read around a getpriority on this thread's own id.
    unsafe {
        *libc::__errno_location() = 0;
        let nice = libc::getpriority(libc::PRIO_PROCESS, tid);
        (nice != -1 || *libc::__errno_location() == 0).then_some(nice)
    }
}

/// Whether this thread may lower its nice value back to `nice` (root, or RLIMIT_NICE allows it).
#[cfg(all(target_os = "linux", not(target_vendor = "apple")))]
fn can_restore(nice: libc::c_int) -> bool {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: valid out pointer.
    let ok = unsafe { libc::getrlimit(libc::RLIMIT_NICE, &mut limit) } == 0;
    // SAFETY: no arguments.
    let root = unsafe { libc::geteuid() } == 0;
    root || (ok && 20 - i64::try_from(limit.rlim_cur).unwrap_or(i64::MAX) <= i64::from(nice))
}

#[cfg(all(target_os = "linux", not(target_vendor = "apple")))]
fn set_nice(tid: libc::id_t, nice: libc::c_int) {
    // SAFETY: setpriority on this thread's own id.
    unsafe { libc::setpriority(libc::PRIO_PROCESS, tid, nice) };
}

/// Idle IO class for the thread (Linux), used by [`apply_maintenance_io`].
#[cfg(target_os = "linux")]
fn set_idle_io(tid: libc::id_t) {
    // ioprio_set(IOPRIO_WHO_PROCESS, tid, IOPRIO_CLASS_IDLE).
    // SAFETY: plain syscall on this thread's own id.
    unsafe { libc::syscall(libc::SYS_ioprio_set, 1, tid, 3 << 13) };
}

/// For a thread that lives its whole life as maintenance: [`Qos::Background`] and, on Linux, idle IO. Never put
/// back (the thread is the pass).
pub fn lower_current_thread_for_life() {
    #[cfg(target_vendor = "apple")]
    apply_current_thread(Qos::Background);
    // One way on Linux: the thread is never put back, so it needs no permission to restore and gets nice 19
    // even unprivileged (apply_current_thread skips a demotion it could not undo).
    #[cfg(all(target_os = "linux", not(target_vendor = "apple")))]
    {
        let tid = thread_id();
        if get_nice(tid).is_none_or(|nice| nice < Qos::Background.nice()) {
            set_nice(tid, Qos::Background.nice());
        }
    }
    #[cfg(target_os = "linux")]
    set_idle_io(thread_id());
}

/// A long-lived thread that follows the policy: [`Follower::follow`] before each unit of work sets the thread's QoS
/// when the policy's answer for the class changed since the last call. One atomic-load check per call (plus a clock
/// read), a system call only on a change; never put back (the thread lives by the policy).
#[derive(Default)]
pub struct Follower {
    current: Option<Qos>,
}

impl Follower {
    pub const fn new() -> Self {
        Self { current: None }
    }

    /// Sets the calling thread to the policy's QoS for `class` now when it differs from the last one set.
    pub fn follow(&mut self, class: WorkClass) {
        let qos = qos_for(class);
        if self.current != Some(qos) {
            self.current = Some(qos);
            apply_current_thread(qos);
        }
    }
}

/// The calling thread at `qos` until dropped.
#[must_use = "the thread goes back when the guard drops"]
pub struct Scoped {
    previous: Option<Previous>,
}

impl Scoped {
    pub fn new(qos: Qos) -> Self {
        Self { previous: Some(apply_current_thread(qos)) }
    }

    /// The calling thread at the policy's QoS for `class` right now, for the scope of the guard.
    pub fn for_class(class: WorkClass) -> Self {
        Self::new(qos_for(class))
    }
}

impl Drop for Scoped {
    fn drop(&mut self) {
        if let Some(previous) = self.previous.take() {
            restore_current_thread(previous);
        }
    }
}

#[cfg(test)]
mod tests;
