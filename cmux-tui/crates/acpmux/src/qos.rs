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
//! | [`Tier::Serving`] | the daemon | disk I/O at `IOPOL_UTILITY`; CPU unchanged | unchanged |
//! | [`Tier::Agent`] | agent hosts, background-task runners, and everything they start | CPU clamped to utility (priority 20) and disk I/O at `IOPOL_UTILITY` | nice +5 |
//! | [`Tier::Background`] | housekeeping inside the daemon that holds no lock other work waits on (probe cleanup at start) | the thread at `QOS_CLASS_BACKGROUND` for the pass (CPU throttled; its disk I/O stays at the daemon's utility tier), then back | unchanged |
//! | [`Tier::OnScreen`] | the daemon's reads for a chat being opened on screen (a visible `_acpmux/attach`: its log load and its first page) | the thread at `QOS_CLASS_USER_INITIATED` for the read (CPU only: its disk I/O stays at the daemon's utility tier), then back | unchanged |
//!
//! The daemon keeps its CPU priority: the app waits on it for every streamed
//! frame, so demoting it would put a person's own stream behind agent
//! compiles. Its disk work (journals, the store) yields to the app's, the
//! reads a person is waiting on to open a chat ([`on_screen`]) too: a thread's
//! disk I/O tier is the most throttled of the process's, its own and its QoS
//! class's (xnu `thread_policy.c`), and the process is at utility, so only the
//! CPU of those reads is raised. A per-thread I/O policy cannot lift it either,
//! and it drops the thread out of QoS (`imp::ThreadOnScreen`).
//!
//! macOS gives no call that clamps a running process, and a thread's QoS does
//! not survive exec into another program (a probe on a fleet mini: a child's
//! new threads come back at the default whatever its parent ran at). The QoS
//! clamp does: `posix_spawnattr_set_qos_clamp_np`, the call behind
//! `taskpolicy -c utility`, holds every thread of the process and of every
//! process it starts. So an agent host re-executes itself in place
//! (`POSIX_SPAWN_SETEXEC`: same pid, same descriptors) under the clamp before
//! it starts any thread, and its harness, shells and tools inherit it. The I/O
//! policy is process wide and inherited across exec, so it needs no re-exec.
//!
//! A pass that holds a lock chat traffic takes (log retention's compaction
//! holds the store's writers lock; the upload sweep holds the in-use set) stays
//! at the daemon's own priority: throttling it would stall every stream.
//!
//! Why utility and not background for agents: background class gives the app
//! more (manaflow-ai/cmuxterm-hq#4947: a Chromium pane's drag lag under 14 busy
//! processes was 55 ms p95 at default, 40 ms at utility, 6 ms at background),
//! but it keeps agent work off the performance cores even on an idle Mac: a
//! fixed CPU job took 0.9 s at default, 0.8 s at utility and 16.6 s at
//! background on one thread, and 4.0 / 3.6 / 28.5 s on ten (cmux-mac-mini, 4P +
//! 6E). `ACPMUX_QOS=background` picks background for agent hosts anyway.
//!
//! `ACPMUX_QOS=off` turns all of it off (a process started with it set starts
//! as before); agent hosts get it through their environment allowlist
//! (`agent::host_environment`). Best effort: a call that fails leaves the process as it was.

use std::ffi::OsString;

/// How much a process yields to the person at the screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tier {
    /// The daemon: the app waits on it, so only its disk I/O yields.
    Serving,
    /// Agent work: hosts, harnesses and every tool they run.
    Agent,
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
        Role::AgentHost | Role::BackgroundTaskRunner => Tier::Agent,
        Role::Housekeeping => Tier::Background,
        Role::VisibleOpen => Tier::OnScreen,
    }
}

/// Turns the whole policy off when set to `off`.
pub const ENV: &str = "ACPMUX_QOS";
/// Set in a process that already re-executed itself under the clamp.
pub const CLAMPED_ENV: &str = "ACPMUX_QOS_CLAMPED";

fn enabled() -> bool {
    std::env::var_os(ENV).is_none_or(|v| v != "off")
}

/// `ACPMUX_QOS=background`: agent hosts run in background instead of utility.
fn agent_background() -> bool {
    std::env::var_os(ENV).is_some_and(|v| v == "background")
}

/// Put this process in `role`'s tier. Call it first thing in `main`, before
/// any thread starts: for [`Tier::Agent`] on macOS it re-executes the process
/// in place and returns only when that is not done (already clamped, turned
/// off, or the call failed).
pub fn enter(role: Role) {
    if !enabled() {
        return;
    }
    match tier(role) {
        Tier::Serving => imp::disk_utility(),
        // Opt-in: the whole agent tree in background (hq#4947's 55 -> 6 ms
        // drag lag), at the cost of agent speed (module docs).
        Tier::Agent if agent_background() => imp::process_background(),
        Tier::Agent => {
            imp::disk_utility();
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

/// Run `work` (blocking) with this thread in [`Tier::OnScreen`], then put the
/// thread back as it was: the reads for a chat being opened on screen, which
/// the person is waiting on, ahead of agent work's CPU and disk. Tokio worker
/// and blocking-pool threads are reused, so the guard restores what it found.
pub fn on_screen<T>(work: impl FnOnce() -> T) -> T {
    let _guard = enabled().then(imp::ThreadOnScreen::enter);
    work()
}

/// The argv and environment an in-place re-exec runs with: this process's
/// own, plus [`CLAMPED_ENV`], so the new image does not do it again.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn reexec_env(mut vars: Vec<(OsString, OsString)>) -> Vec<(OsString, OsString)> {
    vars.retain(|(k, _)| k != CLAMPED_ENV);
    vars.push((CLAMPED_ENV.into(), "utility".into()));
    vars
}

#[cfg(target_os = "macos")]
mod imp {
    use super::*;
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    const IOPOL_TYPE_DISK: libc::c_int = 0;
    const IOPOL_SCOPE_PROCESS: libc::c_int = 0;
    #[cfg(test)]
    const IOPOL_SCOPE_THREAD: libc::c_int = 1;
    const IOPOL_UTILITY: libc::c_int = 4;
    const PRIO_DARWIN_BG: libc::c_int = 0x1000;
    const POSIX_SPAWN_SETEXEC: libc::c_short = 0x0040;
    /// `POSIX_SPAWN_PROC_CLAMP_UTILITY` (spawn_private.h): the clamp takes its own small
    /// numbers, not a `qos_class_t` (0x11 is accepted and does nothing; a fleet-mini probe).
    const POSIX_SPAWN_PROC_CLAMP_UTILITY: u64 = 1;

    unsafe extern "C" {
        fn setiopolicy_np(
            iotype: libc::c_int,
            scope: libc::c_int,
            policy: libc::c_int,
        ) -> libc::c_int;
        #[cfg(test)]
        fn getiopolicy_np(iotype: libc::c_int, scope: libc::c_int) -> libc::c_int;
    }

    /// `int posix_spawnattr_set_qos_clamp_np(posix_spawnattr_t *, uint64_t)`.
    type ClampFn = unsafe extern "C" fn(*mut libc::posix_spawnattr_t, u64) -> libc::c_int;

    pub(super) fn disk_utility() {
        // SAFETY: plain syscall wrapper with constant arguments.
        if unsafe { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_UTILITY) } != 0 {
            tracing::debug!("setiopolicy_np: {}", std::io::Error::last_os_error());
        }
    }

    /// The clamp setter, looked up at run time: it is not in the public SDK
    /// headers, so a macOS without it starts unclamped instead of failing to load.
    fn clamp_fn() -> Option<ClampFn> {
        // SAFETY: dlsym with a NUL-terminated name; the symbol, when present,
        // has this signature (spawn_private.h).
        let sym = unsafe {
            libc::dlsym(libc::RTLD_DEFAULT, c"posix_spawnattr_set_qos_clamp_np".as_ptr())
        };
        // SAFETY: a non-null result is that function.
        (!sym.is_null()).then(|| unsafe { std::mem::transmute::<*mut libc::c_void, ClampFn>(sym) })
    }

    pub(super) fn clamp_cpu_utility() {
        if std::env::var_os(CLAMPED_ENV).is_some() {
            return;
        }
        let Ok(exe) = std::env::current_exe() else { return };
        let argv: Vec<OsString> = std::env::args_os().collect();
        let envp = reexec_env(std::env::vars_os().collect());
        // Returns only when the re-exec did not happen.
        if let Err(rc) = spawn_clamped(&exe, &argv, &envp, true) {
            tracing::debug!("in-place re-exec under the utility clamp failed: {rc}");
        }
    }

    /// `posix_spawn` of `path` under the utility clamp: in place of this
    /// process (`in_place`, which returns only on failure) or as a child, whose
    /// pid it returns. Errors are the call's code (-1: no clamp setter here, or
    /// a NUL in an argument).
    pub(super) fn spawn_clamped(
        path: &std::path::Path,
        argv: &[OsString],
        envp: &[(OsString, OsString)],
        in_place: bool,
    ) -> Result<libc::pid_t, libc::c_int> {
        let set_clamp = clamp_fn().ok_or(-1)?;
        let cstr = |b: &[u8]| CString::new(b).map_err(|_| -1);
        let path = cstr(path.as_os_str().as_bytes())?;
        let argv = argv.iter().map(|a| cstr(a.as_bytes())).collect::<Result<Vec<_>, _>>()?;
        let envp = envp
            .iter()
            .map(|(k, v)| {
                let mut kv = k.as_bytes().to_vec();
                kv.push(b'=');
                kv.extend_from_slice(v.as_bytes());
                cstr(&kv)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut argv_ptrs: Vec<*mut libc::c_char> =
            argv.iter().map(|a| a.as_ptr().cast_mut()).chain([std::ptr::null_mut()]).collect();
        let mut envp_ptrs: Vec<*mut libc::c_char> =
            envp.iter().map(|a| a.as_ptr().cast_mut()).chain([std::ptr::null_mut()]).collect();
        // SAFETY: attr is initialized before use and destroyed on every path;
        // the argument vectors are NUL-terminated and outlive the call. With
        // SETEXEC a successful posix_spawn does not return (the image is
        // replaced in place, like execve).
        unsafe {
            let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
            let rc = libc::posix_spawnattr_init(&mut attr);
            if rc != 0 {
                return Err(rc);
            }
            let flags = if in_place { POSIX_SPAWN_SETEXEC } else { 0 };
            let mut rc = set_clamp(&mut attr, POSIX_SPAWN_PROC_CLAMP_UTILITY);
            if rc == 0 {
                rc = libc::posix_spawnattr_setflags(&mut attr, flags);
            }
            let mut pid: libc::pid_t = 0;
            if rc == 0 {
                rc = libc::posix_spawn(
                    &mut pid,
                    path.as_ptr(),
                    std::ptr::null(),
                    &attr,
                    argv_ptrs.as_mut_ptr(),
                    envp_ptrs.as_mut_ptr(),
                );
            }
            libc::posix_spawnattr_destroy(&mut attr);
            if rc == 0 { Ok(pid) } else { Err(rc) }
        }
    }

    /// This process, and every process it starts, in `PRIO_DARWIN_BG`
    /// (inherited across fork and exec; a fleet-mini probe).
    pub(super) fn process_background() {
        const PRIO_DARWIN_PROCESS: libc::c_int = 4;
        // SAFETY: plain syscall on this process.
        unsafe { libc::setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG) };
    }

    /// This thread at background QoS until dropped (CPU throttled; its disk I/O stays at the
    /// process's utility tier), then back to the class it had. Not the per-thread
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

    /// This thread at user-initiated QoS until dropped, then back to the class it had. CPU only:
    /// its disk I/O tier stays at the process's utility tier, the most throttled of the
    /// process's, its QoS's and its own (xnu `thread_policy.c`). No thread-scope `setiopolicy_np`: on macOS 26 and 27 that call
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_daemon_keeps_its_cpu_and_agents_yield() {
        assert_eq!(tier(Role::Daemon), Tier::Serving);
        assert_eq!(tier(Role::AgentHost), Tier::Agent);
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

    /// The clamp takes effect: a child spawned under it, and the shell it
    /// starts, run at priority 20 (utility), not 31 (cmux#27587's first cut
    /// passed `QOS_CLASS_UTILITY`, which the setter takes and ignores).
    #[cfg(target_os = "macos")]
    #[test]
    fn a_clamped_child_and_what_it_starts_run_at_utility() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("pri");
        let script = format!(
            "/bin/sh -c 'ps -o pri= -p $$' > '{}'; ps -o pri= -p $$ >> '{}'",
            out.display(),
            out.display()
        );
        let argv: Vec<OsString> = vec!["sh".into(), "-c".into(), script.into()];
        let pid = imp::spawn_clamped(std::path::Path::new("/bin/sh"), &argv, &[], false)
            .expect("spawn under the clamp");
        let mut status = 0;
        // SAFETY: waits for the child this test started.
        unsafe { libc::waitpid(pid, &mut status, 0) };
        let text = std::fs::read_to_string(&out).unwrap();
        let pris: Vec<&str> = text.split_whitespace().collect();
        assert_eq!(pris.len(), 2, "{text:?}");
        for pri in pris {
            assert!(pri.starts_with("20"), "expected priority 20, got {text:?}");
        }
    }

    #[test]
    fn the_reexec_marks_itself_once() {
        let vars = vec![("PATH".into(), "/bin".into()), (CLAMPED_ENV.into(), "stale".into())];
        let out = reexec_env(vars);
        assert_eq!(out.iter().filter(|(k, _)| k == CLAMPED_ENV).count(), 1);
        assert!(out.contains(&(CLAMPED_ENV.into(), "utility".into())));
        assert!(out.contains(&("PATH".into(), "/bin".into())));
    }
}
