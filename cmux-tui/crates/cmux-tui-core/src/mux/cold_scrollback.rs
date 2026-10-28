//! Cold scrollback (plans/cmux-next/chrome-parity/p07-memory.md).
//!
//! A terminal that no client views and that printed nothing for
//! [`COLD_SCROLLBACK_AFTER`] is compressed with ghostty-vt's lossless codec,
//! on one utility thread per mux. Its next access restores
//! it first (surface/terminal_runtime/cold_terminal.rs), so a read is
//! byte-identical. This is Chrome's tab discarding with its rules: only what
//! the person cannot see, decided by one policy with one timer, restored on
//! access (`chrome/browser/resource_coordinator/tab_manager.cc`,
//! `chrome/browser/performance_manager/policies/page_discarding_helper.cc`).
//!
//! - Full persistence mode compresses nothing: its segment files are the
//!   cold store there.
//! - Nothing is compressed under memory pressure. Compressing reads every
//!   page, and at warning the kernel may have compressed or swapped them
//!   already; reading them would bring them back. A due terminal waits one
//!   more period instead.
//! - One deadline per mux: the thread sleeps until the earliest unviewed
//!   terminal is due. With none it blocks, so an idle daemon wakes for
//!   nothing, until one of the events that can make a terminal due again:
//!   a terminal enters the catalog (created, restored or adopted), a view
//!   detaches, a cold terminal is restored, the persistence mode changes, or
//!   a terminal the codec refused prints.
//! - Off by default (daemon feature `coldScrollbackCompression`, read from
//!   the daemon's [`cmux_features::Snapshot`], so the signed `flags.json`
//!   `DisabledFeatures` list turns it off), and kept off until
//!   p07-memory-112 measures a gain of 2x or more over the macOS kernel
//!   compressor (plans/cmux-next/cold-scrollback-DESIGN.md). Chrome on macOS
//!   leaves idle pages to the kernel compressor.

use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};

use cmux_threads::ThreadQos;

use super::*;
use crate::supervised::{self, Fatal, ShutdownBehavior};
use crate::surface::{ColdFreeze, ThawWake};

/// Wakes the cold-scrollback worker; a send never blocks.
#[derive(Clone)]
pub(crate) struct ColdScrollbackWake(Sender<()>);

impl ColdScrollbackWake {
    pub(crate) fn wake(&self) {
        // The worker is gone only with its mux.
        let _ = self.0.send(());
    }
}

/// How long a terminal stays unviewed and quiet before it is compressed.
/// `DaemonBudget::cold_scrollback_after` replaces it.
pub(crate) const COLD_SCROLLBACK_AFTER: Duration = Duration::from_secs(10 * 60);

/// The kernel's memory pressure level.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MemoryPressure {
    Normal,
    Warning,
    Critical,
}

/// The inputs of one pass, injected so tests choose them.
#[derive(Clone, Copy)]
pub(crate) struct ColdPolicy {
    pub(crate) after: Duration,
    /// Read only when a terminal is due.
    pub(crate) pressure: fn() -> MemoryPressure,
}

impl ColdPolicy {
    fn daemon() -> Self {
        Self { after: COLD_SCROLLBACK_AFTER, pressure: kernel_pressure }
    }
}

/// One terminal as a pass observes it.
#[derive(Clone, Copy, Debug)]
pub(crate) struct ColdCandidate<'a> {
    pub(crate) terminal_id: &'a TerminalPublicId,
    /// Some client holds an attach stream on one of its views.
    pub(crate) viewed: bool,
    /// Newest attach epoch over its views; a change means a view came and went.
    pub(crate) attach_epoch: u64,
    /// When it last printed (`None`: never in this daemon).
    pub(crate) last_output: Option<Instant>,
    pub(crate) cold: bool,
}

#[derive(Debug)]
struct Tracked {
    /// Start of the unviewed period (or the last restore or busy check).
    since: Instant,
    attach_epoch: u64,
    cold: bool,
    /// The codec refused the terminal at this output; it is not asked again
    /// until the terminal prints.
    refused_at: Option<Option<Instant>>,
}

/// The idle bookkeeping of one mux, owned by its worker thread (no lock).
#[derive(Debug, Default)]
pub(crate) struct ColdTracker {
    terminals: HashMap<TerminalPublicId, Tracked>,
}

impl ColdTracker {
    /// Advance to `now` and return the terminals to compress.
    pub(crate) fn due(
        &mut self,
        now: Instant,
        after: Duration,
        candidates: &[ColdCandidate<'_>],
    ) -> Vec<TerminalPublicId> {
        let live: HashSet<&TerminalPublicId> = candidates.iter().map(|c| c.terminal_id).collect();
        self.terminals.retain(|terminal_id, _| live.contains(terminal_id));
        let mut due = Vec::new();
        for candidate in candidates {
            if candidate.viewed {
                self.terminals.remove(candidate.terminal_id);
                continue;
            }
            let entry = self.terminals.entry(candidate.terminal_id.clone()).or_insert(Tracked {
                since: now,
                attach_epoch: candidate.attach_epoch,
                cold: candidate.cold,
                refused_at: None,
            });
            // A view that came and went, or a restore, is activity.
            if entry.attach_epoch != candidate.attach_epoch || (entry.cold && !candidate.cold) {
                entry.since = now;
                entry.attach_epoch = candidate.attach_epoch;
            }
            entry.cold = candidate.cold;
            if entry.refused_at.is_some_and(|at| at != candidate.last_output) {
                entry.refused_at = None;
            }
            if Self::waiting(entry).is_some_and(|since| {
                now.saturating_duration_since(idle_since(since, candidate)) >= after
            }) {
                due.push(candidate.terminal_id.clone());
            }
        }
        due
    }

    /// Record what a compression attempt did.
    pub(crate) fn settle(
        &mut self,
        terminal_id: &TerminalPublicId,
        outcome: ColdFreeze,
        now: Instant,
        last_output: Option<Instant>,
    ) {
        let Some(entry) = self.terminals.get_mut(terminal_id) else { return };
        match outcome {
            ColdFreeze::Frozen { .. } | ColdFreeze::AlreadyCold => entry.cold = true,
            ColdFreeze::Busy | ColdFreeze::Viewed => entry.since = now,
            ColdFreeze::Refused(_) | ColdFreeze::InactiveScreenScrolled => {
                entry.refused_at = Some(last_output);
            }
        }
    }

    /// A due terminal waits one more period (memory pressure).
    pub(crate) fn defer(&mut self, terminal_ids: &[TerminalPublicId], now: Instant) {
        for terminal_id in terminal_ids {
            if let Some(entry) = self.terminals.get_mut(terminal_id) {
                entry.since = now;
            }
        }
    }

    /// When the earliest tracked hot terminal becomes due; `None` when there
    /// is none (the worker then blocks until a wake).
    pub(crate) fn next_deadline(
        &self,
        after: Duration,
        candidates: &[ColdCandidate<'_>],
    ) -> Option<Instant> {
        candidates
            .iter()
            .filter(|candidate| !candidate.viewed)
            .filter_map(|candidate| {
                let since = Self::waiting(self.terminals.get(candidate.terminal_id)?)?;
                idle_since(since, candidate).checked_add(after)
            })
            .min()
    }

    /// The start of a hot, not refused terminal's period.
    fn waiting(entry: &Tracked) -> Option<Instant> {
        (!entry.cold && entry.refused_at.is_none()).then_some(entry.since)
    }

    pub(crate) fn clear(&mut self) {
        self.terminals.clear();
    }
}

fn idle_since(since: Instant, candidate: &ColdCandidate<'_>) -> Instant {
    candidate.last_output.map_or(since, |output| output.max(since))
}

/// One catalog terminal, collected under the state lock.
struct Observed {
    terminal_id: TerminalPublicId,
    surface: Arc<Surface>,
    /// The placements that show it (their scroll anchors cross a restore).
    views: Vec<Arc<Surface>>,
    viewed: bool,
    attach_epoch: u64,
    last_output: Option<Instant>,
}

impl Mux {
    /// Start this owner's cold-scrollback worker when `features` turns
    /// `coldScrollbackCompression` on. Call it once the mux is built: a
    /// terminal that enters the catalog later (an adoption that finishes on
    /// its own thread, a create) wakes the worker.
    pub fn start_cold_scrollback(
        self: &Arc<Self>,
        features: &cmux_features::Snapshot,
    ) -> std::io::Result<()> {
        if !features.is_enabled(cmux_features::feature::COLD_SCROLLBACK_COMPRESSION) {
            return Ok(());
        }
        self.start_cold_scrollback_with(ColdPolicy::daemon())
    }

    pub(crate) fn start_cold_scrollback_with(
        self: &Arc<Self>,
        policy: ColdPolicy,
    ) -> std::io::Result<()> {
        let Some(wakes) = self.install_cold_scrollback_wake() else { return Ok(()) };
        let mux = Arc::downgrade(self);
        supervised::spawn_at(
            "mux-cold-scrollback",
            ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                run_cold_scrollback(&mux, &wakes, policy);
            },
        )?;
        Ok(())
    }

    /// Route every event that can make a terminal due to one channel; `None`
    /// when this mux has one already. The catalog hook is set under the state
    /// lock, so a terminal is either in the catalog the first pass reads or
    /// its insert wakes the worker.
    pub(crate) fn install_cold_scrollback_wake(self: &Arc<Self>) -> Option<Receiver<()>> {
        let (sender, wakes) = mpsc::channel::<()>();
        let wake = ColdScrollbackWake(sender);
        self.cold_scrollback_wake.set(wake.clone()).ok()?;
        // Every clone of the state shares this cell, so it is set once.
        let _ = self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .catalog_insert_wake
            .set(wake.clone());
        self.control_clients.add_detach_waker(move || wake.wake());
        Some(wakes)
    }

    /// Wake the worker, when there is one.
    pub(crate) fn wake_cold_scrollback(&self) {
        if let Some(wake) = self.cold_scrollback_wake.get() {
            wake.wake();
        }
    }

    /// One pass at `now`: compress every due terminal, and return when the
    /// next one is due (`None`: block until a wake).
    pub(crate) fn cold_scrollback_pass(
        &self,
        tracker: &mut ColdTracker,
        now: Instant,
        policy: ColdPolicy,
    ) -> Option<Instant> {
        if self.output_store.full_mode() {
            tracker.clear();
            return None;
        }
        let observed = self.cold_scrollback_terminals();
        let candidates: Vec<ColdCandidate<'_>> = observed
            .iter()
            .map(|terminal| ColdCandidate {
                terminal_id: &terminal.terminal_id,
                viewed: terminal.viewed,
                attach_epoch: terminal.attach_epoch,
                last_output: terminal.last_output,
                cold: terminal.surface.terminal_is_cold(),
            })
            .collect();
        let due = tracker.due(now, policy.after, &candidates);
        if !due.is_empty() {
            if (policy.pressure)() == MemoryPressure::Normal {
                let thawed = self.cold_scrollback_thaw_wake();
                for terminal in
                    observed.iter().filter(|terminal| due.contains(&terminal.terminal_id))
                {
                    let Some(outcome) =
                        terminal.surface.freeze_cold_terminal(&terminal.views, &thawed)
                    else {
                        continue;
                    };
                    tracker.settle(&terminal.terminal_id, outcome, now, terminal.last_output);
                    let refused = matches!(
                        outcome,
                        ColdFreeze::Refused(_) | ColdFreeze::InactiveScreenScrolled
                    );
                    // A refused terminal is asked again after it prints; if
                    // it printed since this pass read it, ask now.
                    if refused
                        && self
                            .output_store
                            .wake_on_next_output(&terminal.terminal_id, terminal.last_output)
                    {
                        self.wake_cold_scrollback();
                    }
                }
            } else {
                tracker.defer(&due, now);
            }
        }
        tracker.next_deadline(policy.after, &candidates)
    }

    /// Every catalog terminal with its views, their attach state and its last
    /// output.
    fn cold_scrollback_terminals(&self) -> Vec<Observed> {
        type Collected = (TerminalPublicId, Arc<Surface>, Vec<SurfaceId>, Vec<Arc<Surface>>);
        let terminals: Vec<Collected> = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            state
                .terminal_catalog
                .iter()
                .map(|(terminal_id, surface)| {
                    let content = ContentPublicId::Terminal(terminal_id.clone());
                    let placements = state.placements_of_content(&content);
                    let views: Vec<Arc<Surface>> = placements
                        .iter()
                        .filter_map(|id| state.surfaces.get(id).cloned())
                        .collect();
                    let mut view_ids = placements.to_vec();
                    view_ids.push(surface.id);
                    (terminal_id.clone(), surface.clone(), view_ids, views)
                })
                .collect()
        };
        terminals
            .into_iter()
            .map(|(terminal_id, surface, view_ids, views)| {
                let (viewed, attach_epoch) = self.control_clients.attach_observation(&view_ids);
                let last_output = self.output_store.last_output(&terminal_id);
                Observed { terminal_id, surface, views, viewed, attach_epoch, last_output }
            })
            .collect()
    }

    /// What a restore calls: wake the worker (nothing without one).
    fn cold_scrollback_thaw_wake(&self) -> ThawWake {
        match self.cold_scrollback_wake.get() {
            Some(wake) => {
                let wake = wake.clone();
                Arc::new(move || wake.wake())
            }
            None => Arc::new(|| {}),
        }
    }
}

/// The worker: a pass, then sleep until the next deadline or a wake. It ends
/// when the mux is gone (every sender lives in the mux).
fn run_cold_scrollback(mux: &Weak<Mux>, wakes: &Receiver<()>, policy: ColdPolicy) {
    let mut tracker = ColdTracker::default();
    loop {
        let Some(owner) = mux.upgrade() else { break };
        let now = Instant::now();
        let next = owner.cold_scrollback_pass(&mut tracker, now, policy);
        drop(owner);
        let woke = match next {
            None => wakes.recv().map_err(|_| RecvTimeoutError::Disconnected),
            Some(next) => wakes.recv_timeout(next.saturating_duration_since(now)),
        };
        match woke {
            // Wakes that queued meanwhile are covered by the next pass.
            Ok(()) => while wakes.try_recv().is_ok() {},
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

/// The kernel's level now: `kern.memorystatus_vm_pressure_level` on macOS
/// (the level Chrome's `SystemMemoryPressureEvaluator` reads,
/// components/memory_pressure/system_memory_pressure_evaluator_mac.cc), PSI
/// on Linux with the thresholds of p07-memory-042's trigger.
pub(crate) fn kernel_pressure() -> MemoryPressure {
    #[cfg(target_os = "macos")]
    {
        let mut level: libc::c_int = 0;
        let mut size = std::mem::size_of::<libc::c_int>();
        // SAFETY: the name is NUL-terminated, `level` and `size` are valid
        // for writes and `size` is the size of `level`; no new value is set.
        let read = unsafe {
            libc::sysctlbyname(
                c"kern.memorystatus_vm_pressure_level".as_ptr(),
                (&raw mut level).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        match (read, level) {
            (0, 1) => MemoryPressure::Normal,
            (0, 2) => MemoryPressure::Warning,
            (0, 4) => MemoryPressure::Critical,
            // An unreadable level is not a reason to compress.
            _ => MemoryPressure::Warning,
        }
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/proc/pressure/memory")
            .map_or(MemoryPressure::Normal, |psi| psi_pressure(&psi))
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        MemoryPressure::Normal
    }
}

/// `some`/`full avg10` of 15 % or more (p07-memory-042's 150 ms per second).
#[cfg_attr(not(any(target_os = "linux", test)), allow(dead_code))]
fn psi_pressure(psi: &str) -> MemoryPressure {
    let avg10 = |kind: &str| {
        psi.lines()
            .find(|line| line.split_whitespace().next() == Some(kind))
            .and_then(|line| line.split_whitespace().find_map(|f| f.strip_prefix("avg10=")))
            .and_then(|value| value.parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    if avg10("full") >= 15.0 {
        MemoryPressure::Critical
    } else if avg10("some") >= 15.0 {
        MemoryPressure::Warning
    } else {
        MemoryPressure::Normal
    }
}

#[cfg(test)]
#[path = "cold_scrollback_tests.rs"]
mod tests;
