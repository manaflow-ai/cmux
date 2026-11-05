//! The machine's own workload for the Cloud's idle decision: processes using CPU, sockets
//! listening and timers (cron, systemd timers, at jobs) that are not the system's.
//!
//! The Cloud pauses a machine it reads as idle. Until this, idle meant no input and no agent
//! turn, so a pause froze what an agent left running: a dev server, a build, a cron job
//! (exe.dev, <https://blog.exe.dev/persistent>: "Every time we talked about quiescing, we
//! realized it would break cron jobs."). The report's `activity.workload` (capability
//! `activity-workload`) now says what runs, and cmux-platform reads a machine as idle only when
//! it counts nothing:
//!
//! - `busy_processes`: processes that used more than [`CPU_BUSY_PERCENT`] of one CPU between
//!   two probes ([`PROBE_INTERVAL_MS`] apart). A process's reaped children count toward it, so
//!   a `make` whose compilers each live a second still reads busy.
//! - `listening_ports`: TCP sockets in LISTEN (IPv4 and IPv6, loopback included: a dev server on
//!   127.0.0.1 is still a dev server). A socket whose owner cannot be found counts.
//! - `timers`: user crontabs, `/etc/cron.d` entries, at jobs, transient (`systemd-run`) timers
//!   and timer units under `/etc/systemd/system` or a user's `~/.config/systemd/user`.
//!
//! Each count comes with at most [`NAMES_MAX`] names: a process's `comm` (15 characters, never
//! a command line), a port number, a timer's unit or crontab name. Never a command line, an
//! argument or an environment, so no secret travels.
//!
//! System work never counts, by the documented allowlists [`SYSTEM_PROCESSES`],
//! [`SYSTEM_PROCESS_PREFIXES`], [`SYSTEM_TIMERS`] and [`SYSTEM_CRON_D`]: kernel threads, systemd
//! and its daemons, sshd, cron and atd themselves, journald, dbus, this agent (cmux-host), the
//! terminal daemon (cmux-tui and its terminal hosts), acpmux, the machine health timer, the
//! image's desktop (Xvnc, websockify, openbox, ...) and the distribution's housekeeping timers.
//!
//! A probe that cannot read `/proc` is unknown: the report then drops `activity-workload`, and
//! the Cloud never pauses a machine whose workload it does not know.

use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// How often the agent probes.
pub const PROBE_INTERVAL_MS: u64 = 30_000;
/// A process above this share of one CPU between two probes is busy.
pub const CPU_BUSY_PERCENT: u64 = 2;
/// At most this many names per list.
pub const NAMES_MAX: usize = 8;

/// System processes by `comm` (exact): never busy, their listeners never count.
pub const SYSTEM_PROCESSES: &[&str] = &[
    // init and systemd's own daemons (comm is at most 15 characters).
    "systemd",
    "(sd-pam)",
    "init",
    "systemd-journal",
    "systemd-logind",
    "systemd-udevd",
    "systemd-network",
    "systemd-resolve",
    "systemd-timesyn",
    "systemd-oomd",
    "systemd-userdbd",
    "systemd-userwor",
    // Remote access, scheduling, logging, the bus.
    "sshd",
    "sshd-session",
    "cron",
    "crond",
    "atd",
    "rsyslogd",
    "dbus-daemon",
    "dbus-broker",
    "dbus-broker-lau",
    "agetty",
    "polkitd",
    "chronyd",
    "irqbalance",
    "multipathd",
    "unattended-upgr",
    "snapd",
    "tailscaled",
    "containerd",
    "dockerd",
    // cmux on the machine: this agent, the CLI, acpmux and its idle daemon, machine health.
    "cmux-host",
    "cmux",
    "acpmux",
    "cmux-machine-he",
    // The image's desktop (Cloud computer use).
    "Xtigervnc",
    "Xvnc",
    "openbox",
    "tint2",
    "vncconfig",
    "websockify",
    "at-spi-bus-laun",
    "at-spi2-registr",
    "cmux-desktop-bo",
];

/// System processes by `comm` prefix: the terminal daemon and its terminal hosts.
pub const SYSTEM_PROCESS_PREFIXES: &[&str] = &["cmux-tui", "__terminal"];

/// Timer units that are the system's: the distribution's housekeeping (the same list
/// [`crate::config::HOUSEKEEPING_TIMERS`] stops at park, plus common others) and cmux's own.
pub const SYSTEM_TIMERS: &[&str] = &[
    "apt-daily.timer",
    "apt-daily-upgrade.timer",
    "dpkg-db-backup.timer",
    "e2scrub_all.timer",
    "fstrim.timer",
    "logrotate.timer",
    "man-db.timer",
    "motd-news.timer",
    "systemd-tmpfiles-clean.timer",
    "fwupd-refresh.timer",
    "ua-timer.timer",
    "update-notifier-download.timer",
    "update-notifier-motd.timer",
    "snapd.snap-repair.timer",
    "sysstat-collect.timer",
    "sysstat-summary.timer",
    "phpsessionclean.timer",
    "certbot.timer",
    "apport-autoreport.timer",
    "plocate-updatedb.timer",
    "mlocate.timer",
    "anacron.timer",
    "cmux-machine-health.timer",
    "cmux-self-update-guard.timer",
];

/// `/etc/cron.d` entries that are the distribution's.
pub const SYSTEM_CRON_D: &[&str] = &[
    ".placeholder",
    "e2scrub_all",
    "popularity-contest",
    "sysstat",
    "php",
    "anacron",
    "certbot",
    "mdadm",
];

/// Whether `comm` is a system process.
pub fn is_system_process(comm: &str) -> bool {
    SYSTEM_PROCESSES.contains(&comm) || SYSTEM_PROCESS_PREFIXES.iter().any(|p| comm.starts_with(p))
}

/// Whether a timer the reader found is the system's. Names come as `KIND:NAME` (`cron:alice`,
/// `cron.d:backup`, `at:a0001`, `systemd:x.timer`, `user:x.timer`).
pub fn is_system_timer(name: &str) -> bool {
    match name.split_once(':') {
        Some(("systemd", unit)) => SYSTEM_TIMERS.contains(&unit),
        Some(("cron.d", file)) => SYSTEM_CRON_D.contains(&file),
        _ => false,
    }
}

/// One process at one probe (`/proc/<pid>/stat`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcStat {
    pub pid: u32,
    pub comm: String,
    /// Start time in clock ticks after boot: with the pid, the process's identity.
    pub start: u64,
    /// utime + stime + cutime + cstime, in clock ticks.
    pub ticks: u64,
    pub kthread: bool,
}

/// `/proc/<pid>/stat`, or None when it does not read. `comm` may hold spaces and parens.
pub fn parse_stat(pid: u32, text: &str) -> Option<ProcStat> {
    let open = text.find('(')?;
    let close = text.rfind(')')?;
    let comm = text.get(open + 1..close)?.to_owned();
    let rest: Vec<&str> = text.get(close + 1..)?.split_whitespace().collect();
    // rest[0] is field 3 (state): field k is rest[k - 3].
    let field = |k: usize| rest.get(k - 3).and_then(|v| v.parse::<u64>().ok());
    const PF_KTHREAD: u64 = 0x0020_0000;
    let flags = field(9)?;
    let ticks =
        [14, 15, 16, 17].iter().try_fold(0u64, |sum, k| Some(sum.saturating_add(field(*k)?)))?;
    Some(ProcStat { pid, comm, start: field(22)?, ticks, kthread: flags & PF_KTHREAD != 0 })
}

/// The LISTEN sockets of one `/proc/net/tcp` or `/proc/net/tcp6`: (port, inode).
pub fn parse_listeners(text: &str) -> Vec<(u16, u64)> {
    text.lines()
        .skip(1)
        .filter_map(|line| {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.get(3) != Some(&"0A") {
                return None;
            }
            let port = u16::from_str_radix(f.get(1)?.rsplit(':').next()?, 16).ok()?;
            let inode = f.get(9)?.parse::<u64>().ok()?;
            (inode > 0).then_some((port, inode))
        })
        .collect()
}

/// Whether a crontab holds a job: a line that is not blank, a comment or an assignment.
pub fn crontab_has_jobs(text: &str) -> bool {
    text.lines().map(str::trim).any(|line| {
        !line.is_empty()
            && !line.starts_with('#')
            && !line.split_whitespace().next().is_some_and(|first| first.contains('='))
    })
}

/// What one probe read.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    /// Monotonic milliseconds of the probe.
    pub mono_ms: u64,
    /// Clock ticks per second (`sysconf(_SC_CLK_TCK)`).
    pub clk_tck: u64,
    pub procs: Vec<ProcStat>,
    /// Each LISTEN socket's port and its owner's `comm`, None when no process holds it.
    pub listeners: Vec<(u16, Option<String>)>,
    /// Every timer found, as `KIND:NAME` ([`is_system_timer`]).
    pub timers: Vec<String>,
}

/// The workload as the report carries it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Workload {
    pub busy_processes: Vec<String>,
    pub listening_ports: Vec<u16>,
    pub timers: Vec<String>,
    /// When a probe last found the machine busy (Unix ms): the idle period starts no earlier.
    pub last_busy_at: Option<u64>,
}

impl Workload {
    pub fn busy(&self) -> bool {
        !(self.busy_processes.is_empty()
            && self.listening_ports.is_empty()
            && self.timers.is_empty())
    }

    /// What a new report waits for: busy or not, the ports and timers, and the last busy time
    /// while quiet. Which processes use CPU while busy changes from probe to probe; it rides along
    /// with the next report instead of making one every probe.
    pub fn key(&self) -> (bool, &[u16], &[String], Option<u64>) {
        let busy = !self.busy_processes.is_empty();
        let quiet_since = if self.busy() { None } else { self.last_busy_at };
        (busy, &self.listening_ports, &self.timers, quiet_since)
    }

    /// `activity.workload` of the report: counts, at most [`NAMES_MAX`] names each.
    pub fn to_json(&self) -> Value {
        let first = |v: &[String]| v.iter().take(NAMES_MAX).cloned().collect::<Vec<_>>();
        let mut out = json!({
            "busy_processes": self.busy_processes.len(),
            "listening_ports": self.listening_ports.len(),
            "timers": self.timers.len(),
            "process_names": first(&self.busy_processes),
            "ports": self.listening_ports.iter().take(NAMES_MAX).collect::<Vec<_>>(),
            "timer_names": first(&self.timers),
        });
        if let Some(at) = self.last_busy_at {
            out["last_busy_at"] = json!(at);
        }
        out
    }
}

/// CPU ticks by process identity (pid, start time).
type Ticks = BTreeMap<(u32, u64), u64>;

/// The probes' memory: the last sample's CPU ticks and when the machine was last busy.
#[derive(Debug, Default)]
pub struct Tracker {
    prev: Option<(u64, Ticks)>,
    last_busy_at: Option<u64>,
}

impl Tracker {
    /// The workload from this probe (`wall_ms`: its Unix time), or None while CPU use is not
    /// known yet (the first probe) or the clock did not move.
    pub fn observe(&mut self, snap: &Snapshot, wall_ms: u64) -> Option<Workload> {
        let ticks: Ticks = snap.procs.iter().map(|p| ((p.pid, p.start), p.ticks)).collect();
        let prev = self.prev.replace((snap.mono_ms, ticks));
        let (prev_ms, prev_ticks) = prev?;
        let window_ms = snap.mono_ms.checked_sub(prev_ms).filter(|ms| *ms > 0)?;
        let clk_tck = snap.clk_tck.max(1);
        let mut busy = BTreeSet::new();
        for p in &snap.procs {
            if p.kthread || is_system_process(&p.comm) {
                continue;
            }
            // A process new since the last probe used all its ticks inside the window.
            let used =
                p.ticks.saturating_sub(prev_ticks.get(&(p.pid, p.start)).copied().unwrap_or(0));
            // used / clk_tck seconds over window_ms / 1000 seconds, above CPU_BUSY_PERCENT.
            if used.saturating_mul(1000 * 100) > CPU_BUSY_PERCENT * clk_tck * window_ms {
                busy.insert(p.comm.clone());
            }
        }
        let ports: BTreeSet<u16> = snap
            .listeners
            .iter()
            .filter(|(_, owner)| !owner.as_deref().is_some_and(is_system_process))
            .map(|(port, _)| *port)
            .collect();
        let timers: BTreeSet<String> =
            snap.timers.iter().filter(|t| !is_system_timer(t)).cloned().collect();
        let mut w = Workload {
            busy_processes: busy.into_iter().collect(),
            listening_ports: ports.into_iter().collect(),
            timers: timers.into_iter().collect(),
            last_busy_at: None,
        };
        if w.busy() {
            self.last_busy_at = Some(wall_ms);
        }
        w.last_busy_at = self.last_busy_at;
        Some(w)
    }
}

#[cfg(unix)]
pub use reader::read_snapshot;

#[cfg(unix)]
mod reader {
    use super::{ProcStat, Snapshot, crontab_has_jobs, parse_listeners, parse_stat};
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::Path;

    /// One probe of the machine under `root` (`/` in production), or None when `/proc` does not
    /// read: the workload is then unknown.
    pub fn read_snapshot(root: &Path, mono_ms: u64) -> Option<Snapshot> {
        let proc_dir = root.join("proc");
        let pids: Vec<u32> = fs::read_dir(&proc_dir)
            .ok()?
            .filter_map(|e| e.ok()?.file_name().to_str()?.parse().ok())
            .collect();
        let procs: Vec<ProcStat> = pids
            .iter()
            .filter_map(|pid| {
                // A process that exited between the listing and the read is gone, not unknown.
                parse_stat(*pid, &fs::read_to_string(proc_dir.join(format!("{pid}/stat"))).ok()?)
            })
            .collect();
        if procs.is_empty() {
            return None;
        }
        let mut sockets: Vec<(u16, u64)> = Vec::new();
        let mut any_table = false;
        for table in ["net/tcp", "net/tcp6"] {
            if let Ok(text) = fs::read_to_string(proc_dir.join(table)) {
                any_table = true;
                sockets.extend(parse_listeners(&text));
            }
        }
        if !any_table {
            return None;
        }
        let owners = socket_owners(&proc_dir, &procs, &sockets);
        let listeners =
            sockets.iter().map(|(port, inode)| (*port, owners.get(inode).cloned())).collect();
        // SAFETY: sysconf has no preconditions.
        let clk_tck = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
        Some(Snapshot {
            mono_ms,
            clk_tck: u64::try_from(clk_tck).ok().filter(|t| *t > 0).unwrap_or(100),
            procs,
            listeners,
            timers: timers(root),
        })
    }

    /// The `comm` of the process holding each wanted socket inode (`/proc/<pid>/fd`).
    fn socket_owners(
        proc_dir: &Path,
        procs: &[ProcStat],
        sockets: &[(u16, u64)],
    ) -> BTreeMap<u64, String> {
        let mut owners = BTreeMap::new();
        if sockets.is_empty() {
            return owners;
        }
        let wanted: std::collections::BTreeSet<u64> = sockets.iter().map(|(_, i)| *i).collect();
        for p in procs.iter().filter(|p| !p.kthread) {
            let Ok(fds) = fs::read_dir(proc_dir.join(format!("{}/fd", p.pid))) else { continue };
            for fd in fds.flatten() {
                let Ok(target) = fs::read_link(fd.path()) else { continue };
                let target = target.to_string_lossy();
                let inode = target
                    .strip_prefix("socket:[")
                    .and_then(|s| s.strip_suffix(']'))
                    .and_then(|s| s.parse::<u64>().ok());
                if let Some(inode) = inode.filter(|i| wanted.contains(i)) {
                    // A socket shared by a system parent and a user child counts as the user's.
                    let system =
                        owners.get(&inode).is_some_and(|c: &String| super::is_system_process(c));
                    if !owners.contains_key(&inode) || system {
                        owners.insert(inode, p.comm.clone());
                    }
                }
            }
            if owners.len() == wanted.len() && owners.values().all(|c| !super::is_system_process(c))
            {
                break;
            }
        }
        owners
    }

    fn files(dir: &Path) -> Vec<(String, std::path::PathBuf)> {
        let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
        let mut out: Vec<(String, std::path::PathBuf)> = entries
            .flatten()
            .filter(|e| e.file_type().is_ok_and(|t| !t.is_dir()))
            .filter_map(|e| Some((e.file_name().to_str()?.to_owned(), e.path())))
            .collect();
        out.sort();
        out
    }

    fn timer_units(dir: &Path, kind: &str, out: &mut Vec<String>) {
        let mut dirs = vec![dir.to_path_buf()];
        if let Ok(entries) = fs::read_dir(dir) {
            dirs.extend(
                entries
                    .flatten()
                    .filter(|e| e.file_name().to_string_lossy().ends_with(".wants"))
                    .map(|e| e.path()),
            );
        }
        for d in dirs {
            for (name, path) in files(&d) {
                // A masked unit links to /dev/null: it never runs.
                let masked = fs::read_link(&path).is_ok_and(|t| t == Path::new("/dev/null"));
                if name.ends_with(".timer") && !masked {
                    out.push(format!("{kind}:{name}"));
                }
            }
        }
    }

    /// Every timer under `root`, as `KIND:NAME`.
    pub(super) fn timers(root: &Path) -> Vec<String> {
        let mut out = Vec::new();
        for spool in ["var/spool/cron/crontabs", "var/spool/cron"] {
            for (name, path) in files(&root.join(spool)) {
                if fs::read_to_string(&path).is_ok_and(|t| crontab_has_jobs(&t)) {
                    out.push(format!("cron:{name}"));
                }
            }
        }
        for (name, path) in files(&root.join("etc/cron.d")) {
            if fs::read_to_string(&path).is_ok_and(|t| crontab_has_jobs(&t)) {
                out.push(format!("cron.d:{name}"));
            }
        }
        for spool in ["var/spool/cron/atjobs", "var/spool/at"] {
            for (name, _) in files(&root.join(spool)) {
                if !name.starts_with('.') {
                    out.push(format!("at:{name}"));
                }
            }
        }
        timer_units(&root.join("run/systemd/transient"), "transient", &mut out);
        timer_units(&root.join("etc/systemd/system"), "systemd", &mut out);
        timer_units(&root.join("root/.config/systemd/user"), "user", &mut out);
        if let Ok(homes) = fs::read_dir(root.join("home")) {
            for home in homes.flatten() {
                timer_units(&home.path().join(".config/systemd/user"), "user", &mut out);
            }
        }
        out.sort();
        out.dedup();
        out
    }
}

#[cfg(test)]
#[path = "workload_tests.rs"]
mod tests;
