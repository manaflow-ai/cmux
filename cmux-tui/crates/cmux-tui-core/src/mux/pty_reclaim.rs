//! PTY reclaim: keep free PTYs on the machine so a new terminal never fails
//! with "PTY capacity exhausted".
//!
//! macOS gives the whole machine `kern.tty.ptmx_max` PTYs (511 by default).
//! Every terminal host holds one for its whole life, so a session with a few
//! hundred agent workspaces, each with a shell tab nobody opened, used them
//! all (Lawrence's Mac, 2026-10-30: 480 of 511 held by this owner, 431 of
//! them shells idle at a prompt for a median 148 h with no client; every
//! new workspace then failed to spawn).
//!
//! When free PTYs fall under [`PTY_RESERVE`], the owner parks idle shells
//! (`park-tabs`, `tab-park-v1`) until [`PTY_REFILL`] are free: the tab stays,
//! shows `relaunch: {cwd}`, and the app starts it again when it is shown. A
//! shell is parked only when all of these hold, so no work is ever lost:
//! it sits at its prompt (OSC 133 A) and printed nothing for at least
//! [`RECLAIM_MIN_IDLE`] (a background job that prints keeps it), no client is
//! attached to any of its views, no program reports a status in it (OSC
//! 7501: an agent keeps it), and it is not kept (`set-terminal-keep`). The
//! oldest prompt goes first. Nothing happens while PTYs are plentiful. It
//! reads only what the owner already holds (cmux-next never scans
//! processes, plans/cmux-next/pty-holder.md).
//!
//! The pass runs on the terminal reaper thread, which wakes on terminal
//! lifecycle events (a launch, a failed launch, an exit), at most once per
//! [`RECLAIM_CHECK_EVERY`] unless the last launch failed for lack of PTYs.

use super::*;

/// Free PTYs under which the owner starts parking idle shells. Also leaves
/// room for ssh, tmux and other programs on the machine.
pub(crate) const PTY_RESERVE: usize = 64;
/// Free PTYs a reclaim pass aims for once it runs (hysteresis, so one pass
/// covers many launches).
pub(crate) const PTY_REFILL: usize = 128;
/// The shortest time a shell must sit at its prompt to be parked.
pub(crate) const RECLAIM_MIN_IDLE: Duration = Duration::from_secs(30 * 60);
/// The most often the headroom is read when nothing failed.
pub(crate) const RECLAIM_CHECK_EVERY: Duration = Duration::from_secs(2);

/// One terminal as a reclaim pass sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ReclaimCandidate {
    /// The tab surfaces that show it.
    pub(crate) surfaces: Vec<SurfaceId>,
    /// When its shell drew the prompt it sits at (Unix ms); `None`: a
    /// command runs or the shell sends no OSC 133.
    pub(crate) prompt_since_ms: Option<u64>,
    /// A client holds an attach stream on one of its views.
    pub(crate) attached: bool,
    /// `set-terminal-keep on`.
    pub(crate) kept: bool,
    /// When it last printed anything (Unix ms); `None`: never.
    pub(crate) last_output_ms: Option<u64>,
    /// A program reports a status in it (OSC 7501).
    pub(crate) program_reported: bool,
}

/// The tab surfaces to park so `want` PTYs come free: oldest prompt first,
/// only terminals that pass every rule in the module docs.
pub(crate) fn pick_reclaim(
    candidates: &[ReclaimCandidate],
    now_ms: u64,
    want: usize,
) -> Vec<SurfaceId> {
    let min_idle = RECLAIM_MIN_IDLE.as_millis() as u64;
    let mut eligible: Vec<(u64, &ReclaimCandidate)> = candidates
        .iter()
        .filter(|c| !c.attached && !c.kept && !c.program_reported)
        .filter(|c| c.last_output_ms.is_none_or(|at| now_ms.saturating_sub(at) >= min_idle))
        .filter(|c| !c.surfaces.is_empty())
        .filter_map(|c| {
            let since = c.prompt_since_ms?;
            (now_ms.saturating_sub(since) >= min_idle).then_some((since, c))
        })
        .collect();
    eligible.sort_by_key(|(since, _)| *since);
    eligible.into_iter().take(want).flat_map(|(_, c)| c.surfaces.iter().copied()).collect()
}

/// How many PTYs to free given `used` of `max`: none while at least
/// [`PTY_RESERVE`] are free, else enough to reach [`PTY_REFILL`] free.
pub(crate) fn reclaim_need(used: usize, max: usize) -> usize {
    let free = max.saturating_sub(used);
    if free >= PTY_RESERVE { 0 } else { PTY_REFILL.min(max).saturating_sub(free) }
}

/// PTYs in use on this machine and its limit; `None` where it cannot be read.
#[cfg(target_os = "macos")]
pub(crate) fn pty_usage() -> Option<(usize, usize)> {
    let mut max: libc::c_int = 0;
    let mut size = size_of::<libc::c_int>();
    // SAFETY: the out buffer is a c_int and `size` is its size; the name is NUL-terminated.
    let read = unsafe {
        libc::sysctlbyname(
            c"kern.tty.ptmx_max".as_ptr(),
            (&raw mut max).cast(),
            &mut size,
            std::ptr::null_mut(),
            0,
        )
    };
    if read != 0 || max <= 0 {
        return None;
    }
    // Each open PTY has a `/dev/ttysNNN` node (three or more digits); the
    // legacy `ttys0`..`ttysf` nodes are not counted against the limit.
    let used = std::fs::read_dir("/dev")
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| is_pty_node(&entry.file_name().to_string_lossy()))
        .count();
    Some((used, usize::try_from(max).ok()?))
}

/// PTYs in use on this machine and its limit; `None` where it cannot be read.
#[cfg(target_os = "linux")]
pub(crate) fn pty_usage() -> Option<(usize, usize)> {
    let read = |name: &str| -> Option<usize> {
        std::fs::read_to_string(format!("/proc/sys/kernel/pty/{name}")).ok()?.trim().parse().ok()
    };
    Some((read("nr")?, read("max")?))
}

/// PTYs in use on this machine and its limit; `None` where it cannot be read.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(crate) fn pty_usage() -> Option<(usize, usize)> {
    None
}

/// Whether a `/dev` entry is a macOS PTY slave counted against `ptmx_max`.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn is_pty_node(name: &str) -> bool {
    name.strip_prefix("ttys")
        .is_some_and(|digits| digits.len() >= 3 && digits.bytes().all(|b| b.is_ascii_digit()))
}

/// Whether `error` is a terminal launch that found no free PTY.
pub(crate) fn is_pty_exhaustion(error: &anyhow::Error) -> bool {
    use crate::terminal_host_protocol::{HostLaunchFailure, HostLaunchFailureKind};
    error.chain().any(|cause| {
        cause
            .downcast_ref::<HostLaunchFailure>()
            .is_some_and(|failure| failure.kind == HostLaunchFailureKind::PtyCapacityExhausted)
            || cause
                .downcast_ref::<cmux_pty::PtyOpenError>()
                .is_some_and(cmux_pty::PtyOpenError::is_capacity_exhausted)
    })
}

/// When the reaper thread last read the headroom, and whether a launch
/// failed for lack of PTYs since (then the next pass reads it at once).
#[derive(Debug, Default)]
pub(crate) struct ReclaimClock {
    last_check: Option<Instant>,
}

impl ReclaimClock {
    /// Whether a pass is due at `now`.
    pub(crate) fn due(&mut self, now: Instant, forced: bool) -> bool {
        let due = forced
            || self.last_check.is_none_or(|last| now.duration_since(last) >= RECLAIM_CHECK_EVERY);
        if due {
            self.last_check = Some(now);
        }
        due
    }
}

impl Mux {
    /// Notes a launch that failed for lack of PTYs: the next reaper pass
    /// reads the headroom at once.
    pub(crate) fn note_pty_exhausted(&self) {
        self.pty_reclaim_forced.store(true, Ordering::Release);
        self.wake_terminal_reaper();
    }

    /// One reclaim pass (module docs). Returns the tab surfaces parked.
    pub(crate) fn reclaim_ptys_if_low(&self, clock: &mut ReclaimClock) -> Vec<SurfaceId> {
        let forced = self.pty_reclaim_forced.swap(false, Ordering::AcqRel);
        if !clock.due(Instant::now(), forced) {
            return Vec::new();
        }
        let Some((used, max)) = pty_usage() else { return Vec::new() };
        let want = reclaim_need(used, max);
        if want == 0 {
            return Vec::new();
        }
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let candidates = self.reclaim_candidates();
        let surfaces = pick_reclaim(&candidates, now_ms, want);
        if surfaces.is_empty() {
            self.report_internal_diagnostic(format!(
                "PTYs low ({used} of {max} in use) and no idle shell can be parked"
            ));
            return Vec::new();
        }
        match self.park_terminal_tabs(&surfaces) {
            Ok(parked) => {
                eprintln!(
                    "cmux-tui: PTYs low ({used} of {max} in use): parked {} idle shell tabs",
                    parked.len()
                );
                parked
            }
            Err(error) => {
                self.report_internal_diagnostic(format!("PTY reclaim failed: {error:#}"));
                Vec::new()
            }
        }
    }

    /// Every running terminal of this owner with the facts
    /// [`pick_reclaim`] judges.
    fn reclaim_candidates(&self) -> Vec<ReclaimCandidate> {
        let kept = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .kept_terminals()
            .unwrap_or_default();
        let rows: Vec<(String, Vec<SurfaceId>, Arc<Surface>)> = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let mut by_terminal: HashMap<TerminalPublicId, Vec<SurfaceId>> = HashMap::new();
            for (surface, content) in &state.resource_indexes.content_ids {
                if let ContentPublicId::Terminal(id) = content {
                    by_terminal.entry(id.clone()).or_default().push(*surface);
                }
            }
            by_terminal
                .into_iter()
                .filter_map(|(id, surfaces)| {
                    let runtime = state.terminal_catalog.get(&id)?.clone();
                    let host = self.resource_terminal_host_identity(&runtime)?.terminal_id;
                    Some((host, surfaces, runtime))
                })
                .collect()
        };
        let placements = self.terminal_placements_by_host();
        rows.into_iter()
            .map(|(host, surfaces, runtime)| {
                let views = placements.get(&host).map(Vec::as_slice).unwrap_or(&[]);
                let mut all_views = views.to_vec();
                all_views.extend(surfaces.iter().copied());
                ReclaimCandidate {
                    attached: self.control_clients.attach_observation(&all_views).0,
                    kept: kept.contains(&host),
                    prompt_since_ms: runtime.terminal_prompt_since(),
                    last_output_ms: runtime.terminal_last_output(),
                    program_reported: runtime.shown_program_status().is_some(),
                    surfaces,
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR_MS: u64 = 60 * 60 * 1000;

    fn sid(id: u64) -> SurfaceId {
        id
    }

    fn idle(surface: u64, since_ms: u64) -> ReclaimCandidate {
        ReclaimCandidate {
            surfaces: vec![sid(surface)],
            prompt_since_ms: Some(since_ms),
            attached: false,
            kept: false,
            last_output_ms: Some(since_ms),
            program_reported: false,
        }
    }

    #[test]
    fn parks_only_idle_quiet_unwatched_unkept_shells_oldest_first() {
        let now = 200 * HOUR_MS;
        let busy = ReclaimCandidate { prompt_since_ms: None, ..idle(2, 0) };
        let watched = ReclaimCandidate { attached: true, ..idle(3, 0) };
        let kept = ReclaimCandidate { kept: true, ..idle(4, 0) };
        let agent = ReclaimCandidate { program_reported: true, ..idle(5, 0) };
        let printing = ReclaimCandidate { last_output_ms: Some(now - 1000), ..idle(6, 0) };
        let fresh = idle(7, now - 10 * 60 * 1000);
        let candidates =
            [idle(1, 50 * HOUR_MS), busy, watched, kept, agent, printing, fresh, idle(8, HOUR_MS)];
        assert_eq!(
            pick_reclaim(&candidates, now, 10),
            [sid(8), sid(1)],
            "the oldest prompt first; nothing busy, watched, kept, reporting, printing or fresh"
        );
        assert_eq!(pick_reclaim(&candidates, now, 1), [sid(8)]);
        assert!(pick_reclaim(&candidates, now, 0).is_empty());
    }

    #[test]
    fn reclaims_only_under_the_reserve_and_refills_past_it() {
        assert_eq!(reclaim_need(100, 511), 0);
        assert_eq!(reclaim_need(511 - PTY_RESERVE, 511), 0);
        assert_eq!(reclaim_need(511 - PTY_RESERVE + 1, 511), PTY_REFILL - PTY_RESERVE + 1);
        assert_eq!(reclaim_need(511, 511), PTY_REFILL);
        assert_eq!(reclaim_need(527, 511), PTY_REFILL, "more nodes than the limit");
        assert_eq!(reclaim_need(40, 50), 50 - 10, "a limit under the refill frees what it can");
    }

    #[test]
    fn counts_only_numbered_pty_nodes() {
        assert!(is_pty_node("ttys000"));
        assert!(is_pty_node("ttys510"));
        assert!(!is_pty_node("ttys0"), "legacy node");
        assert!(!is_pty_node("ttysf"));
        assert!(!is_pty_node("ttyp000"));
    }

    #[test]
    fn a_failed_launch_forces_the_next_pass() {
        let mut clock = ReclaimClock::default();
        let start = Instant::now();
        assert!(clock.due(start, false));
        assert!(!clock.due(start + Duration::from_millis(10), false));
        assert!(clock.due(start + Duration::from_millis(20), true));
        assert!(clock.due(start + RECLAIM_CHECK_EVERY * 2, false));
    }
}
