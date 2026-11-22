//! Process probes and process-group signals (cx-ko2e `ProcessProbe` and
//! `ProcessTree` seams, Unix side). Moved from `unix/unadoptable.rs`.

/// Positive proof that no process has `pid` (ESRCH). Permission errors and
/// live processes are not proof.
pub(crate) fn process_definitely_absent(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return true };
    // SAFETY: signal zero performs a liveness/permission probe and does not
    // deliver a signal to the target process.
    if unsafe { libc::kill(pid, 0) } == 0 {
        return false;
    }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

/// SIGKILL the process group `pid` leads. Ok(false) when the signal was not
/// delivered; an error when `pid` is not a valid process id.
pub(crate) fn kill_process_group(pid: u32) -> anyhow::Result<bool> {
    let pid = libc::pid_t::try_from(pid)?;
    // SAFETY: the caller proved `pid` leads a live process group it owns.
    Ok(unsafe { libc::killpg(pid, libc::SIGKILL) } == 0)
}
