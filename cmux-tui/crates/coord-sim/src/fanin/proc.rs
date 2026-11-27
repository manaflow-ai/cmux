//! What this bench reads about processes. cmux-next scans no processes (plans/cmux-next/pty-holder.md),
//! and neither does this: it reads only `/proc/self`. A daemon's memory comes from its own gauges
//! (`_acpmux/status` `gauges.memory.rssBytes`); its CPU from this process's reaped-children times
//! (`cutime + cstime`) across the reap of that one daemon, so it is the daemon's whole life, not a
//! window (acpmux reports no CPU of its own: a GAP in the report).

/// This process's own fields of `/proc/self/stat` after the command, numeric ones only: field n
/// (1-based, n >= 4) is `[n - 4]`.
fn self_stat() -> Vec<u64> {
    std::fs::read_to_string("/proc/self/stat")
        .ok()
        .and_then(|s| {
            s.rsplit_once(')')
                .map(|(_, r)| r.split_whitespace().filter_map(|v| v.parse().ok()).collect())
        })
        .unwrap_or_default()
}

/// CPU ticks of this process's reaped children (cutime + cstime, fields 16 and 17).
pub fn reaped_children_ticks() -> u64 {
    let f = self_stat();
    f.get(12).copied().unwrap_or(0) + f.get(13).copied().unwrap_or(0)
}

/// This process's CPU ticks (user + system).
pub fn self_ticks() -> u64 {
    let f = self_stat();
    f.get(10).copied().unwrap_or(0) + f.get(11).copied().unwrap_or(0)
}

/// This process's `VmRSS` in KiB.
pub fn self_rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("VmRSS:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(0)
}

/// Clock ticks per second (`getconf CLK_TCK`; 100 when it cannot be read).
pub fn clk_tck() -> f64 {
    cmux_process::Command::new("getconf")
        .arg("CLK_TCK")
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<f64>().ok())
        .filter(|v| *v > 0.0)
        .unwrap_or(100.0)
}

/// This machine's name.
pub fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .or_else(|_| std::fs::read_to_string("/etc/hostname"))
        .map(|s| s.trim().to_owned())
        .unwrap_or_default()
}

/// Total memory, CPU count and descriptor limit of this machine, for the run record.
pub fn machine() -> serde_json::Value {
    let mem = std::fs::read_to_string("/proc/meminfo").ok().and_then(|m| {
        m.lines()
            .find(|l| l.starts_with("MemTotal:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<u64>().ok())
    });
    let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0);
    let nofile = cmux_process::Command::new("sh")
        .args(["-c", "ulimit -n"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned());
    serde_json::json!({"mem_kb": mem, "cpus": cpus, "nofile": nofile, "host": hostname()})
}

#[cfg(test)]
#[path = "proc_tests.rs"]
mod tests;
