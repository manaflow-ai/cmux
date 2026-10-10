//! Bounded cleanup for descendants that remain in a terminal's PTY session.
//!
//! A PTY session can contain more than the shell's process group. In
//! particular, a background job may create its own process group while still
//! sharing the session and controlling terminal. Keep the session identity
//! and the process groups observed before hangup, then revalidate those groups
//! against the same session before escalating.

use std::collections::HashSet;
#[cfg(target_os = "linux")]
use std::fs;
#[cfg(not(target_os = "linux"))]
use std::process::Command;
use std::sync::Mutex;
use std::sync::atomic::Ordering;

use super::super::shared::host_shared::HostShared;
use super::super::shared::host_state::HOST_KILL_WAIT;
use super::super::sys::GroupSignal;
use std::time::{Duration, Instant};

pub(super) const SESSION_CLEANUP_FAILED_REASON: &str = "terminal session cleanup incomplete";

#[derive(Debug)]
pub(crate) struct SessionCleanup {
    captured: Mutex<CaptureState>,
}

#[derive(Debug, Clone)]
enum CaptureState {
    /// No identity-safe session capture was attempted.
    NotCaptured,
    /// Completion retires the saved identity before the child can be reaped.
    Complete,
    /// The session was enumerated successfully. An empty group list is a
    /// successful observation that there is nothing to clean up.
    Captured(CapturedSession),
    /// The session identity was valid, but enumeration failed. Treat this as
    /// unknown rather than claiming that the session is gone.
    ScanFailed,
}

#[derive(Debug, Clone)]
struct CapturedSession {
    session: libc::pid_t,
    groups: Vec<libc::pid_t>,
}

impl SessionCleanup {
    pub(super) fn new() -> Self {
        Self { captured: Mutex::new(CaptureState::NotCaptured) }
    }

    pub(super) fn signal(
        &self,
        adopted_session: Option<libc::pid_t>,
        pid: Option<u32>,
        signal: libc::c_int,
        host_group: libc::pid_t,
        capture_allowed: bool,
    ) {
        let mut captured = self.captured.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if signal == libc::SIGHUP
            && capture_allowed
            && matches!(&*captured, CaptureState::NotCaptured | CaptureState::ScanFailed)
        {
            let session =
                adopted_session.or_else(|| pid.and_then(|pid| libc::pid_t::try_from(pid).ok()));
            *captured = CapturedSession::capture(session, host_group);
        }
        let scan_succeeded = match &*captured {
            CaptureState::Captured(cleanup) => cleanup.signal(signal, host_group),
            CaptureState::NotCaptured | CaptureState::Complete | CaptureState::ScanFailed => true,
        };
        if !scan_succeeded {
            *captured = CaptureState::ScanFailed;
        }
    }

    pub(super) fn wait_for_exit(&self, timeout: Duration) -> bool {
        let mut captured = self.captured.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let complete = match &*captured {
            CaptureState::NotCaptured | CaptureState::Complete => true,
            CaptureState::ScanFailed => false,
            CaptureState::Captured(captured) => captured.wait_for_exit(timeout),
        };
        if complete {
            *captured = CaptureState::Complete;
        }
        complete
    }
}

impl CapturedSession {
    fn capture(session: Option<libc::pid_t>, host_group: libc::pid_t) -> CaptureState {
        let Some(session) = session else { return CaptureState::NotCaptured };
        if session <= 0 || session == current_session() {
            return CaptureState::NotCaptured;
        }
        let groups = match session_groups(session) {
            Ok(groups) => groups,
            Err(()) => return CaptureState::ScanFailed,
        };
        CaptureState::Captured(Self {
            session,
            groups: groups.into_iter().filter(|group| *group > 0 && *group != host_group).collect(),
        })
    }

    fn signal(&self, signal: libc::c_int, host_group: libc::pid_t) -> bool {
        let Ok(live_groups) = session_groups(self.session) else {
            return false;
        };
        let live_groups = live_groups
            .into_iter()
            .filter(|group| *group > 0 && *group != host_group)
            .collect::<HashSet<_>>();
        for group in self.groups.iter().copied().filter(|group| live_groups.contains(group)) {
            // SAFETY: the group was observed in the captured PTY session and
            // revalidated in that same session immediately before signaling.
            let _ = unsafe { libc::killpg(group, signal) };
        }
        true
    }

    fn wait_for_exit(&self, timeout: Duration) -> bool {
        if self.groups.is_empty() {
            return true;
        }
        let deadline = Instant::now() + timeout;
        loop {
            let Ok(live_groups) = session_groups(self.session) else {
                return false;
            };
            let live = live_groups.into_iter().any(|group| self.groups.contains(&group));
            if !live {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

fn current_session() -> libc::pid_t {
    // SAFETY: getsid(0) queries this process and has no Rust-side preconditions.
    unsafe { libc::getsid(0) }
}

#[cfg(target_os = "linux")]
fn session_groups(session: libc::pid_t) -> Result<Vec<libc::pid_t>, ()> {
    let entries = fs::read_dir("/proc").map_err(|_| ())?;
    let mut groups = HashSet::new();
    for entry in entries {
        let entry = entry.map_err(|_| ())?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Ok(_pid) = name.parse::<libc::pid_t>() else { continue };
        let stat = match fs::read_to_string(entry.path().join("stat")) {
            Ok(stat) => stat,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(()),
        };
        let Some((_, fields)) = stat.rsplit_once(") ") else { return Err(()) };
        let mut fields = fields.split_whitespace();
        let Some(state) = fields.next() else { return Err(()) };
        let Some(_ppid) = fields.next() else { return Err(()) };
        let Some(pgid) = fields.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            return Err(());
        };
        let Some(sid) = fields.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            return Err(());
        };
        if sid == session && state != "Z" && pgid > 0 {
            groups.insert(pgid);
        }
    }
    Ok(groups.into_iter().collect())
}

#[cfg(not(target_os = "linux"))]
fn session_groups(session: libc::pid_t) -> Result<Vec<libc::pid_t>, ()> {
    // Darwin ps does not expose a numeric session ID. Use it only to list
    // non-zombie PIDs, then query their session and group through libc.
    let output = Command::new("/bin/ps").args(["-axo", "pid=,stat="]).output().map_err(|_| ())?;
    if !output.status.success() {
        return Err(());
    }
    let mut groups = HashSet::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let mut fields = line.split_whitespace();
        let Some(pid) = fields.next().and_then(|value| value.parse::<libc::pid_t>().ok()) else {
            continue;
        };
        let Some(stat) = fields.next() else { continue };
        if pid <= 0 || stat.starts_with('Z') {
            continue;
        }
        // SAFETY: both calls query a positive PID; an exited process returns -1.
        let sid = unsafe { libc::getsid(pid) };
        let pgid = unsafe { libc::getpgid(pid) };
        // Query the session again after the group to reject a PID that left
        // the session (or was reused) between the first query and getpgid.
        if sid == session && pgid > 0 && unsafe { libc::getsid(pid) } == session {
            groups.insert(pgid);
        }
    }
    Ok(groups.into_iter().collect())
}

impl HostShared {
    pub(crate) fn signal_terminal_process_groups(&self, signal: GroupSignal) {
        let signal = match signal {
            GroupSignal::Hangup => libc::SIGHUP,
            GroupSignal::Kill => libc::SIGKILL,
        };
        let mut groups = Vec::with_capacity(2);
        // The wait thread observes exit with WNOWAIT, then takes this lock
        // before reaping. While we hold it, `!child_reaped` means the
        // original PID/PGID is still kernel-reserved and cannot have been
        // reused between validation and killpg.
        let _signal = self.child_signal_lock.lock().unwrap();
        let child_reserved = !self.child_reaped.load(Ordering::Acquire) && self.child_signalable();
        // SAFETY: getpgrp has no preconditions.
        let host_group = unsafe { libc::getpgrp() };
        self.session_cleanup.signal(
            self.adopted_session,
            self.pid,
            signal,
            host_group,
            child_reserved,
        );
        if child_reserved
            && let Some(pid) = self.pid.and_then(|pid| libc::pid_t::try_from(pid).ok())
        {
            groups.push(pid);
        }
        // Query the PTY each time rather than trusting the original group:
        // a foreground job or retained descendant may own a different
        // group by the time explicit Terminate escalates.
        if child_reserved
            && let Some(foreground) = self.master.lock().unwrap().process_group_leader()
        {
            groups.push(foreground);
        }
        groups.sort_unstable();
        groups.dedup();
        // Signal validated groups, excluding the terminal host's own group.
        for group in groups.into_iter().filter(|group| *group > 0 && *group != host_group) {
            // SAFETY: validated positive process-group ids owned by this
            // PTY session; signal is a platform constant from this module.
            let _ = unsafe { libc::killpg(group, signal) };
        }
    }

    pub(crate) fn finish_group_escalation(&self) {
        if self.session_cleanup.wait_for_exit(HOST_KILL_WAIT) {
            self.publish_child_wait_predicate(&self.group_escalation_complete);
        } else {
            eprintln!("cmux-tui: terminal session cleanup did not complete within its bound");
            self.group_escalation_failed.store(true, Ordering::Release);
            self.publish_child_wait_predicate(&self.group_escalation_failed);
        }
    }
}
