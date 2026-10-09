//! Who sent a signal (cx-0tgl LA): the name, parent and start time of a
//! process, read once for a diagnostic line, never on a hot path.
//!
//! The sender of a signal often exits right after (`kill`, `pkill`), and its
//! PID can then be reused. A process that started after the signal is not
//! the sender: it is reported as `reused`, never by name. Linux reads
//! `/proc/<pid>/stat` (any user's process); macOS reads the BSD info of
//! `proc_pidinfo`, which answers for processes of other users too.

use serde_json::{Value, json};

/// A process as far as a diagnostic needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProcessIdentity {
    pub(crate) name: String,
    pub(crate) ppid: u32,
    /// Wall-clock start, milliseconds since the epoch.
    pub(crate) started_ms: u64,
}

/// Tolerance for clock granularity between a process start and a signal.
const START_SLACK_MS: u64 = 1_000;

/// `{"name", "ppid", "parent_name"}` of the sender `pid` of a signal sent at
/// `signal_at_ms`; `{"reused": true}` when that PID now names a process that
/// started later; `None` once it is gone (or unreadable).
pub(crate) fn describe_sender(pid: u32, signal_at_ms: u64) -> Option<Value> {
    if pid == 0 {
        return None;
    }
    let sender = identity(pid)?;
    if sender.started_ms > signal_at_ms.saturating_add(START_SLACK_MS) {
        return Some(json!({"reused": true}));
    }
    let parent_name = identity(sender.ppid).map(|parent| parent.name);
    Some(json!({"name": sender.name, "ppid": sender.ppid, "parent_name": parent_name}))
}

#[cfg(target_os = "linux")]
pub(crate) fn identity(pid: u32) -> Option<ProcessIdentity> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let (head, rest) = stat.rsplit_once(')')?;
    let name = head.split_once('(')?.1.to_string();
    // After the name: state(3) ppid(4) ... starttime(22), so ppid is index 1
    // and starttime index 19 of the remaining fields.
    let fields: Vec<&str> = rest.split_whitespace().collect();
    let ppid = fields.get(1)?.parse().ok()?;
    let start_ticks: u64 = fields.get(19)?.parse().ok()?;
    // SAFETY: sysconf has no preconditions.
    let ticks_per_second = u64::try_from(unsafe { libc::sysconf(libc::_SC_CLK_TCK) })
        .ok()
        .filter(|ticks| *ticks > 0)
        .unwrap_or(100);
    let boot_seconds: u64 = std::fs::read_to_string("/proc/stat")
        .ok()?
        .lines()
        .find_map(|line| line.strip_prefix("btime "))?
        .trim()
        .parse()
        .ok()?;
    let started_ms = boot_seconds
        .saturating_mul(1000)
        .saturating_add(start_ticks.saturating_mul(1000) / ticks_per_second);
    Some(ProcessIdentity { name, ppid, started_ms })
}

#[cfg(target_os = "macos")]
pub(crate) fn identity(pid: u32) -> Option<ProcessIdentity> {
    let raw = libc::c_int::try_from(pid).ok()?;
    // SAFETY: proc_bsdinfo is plain old data; all-zero is valid.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
    // SAFETY: `info` is a writable buffer of `size` bytes for this flavor.
    let written =
        unsafe { libc::proc_pidinfo(raw, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    if written != size {
        return None;
    }
    let comm = info.pbi_comm.iter().take_while(|byte| **byte != 0).map(|byte| *byte as u8);
    let name = String::from_utf8_lossy(&comm.collect::<Vec<u8>>()).into_owned();
    let started_ms =
        info.pbi_start_tvsec.saturating_mul(1000).saturating_add(info.pbi_start_tvusec / 1000);
    Some(ProcessIdentity { name, ppid: info.pbi_ppid, started_ms })
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub(crate) fn identity(_pid: u32) -> Option<ProcessIdentity> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn now_ms() -> u64 {
        u64::try_from(
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
        )
        .unwrap()
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn this_process_is_named_with_its_parent() {
        let described = describe_sender(std::process::id(), now_ms()).unwrap();
        assert!(described["name"].as_str().is_some_and(|name| !name.is_empty()), "{described}");
        // SAFETY: getppid has no preconditions.
        let parent = unsafe { libc::getppid() };
        assert_eq!(described["ppid"].as_i64(), Some(i64::from(parent)), "{described}");
    }

    #[cfg(any(target_os = "linux", target_os = "macos"))]
    #[test]
    fn a_process_that_started_after_the_signal_is_not_its_sender() {
        let described = describe_sender(std::process::id(), 1_000).unwrap();
        assert_eq!(described, json!({"reused": true}));
    }

    #[test]
    fn pid_zero_names_nobody() {
        assert_eq!(describe_sender(0, now_ms()), None);
    }
}
