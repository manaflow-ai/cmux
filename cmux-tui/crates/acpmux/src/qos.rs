//! How much CPU and disk each acpmux process may take from the person at the
//! screen: one declared policy ([`tier`]), applied where each process starts.
//!
//! Leo (2026-10-29): "well somehow at "100% cpu" usage claude code desktop
//! still seems fast / how does that work? how can cmux next also do that?
//! let's do that". On a Mac at load 100-360 the app's main thread already runs
//! at the frontmost app's priority (46-47), like Claude Desktop's. What made
//! cmux NEXT feel slower was its agent work: every agent host, harness and the
//! git, rg and compiles they run sat at the default (31) and took the disk at
//! the default I/O tier, level with everything the app needs. So:
//!
//! | Tier | Who | macOS | Linux |
//! |---|---|---|---|
//! | [`Tier::Serving`] | the daemon | unchanged: acknowledged replies wait on the event journal's sync, so its disk I/O stays at the default tier ([`enter_daemon`]) | unchanged |
//! | [`Tier::AgentStart`] | agent hosts and their harnesses | the host's disk I/O at `IOPOL_UTILITY`; its harness back at the default disk tier ([`default_disk_io`]) and the daemon's CPU priority, as a shell in a terminal runs: a `normal` harness (the default) stays at the terminal's class, a `dynamic` one (opt-in) goes to background class only while the Mac is contended, and a `background` one (opt-in) stays there once its start is over (`cpu_class.rs`) | while it starts: unchanged; then the harness at nice +5 and its host's session (autogroup) at nice 5 |
//! | [`Tier::Agent`] | background-task runners, and everything they start | the daemon's CPU priority and the default disk tier, as a shell in a terminal runs | nice +5 |
//! | [`Tier::Background`] | housekeeping inside the daemon that holds no lock other work waits on (probe cleanup at start) | the thread at `QOS_CLASS_BACKGROUND` for the pass (CPU throttled; its disk I/O at the background class's tier), then back | unchanged |
//! | [`Tier::OnScreen`] | the daemon's reads for a chat being opened on screen (a visible `_acpmux/attach`: its log load and its first page) | the thread at `QOS_CLASS_USER_INITIATED` for the read (its CPU; its disk I/O stays at the daemon's default tier), then back | unchanged |
//!
//! The daemon keeps its CPU priority: the app waits on it for every streamed
//! frame, so demoting it would put a person's own stream behind agent
//! compiles. Its disk I/O stays at the default tier too: an acknowledged
//! reply waits on the event journal's sync, which a utility tier throttles
//! 15-30x under another app's disk work (STATUS 11554). Only its background
//! threads yield, each for its whole life ([`background_thread`]: the event
//! journal's checkpointer), since a thread's disk I/O tier is the most
//! throttled of the process's, its own and its QoS class's (xnu
//! `thread_policy.c`). A per-thread I/O policy also drops the thread out of
//! QoS (`imp::ThreadOnScreen`), so a reused pool thread never takes it.
//!
//! An agent's start is work a person waits on, so it is not agent work (W6, 2026-11-12): on
//! Leo's Mac at load average 125 to 256, waking an agent took 10 to 82 s, and one start ran out
//! its 90 s with 1.8 s of CPU used, its host and harness under the utility clamp and below every
//! default-priority process on the machine. An agent host therefore starts at the daemon's CPU
//! priority (its disk I/O still at utility) and spawns its harness there, at the default disk tier.
//! An agent's turns are work a person waits on too (2026-11-24: over 130 sessions on one Mac, a
//! NEXT agent's tests took 37 s at the median against 11 s in a terminal, and its slowest builds
//! 220 s against 52 s; one 1-commit rebase took 87 minutes at 0% CPU, waiting on a throttled
//! disk). The default `normal` class keeps the terminal's CPU class and normal disk I/O. An
//! opt-in `dynamic` class temporarily adds background class only while the host is contended. A
//! `background` session's harness stays lowered once its start is over.
//!
//! An agent's background tasks are work a person waits on too: a build, a test run or a push an
//! agent started in the background is the turn's result. Until 2026-11-27 each task's runner
//! re-executed itself under the utility QoS clamp (`taskpolicy -c utility`: priority 20, and the
//! clamp holds every process it starts) with its disk I/O at `IOPOL_UTILITY`. On a busy Mac (load
//! 94 on 15 cores) a tagged dogfood build started that way took 21 to 41 minutes at the median
//! against 2 to 3 minutes the same builds took two weeks before, and a terminal in cmux classic
//! runs them at the default. So on macOS a task runs as a shell in a terminal runs: the daemon's
//! CPU priority (never above nice 0) and the default disk tier. `ACPMUX_QOS=background` still
//! puts tasks in background class. The I/O policy is process wide and inherited across exec.
//!
//! A pass that holds a lock chat traffic takes (log retention's compaction
//! holds the store's writers lock; the upload sweep holds the in-use set) stays
//! at the daemon's own priority: throttling it would stall every stream.
//!
//! Why not background class for agents: background class gives the app
//! more (manaflow-ai/cmuxterm-hq#4947: a Chromium pane's drag lag under 14 busy
//! processes was 55 ms p95 at default, 40 ms at utility, 6 ms at background),
//! but it keeps agent work off the performance cores even on an idle Mac: a
//! fixed CPU job took 0.9 s at default, 0.8 s at utility and 16.6 s at
//! background on one thread, and 4.0 / 3.6 / 28.5 s on ten (cmux-mac-mini, 4P +
//! 6E). `ACPMUX_QOS=background` picks background for agent hosts and tasks anyway.
//!
//! `ACPMUX_QOS=off` turns all of it off (a process started with it set starts
//! as before); agent hosts get it through their environment allowlist
//! (`agent::host_environment`). Best effort: a call that fails leaves the process as it was.

/// How much a process yields to the person at the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// The daemon: the app waits on it, and its replies wait on the event journal's sync, so
    /// nothing of it yields (only its background threads, [`background_thread`]).
    Serving,
    /// Agent work: background-task runners and every tool they run. macOS: a terminal shell's
    /// CPU priority and disk tier; Linux: nice +5.
    Agent,
    /// Agent hosts: the daemon's CPU tier, disk I/O at utility. Their harnesses run at the
    /// daemon's tier and the default disk tier; a `dynamic` session's harness goes to background
    /// class while contended and a `background` session stays there (`cpu_class::CpuClass::enter`).
    AgentStart,
    /// Work nobody waits for: sweeps, retention, cleanup.
    Background,
    /// A read the person at the screen is waiting on: opening a chat.
    OnScreen,
}

/// What a process is, for [`tier`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Daemon,
    AgentHost,
    BackgroundTaskRunner,
    Housekeeping,
    /// A daemon thread reading for a chat being opened on screen.
    VisibleOpen,
}

/// The one policy: the tier of each role. Exhaustive, so a new role cannot
/// start without one.
pub const fn tier(role: Role) -> Tier {
    match role {
        Role::Daemon => Tier::Serving,
        Role::AgentHost => Tier::AgentStart,
        Role::BackgroundTaskRunner => Tier::Agent,
        Role::Housekeeping => Tier::Background,
        Role::VisibleOpen => Tier::OnScreen,
    }
}

/// Turns the whole policy off when set to `off`.
pub const ENV: &str = "ACPMUX_QOS";

pub(crate) fn enabled() -> bool {
    std::env::var_os(ENV).is_none_or(|v| v != "off")
}

/// The nice value a harness runs at once its start is over: on macOS the base priority of the
/// utility clamp (31 - 11 = 20, `nice` lowers a task's priority one step per unit), on Linux the
/// agent tier's +5.
#[cfg(target_os = "macos")]
pub const AGENT_NICE: libc::c_int = 11;
/// The nice value a harness runs at once its start is over (Linux: the agent tier's +5).
#[cfg(all(unix, not(target_os = "macos")))]
pub const AGENT_NICE: libc::c_int = 5;

/// `ACPMUX_QOS=background`: agent hosts run in background instead of utility.
fn agent_background() -> bool {
    std::env::var_os(ENV).is_some_and(|v| v == "background")
}

/// This process (or, on Linux, this thread) at nice 0 when it runs below it: an agent host or a
/// harness the daemon starts, which inherits a negative nice the daemon took
/// (`daemon_priority.rs`). Raising a nice needs no privilege. Async-signal-safe: it runs between
/// fork and exec (`cpu_class::start_at_normal`).
#[cfg(unix)]
pub fn at_least_default_nice() {
    // SAFETY: plain syscalls on the calling process. -1 is also getpriority's error answer, and
    // raising -1 to 0 is right either way.
    unsafe {
        if libc::getpriority(libc::PRIO_PROCESS, 0) < 0 {
            libc::setpriority(libc::PRIO_PROCESS, 0, 0);
        }
    }
}

/// This process's disk I/O back at the default tier (macOS; elsewhere nothing), as a shell in a
/// terminal has it: a harness takes it between fork and exec (`cpu_class::start_at_normal`), so
/// it and every tool its turns run do not inherit its agent host's `IOPOL_UTILITY`, which the
/// kernel throttles behind any default-tier disk work on the machine. Async-signal-safe: one
/// syscall on the calling process.
pub fn default_disk_io() {
    imp::disk_default();
}

/// The daemon's tier: acknowledged replies wait on the event journal's sync, so the daemon keeps
/// the default disk tier (lead rule 2026-11-04: a reply the person waits for never waits on a
/// throttled sync) and only its background threads yield ([`background_thread`]). Nothing to
/// set: the CPU is unchanged for the daemon too.
pub fn enter_daemon() {}

/// The base priority a process runs at when nothing lowered it (macOS `BASEPRI_DEFAULT`): the
/// daemon's CPU tier. `daemon_priority.rs` reports the daemon's base priority against it.
#[cfg(target_os = "macos")]
pub const DAEMON_PRIORITY: i32 = 31;

/// This process's base priority when it runs below [`DAEMON_PRIORITY`], None when it does not,
/// when it cannot be read, or with the policy off (`ACPMUX_QOS=off`). A launchd `Standard` or
/// `Background` job's QoS clamp, and nice, lower it for everything the process starts.
#[cfg(target_os = "macos")]
pub fn lowered_priority() -> Option<i32> {
    if !enabled() {
        return None;
    }
    imp::base_priority().filter(|p| *p < DAEMON_PRIORITY)
}

/// The calling thread, dedicated to background work for its whole life (the event journal's
/// checkpointer): its disk I/O at the utility tier. Only for a thread that does nothing else: a
/// thread-scope I/O policy also drops the thread out of QoS for good (see `imp::ThreadOnScreen`),
/// so a pool thread that is reused must never take it.
pub fn background_thread() {
    if enabled() {
        imp::thread_disk_utility();
    }
}

/// Put this process in `role`'s tier. Call it first thing in `main`, before
/// any thread starts.
pub fn enter(role: Role) {
    if !enabled() {
        return;
    }
    // Never above the default: the daemon may run at a negative nice (`daemon_priority.rs`).
    #[cfg(unix)]
    if matches!(tier(role), Tier::Agent | Tier::AgentStart) {
        at_least_default_nice();
    }
    match tier(role) {
        // Nothing: acknowledged replies wait on the event journal's sync ([`enter_daemon`]).
        Tier::Serving => {}
        // Opt-in: the whole agent tree in background (hq#4947's 55 -> 6 ms
        // drag lag), at the cost of agent speed (module docs).
        Tier::Agent | Tier::AgentStart if agent_background() => imp::process_background(),
        // Its disk I/O at utility, its CPU unclamped: the start runs at the daemon's CPU priority,
        // and the harness is lowered once its session's start is over
        // (`cpu_class::CpuClass::enter`).
        Tier::AgentStart => imp::disk_utility(),
        // A terminal shell's priority on macOS (module docs): the default disk tier, whatever
        // the daemon's starter left, and its CPU unlowered. Linux: nice +5, as a Linux harness.
        Tier::Agent => {
            imp::disk_default();
            #[cfg(not(target_os = "macos"))]
            imp::clamp_cpu_utility();
        }
        // A whole background process is not in the policy yet; threads use
        // [`background`]. On-screen reads are per thread too ([`on_screen`]).
        Tier::Background | Tier::OnScreen => {}
    }
}

/// Run `work` (blocking) with this thread in [`Tier::Background`], then put
/// the thread back: blocking-pool threads are reused for other work.
pub fn background<T>(work: impl FnOnce() -> T) -> T {
    let _guard = enabled().then(imp::ThreadBackground::enter);
    work()
}

/// Run `work`, a request's blocking read (a chat's log page, its prompt index), without holding a
/// runtime worker: on the daemon's multi-thread runtime the worker hands its other tasks to a new
/// one first (`block_in_place`), so a long read never queues a hello, a status or another chat's
/// attach behind it. Leo's daemon, 2026-11-18: three of its workers sat in attach log reads for a
/// whole 4 s sample and `acpmux daemon status` answered in 4.9 to 11.8 s. A current-thread
/// runtime (a one-shot test) and a thread outside any runtime run it in place.
pub fn off_worker<T>(work: impl FnOnce() -> T) -> T {
    let multi = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    if multi { tokio::task::block_in_place(work) } else { work() }
}

/// Run `work` (blocking) with this thread in [`Tier::OnScreen`], then put the
/// thread back as it was: the reads for a chat being opened on screen, which
/// the person is waiting on, ahead of agent work's CPU and disk. Tokio worker
/// and blocking-pool threads are reused, so the guard restores what it found.
pub fn on_screen<T>(work: impl FnOnce() -> T) -> T {
    let _guard = enabled().then(imp::ThreadOnScreen::enter);
    work()
}

#[cfg(target_os = "macos")]
mod imp {
    const IOPOL_TYPE_DISK: libc::c_int = 0;
    const IOPOL_SCOPE_PROCESS: libc::c_int = 0;
    const IOPOL_SCOPE_THREAD: libc::c_int = 1;
    const IOPOL_IMPORTANT: libc::c_int = 1;
    const IOPOL_UTILITY: libc::c_int = 4;
    const PRIO_DARWIN_BG: libc::c_int = 0x1000;

    unsafe extern "C" {
        fn setiopolicy_np(
            iotype: libc::c_int,
            scope: libc::c_int,
            policy: libc::c_int,
        ) -> libc::c_int;
        #[cfg(test)]
        fn getiopolicy_np(iotype: libc::c_int, scope: libc::c_int) -> libc::c_int;
    }

    pub(super) fn disk_utility() {
        // SAFETY: plain syscall wrapper with constant arguments.
        if unsafe { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_UTILITY) } != 0 {
            tracing::debug!("setiopolicy_np: {}", std::io::Error::last_os_error());
        }
    }

    /// The process's disk I/O at `IOPOL_IMPORTANT`, the tier a process starts at
    /// ([`super::default_disk_io`]). No logging: it runs between fork and exec.
    pub(super) fn disk_default() {
        // SAFETY: plain syscall wrapper with constant arguments, async-signal-safe.
        unsafe { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT) };
    }

    /// This process's scheduler base priority (`proc_pidinfo` `PROC_PIDTASKINFO`): 31 at the
    /// default, 20 under a utility clamp or at nice +11, 4 at background class.
    pub(super) fn base_priority() -> Option<i32> {
        // SAFETY: an all-zero proc_taskinfo is a valid out-parameter.
        let mut task: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<libc::proc_taskinfo>() as libc::c_int;
        // SAFETY: `task` is `size` bytes the call fills; getpid has no preconditions.
        let n = unsafe {
            libc::proc_pidinfo(
                libc::getpid(),
                libc::PROC_PIDTASKINFO,
                0,
                (&mut task as *mut libc::proc_taskinfo).cast(),
                size,
            )
        };
        (n == size).then_some(task.pti_priority)
    }

    /// The calling thread's disk I/O at utility (`background_thread`).
    pub(super) fn thread_disk_utility() {
        // SAFETY: plain syscall wrapper on the calling thread with constant arguments.
        if unsafe { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY) } != 0 {
            tracing::debug!("setiopolicy_np (thread): {}", std::io::Error::last_os_error());
        }
    }

    /// This process, and every process it starts, in `PRIO_DARWIN_BG`
    /// (inherited across fork and exec; a fleet-mini probe).
    pub(super) fn process_background() {
        const PRIO_DARWIN_PROCESS: libc::c_int = 4;
        // SAFETY: plain syscall on this process.
        unsafe { libc::setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG) };
    }

    /// This thread at background QoS until dropped (CPU throttled; its disk I/O at the background
    /// class's tier), then back to the class it had. Not the per-thread
    /// `setpriority(PRIO_DARWIN_THREAD, BG)`: like a thread-scope `setiopolicy_np`, it drops the
    /// thread out of QoS for good (see [`ThreadOnScreen`]).
    pub(super) struct ThreadBackground {
        qos: libc::qos_class_t,
    }

    impl ThreadBackground {
        pub(super) fn enter() -> Self {
            let guard = ThreadBackground { qos: thread_qos() };
            set_thread_qos(libc::qos_class_t::QOS_CLASS_BACKGROUND, "background pass");
            guard
        }
    }

    impl Drop for ThreadBackground {
        fn drop(&mut self) {
            set_thread_qos(restorable(self.qos), "after a background pass");
        }
    }

    /// The class a guard puts back: an unspecified class cannot be set again, and default is
    /// what such a thread runs at.
    fn restorable(qos: libc::qos_class_t) -> libc::qos_class_t {
        match qos {
            libc::qos_class_t::QOS_CLASS_UNSPECIFIED => libc::qos_class_t::QOS_CLASS_DEFAULT,
            qos => qos,
        }
    }

    /// This thread at user-initiated QoS until dropped, then back to the class it had. Its disk
    /// I/O tier is the most throttled of the process's (the default, [`super::enter_daemon`]), its
    /// QoS's and its own (xnu `thread_policy.c`). No thread-scope `setiopolicy_np`: on macOS 26 and 27 that call
    /// drops the thread out of QoS (it reads unspecified) and makes every later
    /// `pthread_set_qos_class_self_np` on the thread fail with EPERM, so a reused pool thread
    /// could never be raised again (fleet probes 01949bb5 and 3b349221, 2026-10-31).
    pub(super) struct ThreadOnScreen {
        qos: libc::qos_class_t,
    }

    /// `pthread_set_qos_class_self_np(qos, 0)`, logged when the kernel refuses it.
    fn set_thread_qos(qos: libc::qos_class_t, what: &str) {
        // SAFETY: plain call on the calling thread with a valid class and relative priority 0.
        let rc = unsafe { libc::pthread_set_qos_class_self_np(qos, 0) };
        if rc != 0 {
            tracing::warn!(rc, "{what}: pthread_set_qos_class_self_np refused ({})", qos as u32);
        }
    }

    /// This thread's QoS class (unspecified when none was ever set).
    pub(super) fn thread_qos() -> libc::qos_class_t {
        let mut qos = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
        let mut rel = 0;
        // SAFETY: reads the calling thread's own class into locals.
        unsafe { libc::pthread_get_qos_class_np(libc::pthread_self(), &mut qos, &mut rel) };
        qos
    }

    /// This thread's own disk I/O policy (`IOPOL_DEFAULT`, 0, when it follows the process's).
    #[cfg(test)]
    pub(super) fn thread_io() -> libc::c_int {
        // SAFETY: plain syscall on the calling thread.
        unsafe { getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD) }
    }

    impl ThreadOnScreen {
        pub(super) fn enter() -> Self {
            let guard = ThreadOnScreen { qos: thread_qos() };
            set_thread_qos(libc::qos_class_t::QOS_CLASS_USER_INITIATED, "on-screen read");
            guard
        }
    }

    impl Drop for ThreadOnScreen {
        fn drop(&mut self) {
            set_thread_qos(restorable(self.qos), "after an on-screen read");
        }
    }
}

#[cfg(target_os = "linux")]
mod imp {
    pub(super) fn disk_utility() {}
    pub(super) fn disk_default() {}
    pub(super) fn thread_disk_utility() {}

    /// nice +5: inherited by everything the process starts. Not undone (an
    /// unprivileged process cannot lower its nice value), and not needed to be.
    pub(super) fn clamp_cpu_utility() {
        // SAFETY: plain syscalls on this process.
        unsafe {
            let current = libc::getpriority(libc::PRIO_PROCESS, 0);
            if current < 5 {
                libc::setpriority(libc::PRIO_PROCESS, 0, 5);
            }
        }
    }

    pub(super) fn process_background() {
        clamp_cpu_utility();
    }

    pub(super) struct ThreadBackground;
    impl ThreadBackground {
        pub(super) fn enter() -> Self {
            ThreadBackground
        }
    }

    pub(super) struct ThreadOnScreen;
    impl ThreadOnScreen {
        pub(super) fn enter() -> Self {
            ThreadOnScreen
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    pub(super) fn disk_utility() {}
    pub(super) fn disk_default() {}
    pub(super) fn thread_disk_utility() {}
    pub(super) fn clamp_cpu_utility() {}
    pub(super) fn process_background() {
        clamp_cpu_utility();
    }

    pub(super) struct ThreadBackground;
    impl ThreadBackground {
        pub(super) fn enter() -> Self {
            ThreadBackground
        }
    }

    pub(super) struct ThreadOnScreen;
    impl ThreadOnScreen {
        pub(super) fn enter() -> Self {
            ThreadOnScreen
        }
    }
}

// Its tests read macOS disk policies only.
#[cfg(all(test, target_os = "macos"))]
#[path = "qos_journal_tests.rs"]
mod journal_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_daemon_keeps_its_cpu_and_agents_yield() {
        assert_eq!(tier(Role::Daemon), Tier::Serving);
        assert_eq!(tier(Role::AgentHost), Tier::AgentStart);
        assert_eq!(tier(Role::BackgroundTaskRunner), Tier::Agent);
        assert_eq!(tier(Role::Housekeeping), Tier::Background);
        assert_eq!(tier(Role::VisibleOpen), Tier::OnScreen);
    }

    #[test]
    fn an_on_screen_read_returns_its_value() {
        assert_eq!(on_screen(|| 7), 7);
    }

    /// The read runs at user-initiated QoS, and the thread goes back to what it had: tokio
    /// reuses it for other work, and the next on-screen read on it is raised again.
    #[cfg(target_os = "macos")]
    #[test]
    fn an_on_screen_read_raises_the_thread_and_puts_it_back() {
        if !enabled() {
            return;
        }
        // `qos_class_t` has no `PartialEq` in libc, so the classes compare as their numbers.
        let class = |qos: libc::qos_class_t| qos as u32;
        let (qos, io) = (imp::thread_qos(), imp::thread_io());
        // The thread's own I/O policy is left alone: a thread-scope `setiopolicy_np` drops the
        // thread out of QoS (it read 0, unspecified, on macOS 26 and 27) and makes every later
        // `pthread_set_qos_class_self_np` on it fail with EPERM.
        let inside = on_screen(|| (class(imp::thread_qos()), imp::thread_io()));
        assert_eq!(inside, (class(libc::qos_class_t::QOS_CLASS_USER_INITIATED), io));
        let after = (class(imp::thread_qos()), imp::thread_io());
        let expected_qos = match qos {
            libc::qos_class_t::QOS_CLASS_UNSPECIFIED => libc::qos_class_t::QOS_CLASS_DEFAULT,
            qos => qos,
        };
        assert_eq!(after, (class(expected_qos), io));
        // A pool thread is reused: the next on-screen read on it is raised again.
        let again = on_screen(|| class(imp::thread_qos()));
        assert_eq!(again, class(libc::qos_class_t::QOS_CLASS_USER_INITIATED), "the second raise");
    }

    /// A background pass (`background`) puts the pool thread back as it found it, so a later
    /// on-screen read on that thread is still raised.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_background_pass_leaves_the_thread_raisable() {
        if !enabled() {
            return;
        }
        let class = |qos: libc::qos_class_t| qos as u32;
        let before = class(imp::thread_qos());
        background(|| ());
        assert_eq!(class(imp::thread_qos()), before, "the class after a background pass");
        let raised = on_screen(|| class(imp::thread_qos()));
        assert_eq!(raised, class(libc::qos_class_t::QOS_CLASS_USER_INITIATED), "raised after it");
    }
}
