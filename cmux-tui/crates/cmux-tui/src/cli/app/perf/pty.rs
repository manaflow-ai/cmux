//! How many terminals `cmux perf sim` may open without using up the host's PTYs.
//!
//! macOS has a small fixed pool (`kern.tty.ptmx_max`, 511 by default) shared by every terminal
//! on the Mac; a sim that takes all of it leaves the person's own sessions unable to open a
//! shell. Before it builds, the sim reads the pool size and the PTYs in use and keeps
//! [`HEADROOM`] free for everything else. Linux reads `/proc/sys/kernel/pty/{max,nr}` the same
//! way; anywhere else there is no cap.

/// PTYs left free for the person's own terminals, agents and tools.
pub(super) const HEADROOM: usize = 64;

/// The host's PTY pool: its size and, when that is cheap to read, how many are in use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Pool {
    pub max: usize,
    pub in_use: Option<usize>,
}

/// The most terminals the sim may open: the pool less what is in use (all of it when that is
/// unknown, so the cap then only keeps `headroom` below the pool's size) and less `headroom`.
pub(super) fn cap(pool: Pool, headroom: usize) -> usize {
    pool.max.saturating_sub(pool.in_use.unwrap_or(0)).saturating_sub(headroom)
}

/// The host's pool, `None` where there is no limit to read.
pub(super) fn read_pool() -> Option<Pool> {
    if cfg!(target_os = "macos") {
        let output = cmux_process::Command::new("/usr/sbin/sysctl")
            .args(["-n", "kern.tty.ptmx_max"])
            .output()
            .ok()?;
        let max = String::from_utf8_lossy(&output.stdout).trim().parse().ok()?;
        // devfs makes /dev/ttysNNN when a PTY is allocated and removes it when it is freed.
        let in_use = std::fs::read_dir("/dev").ok().map(|dir| {
            dir.filter_map(Result::ok)
                .filter(|entry| is_pty_slave(&entry.file_name().to_string_lossy()))
                .count()
        });
        Some(Pool { max, in_use })
    } else if cfg!(target_os = "linux") {
        let read = |name: &str| {
            std::fs::read_to_string(format!("/proc/sys/kernel/pty/{name}"))
                .ok()
                .and_then(|text| text.trim().parse::<usize>().ok())
        };
        Some(Pool { max: read("max")?, in_use: read("nr") })
    } else {
        None
    }
}

/// A macOS PTY slave's device name: `ttys` and digits.
pub(super) fn is_pty_slave(name: &str) -> bool {
    name.strip_prefix("ttys")
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}
