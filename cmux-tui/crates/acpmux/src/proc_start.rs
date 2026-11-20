//! When a process started, as `proc_bsdinfo` reports it (macOS): a pid plus
//! its start time names one process, so a reused pid is not taken for it
//! (the Claude Code registry check, `adopt_live.rs`, and the owner watch,
//! `daemon/owner_exit.rs`).

/// `pbi_start_tvsec` / `pbi_start_tvusec` of `pid`.
#[cfg(target_os = "macos")]
pub(crate) fn start_time(pid: i32) -> Option<(u64, u64)> {
    // SAFETY: proc_bsdinfo is plain C data; all zero bytes is a valid value.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: `info` is a writable proc_bsdinfo of `size` bytes.
    let read =
        unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) };
    (read == size).then_some((info.pbi_start_tvsec, info.pbi_start_tvusec))
}
