//! The `starved` leg: the daemon itself starved, not only its host (a free 32-core host at load
//! 305 left send p95 at 123 ms and no peer dropped, so host150 cannot show a fix working).
//!
//! - CPU, by pinning: the daemon's threads (and its children) are pinned to
//!   `ACPMUX_DURESS_STARVE_CORES` cores (default 1), and `ACPMUX_DURESS_STARVE_X` busy loops a
//!   core (default 40: at 1 core x40 send p95 crossed 500 ms on an 8-CPU runner; at 2 cores
//!   x20 it did not) plus the fork storm run pinned to the same cores. `ACPMUX_DURESS_STARVE_IDLE=1` also puts the daemon's threads in SCHED_IDLE
//!   (they run only when its cores have nothing else to run). Pinning, not a CPU limit, because
//!   it needs no cgroup; `ACPMUX_DURESS_STARVE_CPU_MAX` (e.g. `50000 1000000`) adds a cgroup
//!   `cpu.max` when the memory cgroup below works.
//! - Memory, with no systemd: a cgroup v2 child of the daemon's own cgroup with `memory.high`
//!   (`ACPMUX_DURESS_STARVE_MEMORY_HIGH`, default 96M, under the ~140 MB a 40-peer daemon held)
//!   holding the daemon. Every step it could not take is in the row's `starved.cgroup.steps`.
//! - Network: every peer proxy holds each chunk `ACPMUX_DURESS_STARVE_DELAY_MS` (default 40) plus
//!   up to `ACPMUX_DURESS_STARVE_JITTER_MS` (default 40), and every
//!   `ACPMUX_DURESS_STARVE_STALL_EVERY_S` (default 15) holds every peer's frames at once for
//!   `ACPMUX_DURESS_STARVE_STALL_MS` (default 3500), the relayed shape of the case.
//!
//! The row's `starved` field says what was applied and `daemonRunqueueWaitMsPerSec` how long the
//! daemon's threads waited for a CPU (from `/proc/PID/task/*/schedstat`, summed over threads).
use super::*;
use std::sync::atomic::Ordering::Relaxed;

pub(super) const LEG: &str = "starved";
/// Peers in the leg (as host150).
pub(super) const PEERS: usize = 40;
/// What the leg's stressors may run past the knobs' cap: the settle before the clock.
pub(super) const SETTLE: Duration = Duration::from_secs(10);

static DELAY_MS: AtomicU64 = AtomicU64::new(0);
static JITTER_MS: AtomicU64 = AtomicU64::new(0);
static STALL_UNTIL: Mutex<Option<Instant>> = Mutex::new(None);
static SEED: AtomicU64 = AtomicU64::new(0x9E37_79B9_7F4A_7C15);

fn next_rand() -> u64 {
    let step = |mut x: u64| {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let old = SEED.fetch_update(Relaxed, Relaxed, |x| Some(step(x))).unwrap_or(1);
    step(old)
}

/// How long a proxy holds the chunk it just read before writing it on: the delay, the jitter
/// and, while a stall is on, the stall's end. Zero outside the starved leg.
pub(super) fn hold() -> Duration {
    let (delay, jitter) = (DELAY_MS.load(Relaxed), JITTER_MS.load(Relaxed));
    let ms = delay + if jitter > 0 { next_rand() % (jitter + 1) } else { 0 };
    let mut hold = Duration::from_millis(ms);
    if let Some(until) = *STALL_UNTIL.lock().unwrap() {
        hold = hold.max(until.saturating_duration_since(Instant::now()));
    }
    hold
}

// ---------------------------------------------------------------------------------------------
// CPU.

fn allowed_cpus(pid: i32) -> Vec<usize> {
    // SAFETY: a zeroed cpu_set_t is a valid empty set; the kernel fills it.
    let mut set: libc::cpu_set_t = unsafe { std::mem::zeroed() };
    // SAFETY: `set` is a live cpu_set_t of the size passed.
    let ok = unsafe { libc::sched_getaffinity(pid, size_of::<libc::cpu_set_t>(), &mut set) } == 0;
    // SAFETY: CPU_ISSET reads the set within its size.
    (0..libc::CPU_SETSIZE as usize).filter(|c| ok && unsafe { libc::CPU_ISSET(*c, &set) }).collect()
}

fn set_affinity(tid: i32, cpus: &[usize]) -> Result<(), String> {
    // SAFETY: as in `allowed_cpus`.
    let mut set: libc::cpu_set_t = unsafe { std::mem::zeroed() };
    for c in cpus {
        // SAFETY: `c` is below CPU_SETSIZE (it came from `allowed_cpus`).
        unsafe { libc::CPU_SET(*c, &mut set) };
    }
    // SAFETY: `set` is a live cpu_set_t of the size passed.
    if unsafe { libc::sched_setaffinity(tid, size_of::<libc::cpu_set_t>(), &set) } == 0 {
        Ok(())
    } else {
        Err(format!("sched_setaffinity({tid}): {}", std::io::Error::last_os_error()))
    }
}

fn set_idle(tid: i32) -> Result<(), String> {
    let param = libc::sched_param { sched_priority: 0 };
    // SAFETY: `param` is a live sched_param; SCHED_IDLE takes priority 0.
    if unsafe { libc::sched_setscheduler(tid, libc::SCHED_IDLE, &param) } == 0 {
        Ok(())
    } else {
        Err(format!("SCHED_IDLE({tid}): {}", std::io::Error::last_os_error()))
    }
}

/// The threads of `pid` and of every process under it.
fn tasks(pid: u32) -> Vec<i32> {
    let mut pids: Vec<i32> = vec![pid as i32];
    pids.extend(descendants(pid));
    pids.iter()
        .flat_map(|p| {
            std::fs::read_dir(format!("/proc/{p}/task"))
                .into_iter()
                .flatten()
                .flatten()
                .filter_map(|e| e.file_name().to_str()?.parse::<i32>().ok())
                .collect::<Vec<_>>()
        })
        .collect()
}

/// Nanoseconds the threads of `pid` (and its children) waited on a run queue, summed. Threads
/// that ended took theirs with them: a lower bound.
pub(super) fn runqueue_wait_ns(pid: u32) -> u64 {
    tasks(pid)
        .iter()
        .filter_map(|t| {
            let s = std::fs::read_to_string(format!("/proc/{t}/schedstat")).ok()?;
            s.split_whitespace().nth(1)?.parse::<u64>().ok()
        })
        .sum()
}

/// A stressor whose processes run on `cpus` only: the spawning thread is pinned while it forks
/// (a child takes its parent thread's affinity), then set back.
fn spawn_pinned(
    name: &str,
    script: &str,
    cap: Duration,
    cpus: &[usize],
) -> Result<Stressor, String> {
    let before = allowed_cpus(0);
    set_affinity(0, cpus)?;
    let s = Stressor::spawn(name, script, cap).map_err(|e| format!("{name}: spawn failed: {e}"));
    set_affinity(0, &before).map_err(|e| format!("restoring the bench thread's cpus: {e}"))?;
    s
}

// ---------------------------------------------------------------------------------------------
// Memory: a cgroup v2 child holding the daemon.

struct Cgroup {
    dir: PathBuf,
    parent: PathBuf,
}

impl Cgroup {
    /// Moves what is left in it back to its parent, then removes it.
    fn remove(&self) -> Result<(), String> {
        let procs = std::fs::read_to_string(self.dir.join("cgroup.procs")).unwrap_or_default();
        for p in procs.split_whitespace() {
            let _ = std::fs::write(self.parent.join("cgroup.procs"), p);
        }
        std::fs::remove_dir(&self.dir).map_err(|e| format!("rmdir {}: {e}", self.dir.display()))
    }
}

fn cgroup_setup(
    daemon_pid: u32,
    high: &str,
    cpu_max: Option<&str>,
    steps: &mut Vec<String>,
) -> Option<Cgroup> {
    match std::fs::read_to_string("/sys/fs/cgroup/cgroup.controllers") {
        Ok(c) => steps.push(format!("cgroup v2; root controllers: {}", c.trim())),
        Err(e) => {
            steps.push(format!("no cgroup v2 at /sys/fs/cgroup: {e}"));
            return None;
        }
    }
    let Some(own) = cgroup_dir(daemon_pid) else {
        steps.push("the daemon's cgroup is unreadable (/proc/PID/cgroup)".into());
        return None;
    };
    let subtree = std::fs::read_to_string(own.join("cgroup.subtree_control")).unwrap_or_default();
    steps.push(format!("daemon's cgroup {}: subtree_control [{}]", own.display(), subtree.trim()));
    let mut want = vec!["memory"];
    if cpu_max.is_some() {
        want.push("cpu");
    }
    for c in want {
        if subtree.split_whitespace().any(|s| s == c) {
            continue;
        }
        match std::fs::write(own.join("cgroup.subtree_control"), format!("+{c}")) {
            Ok(()) => steps.push(format!("enabled +{c} for its children")),
            Err(e) => steps.push(format!(
                "cannot enable +{c} for its children: {e} (a cgroup that holds processes, here \
                 the runner's, cannot hand domain controllers to children)"
            )),
        }
    }
    let dir = own.join(format!("duress-starved-{}", std::process::id()));
    if let Err(e) = std::fs::create_dir(&dir) {
        steps.push(format!("mkdir {}: {e}", dir.display()));
        return None;
    }
    let cg = Cgroup { dir, parent: own };
    let fail = |steps: &mut Vec<String>, why: String| {
        steps.push(why);
        if let Err(e) = cg.remove() {
            steps.push(e);
        }
    };
    if !cg.dir.join("memory.high").exists() {
        fail(steps, "the child has no memory.high: memory is not enabled for it".into());
        return None;
    }
    if let Err(e) = std::fs::write(cg.dir.join("memory.high"), high) {
        fail(steps, format!("memory.high={high}: {e}"));
        return None;
    }
    steps.push(format!("memory.high={high}"));
    if let Some(m) = cpu_max {
        match std::fs::write(cg.dir.join("cpu.max"), m) {
            Ok(()) => steps.push(format!("cpu.max={m}")),
            Err(e) => steps.push(format!("cpu.max={m}: {e}")),
        }
    }
    let mut pids = vec![daemon_pid as i32];
    pids.extend(descendants(daemon_pid));
    for p in pids {
        if let Err(e) = std::fs::write(cg.dir.join("cgroup.procs"), p.to_string()) {
            fail(steps, format!("moving pid {p} into the child: {e}"));
            return None;
        }
    }
    steps.push("daemon and its children moved in".into());
    Some(cg)
}

// ---------------------------------------------------------------------------------------------
// The leg.

pub(super) struct Starved {
    cpus: Vec<usize>,
    loops: usize,
    idle: bool,
    pinned: usize,
    errors: Vec<String>,
    cgroup: Option<Cgroup>,
    steps: Vec<String>,
    high: String,
    high_events_start: Option<u64>,
    delay_ms: u64,
    jitter_ms: u64,
    stall: Duration,
    stall_every: Duration,
    stop: Arc<AtomicBool>,
    driver: Option<std::thread::JoinHandle<Vec<f64>>>,
    t0: Instant,
    runq0: u64,
    daemon_pid: u32,
}

impl Starved {
    /// Pins, caps and shapes, then starts the stall clock. Stressors go in `stressors`; what it
    /// could not do goes in `notes` too.
    pub(super) fn start(
        daemon_pid: u32,
        cap: Duration,
        stressors: &mut Vec<Stressor>,
        notes: &mut Vec<String>,
    ) -> Self {
        let n_cores = env_or("ACPMUX_DURESS_STARVE_CORES", 1usize).max(1);
        let x = env_or("ACPMUX_DURESS_STARVE_X", 40usize).max(1);
        let idle = env_or("ACPMUX_DURESS_STARVE_IDLE", 0u8) == 1;
        let high = std::env::var("ACPMUX_DURESS_STARVE_MEMORY_HIGH")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .unwrap_or_else(|| "96M".into());
        let cpu_max =
            std::env::var("ACPMUX_DURESS_STARVE_CPU_MAX").ok().filter(|v| !v.trim().is_empty());
        let mut errors = vec![];
        // CPU: the daemon's first allowed cores.
        let cpus: Vec<usize> = allowed_cpus(daemon_pid as i32).into_iter().take(n_cores).collect();
        let mut pinned = 0;
        for t in tasks(daemon_pid) {
            match set_affinity(t, &cpus).and_then(|()| if idle { set_idle(t) } else { Ok(()) }) {
                Ok(()) => pinned += 1,
                Err(e) => errors.push(e),
            }
        }
        let loops = x * cpus.len();
        for (name, script) in
            [("starved-cpu", super::super::cpu_script(loops)), ("starved-spawns", spawn_script())]
        {
            match spawn_pinned(name, &script, cap, &cpus) {
                Ok(s) => stressors.push(s),
                Err(e) => errors.push(e),
            }
        }
        // Memory.
        let mut steps = vec![];
        let cgroup = cgroup_setup(daemon_pid, &high, cpu_max.as_deref(), &mut steps);
        if cgroup.is_none() {
            notes.push(format!(
                "starved memory: not applied, no memory.high on the daemon: {}",
                steps.last().map_or("-", String::as_str)
            ));
        }
        let high_events_start = cgroup.as_ref().and_then(|c| memory_event(&c.dir, "high"));
        // Network.
        let delay_ms = env_or("ACPMUX_DURESS_STARVE_DELAY_MS", 40u64);
        let jitter_ms = env_or("ACPMUX_DURESS_STARVE_JITTER_MS", 40u64);
        let stall = Duration::from_millis(env_or("ACPMUX_DURESS_STARVE_STALL_MS", 3500u64));
        let stall_every =
            Duration::from_secs(env_or("ACPMUX_DURESS_STARVE_STALL_EVERY_S", 15u64).max(1));
        DELAY_MS.store(delay_ms, Relaxed);
        JITTER_MS.store(jitter_ms, Relaxed);
        let stop = Arc::new(AtomicBool::new(false));
        let t0 = Instant::now();
        let driver = (!stall.is_zero()).then(|| {
            let stop = stop.clone();
            std::thread::spawn(move || {
                // Stall starts, seconds from t0. The first comes half a period in.
                let mut at = vec![];
                let mut next = t0 + stall_every / 2;
                while !stop.load(Relaxed) && t0.elapsed() < cap {
                    let now = Instant::now();
                    if now >= next {
                        *STALL_UNTIL.lock().unwrap() = Some(now + stall);
                        at.push(t0.elapsed().as_secs_f64());
                        next = now + stall_every;
                    }
                    std::thread::sleep(
                        Duration::from_millis(50).min(next - Instant::now().min(next)),
                    );
                }
                *STALL_UNTIL.lock().unwrap() = None;
                at
            })
        });
        for e in &errors {
            notes.push(format!("starved: {e}"));
        }
        // The pinned loops take hold within a scheduler tick or two; give the cores a moment
        // so the window opens on starved daemon threads, read from their run-queue wait.
        let settle_by = Instant::now() + SETTLE;
        let w0 = runqueue_wait_ns(daemon_pid);
        let t_w0 = Instant::now();
        while Instant::now() < settle_by {
            std::thread::sleep(Duration::from_millis(500));
            let waited = runqueue_wait_ns(daemon_pid).saturating_sub(w0) as f64 / 1e6;
            // Starved: its threads waited more than a tenth of the wall clock since.
            if waited > ms_f(t_w0.elapsed()) * 0.1 && t_w0.elapsed() > Duration::from_secs(2) {
                break;
            }
        }
        Self {
            cpus,
            loops,
            idle,
            pinned,
            errors,
            cgroup,
            steps,
            high,
            high_events_start,
            delay_ms,
            jitter_ms,
            stall,
            stall_every,
            stop,
            driver,
            t0: Instant::now(),
            runq0: runqueue_wait_ns(daemon_pid),
            daemon_pid,
        }
    }

    /// The row's `starved` field and its run-queue wait (read at the window's end).
    pub(super) fn report(&self) -> Value {
        let secs = self.t0.elapsed().as_secs_f64().max(0.001);
        let waited_ms = runqueue_wait_ns(self.daemon_pid).saturating_sub(self.runq0) as f64 / 1e6;
        let high_end = self.cgroup.as_ref().and_then(|c| memory_event(&c.dir, "high"));
        json!({
            "cpu": {
                "how": if self.idle { "pinned + SCHED_IDLE" } else { "pinned" },
                "cpus": self.cpus, "busyLoops": self.loops,
                "loopsPerDaemonCore": self.loops as f64 / self.cpus.len().max(1) as f64,
                "daemonThreadsPinned": self.pinned, "errors": self.errors,
            },
            "daemonRunqueueWaitMsPerSec": waited_ms / secs,
            "cgroup": {
                "applied": self.cgroup.is_some(),
                "dir": self.cgroup.as_ref().map(|c| c.dir.display().to_string()),
                "memoryHigh": self.high,
                "memoryHighEvents": self.high_events_start.zip(high_end).map(|(a, b)| b.saturating_sub(a)),
                "memoryPressureAvg10": self.cgroup.as_ref().and_then(|c| memory_pressure(&c.dir)),
                "steps": self.steps,
            },
            "network": {
                "delayMs": self.delay_ms, "jitterMs": self.jitter_ms,
                "stallMs": ms_f(self.stall), "stallEverySecs": self.stall_every.as_secs_f64(),
            },
        })
    }

    /// Ends the stalls and shaping, and takes the cgroup down. Returns the stall starts (seconds
    /// from the leg's start) and what it could not remove.
    pub(super) fn stop(&mut self) -> (Vec<f64>, Vec<String>) {
        self.stop.store(true, Relaxed);
        let at = self.driver.take().and_then(|d| d.join().ok()).unwrap_or_default();
        DELAY_MS.store(0, Relaxed);
        JITTER_MS.store(0, Relaxed);
        *STALL_UNTIL.lock().unwrap() = None;
        let errs = self.cgroup.take().and_then(|c| c.remove().err()).into_iter().collect();
        (at, errs)
    }
}
