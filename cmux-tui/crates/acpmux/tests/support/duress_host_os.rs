//! The host readers the duress bench needs, on Linux and macOS.
//!
//! Why (RFD 0050 rule 7, cmuxterm-hq docs/rfd/0050-aliveness-under-duress.md): the drill's Mac
//! round was blocked on a portable harness, because the bench read only `/proc`. Linux keeps its
//! `/proc` reads byte for byte; macOS answers the same questions from `getloadavg`,
//! `host_statistics` (CPU ticks), `host_statistics64` with `hw.memsize` (memory) and `ps`
//! (processes, their state, parent and group). Every reader returns `None` or empty when the
//! host does not answer, and the row says so instead of guessing.
use std::path::Path;
#[cfg(target_os = "macos")]
use std::process::{Command, Stdio};

/// The host's name (`gethostname`, the same answer `/proc/sys/kernel/hostname` gives on Linux).
pub(super) fn hostname() -> String {
    let mut buf = [0u8; 256];
    // SAFETY: `buf` is valid for its length; gethostname NUL-terminates within it or truncates.
    if unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } != 0 {
        return String::new();
    }
    let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
    String::from_utf8_lossy(&buf[..end]).trim().to_owned()
}

/// The 1-minute load average.
pub(super) fn load1() -> Option<f64> {
    let mut v = [0f64; 3];
    // SAFETY: `v` holds the 3 samples asked for.
    (unsafe { libc::getloadavg(v.as_mut_ptr(), 3) } >= 1).then_some(v[0])
}

/// Every process's pid and its fields from the state on, as `/proc/PID/stat` gives them after
/// the command: 0 state, 1 parent pid, 2 process group (the fields callers read).
#[cfg(target_os = "linux")]
pub(super) fn procs() -> Vec<(i32, Vec<String>)> {
    let Ok(dir) = std::fs::read_dir("/proc") else { return vec![] };
    dir.flatten()
        .filter_map(|e| e.file_name().to_str()?.parse::<i32>().ok())
        .filter_map(|pid| {
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            let rest = stat.rsplit_once(')')?.1;
            Some((pid, rest.split_whitespace().map(str::to_owned).collect()))
        })
        .collect()
}

/// macOS: one `ps` read; `stat`'s first letter is the state (`Z` a zombie, as on Linux).
#[cfg(target_os = "macos")]
pub(super) fn procs() -> Vec<(i32, Vec<String>)> {
    ps_rows(&["pid=", "stat=", "ppid=", "pgid="])
        .into_iter()
        .filter_map(|f| {
            let pid = f.first()?.parse().ok()?;
            let state = f.get(1)?.chars().next()?.to_string();
            Some((pid, vec![state, f.get(2)?.clone(), f.get(3)?.clone()]))
        })
        .collect()
}

#[cfg(target_os = "macos")]
fn ps_rows(cols: &[&str]) -> Vec<Vec<String>> {
    let mut cmd = Command::new("/bin/ps");
    cmd.arg("-A").stdin(Stdio::null()).stderr(Stdio::null());
    for c in cols {
        cmd.args(["-o", c]);
    }
    let Ok(out) = cmd.output() else { return vec![] };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| l.split_whitespace().map(str::to_owned).collect())
        .collect()
}

pub(super) fn proc_count() -> usize {
    procs().len()
}

/// The pid of a stand-in harness (`fake_agent.py`) working in `cwd`.
#[cfg(target_os = "linux")]
pub(super) fn harness_in(cwd: &Path) -> Option<i32> {
    let want = std::fs::canonicalize(cwd).ok()?;
    procs().into_iter().map(|(pid, _)| pid).find(|pid| {
        let cmd = std::fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
        String::from_utf8_lossy(&cmd).contains("fake_agent.py")
            && std::fs::read_link(format!("/proc/{pid}/cwd")).is_ok_and(|c| c == want)
    })
}

/// macOS: `ps` finds the stand-ins, `lsof -d cwd` says where each works.
#[cfg(target_os = "macos")]
pub(super) fn harness_in(cwd: &Path) -> Option<i32> {
    let want = std::fs::canonicalize(cwd).ok()?;
    let out = Command::new("/bin/ps").args(["-A", "-o", "pid=,command="]).output().ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|l| l.contains("fake_agent.py"))
        .filter_map(|l| l.split_whitespace().next()?.parse::<i32>().ok())
        .find(|pid| {
            let Ok(o) = Command::new("/usr/sbin/lsof")
                .args(["-a", "-p", &pid.to_string(), "-d", "cwd", "-Fn"])
                .stderr(Stdio::null())
                .output()
            else {
                return false;
            };
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter_map(|l| l.strip_prefix('n'))
                .any(|p| std::fs::canonicalize(p).is_ok_and(|c| c == want))
        })
}

/// `(total, available)` bytes of memory: `MemTotal` and `MemAvailable` on Linux.
#[cfg(target_os = "linux")]
pub(super) fn mem_total_avail() -> Option<(u64, u64)> {
    let text = std::fs::read_to_string("/proc/meminfo").ok()?;
    let get = |key: &str| -> Option<u64> {
        let line = text.lines().find(|l| l.starts_with(key) && l[key.len()..].starts_with(':'))?;
        Some(line.split_whitespace().nth(1)?.parse::<u64>().ok()? * 1024)
    };
    Some((get("MemTotal")?, get("MemAvailable")?))
}

/// macOS: `hw.memsize`, and available as Activity Monitor counts it: free, inactive,
/// speculative and purgeable pages (what the kernel hands out without compressing or swapping).
#[cfg(target_os = "macos")]
pub(super) fn mem_total_avail() -> Option<(u64, u64)> {
    let total = sysctl_u64(c"hw.memsize")?;
    let page = sysctl_u64(c"hw.pagesize")?;
    // SAFETY: a zeroed vm_statistics64 is a valid out parameter of the count passed.
    let mut s: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
    let mut count = libc::HOST_VM_INFO64_COUNT;
    // SAFETY: `s` is a vm_statistics64 and `count` its size in natural_t, as HOST_VM_INFO64 asks.
    #[allow(deprecated)]
    let kr = unsafe {
        libc::host_statistics64(
            libc::mach_host_self(),
            libc::HOST_VM_INFO64,
            (&mut s as *mut libc::vm_statistics64).cast(),
            &mut count,
        )
    };
    if kr != libc::KERN_SUCCESS {
        return None;
    }
    let pages = u64::from(s.free_count)
        + u64::from(s.inactive_count)
        + u64::from(s.speculative_count)
        + u64::from(s.purgeable_count);
    Some((total, (pages * page).min(total)))
}

#[cfg(target_os = "macos")]
fn sysctl_u64(name: &std::ffi::CStr) -> Option<u64> {
    let mut v: u64 = 0;
    let mut len = std::mem::size_of::<u64>();
    // SAFETY: `v` is 8 writable bytes and `len` says so; no new value is set.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            (&mut v as *mut u64).cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    // hw.pagesize is 8 bytes on current macOS; a 4-byte answer fills the low half (little endian).
    (rc == 0 && (len == 8 || len == 4)).then_some(v)
}

/// `(busy, total)` CPU ticks of all CPUs since boot: `/proc/stat`'s first line on Linux.
#[cfg(target_os = "linux")]
pub(super) fn cpu_ticks() -> Option<(u64, u64)> {
    let text = std::fs::read_to_string("/proc/stat").ok()?;
    let v: Vec<u64> =
        text.lines().next()?.split_whitespace().skip(1).filter_map(|x| x.parse().ok()).collect();
    let total: u64 = v.iter().take(8).sum();
    let idle = v.get(3).copied().unwrap_or(0) + v.get(4).copied().unwrap_or(0);
    Some((total - idle, total))
}

/// macOS: `host_statistics(HOST_CPU_LOAD_INFO)`, user + system + nice busy of the four states.
#[cfg(target_os = "macos")]
pub(super) fn cpu_ticks() -> Option<(u64, u64)> {
    // SAFETY: a zeroed host_cpu_load_info is a valid out parameter of the count passed.
    let mut info: libc::host_cpu_load_info = unsafe { std::mem::zeroed() };
    let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
    // SAFETY: `info` is a host_cpu_load_info and `count` its size in natural_t.
    #[allow(deprecated)]
    let kr = unsafe {
        libc::host_statistics(
            libc::mach_host_self(),
            libc::HOST_CPU_LOAD_INFO,
            (&mut info as *mut libc::host_cpu_load_info).cast(),
            &mut count,
        )
    };
    if kr != libc::KERN_SUCCESS {
        return None;
    }
    let t = info.cpu_ticks.map(u64::from);
    let busy = t[libc::CPU_STATE_USER as usize]
        + t[libc::CPU_STATE_SYSTEM as usize]
        + t[libc::CPU_STATE_NICE as usize];
    Some((busy, busy + t[libc::CPU_STATE_IDLE as usize]))
}

/// The legs that need Linux: a tmpfs or `prlimit` (disk), `systemd-run` memory ceilings
/// (bigchat, host150), CPU pinning and cgroups (starved). Elsewhere they are refused by name.
pub(super) const LINUX_ONLY_LEGS: [&str; 5] = ["disk", "bigchat", "all", "host150", "starved"];

/// Why `leg` cannot run on this OS, or none when it can.
pub(super) fn refuses(leg: &str) -> Option<String> {
    (cfg!(not(target_os = "linux")) && LINUX_ONLY_LEGS.contains(&leg)).then(|| {
        format!(
            "leg {leg:?} needs Linux (tmpfs/prlimit, systemd-run or cgroups); on {} run \
             legs={}",
            std::env::consts::OS,
            "baseline,cpu,fork,hub503,hubslow,peercut,relay,relayfail,rfd0050,peerscale,peerburst"
        )
    })
}

#[cfg(test)]
mod unit {
    use super::*;

    #[test]
    fn this_host_answers() {
        assert!(!hostname().is_empty());
        assert!(load1().is_some());
        let (total, avail) = mem_total_avail().expect("memory");
        assert!(total > 0 && avail <= total);
        let (busy, all) = cpu_ticks().expect("cpu ticks");
        assert!(busy <= all && all > 0);
        let me = std::process::id() as i32;
        let rows = procs();
        let mine = rows.iter().find(|(p, _)| *p == me).expect("this process listed");
        assert!(mine.1.len() >= 3, "state, parent, group: {:?}", mine.1);
    }

    #[test]
    fn linux_only_legs_refused_elsewhere() {
        assert_eq!(refuses("rfd0050"), None);
        assert_eq!(refuses("disk").is_some(), cfg!(not(target_os = "linux")));
    }
}
