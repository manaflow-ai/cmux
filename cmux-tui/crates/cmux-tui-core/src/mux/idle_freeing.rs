//! The daemon's freeing timer (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md, Part 2):
//! while `workspaces.freeing.enabled` is on, a terminal that has had no attached client and
//! printed nothing for `workspaces.freeing.idleMinutes` (one day by default) is parked through
//! the `park-tabs` path, under the same rules (`park_eligibility.rs`): only a shell idle at its
//! prompt that runs nothing, or an idle agent with a resumable session
//! (`workspaces.freeing.agents`). A running command is never ended by the timer.
//!
//! One deadline, no polling: the pass runs on the idle-close reaper thread (`idle_close.rs`),
//! which sleeps until the earliest of its own deadline and this one. A client detaching wakes it
//! (the detach waker), as do a settings change and, while no terminal is tracked, a terminal
//! launch. Output does not wake it: at the deadline the pass reads each terminal's last output
//! and sleeps again until the new deadline. With freeing off, or nothing tracked, it adds no
//! wakeup at all.
//!
//! Idle time is measured by this owner only, never early: a terminal is idle from the newest of
//! its last output, the moment this owner began tracking it (freeing turned on, the owner
//! started), and the last pass that saw a client attached to it (or saw an attach since the
//! pass before). A refused terminal waits another full period before it is judged again.
//!
//! `--freeing-idle-seconds N` (the bench) turns freeing on with an idle time of N seconds,
//! whatever the settings file says.

use super::park_eligibility::ParkRules;
use super::*;

/// `workspaces.freeing.*` as the daemon reads them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct FreeingSettings {
    pub(crate) enabled: bool,
    pub(crate) idle: Duration,
    pub(crate) agents: bool,
    /// `runningCommands: relaunch`.
    pub(crate) relaunch_running_commands: bool,
}

impl Default for FreeingSettings {
    /// The schema's defaults (schemas/settings/source/workspace-hibernation.json): freeing on
    /// (Leo, 2026-11-19: "Yes" to freeing idle shells in workspaces hidden for a day by default).
    fn default() -> Self {
        Self {
            enabled: true,
            idle: Duration::from_secs(1440 * 60),
            agents: true,
            relaunch_running_commands: false,
        }
    }
}

/// The freeing timer's state on the mux.
#[derive(Default)]
pub(crate) struct IdleFreeing {
    inner: Mutex<FreeingInner>,
    /// Freeing is on and no terminal is tracked: a launch wakes the reaper.
    wants_launch_wake: AtomicBool,
}

struct FreeingInner {
    settings: FreeingSettings,
    /// `--freeing-idle-seconds`: on, with this idle time.
    override_idle: Option<Duration>,
    tracker: FreeingTracker,
}

impl Default for FreeingInner {
    /// Off until the daemon's settings owner reads the settings file (`mux/settings.rs`), whose
    /// default is on: a mux with no settings owner (tests, embedders) never frees on its own.
    fn default() -> Self {
        Self {
            settings: FreeingSettings { enabled: false, ..FreeingSettings::default() },
            override_idle: None,
            tracker: FreeingTracker::default(),
        }
    }
}

impl FreeingInner {
    /// Whether freeing is on, and its idle time.
    fn active(&self) -> Option<Duration> {
        match self.override_idle {
            Some(idle) => Some(idle),
            None => self.settings.enabled.then_some(self.settings.idle),
        }
    }
}

/// One live terminal as a freeing pass sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FreeingCandidate<'a> {
    pub(crate) host: &'a str,
    pub(crate) attached: bool,
    pub(crate) attach_epoch: u64,
    pub(crate) last_output_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy)]
struct Tracked {
    /// The last moment the terminal was known in use (Unix ms).
    used_ms: u64,
    attached: bool,
    attach_epoch: u64,
}

/// Pure idle bookkeeping on a Unix-ms clock the caller passes.
#[derive(Debug, Default)]
pub(crate) struct FreeingTracker {
    tracked: HashMap<String, Tracked>,
    /// When tracking began: nothing counts as idle from before it.
    since_ms: Option<u64>,
}

impl FreeingTracker {
    /// Forgets everything (freeing turned off).
    pub(crate) fn clear(&mut self) {
        self.tracked.clear();
        self.since_ms = None;
    }

    /// Advances to `now_ms` and returns the hosts idle for at least `idle_ms`. Terminals absent
    /// from `candidates` are forgotten.
    pub(crate) fn due(
        &mut self,
        now_ms: u64,
        idle_ms: u64,
        candidates: &[FreeingCandidate<'_>],
    ) -> Vec<String> {
        let since = *self.since_ms.get_or_insert(now_ms);
        let live: HashSet<&str> = candidates.iter().map(|candidate| candidate.host).collect();
        self.tracked.retain(|host, _| live.contains(host.as_str()));
        let mut due = Vec::new();
        for candidate in candidates {
            let entry = self.tracked.entry(candidate.host.to_string()).or_insert(Tracked {
                used_ms: since,
                attached: candidate.attached,
                attach_epoch: candidate.attach_epoch,
            });
            // Attached now, at the last pass, or attached and gone between the two passes.
            if candidate.attached || entry.attached || entry.attach_epoch != candidate.attach_epoch
            {
                entry.used_ms = now_ms;
            }
            entry.attached = candidate.attached;
            entry.attach_epoch = candidate.attach_epoch;
            if let Some(output) = candidate.last_output_ms {
                entry.used_ms = entry.used_ms.max(output.min(now_ms));
            }
            if !candidate.attached && now_ms.saturating_sub(entry.used_ms) >= idle_ms {
                due.push(candidate.host.to_string());
            }
        }
        due
    }

    /// A due terminal stays (refused or not parked): judged again a full period from `now_ms`.
    pub(crate) fn restart(&mut self, host: &str, now_ms: u64) {
        if let Some(entry) = self.tracked.get_mut(host) {
            entry.used_ms = now_ms;
        }
    }

    /// When the earliest unattached tracked terminal comes due (Unix ms); `None`: none will
    /// without a change (an attach ends with a detach, which wakes the pass).
    pub(crate) fn next_deadline_ms(&self, idle_ms: u64) -> Option<u64> {
        self.tracked
            .values()
            .filter(|entry| !entry.attached)
            .map(|entry| entry.used_ms.saturating_add(idle_ms))
            .min()
    }

    #[cfg(test)]
    pub(crate) fn is_empty(&self) -> bool {
        self.tracked.is_empty()
    }
}

impl Mux {
    /// Adopts `workspaces.freeing.*` from the settings file; the reaper looks again.
    pub(crate) fn set_freeing_settings(&self, settings: FreeingSettings) {
        let mut inner = self.idle_freeing.inner.lock().unwrap_or_else(PoisonError::into_inner);
        if inner.settings == settings {
            return;
        }
        inner.settings = settings;
        drop(inner);
        self.wake_idle_close_reaper();
    }

    /// `--freeing-idle-seconds`: freeing on with `idle`, whatever the settings say.
    pub fn set_freeing_idle_override(&self, idle: Duration) {
        self.idle_freeing.inner.lock().unwrap_or_else(PoisonError::into_inner).override_idle =
            Some(idle);
        // A parked tab keeps its shell's last command while freeing is on (`command_history.rs`).
        self.set_terminal_last_command(true);
        self.wake_idle_close_reaper();
    }

    /// Whether `--freeing-idle-seconds` turned freeing on.
    pub(crate) fn freeing_overridden(&self) -> bool {
        self.idle_freeing
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .override_idle
            .is_some()
    }

    /// The waivers `park-tabs` allows: the agent path and `runningCommands: relaunch` follow
    /// the settings; a shell nobody used yet may park before its first prompt.
    pub(crate) fn park_tabs_rules(&self) -> ParkRules {
        let settings =
            self.idle_freeing.inner.lock().unwrap_or_else(PoisonError::into_inner).settings;
        ParkRules {
            agents: settings.agents,
            running_commands: settings.relaunch_running_commands,
            unused_before_prompt: true,
        }
    }

    /// A terminal launched: wakes the reaper only when freeing is on and tracks nothing yet
    /// (otherwise the next deadline's pass finds the new terminal).
    pub(crate) fn note_launch_for_freeing(&self) {
        if self.idle_freeing.wants_launch_wake.swap(false, Ordering::AcqRel) {
            self.wake_idle_close_reaper();
        }
    }

    /// One freeing pass at `now` (module docs): parks what came due, and returns when the next
    /// terminal comes due (`None`: freeing is off or nothing will without a change).
    pub(crate) fn free_idle_terminals_until_next(&self, now: Instant) -> Option<Instant> {
        let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap_or(0);
        let (idle, agents) = {
            let mut inner = self.idle_freeing.inner.lock().unwrap_or_else(PoisonError::into_inner);
            match inner.active() {
                Some(idle) => (idle, inner.settings.agents),
                None => {
                    inner.tracker.clear();
                    self.idle_freeing.wants_launch_wake.store(false, Ordering::Release);
                    return None;
                }
            }
        };
        let idle_ms = u64::try_from(idle.as_millis()).unwrap_or(u64::MAX);
        let mut candidates = self.reclaim_candidates(None);
        let due: HashSet<String> = {
            let views: Vec<FreeingCandidate<'_>> = candidates
                .iter()
                .map(|candidate| FreeingCandidate {
                    host: &candidate.host,
                    attached: candidate.facts.attached,
                    attach_epoch: candidate.attach_epoch,
                    last_output_ms: candidate.last_output_ms,
                })
                .collect();
            let mut inner = self.idle_freeing.inner.lock().unwrap_or_else(PoisonError::into_inner);
            inner.tracker.due(now_ms, idle_ms, &views).into_iter().collect()
        };
        if !due.is_empty() {
            candidates.retain(|candidate| due.contains(&candidate.host));
            pty_reclaim::read_children(&mut candidates);
            let rules = ParkRules { agents, running_commands: false, unused_before_prompt: false };
            let surfaces: Vec<SurfaceId> = candidates
                .iter()
                .flat_map(|candidate| candidate.surfaces.iter().copied())
                .collect();
            let (parkable, refused) = pty_reclaim::split_parkable(&candidates, &surfaces, rules);
            if !parkable.is_empty() {
                match self.park_terminal_tabs(&parkable) {
                    Ok(parked) => eprintln!(
                        "cmux-tui: freed {} idle terminal tabs ({} kept running)",
                        parked.len(),
                        refused.len()
                    ),
                    Err(error) => {
                        self.report_internal_diagnostic(format!("idle freeing failed: {error:#}"))
                    }
                }
            }
            // A parked terminal leaves the next pass's candidates; one that stays is judged
            // again a full period from now.
            let mut inner = self.idle_freeing.inner.lock().unwrap_or_else(PoisonError::into_inner);
            for host in &due {
                inner.tracker.restart(host, now_ms);
            }
        }
        let next_ms = self
            .idle_freeing
            .inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .tracker
            .next_deadline_ms(idle_ms);
        // No deadline: a new terminal would wait for an unrelated wakeup, so a launch wakes us.
        self.idle_freeing.wants_launch_wake.store(next_ms.is_none(), Ordering::Release);
        next_ms.map(|at_ms| now + Duration::from_millis(at_ms.saturating_sub(now_ms)))
    }
}

#[cfg(test)]
#[path = "idle_freeing_tests.rs"]
mod tests;
