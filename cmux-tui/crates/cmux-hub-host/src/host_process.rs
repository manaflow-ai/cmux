//! The running `cmux-rd linux-host run` processes, as a teardown sees them (review F1 of
//! #45369): whoever stops the host (cmux-rd's own teardown, `acpmux machine leave`) checks
//! that every one of this user's host processes is really gone instead of trusting
//! `systemctl`, whether the unit started it, a person did by hand or an older build did. A
//! process is a host only while it is this user's and its command line says `linux-host run`,
//! so a reused pid or another user's process is never touched.

use std::time::{Duration, Instant};

/// How long a stopped host gets to end by itself before its process group is killed.
pub const STOP_WAIT: Duration = Duration::from_secs(5);

/// How long a killed host gets to be gone.
const KILL_WAIT: Duration = Duration::from_secs(2);

/// This user's host processes running now (none where there is no `/proc`).
pub fn running() -> Vec<u32> {
    let Ok(entries) = std::fs::read_dir("/proc") else { return Vec::new() };
    let mut pids: Vec<u32> = entries
        .flatten()
        .filter_map(|e| e.file_name().to_str()?.parse().ok())
        .filter(|&pid| is_host(pid))
        .collect();
    pids.sort_unstable();
    pids
}

/// Whether `pid` is this user's, alive, and runs `linux-host run` (a zombie's command line is
/// empty). Never this process.
pub fn is_host(pid: u32) -> bool {
    use std::os::unix::fs::MetadataExt;
    if pid == 0 || pid == std::process::id() {
        return false;
    }
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    let ours = std::fs::metadata(format!("/proc/{pid}")).is_ok_and(|m| m.uid() == uid);
    let Ok(cmdline) = std::fs::read(format!("/proc/{pid}/cmdline")) else { return false };
    let args: Vec<&[u8]> = cmdline.split(|b| *b == 0).collect();
    ours && args.windows(2).any(|w| w[0] == b"linux-host" && w[1] == b"run")
}

/// Waits up to `wait` for each of `pids` to stop being a host; then kills the process group of
/// each one still running (only that process when it shares this one's group) and waits up to
/// two more seconds. Ok once none is a host; else the ones still running.
pub fn ensure_gone(pids: &[u32], wait: Duration) -> Result<(), Vec<u32>> {
    let left = wait_gone(pids, wait);
    if left.is_empty() {
        return Ok(());
    }
    // SAFETY: getpgrp has no preconditions and cannot fail.
    let ours = unsafe { libc::getpgrp() };
    for &pid in &left {
        let Ok(pid) = libc::pid_t::try_from(pid) else { continue };
        // SAFETY: getpgid and kill take plain integers; a gone process only makes them fail.
        unsafe {
            let group = libc::getpgid(pid);
            if group > 1 && group != ours {
                libc::kill(-group, libc::SIGKILL);
            } else {
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
    let left = wait_gone(&left, KILL_WAIT);
    if left.is_empty() {
        Ok(())
    } else {
        Err(left)
    }
}

fn wait_gone(pids: &[u32], wait: Duration) -> Vec<u32> {
    let until = Instant::now() + wait;
    loop {
        let left: Vec<u32> = pids.iter().copied().filter(|&p| is_host(p)).collect();
        if left.is_empty() || Instant::now() >= until {
            return left;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

// The command line is read from /proc, which only Linux has.
#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::os::unix::process::CommandExt;

    /// A process whose command line says `linux-host run`, in a process group of its own, once
    /// it reads as a host.
    fn fake_host(ignore_term: bool) -> std::process::Child {
        let script = if ignore_term { "trap '' TERM; sleep 30; :" } else { "sleep 30; :" };
        let child = std::process::Command::new("sh")
            .args(["-c", script, "linux-host", "run"])
            .process_group(0)
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !is_host(child.id()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        child
    }

    #[test]
    fn a_host_that_does_not_stop_is_killed_and_then_gone() {
        let mut child = fake_host(true);
        let pid = child.id();
        assert!(running().contains(&pid));
        let reaper = std::thread::spawn(move || child.wait());
        assert_eq!(ensure_gone(&[pid], Duration::from_millis(100)), Ok(()));
        assert!(!is_host(pid));
        assert!(!running().contains(&pid));
        reaper.join().unwrap().unwrap();
    }

    #[test]
    fn only_processes_that_run_the_host_count() {
        assert!(!is_host(std::process::id()));
        assert!(!is_host(0));
        let mut other = std::process::Command::new("sleep").arg("30").spawn().unwrap();
        assert!(!is_host(other.id()));
        // Nothing to kill: it is not a host.
        assert_eq!(ensure_gone(&[other.id()], Duration::ZERO), Ok(()));
        assert!(other.try_wait().unwrap().is_none(), "a process that is not a host was killed");
        other.kill().unwrap();
        other.wait().unwrap();
    }
}
