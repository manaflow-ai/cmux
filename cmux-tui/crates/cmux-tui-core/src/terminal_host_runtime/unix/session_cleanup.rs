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

#[derive(Debug, Clone)]
pub(super) struct SessionCleanup {
    session: libc::pid_t,
    groups: Vec<libc::pid_t>,
}

impl SessionCleanup {
    pub(super) fn capture(session: libc::pid_t, host_group: libc::pid_t) -> Option<Self> {
        if session <= 0 || session == current_session() {
            return None;
        }
        let groups = session_groups(session)
            .into_iter()
            .filter(|group| *group > 0 && *group != host_group)
            .collect::<Vec<_>>();
        (!groups.is_empty()).then_some(Self { session, groups })
    }

    pub(super) fn signal(&self, signal: libc::c_int, host_group: libc::pid_t) {
        let live_groups = session_groups(self.session)
            .into_iter()
            .filter(|group| *group > 0 && *group != host_group)
            .collect::<HashSet<_>>();
        for group in self.groups.iter().copied().filter(|group| live_groups.contains(group)) {
            // SAFETY: the group was observed in the captured PTY session and
            // revalidated in that same session immediately before signaling.
            let _ = unsafe { libc::killpg(group, signal) };
        }
    }
}

fn current_session() -> libc::pid_t {
    // SAFETY: getsid(0) queries this process and has no Rust-side preconditions.
    unsafe { libc::getsid(0) }
}

#[cfg(target_os = "linux")]
fn session_groups(session: libc::pid_t) -> Vec<libc::pid_t> {
    let Ok(entries) = fs::read_dir("/proc") else { return Vec::new() };
    let mut groups = HashSet::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Ok(_pid) = name.parse::<libc::pid_t>() else { continue };
        let Ok(stat) = fs::read_to_string(entry.path().join("stat")) else { continue };
        let Some((_, fields)) = stat.rsplit_once(") ") else { continue };
        let mut fields = fields.split_whitespace();
        let Some(state) = fields.next() else { continue };
        let Some(_ppid) = fields.next() else { continue };
        let Some(pgid) = fields.next().and_then(|value| value.parse().ok()) else { continue };
        let Some(sid) = fields.next().and_then(|value| value.parse().ok()) else { continue };
        if sid == session && state != "Z" && pgid > 0 {
            groups.insert(pgid);
        }
    }
    groups.into_iter().collect()
}

#[cfg(not(target_os = "linux"))]
fn session_groups(session: libc::pid_t) -> Vec<libc::pid_t> {
    let Ok(output) = Command::new("ps").args(["-axo", "pid=,sid=,pgid="]).output() else {
        return Vec::new();
    };
    let mut groups = HashSet::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let mut fields = line.split_whitespace();
        let Some(_pid) = fields.next() else { continue };
        let Some(sid) = fields.next().and_then(|value| value.parse().ok()) else { continue };
        let Some(pgid) = fields.next().and_then(|value| value.parse().ok()) else { continue };
        if sid == session && pgid > 0 {
            groups.insert(pgid);
        }
    }
    groups.into_iter().collect()
}
