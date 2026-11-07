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
//! Not done: an earlyoom `--avoid` rule needs root (`/etc/default/earlyoom`),
//! and earlyoom ranks by the same `oom_score`, so the adjustment covers it.
//! Best effort: a write the kernel refuses leaves the process as it was.
//! Elsewhere than Linux every call does nothing.

/// The `oom_score_adj` agents run at, at least: above systemd's default for a
/// user's programs (200), so a runaway agent is ended before them too.
pub const AGENT: i32 = 500;

/// What the daemon asks for, lowest first; the first the kernel takes stays.
pub const DAEMON_STEPS: [&[u8]; 4] = [b"-900", b"-500", b"0", b"100"];

/// The daemon: its `oom_score_adj` as low as the kernel lets it, and never
/// higher than it was. The value it now runs at.
pub fn protect_daemon() -> Option<i32> {
    imp::protect_daemon()
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
fn parse(bytes: &[u8]) -> Option<i32> {
    let (negative, digits) = match bytes.split_first()? {
        (b'-', rest) => (true, rest),
        _ => (false, bytes),
    };
    let mut value: i32 = 0;
    let mut any = false;
    for &b in digits.iter().take_while(|b| b.is_ascii_digit()) {
        value = value.checked_mul(10)?.checked_add(i32::from(b - b'0'))?;
        any = true;
    }
    any.then_some(if negative { -value } else { value })
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
        usize::try_from(n).ok().and_then(|n| super::parse(&buf[..n]))
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

    pub(super) fn protect_daemon() -> Option<i32> {
        let now = read()?;
        for step in super::DAEMON_STEPS {
            if super::parse(step).is_some_and(|v| v >= now) {
                break;
            }
            if write(step) {
                break;
            }
        }
        read()
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
    pub(super) fn protect_daemon() -> Option<i32> {
        None
    }
    pub(super) fn raise_agent() -> Option<i32> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_what_the_kernel_writes() {
        assert_eq!(parse(b"200\n"), Some(200));
        assert_eq!(parse(b"-900\n"), Some(-900));
        assert_eq!(parse(b"0"), Some(0));
        assert_eq!(parse(b""), None);
        assert_eq!(parse(b"-"), None);
        assert_eq!(parse(b"x"), None);
        assert_eq!(parse(&AGENT.to_string().into_bytes()), Some(AGENT));
    }

    /// A child's own `oom_score_adj` after `hook` ran at its exec.
    #[cfg(target_os = "linux")]
    async fn child_adj(hook: impl Fn() + Send + Sync + 'static) -> i32 {
        let mut cmd = tokio::process::Command::new("cat");
        cmd.arg("/proc/self/oom_score_adj");
        // SAFETY: test hooks call only this module's allocation-free functions.
        unsafe {
            cmd.pre_exec(move || {
                hook();
                Ok(())
            });
        }
        let out = cmd.output().await.unwrap();
        parse(&out.stdout).unwrap()
    }

    /// The daemon ends at or below where it started, an agent it starts at
    /// [`AGENT`] or above, and the agent stays above the daemon whatever floor
    /// this host's manager set.
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn agents_rank_above_the_daemon_for_the_oom_killer() {
        let start = child_adj(|| {}).await;
        let daemon = child_adj(|| {
            imp::protect_daemon();
        })
        .await;
        assert!(daemon <= start, "the daemon went up: {start} -> {daemon}");
        let agent = child_adj(|| {
            imp::protect_daemon();
            imp::raise_agent();
        })
        .await;
        assert!(agent >= AGENT, "an agent of the daemon kept {agent}");
        assert!(agent > daemon);
        let mut cmd = tokio::process::Command::new("cat");
        cmd.arg("/proc/self/oom_score_adj");
        agent_at_exec(&mut cmd);
        let harness = parse(&cmd.output().await.unwrap().stdout).unwrap();
        assert!(harness >= AGENT, "a harness kept {harness}");
    }
}
