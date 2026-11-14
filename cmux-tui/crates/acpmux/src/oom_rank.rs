//! Which acpmux process the kernel's OOM killer, or a userspace one such as
//! earlyoom, ends first on Linux: agents before the daemon.
//!
//! Both pick the process with the highest `/proc/<pid>/oom_score`, which is
//! its share of memory (0-1000) plus its `oom_score_adj`. A Linux host
//! (2026-11-06) shows why the order matters: earlyoom ended the daemon of a
//! host with 496 sessions, every chat on it went unreachable, and its agents,
//! which were the memory, kept running with nobody to talk to.
//!
//! - The daemon lowers its own `oom_score_adj` as far as the kernel lets it
//!   ([`protect_daemon`]). An unprivileged process may go down only to the
//!   floor a privileged one set for it: 100 under a stock systemd user manager
//!   (`user@.service` has `OOMScoreAdjust=100`; its units start at 200), -900
//!   on a cmux VM image (`machine-health`'s user-manager guard), 0 elsewhere.
//!   The floor is not readable, so it tries [`DAEMON_STEPS`] lowest first.
//! - Every agent host, background-task runner and directly started harness
//!   raises its own to at least [`AGENT`] ([`raise_agent`],
//!   [`agent_at_exec`]): raising never needs a privilege, so the agents are
//!   killable as before, now ahead of the daemon and of the person's own
//!   programs (200), and never inherit the daemon's protection.
//!
//! Where the kernel refuses every lower step (no `CAP_SYS_RESOURCE`, a floor
//! at or above the daemon's value), the daemon stays as it was and logs it
//! ([`describe`]): agents at [`AGENT`] still rank above it, since raising
//! never needs a privilege.
//!
//! Not done: an earlyoom `--avoid` rule needs root (`/etc/default/earlyoom`),
//! and earlyoom ranks by the same `oom_score`, so the adjustment covers it.
//! Best effort: a write the kernel refuses leaves the process as it was.
//! Elsewhere than Linux every call does nothing.

/// The `oom_score_adj` agents run at, at least: above systemd's default for a
/// user's programs (200), so a runaway agent is ended before them too.
pub const AGENT: i32 = 500;

/// What the daemon asks for, lowest first; the first the kernel takes stays.
pub const DAEMON_STEPS: [&[u8]; 4] = [b"-900", b"-500", b"0", b"100"];

/// What [`protect_daemon`] found and left.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Protection {
    /// `oom_score_adj` before.
    pub was: i32,
    /// `oom_score_adj` after: `was` when the kernel refused every lower step.
    pub now: i32,
}

/// The daemon: its `oom_score_adj` as low as the kernel lets it, and never
/// higher than it was; None where there is none to read (not Linux). A
/// kernel that refuses every step (no `CAP_SYS_RESOURCE` and a floor at or
/// above where it runs) leaves it as it was: agents still rank above it at
/// [`AGENT`], unless it runs at [`AGENT`] or more.
pub fn protect_daemon() -> Option<Protection> {
    imp::protect_daemon()
}

/// The daemon's log line for `p`: lowered, or why it was not.
pub fn describe(p: Protection) -> String {
    if p.now < p.was {
        format!(
            "oom_score_adj {} -> {}: agents ({AGENT}) are ended before the daemon",
            p.was, p.now
        )
    } else if p.now < AGENT {
        format!(
            "oom_score_adj kept at {}: the kernel refused a lower value (its floor without CAP_SYS_RESOURCE); agents ({AGENT}) are still ended first",
            p.now
        )
    } else {
        format!(
            "oom_score_adj kept at {}: the kernel refused a lower value, so agents ({AGENT}) do not rank above the daemon",
            p.now
        )
    }
}

/// The first of [`DAEMON_STEPS`] below `was` that `write` takes, or `was`
/// when it takes none. Only Linux has `oom_score_adj`; the unit tests run everywhere.
#[cfg(any(target_os = "linux", test))]
fn lower(was: i32, mut write: impl FnMut(&[u8]) -> bool) -> i32 {
    for step in DAEMON_STEPS {
        let Some(value) = parse(step) else { continue };
        if value >= was {
            break;
        }
        if write(step) {
            return value;
        }
    }
    was
}

/// This process (an agent host, a task runner): its `oom_score_adj` raised to
/// [`AGENT`] when lower. The value it now runs at.
pub fn raise_agent() -> Option<i32> {
    imp::raise_agent()
}

/// A harness the daemon starts itself: raised to [`AGENT`] at its exec, so it
/// never keeps the daemon's protection.
pub fn agent_at_exec(cmd: &mut tokio::process::Command) {
    #[cfg(target_os = "linux")]
    // SAFETY: the hook runs in the child between fork and exec and makes only
    // open(2), read(2), write(2) and close(2) calls on a static path with stack
    // buffers: no allocation, no lock, async-signal-safe. It never fails the
    // spawn: a harness whose value could not be raised starts as before.
    unsafe {
        cmd.pre_exec(|| {
            imp::raise_agent();
            Ok(())
        });
    }
    #[cfg(not(target_os = "linux"))]
    let _ = cmd;
}

/// The decimal `oom_score_adj` in `bytes` (`-1000`..`1000`, a newline after it).
#[cfg(any(target_os = "linux", test))]
fn parse(bytes: &[u8]) -> Option<i32> {
    let (negative, digits) = match bytes.split_first()? {
        (b'-', rest) => (true, rest),
        _ => (false, bytes),
    };
    let mut value: i32 = 0;
    let mut any = false;
    for &b in digits.iter().take_while(|b| b.is_ascii_digit()) {
        value = value.checked_mul(10)?.checked_add(i32::from(b.checked_sub(b'0')?))?;
        any = true;
    }
    if !any {
        return None;
    }
    if negative { value.checked_neg() } else { Some(value) }
}

#[cfg(target_os = "linux")]
mod imp {
    const PATH: &std::ffi::CStr = c"/proc/self/oom_score_adj";

    /// Nothing here allocates or locks: [`super::agent_at_exec`] runs it after fork.
    fn read() -> Option<i32> {
        let mut buf = [0u8; 16];
        // SAFETY: a static NUL-terminated path; the buffer outlives the read.
        let n = unsafe {
            let fd = libc::open(PATH.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC);
            if fd < 0 {
                return None;
            }
            let n = libc::read(fd, buf.as_mut_ptr().cast(), buf.len());
            libc::close(fd);
            n
        };
        usize::try_from(n).ok().and_then(|n| super::parse(buf.get(..n)?))
    }

    fn write(value: &[u8]) -> bool {
        // SAFETY: a static NUL-terminated path; `value` outlives the write.
        unsafe {
            let fd = libc::open(PATH.as_ptr(), libc::O_WRONLY | libc::O_CLOEXEC);
            if fd < 0 {
                return false;
            }
            let n = libc::write(fd, value.as_ptr().cast(), value.len());
            libc::close(fd);
            usize::try_from(n).is_ok_and(|n| n == value.len())
        }
    }

    pub(super) fn protect_daemon() -> Option<super::Protection> {
        let was = read()?;
        super::lower(was, write);
        Some(super::Protection { was, now: read().unwrap_or(was) })
    }

    pub(super) fn raise_agent() -> Option<i32> {
        if read().is_some_and(|now| now < super::AGENT) {
            write(b"500");
        }
        read()
    }
}

#[cfg(not(target_os = "linux"))]
mod imp {
    pub(super) fn protect_daemon() -> Option<super::Protection> {
        None
    }
    pub(super) fn raise_agent() -> Option<i32> {
        None
    }
}

#[cfg(test)]
mod tests;
