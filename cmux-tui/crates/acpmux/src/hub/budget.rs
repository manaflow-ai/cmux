#![cfg(unix)]
//! Part of `Hub`; see `hub/mod.rs`. Each session's resource budget: the
//! guard for the harness limits acpmux lifts (`harness_limits.rs`), which
//! allow as many subagents and background commands as the agent starts.
//! Counting them would cap honest work; a runaway shows in what the
//! session's processes use.
//!
//! Every `interval` the watcher reads the process table once and sums each
//! live harness and everything under it. Over the memory budget, the largest
//! process the agent started (a runaway shell, a subagent's build) is
//! killed and the chat says so. The agent itself is never killed: neither
//! the harness nor anything started with it (`launch_grace`), such as the
//! agent a launcher like `sr` or `coderouter` runs, or its MCP servers. When
//! those alone are over the budget, stopping work under them would not help,
//! so nothing is killed. Over
//! the CPU budget for `CPU_STRIKES` samples in a row, the session's
//! processes run at a lower priority (`nice` 10), which costs nothing while
//! the machine is otherwise idle. Unix only: Windows has its own job limits
//! (a later landing).

use super::*;
use crate::harness_limits::SessionBudget;

/// Samples over the CPU budget in a row before the session is reniced.
const CPU_STRIKES: u32 = 3;
/// The priority an over-budget session's processes run at.
const NICE: i32 = 10;

/// One process from `ps`.
#[derive(Debug, Clone)]
struct Proc {
    pid: u32,
    ppid: u32,
    rss_bytes: u64,
    /// CPU time used so far, in seconds.
    cpu_secs: f64,
    /// Seconds since it started.
    age_secs: f64,
    /// Start time, so a reused pid is never taken for this one.
    start: String,
    command: String,
}

/// Every process, from `ps`; empty when `ps` fails.
async fn process_table() -> Vec<Proc> {
    let out = tokio::process::Command::new("ps")
        .args(["-axww", "-o", "pid=,ppid=,rss=,time=,etime=,lstart=,comm="])
        .env("LC_ALL", "C")
        .output()
        .await;
    let Ok(out) = out else { return Vec::new() };
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut f = line.split_whitespace();
            let pid = f.next()?.parse().ok()?;
            let ppid = f.next()?.parse().ok()?;
            let rss_kb: u64 = f.next()?.parse().ok()?;
            let cpu_secs = clock_secs(f.next()?)?;
            let age_secs = clock_secs(f.next()?)?;
            // lstart is five words: "Tue Oct 14 08:24:59 2026".
            let start = f.by_ref().take(5).collect::<Vec<_>>().join(" ");
            let command = f.collect::<Vec<_>>().join(" ");
            Some(Proc { pid, ppid, rss_bytes: rss_kb * 1024, cpu_secs, age_secs, start, command })
        })
        .collect()
}

/// `ps`'s CPU and elapsed times: `[dd-][hh:]mm:ss[.cc]` (macOS prints
/// `m:ss.cc`, Linux `[dd-]hh:mm:ss`).
fn clock_secs(text: &str) -> Option<f64> {
    let (days, clock) = match text.split_once('-') {
        Some((d, rest)) => (d.parse::<f64>().ok()?, rest),
        None => (0.0, text),
    };
    let mut secs = 0.0;
    for part in clock.split(':') {
        secs = secs * 60.0 + part.parse::<f64>().ok()?;
    }
    Some(days * 86_400.0 + secs)
}

/// `root` and every process under it.
fn tree(table: &[Proc], root: u32) -> Vec<&Proc> {
    let mut found: Vec<&Proc> = table.iter().filter(|p| p.pid == root).collect();
    let mut i = 0;
    while i < found.len() {
        let parent = found[i].pid;
        for p in table.iter().filter(|p| p.ppid == parent && p.pid != root) {
            if !found.iter().any(|f| f.pid == p.pid) {
                found.push(p);
            }
        }
        i += 1;
    }
    found
}

/// What the watcher remembers of one session between samples.
#[derive(Debug, Default)]
struct BudgetState {
    /// CPU seconds the tree had used, by pid and start, at the last sample.
    cpu: HashMap<(u32, String), f64>,
    at: Option<std::time::Instant>,
    strikes: u32,
    reniced: bool,
    /// The harness these are of; a new one starts over.
    root: u32,
}

impl Hub {
    /// Checks each session's budget (`Config::session_budget`) until the hub
    /// is gone or stopping. Started with the idle reaper.
    pub(super) async fn budget_loop(weak: std::sync::Weak<Self>) {
        let mut states: HashMap<String, BudgetState> = HashMap::new();
        loop {
            let interval = {
                let Some(hub) = weak.upgrade() else { return };
                if hub.stopping.load(Ordering::SeqCst) {
                    return;
                }
                let budget = hub.config.read().await.session_budget;
                if let Some(budget) = budget {
                    hub.check_budgets(budget, &mut states).await;
                }
                budget.map_or(std::time::Duration::from_secs(10), |b| b.interval)
            };
            tokio::time::sleep(interval).await;
        }
    }

    /// One sample of every session with a live harness.
    async fn check_budgets(
        &self,
        budget: SessionBudget,
        states: &mut HashMap<String, BudgetState>,
    ) {
        // Each live harness and the process it must be a child of: its agent
        // host, or this daemon for a direct child.
        let mut live = Vec::new();
        for session in self.sessions() {
            let child = session.child.lock().await.clone();
            let Some(child) = child else { continue };
            let Some(pid) = child.pid.filter(|p| *p > 1) else { continue };
            if !child.is_alive().await {
                continue;
            }
            let parent = child.host_record().map_or(std::process::id(), |r| r.host_pid);
            live.push((session, pid, parent));
        }
        // Ended sessions leave nothing behind.
        states.retain(|id, _| live.iter().any(|(s, _, _)| s.id == *id));
        if live.is_empty() {
            return;
        }
        let table = process_table().await;
        let now = std::time::Instant::now();
        for (session, root, parent) in live {
            // A pid that is no longer the harness (it ended and the pid went
            // to another process) is not this session's.
            if !table.iter().any(|p| p.pid == root && p.ppid == parent) {
                continue;
            }
            let procs = tree(&table, root);
            let rss: u64 = procs.iter().map(|p| p.rss_bytes).sum();
            if budget.memory_bytes > 0 && rss > budget.memory_bytes {
                self.over_memory(&session, root, &procs, rss, budget);
            }
            if budget.cpu_cores > 0.0 {
                let state = states.entry(session.id.clone()).or_default();
                if state.root != root {
                    *state = BudgetState { root, ..Default::default() };
                }
                self.check_cpu(&session, state, &procs, now, budget.cpu_cores);
            }
        }
    }
    /// Kills the largest process the agent started and notes it in the
    /// chat.
    fn over_memory(
        &self,
        session: &Session,
        root: u32,
        procs: &[&Proc],
        rss: u64,
        budget: SessionBudget,
    ) {
        let Some(harness) = procs.iter().find(|p| p.pid == root) else { return };
        let grace = budget.launch_grace.as_secs_f64();
        let (work, agent): (Vec<&Proc>, Vec<&Proc>) = procs
            .iter()
            .copied()
            .partition(|p| p.pid != root && harness.age_secs - p.age_secs >= grace);
        let agent_rss: u64 = agent.iter().map(|p| p.rss_bytes).sum();
        let Some(largest) = work.iter().max_by_key(|p| p.rss_bytes).copied() else { return };
        if agent_rss > budget.memory_bytes {
            // The agent alone is over: the agent is not ended for its memory.
            return;
        }
        // Nor is a process too small to matter (a `git` call) killed: it
        // must hold the overage, or a tenth of the budget.
        if largest.rss_bytes < (rss - budget.memory_bytes).min(budget.memory_bytes / 10) {
            return;
        }
        let Ok(pid) = i32::try_from(largest.pid) else { return };
        let budget = budget.memory_bytes;
        tracing::warn!(session = %session.id, pid, rss, budget, "session over its memory budget: killing its largest process");
        // SAFETY: kill only signals. The pid was read under this session's
        // harness (checked to be the child of its host or of this daemon) an
        // instant ago; a process that exited since and whose pid was reused
        // in that instant is the case it cannot rule out.
        unsafe { libc::kill(pid, libc::SIGKILL) };
        self.append(
            session,
            "mux",
            "budget_exceeded",
            json!({"resource": "memory", "usedBytes": rss, "budgetBytes": budget,
                   "stopped": {"pid": largest.pid, "command": largest.command, "rssBytes": largest.rss_bytes}}),
        );
    }

    /// Lowers the session's priority once it kept more cores busy than its
    /// budget for `CPU_STRIKES` samples in a row.
    fn check_cpu(
        &self,
        session: &Session,
        state: &mut BudgetState,
        procs: &[&Proc],
        now: std::time::Instant,
        cores: f64,
    ) {
        let current: HashMap<(u32, String), f64> =
            procs.iter().map(|p| ((p.pid, p.start.clone()), p.cpu_secs)).collect();
        if let Some(at) = state.at {
            let elapsed = now.duration_since(at).as_secs_f64();
            let used: f64 = current
                .iter()
                .map(|(k, secs)| (secs - state.cpu.get(k).copied().unwrap_or(0.0)).max(0.0))
                .sum();
            let busy = if elapsed > 0.0 { used / elapsed } else { 0.0 };
            state.strikes = if busy > cores { state.strikes + 1 } else { 0 };
            if state.strikes >= CPU_STRIKES && !state.reniced {
                state.reniced = true;
                for p in procs {
                    renice(p.pid);
                }
                tracing::warn!(session = %session.id, busy, cores, "session over its CPU budget: lower priority");
                self.append(
                    session,
                    "mux",
                    "budget_exceeded",
                    json!({"resource": "cpu", "usedCores": busy, "budgetCores": cores, "nice": NICE}),
                );
            }
        }
        state.cpu = current;
        state.at = Some(now);
    }
}

/// Runs `pid` at `NICE`: on Linux every thread of it (a priority there is
/// per thread, and node's and tokio's workers already run), elsewhere the
/// process.
fn renice(pid: u32) {
    #[cfg(target_os = "linux")]
    let ids: Vec<u32> = std::fs::read_dir(format!("/proc/{pid}/task"))
        .map(|tasks| tasks.filter_map(|t| t.ok()?.file_name().to_str()?.parse().ok()).collect())
        .unwrap_or_default();
    #[cfg(not(target_os = "linux"))]
    let ids = [pid];
    for id in ids {
        // SAFETY: setpriority only changes the scheduling of a process (or
        // thread) of the session's tree; another user's fails with EPERM.
        unsafe { libc::setpriority(libc::PRIO_PROCESS, id as libc::id_t, NICE) };
    }
}
