//! Which process a pid names. A pid alone does not: the kernel gives a dead process's pid to
//! the next one, and after a reboot any pid a file recorded can belong to anything. A process
//! is named by its pid, its start time and the boot it started in ([`Identity`]), and
//! [`check`] says whether that process still runs:
//!
//! - [`Liveness::Alive`]: the pid runs, in this boot, with the recorded start time;
//! - [`Liveness::Dead`]: no process has the pid (a zombie counts as exited), the pid runs with
//!   another start time (reused), or the record is from another boot;
//! - [`Liveness::Unknown`]: the start time or the boot could not be read. Nothing is proven,
//!   so a caller keeps what it has: never signals, never takes over, never restarts.
//!
//! The same rule as leo-workspace `tools/process_identity.py` (handbook
//! `kill-by-recorded-owner`), in Rust for every cmux supervisor.

use serde::{Deserialize, Serialize};

/// A process as recorded: enough to tell it from any later holder of its pid.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Identity {
    pub pid: u32,
    /// The kernel's start time of the process: clock ticks since boot on Linux
    /// (`/proc/<pid>/stat` field 22), microseconds since the epoch on macOS
    /// (`proc_bsdinfo.pbi_start_*`). Compared for equality only.
    pub start_time: u64,
    /// The process group, for a group signal to the whole tree the process leads.
    pub pgid: u32,
    /// This boot: `/proc/sys/kernel/random/boot_id` on Linux, `kern.boottime` on macOS.
    pub boot_id: String,
}

/// Whether a recorded process still runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Liveness {
    Alive,
    Dead,
    Unknown,
}

/// What reading one pid found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Read {
    /// It runs (not a zombie).
    Running { start_time: u64, pgid: u32 },
    /// No process has the pid, or it has exited and waits for its parent.
    Gone,
    /// It could not be told.
    Unknown,
}

/// The identity of the process `pid` now, when it runs and can be read.
pub fn of(pid: u32) -> Option<Identity> {
    let boot_id = boot_id()?;
    match read(pid) {
        Read::Running { start_time, pgid } => Some(Identity { pid, start_time, pgid, boot_id }),
        Read::Gone | Read::Unknown => None,
    }
}

/// This process's identity. `None` only where the platform cannot say (no `/proc`, a sandbox).
pub fn current() -> Option<Identity> {
    of(std::process::id())
}

/// Whether `recorded` still runs. A record from another boot is dead whatever its pid holds now.
pub fn check(recorded: &Identity) -> Liveness {
    let Some(boot) = boot_id() else { return Liveness::Unknown };
    if boot != recorded.boot_id {
        return Liveness::Dead;
    }
    match read(recorded.pid) {
        Read::Running { start_time, .. } if start_time == recorded.start_time => Liveness::Alive,
        Read::Running { .. } | Read::Gone => Liveness::Dead,
        Read::Unknown => Liveness::Unknown,
    }
}

/// The id of this boot; `None` when it cannot be read.
pub fn boot_id() -> Option<String> {
    platform::boot_id()
}

/// One read of `pid`.
pub fn read(pid: u32) -> Read {
    if pid == 0 || pid > i32::MAX as u32 {
        return Read::Gone;
    }
    platform::read(pid)
}

#[cfg(target_os = "linux")]
mod platform {
    use super::Read;

    pub(super) fn boot_id() -> Option<String> {
        let text = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
        let id = text.trim();
        (!id.is_empty()).then(|| id.to_owned())
    }

    /// The one pid's start (clock ticks since the boot), through the platform crate's single-process
    /// read (`cmux_tui_platform::process_resources::process_start`), never a scan. A zombie still reads running: it
    /// holds its pid until reaped, so no other process can take it meanwhile.
    pub(super) fn read(pid: u32) -> Read {
        let Some(start) = cmux_tui_platform::process_resources::process_start(pid) else {
            // No start: gone, or there and unreadable (another user's under hidepid).
            // SAFETY: signal 0 only checks that the pid exists.
            let exists = unsafe { libc::kill(pid as libc::pid_t, 0) } == 0
                || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH);
            return if exists { Read::Unknown } else { Read::Gone };
        };
        // SAFETY: getpgid reads one pid's process group.
        let pgid = unsafe { libc::getpgid(pid as libc::pid_t) };
        if pgid < 0 {
            return Read::Gone;
        }
        Read::Running { start_time: start.0, pgid: pgid as u32 }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::Read;

    pub(super) fn boot_id() -> Option<String> {
        let mut tv = libc::timeval { tv_sec: 0, tv_usec: 0 };
        let mut len = std::mem::size_of::<libc::timeval>();
        let name = c"kern.boottime";
        // SAFETY: `tv` and `len` are valid out parameters of the sizes passed.
        let rc = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                (&raw mut tv).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            )
        };
        (rc == 0 && tv.tv_sec > 0).then(|| format!("{}.{:06}", tv.tv_sec, tv.tv_usec))
    }

    pub(super) fn read(pid: u32) -> Read {
        let mut info: libc::proc_bsdinfo = unsafe {
            // SAFETY: a plain C struct of integers and byte arrays; all zero is valid.
            std::mem::zeroed()
        };
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: `info` is a valid buffer of `size` bytes for PROC_PIDTBSDINFO.
        let got = unsafe {
            libc::proc_pidinfo(
                pid as libc::c_int,
                libc::PROC_PIDTBSDINFO,
                0,
                (&raw mut info).cast(),
                size,
            )
        };
        if got != size {
            return match std::io::Error::last_os_error().raw_os_error() {
                Some(libc::ESRCH) => Read::Gone,
                // No error and no data: the pid is gone (proc_pidinfo answers 0 for it).
                Some(0) | None if got == 0 => Read::Gone,
                _ => Read::Unknown,
            };
        }
        // SZOMB
        if info.pbi_status == 5 {
            return Read::Gone;
        }
        Read::Running {
            start_time: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
            pgid: info.pbi_pgid,
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod platform {
    use super::Read;

    pub(super) fn boot_id() -> Option<String> {
        None
    }

    pub(super) fn read(_pid: u32) -> Read {
        Read::Unknown
    }
}

#[cfg(test)]
#[cfg(target_os = "linux")]
mod tests {
    use super::*;

    #[test]
    fn this_process_is_alive_and_a_reused_pid_or_another_boot_is_dead() {
        let me = current().expect("this process reads");
        assert_eq!(check(&me), Liveness::Alive);
        let reused = Identity { start_time: me.start_time + 1, ..me.clone() };
        assert_eq!(check(&reused), Liveness::Dead, "a pid with another start time was reused");
        let rebooted = Identity {
            pid: me.pid,
            start_time: me.start_time,
            pgid: me.pgid,
            boot_id: "another-boot".into(),
        };
        assert_eq!(check(&rebooted), Liveness::Dead, "a record from another boot is dead");
        let gone = Identity { pid: i32::MAX as u32, ..me };
        assert_eq!(check(&gone), Liveness::Dead);
    }

    #[test]
    fn an_exited_child_holds_its_pid_until_reaped_then_reads_gone() {
        let mut child = std::process::Command::new("true").spawn().unwrap();
        let pid = child.id();
        let before = of(pid).expect("a child that just started reads");
        // Wait for the exit without reaping, so the pid stays a zombie.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: waitid on our own child with WNOWAIT leaves it unreaped.
        let rc =
            unsafe { libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT) };
        assert_eq!(rc, 0);
        assert_eq!(check(&before), Liveness::Alive, "a zombie still holds its pid");
        child.wait().unwrap();
        assert_eq!(read(pid), Read::Gone, "reaped, the pid is free");
        assert_eq!(check(&before), Liveness::Dead);
    }
}
