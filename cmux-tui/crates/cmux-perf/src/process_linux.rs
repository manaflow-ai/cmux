//! Linux processes from `/proc`: `stat` (start time, utime + stime), `statm`
//! (resident pages) and `status` (voluntary and involuntary context switches,
//! the nearest thing Linux keeps to macOS's wakeups).

use super::Usage;

fn clock_ticks() -> u64 {
    // SAFETY: sysconf has no preconditions.
    let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
    if ticks > 0 { ticks as u64 } else { 100 }
}

fn page_size() -> u64 {
    // SAFETY: sysconf has no preconditions.
    let size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if size > 0 { size as u64 } else { 4096 }
}

/// The fields of `/proc/<pid>/stat` after the command name, from field 3
/// (`state`) on: the name is in parentheses and may hold spaces.
pub(super) fn stat_fields(stat: &str) -> Option<Vec<&str>> {
    let after = &stat[stat.rfind(')')? + 1..];
    Some(after.split_whitespace().collect())
}

fn stat(pid: i32) -> Option<String> {
    std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()
}

/// (pid, start time) of every process.
pub(super) fn list() -> Vec<(i32, u64)> {
    let Ok(entries) = std::fs::read_dir("/proc") else { return Vec::new() };
    let mut found = Vec::new();
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|name| name.parse::<i32>().ok()) else {
            continue;
        };
        let Some(text) = stat(pid) else { continue };
        let Some(start) = stat_fields(&text).and_then(|fields| fields.get(19)?.parse().ok()) else {
            continue;
        };
        found.push((pid, start));
    }
    found
}

/// The executable's path, then the arguments after argv[0].
pub(super) fn command(pid: i32) -> Option<String> {
    let exe = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
    let mut words = vec![exe.to_string_lossy().into_owned()];
    words.extend(
        cmdline
            .split(|byte| *byte == 0)
            .skip(1)
            .filter(|word| !word.is_empty())
            .map(|word| String::from_utf8_lossy(word).into_owned()),
    );
    Some(words.join(" "))
}

/// `voluntary_ctxt_switches` plus `nonvoluntary_ctxt_switches` of a `status` file.
pub(super) fn switches(status: &str) -> u64 {
    status
        .lines()
        .filter_map(|line| {
            let (key, value) = line.split_once(':')?;
            matches!(key, "voluntary_ctxt_switches" | "nonvoluntary_ctxt_switches")
                .then(|| value.trim().parse::<u64>().ok())?
        })
        .sum()
}

pub(super) fn usage(pid: i32) -> Option<Usage> {
    let text = stat(pid)?;
    let fields = stat_fields(&text)?;
    let utime: u64 = fields.get(11)?.parse().ok()?;
    let stime: u64 = fields.get(12)?.parse().ok()?;
    let statm = std::fs::read_to_string(format!("/proc/{pid}/statm")).ok()?;
    let resident: u64 = statm.split_whitespace().nth(1)?.parse().ok()?;
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
    Some(Usage {
        cpu_ns: (utime + stime).saturating_mul(1_000_000_000) / clock_ticks(),
        wakeups: switches(&status),
        memory: resident * page_size(),
    })
}

pub(super) fn executable(pid: i32) -> Option<std::path::PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/exe")).ok()
}

pub(super) fn responsible(_pid: i32) -> Option<i32> {
    None
}

pub(super) fn responsibility_available() -> bool {
    false
}
