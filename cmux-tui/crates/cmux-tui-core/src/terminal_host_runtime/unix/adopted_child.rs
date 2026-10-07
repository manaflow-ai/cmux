//! A running session a replacement host adopted (cx-6so.49 L1).
//!
//! The adopted shell was spawned by an earlier host of the same terminal,
//! which died; the kernel reparented it, so this host can neither `waitid`
//! nor reap it and never learns its status. It watches for the end with a
//! pidfd (Linux) or a kqueue `EVFILT_PROC`/`NOTE_EXIT` filter (macOS), and
//! falls back to probing the PID. Every signal first proves the PID still
//! names the adopted session (`getsid(pid) == session`, or a pidfd on
//! Linux), so a reused PID is never signaled. Dropping an adopted child
//! never signals it: only an explicit Terminate ends a session the host
//! does not own.

use std::os::fd::{FromRawFd, OwnedFd};

use super::*;

/// The adopted session leader. Its PID equals its session id (hosts spawn
/// every PTY child as a session leader, and a leader cannot leave its
/// process group), so signaling its group signals exactly the session.
#[derive(Debug)]
pub(super) struct AdoptedChild {
    pid: libc::pid_t,
    pidfd: Option<Arc<OwnedFd>>,
}

/// Whether `pid` is alive (not a zombie) and still leads `session`.
pub(super) fn leads_session(pid: libc::pid_t, session: libc::pid_t) -> bool {
    // SAFETY: getsid has no memory preconditions.
    pid > 0 && unsafe { libc::getsid(pid) } == session && !is_zombie(pid)
}

#[cfg(target_os = "linux")]
fn is_zombie(pid: libc::pid_t) -> bool {
    // `/proc/<pid>/stat` is "pid (comm) S ..."; comm may contain spaces or
    // parentheses, so the state follows the last ')'.
    fs::read_to_string(format!("/proc/{pid}/stat")).ok().is_some_and(|stat| {
        stat.rsplit_once(')').is_some_and(|(_, rest)| rest.trim_start().starts_with('Z'))
    })
}

#[cfg(target_os = "macos")]
fn is_zombie(pid: libc::pid_t) -> bool {
    // proc_pidinfo answers nothing for a zombie (it has no task), so read
    // the process table: sysctl {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid}
    // fills one `struct kinfo_proc` (648 bytes on 64-bit Darwin) whose
    // `kp_proc` is `struct extern_proc`: `p_stat` (char) at offset 36 and
    // `p_pid` (int) at offset 40.
    const KINFO_PROC_SIZE: usize = 648;
    const P_STAT_OFFSET: usize = 36;
    const P_PID_OFFSET: usize = 40;
    let mut mib = [libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PID, pid];
    let mut info = [0u8; KINFO_PROC_SIZE];
    let mut size = info.len();
    // SAFETY: the kernel writes at most `size` bytes into `info`.
    let result = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            4,
            info.as_mut_ptr().cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if result != 0 || size != KINFO_PROC_SIZE {
        return false;
    }
    let recorded_pid = libc::pid_t::from_ne_bytes([
        info[P_PID_OFFSET],
        info[P_PID_OFFSET + 1],
        info[P_PID_OFFSET + 2],
        info[P_PID_OFFSET + 3],
    ]);
    recorded_pid == pid && u32::from(info[P_STAT_OFFSET]) == libc::SZOMB
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn is_zombie(_pid: libc::pid_t) -> bool {
    false
}

#[cfg(target_os = "linux")]
fn open_pidfd(pid: libc::pid_t) -> Option<Arc<OwnedFd>> {
    // SAFETY: pidfd_open takes a PID and flags and returns a new descriptor
    // or -1; the descriptor is owned below.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    let fd = libc::c_int::try_from(fd).ok().filter(|fd| *fd >= 0)?;
    // SAFETY: the syscall returned a fresh descriptor this process owns.
    Some(Arc::new(unsafe { OwnedFd::from_raw_fd(fd) }))
}

#[cfg(not(target_os = "linux"))]
fn open_pidfd(_pid: libc::pid_t) -> Option<Arc<OwnedFd>> {
    None
}

/// Send `signal` to the adopted PID only while it still leads `session`.
fn signal_adopted(
    pid: libc::pid_t,
    session: libc::pid_t,
    pidfd: Option<&OwnedFd>,
    signal: libc::c_int,
) -> std_io::Result<()> {
    #[cfg(target_os = "linux")]
    if let Some(pidfd) = pidfd {
        // A pidfd names exactly the adopted process even after PID reuse.
        // SAFETY: valid pidfd, no siginfo, zero flags.
        let result = unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                pidfd.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        };
        return if result == 0 { Ok(()) } else { Err(std_io::Error::last_os_error()) };
    }
    let _ = pidfd;
    if !leads_session(pid, session) {
        return Err(std_io::Error::from_raw_os_error(libc::ESRCH));
    }
    // SAFETY: the PID was just proven to lead the adopted session.
    if unsafe { libc::kill(pid, signal) } == 0 {
        Ok(())
    } else {
        Err(std_io::Error::last_os_error())
    }
}

impl AdoptedChild {
    /// Adopt the running session leader `pid` of `session`.
    pub(super) fn adopt(pid: u32, session: u32) -> anyhow::Result<Self> {
        let pid = libc::pid_t::try_from(pid).context("adopted PID is out of range")?;
        let session = libc::pid_t::try_from(session).context("adopted session is out of range")?;
        anyhow::ensure!(pid > 0 && pid == session, "adopted process must lead its session");
        let pidfd = open_pidfd(pid);
        // Prove identity after the pidfd exists, so the pidfd cannot name a
        // process that replaced the session between the two calls.
        anyhow::ensure!(
            leads_session(pid, session),
            "adopted process {pid} no longer leads session {session}"
        );
        Ok(Self { pid, pidfd })
    }

    pub(super) fn pid(&self) -> u32 {
        self.pid.unsigned_abs()
    }

    pub(super) fn session_id(&self) -> libc::pid_t {
        self.pid
    }

    pub(super) fn killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(AdoptedKiller { pid: self.pid, pidfd: self.pidfd.clone() })
    }

    /// Block until the adopted process ended (it may linger as a zombie of
    /// its new parent; that counts as ended).
    pub(super) fn wait_for_exit(&self) {
        if let Some(pidfd) = &self.pidfd
            && wait_readable(pidfd.as_raw_fd())
        {
            return;
        }
        #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
        if wait_note_exit(self.pid, self.pid) {
            return;
        }
        while leads_session(self.pid, self.pid) {
            thread::sleep(Duration::from_millis(50));
        }
    }
}

/// Wait for a pidfd to report the exit. False when polling it failed.
fn wait_readable(fd: RawFd) -> bool {
    loop {
        let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd for the duration of the call.
        let result = unsafe { libc::poll(&mut poll, 1, -1) };
        if result > 0 {
            return true;
        }
        if result < 0 && std_io::Error::last_os_error().kind() != std_io::ErrorKind::Interrupted {
            return false;
        }
    }
}

/// Wait for `NOTE_EXIT` of `pid`. False when the filter could not be armed
/// for a live session leader.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
fn wait_note_exit(pid: libc::pid_t, session: libc::pid_t) -> bool {
    // SAFETY: kqueue has no preconditions; the descriptor is owned below.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return false;
    }
    // SAFETY: kqueue returned a fresh descriptor this process owns.
    let queue = unsafe { OwnedFd::from_raw_fd(queue) };
    // SAFETY: zeroed kevent is a valid all-default value.
    let mut change: libc::kevent = unsafe { std::mem::zeroed() };
    change.ident = pid as libc::uintptr_t;
    change.filter = libc::EVFILT_PROC;
    change.flags = libc::EV_ADD | libc::EV_ONESHOT;
    change.fflags = libc::NOTE_EXIT;
    // SAFETY: one change, no events, valid queue.
    let armed = unsafe {
        libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
    };
    if armed < 0 {
        // ESRCH: already gone.
        return std_io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
    }
    if !leads_session(pid, session) {
        return true;
    }
    loop {
        // SAFETY: zeroed kevent is a valid output buffer.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: no changes, one output slot, no timeout.
        let result = unsafe {
            libc::kevent(queue.as_raw_fd(), std::ptr::null(), 0, &mut event, 1, std::ptr::null())
        };
        if result > 0 {
            return true;
        }
        if result < 0 && std_io::Error::last_os_error().kind() != std_io::ErrorKind::Interrupted {
            return false;
        }
    }
}

/// Signals the adopted session leader with `SIGHUP`, like the spawned
/// child's portable killer, after proving its identity.
#[derive(Debug, Clone)]
struct AdoptedKiller {
    pid: libc::pid_t,
    pidfd: Option<Arc<OwnedFd>>,
}

impl ChildKiller for AdoptedKiller {
    fn kill(&mut self) -> std_io::Result<()> {
        signal_adopted(self.pid, self.pid, self.pidfd.as_deref(), libc::SIGHUP)
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(self.clone())
    }
}

impl HostShared {
    /// Whether the child's PID and group may still be signaled. A spawned
    /// child's PID stays reserved until this host reaps it. An adopted one
    /// is not reserved: it may be signaled only before its end was observed
    /// and while it still leads its session.
    pub(super) fn child_signalable(&self) -> bool {
        let Some(session) = self.adopted_session else { return true };
        !self.child_waitable.load(Ordering::Acquire)
            && self
                .pid
                .and_then(|pid| libc::pid_t::try_from(pid).ok())
                .is_some_and(|pid| leads_session(pid, session))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A shell that died a moment before its host must not get a
    /// replacement: an exited, unreaped process is a zombie on every
    /// platform, never a live session leader (L1.3).
    #[test]
    fn an_exited_unreaped_process_is_a_zombie_and_no_longer_leads_its_session() {
        let mut leader = Command::new("/bin/sh");
        leader.args(["-c", "exit 0"]);
        // SAFETY: setsid is async-signal-safe in the forked child.
        unsafe {
            leader.pre_exec(|| {
                if libc::setsid() < 0 { Err(std_io::Error::last_os_error()) } else { Ok(()) }
            });
        }
        let mut child = leader.spawn().unwrap();
        let pid = libc::pid_t::try_from(child.id()).unwrap();
        // Wait for the exit without reaping, so the PID stays a zombie.
        let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: waitid writes one siginfo_t for this exact child.
        let waited = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                info.as_mut_ptr(),
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        assert_eq!(waited, 0, "{}", std_io::Error::last_os_error());
        assert!(is_zombie(pid), "an exited, unreaped child is not reported as a zombie");
        assert!(!leads_session(pid, pid), "a zombie still counts as a live session leader");
        child.wait().unwrap();
    }

    /// Wait (up to 5 s) until `pid` runs `name`, so a signal reaches the
    /// final program and not a process still between fork and exec. Linux
    /// reads `/proc/<pid>/comm`; elsewhere it waits a fixed short time.
    fn wait_until_exec(pid: u32, name: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match fs::read_to_string(format!("/proc/{pid}/comm")) {
                Ok(comm) if comm.trim() == name => return,
                Ok(_) => {}
                Err(_) if !cfg!(target_os = "linux") => {
                    thread::sleep(Duration::from_millis(200));
                    return;
                }
                Err(_) => {}
            }
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn adopted_child_sees_a_non_child_session_end_and_never_signals_on_drop() {
        // A session leader this test spawned stands in for an adopted one:
        // it is waited on only through the adoption path.
        let mut leader = Command::new("/bin/sh");
        leader.args(["-c", "exec sleep 30"]);
        // The leader must not depend on this test process's signal state:
        // other tests in the process may change dispositions or a thread's
        // mask, and ignored signals and the mask survive exec.
        // SAFETY: signal, sigprocmask and setsid are async-signal-safe in
        // the forked child.
        unsafe {
            leader.pre_exec(|| {
                libc::signal(libc::SIGHUP, libc::SIG_DFL);
                let mut empty = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
                libc::sigemptyset(empty.as_mut_ptr());
                libc::sigprocmask(libc::SIG_SETMASK, empty.as_ptr(), std::ptr::null_mut());
                if libc::setsid() < 0 { Err(std_io::Error::last_os_error()) } else { Ok(()) }
            });
        }
        let mut leader = leader.spawn().unwrap();
        let pid = leader.id();
        wait_until_exec(pid, "sleep");
        assert!(AdoptedChild::adopt(pid, pid + 1).is_err(), "a non-leader was adopted");
        let adopted = AdoptedChild::adopt(pid, pid).unwrap();
        drop(AdoptedChild::adopt(pid, pid).unwrap());
        let raw = libc::pid_t::try_from(pid).unwrap();
        assert!(leads_session(raw, raw), "dropping an adopted child signaled it");
        let before = fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
        let kill_result = adopted.killer().kill();
        let watcher = thread::spawn(move || adopted.wait_for_exit());
        let status = leader.wait().unwrap();
        let state = before
            .lines()
            .filter(|line| line.starts_with("Sig") || line.starts_with("Name"))
            .collect::<Vec<_>>();
        assert!(
            status.code().is_none(),
            "SIGHUP did not end the leader: {status:?}, kill {kill_result:?}, {state:?}"
        );
        watcher.join().unwrap();
        assert!(AdoptedChild::adopt(pid, pid).is_err(), "an ended session was adopted");
    }
}
