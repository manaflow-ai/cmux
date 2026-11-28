//! Agents' own use of the host (RFD 0072 piece 2, "Agents' own use"): the cores and resident
//! memory of each session's process trees, rooted at the pids this daemon started (the agent's
//! harness, or the agent host it runs under, and the runners of its background tasks). Reported in
//! `daemon status` `host_pressure.agents` (`hub/views/host_load.rs`), so the auto-move trigger can
//! tell the agents' load from the person's own: "we should be able to auto-detect if your
//! computer is under load, true load, OR if they're affecting interactive speed" (Leo).
//!
//! A tree's CPU counts what its live processes used plus what their exited children used once
//! reaped (Linux `cutime`/`cstime`, macOS `ri_child_*_time`): a hook or a short tool that starts
//! and ends between two samples still counts (RFD 0072, run A: the accounting must count hooks).
//! A process that detaches from its tree (reparented to init) is not seen; RFD 0072 lists that as
//! an open question.
//!
//! Cost: one sample at most every [`MIN_INTERVAL`], cached; a caller off the async runtime
//! (`spawn_blocking`). A sample reads only the trees' processes, through the same reviewed own-tree
//! reader a start's harness check uses (`cpu_class::own_tree`: Linux `/proc/PID/task/*/children`,
//! macOS `proc_listchildpids`, at most 256 and 64 per root), never a scan of the machine; a kernel
//! without `/proc/.../children` counts each root alone (its reaped children still count).

use cmux_host_budget::SessionLoad;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The least time between two samples: the host budget's cadence (RFD 0072 "Signals").
pub(crate) const MIN_INTERVAL: Duration = Duration::from_secs(3);
/// The `cpu_cores` average's time constant ([`SessionLoad`]: "EWMA over 5 minutes").
pub(crate) const EWMA_TAU: Duration = Duration::from_secs(300);

/// One process as a sample reads it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Proc {
    pub pid: u32,
    /// CPU time it used plus what its reaped children used, in nanoseconds.
    pub cpu_ns: u64,
    pub rss_bytes: u64,
}

/// One session's roots: the pids this daemon started for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Roots {
    pub id: String,
    /// A turn, a running process or a background task now.
    pub active: bool,
    pub pids: Vec<u32>,
}

/// One session's use: [`SessionLoad`] with the session's id.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub(crate) struct SessionUsage {
    pub id: String,
    #[serde(flatten)]
    pub load: SessionLoad,
}

/// `host_pressure.agents`: every session's use and their sum.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub(crate) struct AgentsUsage {
    pub cpu_cores: f64,
    pub rss_bytes: u64,
    /// The sessions with at least one process read, heaviest CPU first.
    pub sessions: Vec<SessionUsage>,
    /// How old the sample is, in milliseconds.
    pub age_ms: u64,
}

/// A tree's CPU (nanoseconds, with reaped children) and resident bytes.
pub(crate) fn fold(procs: &[Proc]) -> (u64, u64) {
    procs.iter().fold((0u64, 0u64), |(cpu, rss), p| {
        (cpu.saturating_add(p.cpu_ns), rss.saturating_add(p.rss_bytes))
    })
}

/// The cores a tree used between two readings of its CPU `elapsed` apart. A drop (a child that
/// left the tree unreaped, a reused pid) reads as 0, never negative.
pub(crate) fn cores(before_ns: u64, now_ns: u64, elapsed: Duration) -> f64 {
    let secs = elapsed.as_secs_f64();
    if secs <= 0.0 {
        return 0.0;
    }
    Duration::from_nanos(now_ns.saturating_sub(before_ns)).as_secs_f64() / secs
}

/// The average after a reading `dt` after the last, with time constant `tau`; the first reading
/// is the average.
pub(crate) fn ewma(prev: Option<f64>, reading: f64, dt: Duration, tau: Duration) -> f64 {
    let Some(prev) = prev else { return reading };
    let tau = tau.as_secs_f64();
    if tau <= 0.0 {
        return reading;
    }
    let alpha = 1.0 - (-dt.as_secs_f64() / tau).exp();
    prev + alpha * (reading - prev)
}

/// A Linux `/proc/PID/stat` record's fields after the command name (field 3 first) as a
/// [`Proc`]: `tick_ns` nanoseconds per clock tick, `page` bytes per page. utime is field 14,
/// stime 15, cutime 16, cstime 17, rss (pages) 24; state (field 3) must be there.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub(crate) fn parse_stat(pid: u32, f: &[impl AsRef<str>], tick_ns: u64, page: u64) -> Option<Proc> {
    f.first()?;
    // A field that is missing or negative (rss of a kernel thread) reads 0.
    let num = |i: usize| f.get(i).and_then(|v| v.as_ref().parse::<u64>().ok());
    let ticks =
        [11, 12, 13, 14].iter().fold(0u64, |sum, &i| sum.saturating_add(num(i).unwrap_or(0)));
    let rss_pages = num(21).unwrap_or(0);
    Some(Proc {
        pid,
        cpu_ns: ticks.saturating_mul(tick_ns),
        rss_bytes: rss_pages.saturating_mul(page),
    })
}

/// What the sampler keeps between samples.
#[derive(Default)]
struct State {
    at: Option<Instant>,
    last: AgentsUsage,
    /// Per root pid: its tree's CPU at the last sample.
    root_cpu: HashMap<u32, u64>,
    /// Per session: its `cpu_cores` average.
    avg: HashMap<String, f64>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

/// The sessions' use now, or the cached one when the last sample is under [`MIN_INTERVAL`] old.
/// Blocking: call it off the async runtime.
pub(crate) fn sample(sessions: Vec<Roots>) -> AgentsUsage {
    let mut guard = STATE.lock().unwrap_or_else(|e| e.into_inner());
    let state = guard.get_or_insert_with(State::default);
    let now = Instant::now();
    if let Some(at) = state.at
        && now.duration_since(at) < MIN_INTERVAL
    {
        let mut cached = state.last.clone();
        cached.age_ms = u64::try_from(now.duration_since(at).as_millis()).unwrap_or(u64::MAX);
        return cached;
    }
    let reader = imp::Reader::new();
    let readings: Vec<(Roots, Vec<(u32, u64, u64)>)> = sessions
        .into_iter()
        .map(|s| {
            let trees = s.pids.iter().map(|&root| {
                let procs = reader.tree(root);
                let (cpu, rss) = fold(&procs);
                (root, cpu, rss)
            });
            let trees: Vec<_> = trees.filter(|(_, cpu, rss)| *cpu > 0 || *rss > 0).collect();
            (s, trees)
        })
        .collect();
    let dt = state.at.map(|at| now.duration_since(at));
    *state = advance(std::mem::take(state), readings, now, dt);
    state.last.clone()
}

/// The next state from this sample's readings: per session its roots' `(pid, cpu_ns, rss)`.
/// A root seen last time adds its CPU since then; a new root only sets its baseline (its CPU
/// before now is not this window's).
fn advance(
    prev: State,
    readings: Vec<(Roots, Vec<(u32, u64, u64)>)>,
    now: Instant,
    dt: Option<Duration>,
) -> State {
    let mut next = State { at: Some(now), ..State::default() };
    let mut sessions = Vec::new();
    for (roots, trees) in readings {
        if trees.is_empty() {
            continue;
        }
        let mut used = 0u64;
        let mut known = false;
        let mut rss = 0u64;
        for &(pid, cpu, bytes) in &trees {
            if let Some(&before) = prev.root_cpu.get(&pid) {
                used = used.saturating_add(cpu.saturating_sub(before));
                known = true;
            }
            next.root_cpu.insert(pid, cpu);
            rss = rss.saturating_add(bytes);
        }
        let prior = prev.avg.get(&roots.id).copied();
        let avg = match dt {
            Some(dt) if known => Some(ewma(prior, cores(0, used, dt), dt, EWMA_TAU)),
            _ => prior,
        };
        if let Some(avg) = avg {
            next.avg.insert(roots.id.clone(), avg);
        }
        let load =
            SessionLoad { active: roots.active, cpu_cores: avg.unwrap_or(0.0), rss_bytes: rss };
        sessions.push(SessionUsage { id: roots.id, load });
    }
    sessions.sort_by(|a, b| b.load.cpu_cores.total_cmp(&a.load.cpu_cores).then(a.id.cmp(&b.id)));
    next.last = AgentsUsage {
        cpu_cores: sessions.iter().map(|s| s.load.cpu_cores).sum(),
        rss_bytes: sessions.iter().map(|s| s.load.rss_bytes).sum(),
        sessions,
        age_ms: 0,
    };
    next
}

#[cfg(target_os = "linux")]
mod imp {
    use super::{Proc, parse_stat};

    pub(super) struct Reader {
        tick_ns: u64,
        page: u64,
    }

    impl Reader {
        pub(super) fn new() -> Self {
            // SAFETY: sysconf reads a constant.
            let (hz, page) =
                unsafe { (libc::sysconf(libc::_SC_CLK_TCK), libc::sysconf(libc::_SC_PAGESIZE)) };
            let hz = u64::try_from(hz).ok().filter(|h| *h > 0).unwrap_or(100);
            let page = u64::try_from(page).ok().filter(|p| *p > 0).unwrap_or(4096);
            Self { tick_ns: 1_000_000_000u64.checked_div(hz).unwrap_or(10_000_000), page }
        }

        fn read(&self, pid: u32) -> Option<Proc> {
            let fields = crate::cpu_class::stat_fields(pid)?;
            parse_stat(pid, &fields, self.tick_ns, self.page)
        }

        pub(super) fn tree(&self, root: u32) -> Vec<Proc> {
            crate::cpu_class::own_tree(root).into_iter().filter_map(|pid| self.read(pid)).collect()
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::Proc;

    pub(super) struct Reader {
        numer: u128,
        denom: u128,
    }

    impl Reader {
        // The Mach timebase's struct and call are deprecated in favour of the `mach2` crate,
        // which acpmux does not depend on (as `cpu_class.rs`).
        #[allow(deprecated)]
        pub(super) fn new() -> Self {
            let mut base = libc::mach_timebase_info { numer: 1, denom: 1 };
            // SAFETY: the call fills the struct it is given.
            let ok = unsafe { libc::mach_timebase_info(&mut base) } == 0;
            if ok && base.denom != 0 {
                Self { numer: u128::from(base.numer), denom: u128::from(base.denom) }
            } else {
                Self { numer: 1, denom: 1 }
            }
        }

        fn ns(&self, abs: u64) -> u64 {
            let ns = u128::from(abs).saturating_mul(self.numer).checked_div(self.denom);
            ns.and_then(|ns| u64::try_from(ns).ok()).unwrap_or(u64::MAX)
        }

        fn read(&self, pid: u32) -> Option<Proc> {
            let id = libc::c_int::try_from(pid).ok().filter(|p| *p > 0)?;
            let mut info = std::mem::MaybeUninit::<libc::rusage_info_v2>::zeroed();
            // SAFETY: the buffer is a rusage_info_v2, the struct RUSAGE_INFO_V2 writes.
            let rc = unsafe {
                libc::proc_pid_rusage(id, libc::RUSAGE_INFO_V2, info.as_mut_ptr().cast())
            };
            if rc != 0 {
                return None;
            }
            // SAFETY: the call succeeded and filled the integer-only struct.
            let info = unsafe { info.assume_init() };
            let abs = info
                .ri_user_time
                .saturating_add(info.ri_system_time)
                .saturating_add(info.ri_child_user_time)
                .saturating_add(info.ri_child_system_time);
            Some(Proc { pid, cpu_ns: self.ns(abs), rss_bytes: info.ri_resident_size })
        }

        pub(super) fn tree(&self, root: u32) -> Vec<Proc> {
            crate::cpu_class::own_tree(root).into_iter().filter_map(|pid| self.read(pid)).collect()
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod imp {
    use super::Proc;

    pub(super) struct Reader;

    impl Reader {
        pub(super) fn new() -> Self {
            Self
        }

        pub(super) fn tree(&self, _root: u32) -> Vec<Proc> {
            Vec::new()
        }
    }
}

#[cfg(test)]
#[path = "session_usage_tests.rs"]
mod tests;
