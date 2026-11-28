//! A cgroup's working set, measured by stepping it down (RFD 0182 B11, after TMO's Senpai).
//!
//! AutoSize shrinks a VM after 2 idle hours to a guess (40% headroom over use), because nothing
//! measures what the machine actually needs. This probe does: it asks the kernel to reclaim a
//! small step of a cgroup's memory (`memory.reclaim`, Linux 5.19+), waits, and counts the pages
//! that come straight back (`workingset_refault_*` in `memory.stat`). While little comes back, what
//! it took was cold. When a step's refaults pass a share of the step, or the kernel finds nothing
//! more it can reclaim, the cgroup's size is its working set.
//!
//! - Writable without root: acpmux's session slices are delegated to the user manager, so the
//!   probe works on `acpmuxsessions.slice` (the default) and any slice under it. DAMON would read
//!   the same answer more cheaply but needs root on our guests.
//! - Bounded: at most [`Probe::max_steps`] steps of [`Probe::settle_ms`] each (a minute by
//!   default), and never below [`Probe::floor_bytes`]. The cost is the refaults it causes: pages
//!   read back from disk once, on a machine that is idle when it is worth asking.
//! - Without swap the kernel can only reclaim file pages, so anonymous memory counts as working
//!   set: the answer is an upper bound there, which is the safe side for a shrink target.
//! - Reads and writes only the cgroup it is given; the stepping rule ([`next`]) is pure.

use serde::Serialize;

/// How the probe steps. Defaults: 2% of the cgroup per step (at least 16 MiB), 1 s to settle,
/// stop when a step's refaults pass 10% of it, 60 steps at most.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Probe {
    /// Each step asks for this share of the cgroup's current size, in parts per thousand.
    pub step_permille: u64,
    /// The smallest step.
    pub min_step_bytes: u64,
    /// Time between a step and reading its refaults.
    pub settle_ms: u64,
    /// Stop once a step's refaulted bytes pass this share of the step, in parts per thousand.
    pub refault_permille: u64,
    /// The most steps one probe takes.
    pub max_steps: u32,
    /// Never reclaim below this size.
    pub floor_bytes: u64,
}

impl Default for Probe {
    fn default() -> Self {
        Self {
            step_permille: 20,
            min_step_bytes: 16 << 20,
            settle_ms: 1000,
            refault_permille: 100,
            max_steps: 60,
            floor_bytes: 64 << 20,
        }
    }
}

/// One reading of the cgroup.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Sample {
    /// `memory.current`.
    pub current: u64,
    /// `workingset_refault_anon` + `workingset_refault_file` from `memory.stat`, in pages.
    pub refaults: u64,
}

/// Why a probe stopped.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Stop {
    /// The last step's refaults passed the threshold: the cgroup is at its working set.
    Refaults,
    /// The kernel reclaimed nothing more (what is left is in use, or anonymous without swap).
    NothingReclaimable,
    /// The next step would go under the floor.
    Floor,
    /// The step cap ran out before refaults rose: the working set is at most what is left.
    MaxSteps,
}

/// What the probe does next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Next {
    /// Ask the kernel to reclaim this many bytes.
    Reclaim(u64),
    /// Stop.
    Stop(Stop),
}

/// The step to take from `now`, given the step just taken (`last`, its bytes asked) and the
/// refaults counted since it (`refaulted_pages`). Pure.
pub fn next(probe: &Probe, now: Sample, last: Option<(u64, u64)>, steps: u32, page: u64) -> Next {
    if let Some((asked, refaulted_pages)) = last {
        let back = refaulted_pages.saturating_mul(page);
        let limit = asked.saturating_mul(probe.refault_permille) / 1000;
        if back > limit {
            return Next::Stop(Stop::Refaults);
        }
    }
    if steps >= probe.max_steps {
        return Next::Stop(Stop::MaxSteps);
    }
    let step = (now.current.saturating_mul(probe.step_permille) / 1000).max(probe.min_step_bytes);
    if now.current.saturating_sub(step) < probe.floor_bytes {
        return Next::Stop(Stop::Floor);
    }
    Next::Reclaim(step)
}

/// The probe's answer, as `acpmux machine working-set` prints it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    /// The cgroup under `/sys/fs/cgroup`.
    pub cgroup: String,
    /// Its size before the probe.
    pub start_bytes: u64,
    /// Its size when the probe stopped: the working set (an upper bound unless `stoppedBy` is
    /// `refaults`).
    pub working_set_bytes: u64,
    /// What the kernel reclaimed in all.
    pub reclaimed_bytes: u64,
    /// Pages that came back during the probe.
    pub refaulted_pages: u64,
    pub steps: u32,
    pub stopped_by: Stop,
    pub elapsed_ms: u64,
}

/// The cgroup files the probe touches; [`Kernel`] on a host, a fake in tests.
pub trait Cgroup {
    fn sample(&mut self) -> anyhow::Result<Sample>;
    /// Ask for `bytes` back. `Ok(false)`: the kernel could not reclaim them (EAGAIN).
    fn reclaim(&mut self, bytes: u64) -> anyhow::Result<bool>;
    fn settle(&mut self, ms: u64);
}

/// Step `cg` down until [`next`] stops.
pub fn run(probe: &Probe, cg: &mut dyn Cgroup, name: &str, page: u64) -> anyhow::Result<Report> {
    let started = std::time::Instant::now();
    let first = cg.sample()?;
    let mut now = first;
    let mut last = None;
    let mut steps = 0u32;
    let stopped_by = loop {
        match next(probe, now, last, steps, page) {
            Next::Stop(why) => break why,
            Next::Reclaim(bytes) => {
                let ok = cg.reclaim(bytes)?;
                steps = steps.saturating_add(1);
                cg.settle(probe.settle_ms);
                let after = cg.sample()?;
                if !ok {
                    now = after;
                    break Stop::NothingReclaimable;
                }
                last = Some((bytes, after.refaults.saturating_sub(now.refaults)));
                now = after;
            }
        }
    };
    Ok(Report {
        cgroup: name.to_string(),
        start_bytes: first.current,
        working_set_bytes: now.current,
        reclaimed_bytes: first.current.saturating_sub(now.current),
        refaulted_pages: now.refaults.saturating_sub(first.refaults),
        steps,
        stopped_by,
        elapsed_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
    })
}

/// The refault count from `memory.stat` text.
pub fn refaults(stat: &str) -> u64 {
    stat.lines()
        .filter_map(|line| line.split_once(' '))
        .filter(|(key, _)| matches!(*key, "workingset_refault_anon" | "workingset_refault_file"))
        .filter_map(|(_, value)| value.trim().parse::<u64>().ok())
        .fold(0u64, u64::saturating_add)
}

/// The default cgroup: `acpmuxsessions.slice` under this process's user manager, from
/// `/proc/self/cgroup` text (`0::/user.slice/user-1001.slice/user@1001.service/...`).
pub fn default_cgroup(proc_self_cgroup: &str) -> Option<String> {
    let path = proc_self_cgroup.lines().find_map(|line| line.strip_prefix("0::"))?;
    let end = path.find(".service")?.saturating_add(".service".len());
    let manager = path.get(..end)?;
    manager.contains("/user@").then(|| format!("{manager}/acpmuxsessions.slice"))
}

/// A cgroup v2 directory on this host.
#[cfg(target_os = "linux")]
pub struct Kernel {
    dir: std::path::PathBuf,
}

#[cfg(target_os = "linux")]
impl Kernel {
    /// `rel` is a path under `/sys/fs/cgroup`, such as `/user.slice/.../acpmuxsessions.slice`.
    pub fn open(rel: &str) -> anyhow::Result<Self> {
        let dir = std::path::Path::new("/sys/fs/cgroup").join(rel.trim_start_matches('/'));
        anyhow::ensure!(
            dir.join("memory.reclaim").exists(),
            "{} has no memory.reclaim (cgroup v2 on Linux 5.19 or later, memory controller on)",
            dir.display()
        );
        Ok(Self { dir })
    }
}

#[cfg(target_os = "linux")]
impl Cgroup for Kernel {
    fn sample(&mut self) -> anyhow::Result<Sample> {
        let current = std::fs::read_to_string(self.dir.join("memory.current"))?.trim().parse()?;
        let stat = std::fs::read_to_string(self.dir.join("memory.stat"))?;
        Ok(Sample { current, refaults: refaults(&stat) })
    }

    fn reclaim(&mut self, bytes: u64) -> anyhow::Result<bool> {
        match std::fs::write(self.dir.join("memory.reclaim"), bytes.to_string()) {
            Ok(()) => Ok(true),
            Err(e) if e.raw_os_error() == Some(libc::EAGAIN) => Ok(false),
            Err(e) => Err(anyhow::anyhow!("writing {}/memory.reclaim: {e}", self.dir.display())),
        }
    }

    fn settle(&mut self, ms: u64) {
        std::thread::sleep(std::time::Duration::from_millis(ms));
    }
}

/// `acpmux machine working-set`: probe `cgroup` (default [`default_cgroup`]) and print the report.
#[cfg(target_os = "linux")]
pub fn cli(cgroup: Option<String>, probe: Probe) -> anyhow::Result<Report> {
    let rel = match cgroup {
        Some(rel) => rel,
        None => {
            default_cgroup(&std::fs::read_to_string("/proc/self/cgroup")?).ok_or_else(|| {
                anyhow::anyhow!("no user manager in /proc/self/cgroup; pass --cgroup")
            })?
        }
    };
    let mut cg = Kernel::open(&rel)?;
    // SAFETY: sysconf reads a constant.
    let page = u64::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap_or(4096);
    run(&probe, &mut cg, &rel, page)
}

/// `memory.reclaim` is Linux's.
#[cfg(not(target_os = "linux"))]
pub fn cli(_cgroup: Option<String>, _probe: Probe) -> anyhow::Result<Report> {
    anyhow::bail!("the working-set probe needs Linux's cgroup v2 memory.reclaim")
}

#[cfg(test)]
#[path = "working_set_tests.rs"]
mod tests;
