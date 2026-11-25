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
//! When free PTYs fall under [`PTY_RESERVE`], the owner first ends the terminals
//! of closed tabs that wait out the reap grace (no tab shows them; longest closed
//! first, never a kept or attached one), since a burst of tab closes otherwise
//! holds the machine's PTYs for the whole grace (STATUS 7938). If that is not
//! enough, it parks idle shells
//! (`park-tabs`, `tab-park-v1`) until [`PTY_REFILL`] are free: the tab stays,
//! shows `relaunch: {cwd}`, and the app starts it again when it is shown. A
//! shell is parked only when all of these hold, so no work is ever lost:
//! every rule of `park_eligibility.rs` with no waiver (it sits at its prompt,
//! runs no command and no process of its own, no client is attached, no
//! program reports a status, it is not kept), and it sits at its prompt and
//! printed nothing for at least [`RECLAIM_MIN_IDLE`] (a background job that
//! prints keeps it). The oldest prompt goes first. Nothing happens while PTYs
//! are plentiful. Besides what the owner holds it reads only the child
//! processes of the shells it would park (cmux-next never scans every
//! process, plans/cmux-next/pty-holder.md).
//!
//! The pass runs on the terminal reaper thread, which wakes on terminal
//! lifecycle events (a launch, a failed launch, an exit), at most once per
//! [`RECLAIM_CHECK_EVERY`] unless the last launch failed for lack of PTYs.

use super::park_eligibility::{self, ParkFacts, ParkRefusal, ParkRules, park_refusal};
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

/// One terminal as a reclaim pass, `park-tabs` and the freeing timer see it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ReclaimCandidate {
    /// The tab surfaces that show it.
    pub(crate) surfaces: Vec<SurfaceId>,
    /// Its stable host id.
    pub(crate) host: String,
    /// Its PTY child (the shell, or login(1) that started it).
    pub(crate) pid: Option<u32>,
    /// Newest attach epoch over its views (`ClientRegistry::attach_observation`).
    pub(crate) attach_epoch: u64,
    /// When it last printed anything (Unix ms); `None`: never.
    pub(crate) last_output_ms: Option<u64>,
    /// What the park rules judge; `children` stays unknown until [`read_children`].
    pub(crate) facts: ParkFacts,
}

/// Reads the shell's child processes of each candidate a client does not watch and nothing
/// keeps (the others are refused before their children matter).
pub(crate) fn read_children(candidates: &mut [ReclaimCandidate]) {
    for candidate in candidates.iter_mut() {
        if candidate.facts.attached
            || candidate.facts.kept
            || candidate.facts.workspace_kept
            || candidate.facts.children.is_some()
        {
            continue;
        }
        candidate.facts.children = candidate.pid.and_then(crate::platform::shell_has_children);
    }
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
        .filter(|c| park_refusal(&c.facts, ParkRules::PRESSURE).is_none())
        .filter(|c| c.last_output_ms.is_none_or(|at| now_ms.saturating_sub(at) >= min_idle))
        .filter(|c| !c.surfaces.is_empty())
        .filter_map(|c| {
            let since = c.facts.prompt_since_ms?;
            (now_ms.saturating_sub(since) >= min_idle).then_some((since, c))
        })
        .collect();
    eligible.sort_by_key(|(since, _)| *since);
    eligible.into_iter().take(want).flat_map(|(_, c)| c.surfaces.iter().copied()).collect()
}

/// Of `surfaces`, what `park-tabs` may park under `rules`, and each surface whose terminal
/// stays with the reason. A surface no candidate shows is passed on as given;
/// `park_terminal_tabs` skips it when it shows no live terminal.
pub(crate) fn split_parkable(
    candidates: &[ReclaimCandidate],
    surfaces: &[SurfaceId],
    rules: ParkRules,
) -> (Vec<SurfaceId>, Vec<(SurfaceId, ParkRefusal)>) {
    let refusals: HashMap<SurfaceId, ParkRefusal> = candidates
        .iter()
        .filter_map(|c| Some((c, park_refusal(&c.facts, rules)?)))
        .flat_map(|(c, refusal)| c.surfaces.iter().map(move |surface| (*surface, refusal)))
        .collect();
    let mut parkable = Vec::new();
    let mut refused = Vec::new();
    for surface in surfaces {
        match refusals.get(surface) {
            Some(refusal) => refused.push((*surface, *refusal)),
            None => parkable.push(*surface),
        }
    }
    (parkable, refused)
}

/// How many PTYs to free given `used` of `max`: none while at least
/// [`PTY_RESERVE`] are free, else enough to reach [`PTY_REFILL`] free.
pub(crate) fn reclaim_need(used: usize, max: usize) -> usize {
    let free = max.saturating_sub(used);
    if free >= PTY_RESERVE { 0 } else { PTY_REFILL.min(max).saturating_sub(free) }
}

#[cfg(test)]
thread_local! {
    /// A unit test's PTY usage in place of the machine's (`set_pty_usage_for_test`).
    static PTY_USAGE_FOR_TEST: std::cell::Cell<Option<(usize, usize)>> =
        const { std::cell::Cell::new(None) };
}

/// Sets the PTY usage a reclaim pass on this thread reads; `None` reads the machine again.
#[cfg(test)]
pub(crate) fn set_pty_usage_for_test(usage: Option<(usize, usize)>) {
    PTY_USAGE_FOR_TEST.with(|cell| cell.set(usage));
}

/// The usage a reclaim pass reads: the machine's, or a unit test's.
fn current_pty_usage() -> Option<(usize, usize)> {
    #[cfg(test)]
    if let Some(usage) = PTY_USAGE_FOR_TEST.with(std::cell::Cell::get) {
        return Some(usage);
    }
    pty_usage()
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
    #[cfg(test)]
    pub(crate) fn reclaim_ptys_if_low(&self, clock: &mut ReclaimClock) -> Vec<SurfaceId> {
        self.reclaim_ptys_if_low_leaving(clock, &HashSet::new())
    }

    /// [`Self::reclaim_ptys_if_low`], never ending a closed tab's terminal in `held`: the
    /// terminals a new owner holds until the app attaches to them again (terminal_reap.rs,
    /// "Cold adoption"), which look detached until it does.
    pub(crate) fn reclaim_ptys_if_low_leaving(
        &self,
        clock: &mut ReclaimClock,
        held: &HashSet<String>,
    ) -> Vec<SurfaceId> {
        let forced = self.pty_reclaim_forced.swap(false, Ordering::AcqRel);
        if !clock.due(Instant::now(), forced) {
            return Vec::new();
        }
        let Some((used, max)) = current_pty_usage() else { return Vec::new() };
        let want = reclaim_need(used, max);
        if want == 0 {
            return Vec::new();
        }
        // Closed tabs' terminals waiting out the reap grace go first: no tab shows them, and a
        // burst of closes held the machine's PTYs with them until every new tab was refused
        // (STATUS 7938). Each ends through the reaper's own guarded close.
        let ended = self.end_unplaced_terminals_for_ptys(want, held);
        let want = want.saturating_sub(ended);
        if want == 0 {
            eprintln!(
                "cmux-tui: PTYs low ({used} of {max} in use): ended {ended} closed tabs' terminals"
            );
            return Vec::new();
        }
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let mut candidates = self.reclaim_candidates(None);
        read_children(&mut candidates);
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

    /// Ends up to `want` terminals that no tab shows and that wait out the reap grace, longest
    /// unplaced first; returns how many ended. A kept terminal, or one a client is attached to, is
    /// never one of them (`reap_unplaced_terminal` checks again atomically with the close).
    fn end_unplaced_terminals_for_ptys(&self, want: usize, held: &HashSet<String>) -> usize {
        let mut rows_empty = false;
        let unplaced = match self.reapable_terminals_unplaced_for(&mut rows_empty) {
            Ok(unplaced) => unplaced,
            Err(error) => {
                self.report_internal_diagnostic(format!(
                    "PTY reclaim could not list closed terminals: {error:#}"
                ));
                return 0;
            }
        };
        let mut oldest: Vec<(Duration, String)> = unplaced
            .into_iter()
            .filter(|(terminal_id, _)| !held.contains(terminal_id))
            .map(|(terminal_id, unplaced_for)| (unplaced_for, terminal_id))
            .collect();
        oldest.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        let mut ended = 0;
        for (_, terminal_id) in oldest {
            if ended == want {
                break;
            }
            match self.reap_unplaced_terminal(&terminal_id) {
                Ok(terminal_reap::ReapOutcome::Reaped) => ended += 1,
                Ok(_) => {}
                Err(error) => self.report_internal_diagnostic(format!(
                    "PTY reclaim could not end closed terminal {terminal_id}: {error:#}"
                )),
            }
        }
        ended
    }

    /// `park-tabs`: parks the terminals at `surfaces` that pass the park rules
    /// (`park_eligibility.rs`) under `rules`: a shell another Mac or the phone shows, one that is
    /// kept, or one that runs anything keeps running. Returns the surfaces parked and each
    /// surface whose terminal stays, with the reason.
    pub(crate) fn park_idle_terminal_tabs(
        &self,
        surfaces: &[SurfaceId],
        rules: ParkRules,
    ) -> anyhow::Result<(Vec<SurfaceId>, Vec<(SurfaceId, ParkRefusal)>)> {
        let wanted: HashSet<SurfaceId> = surfaces.iter().copied().collect();
        let mut candidates = self.reclaim_candidates(Some(&wanted));
        read_children(&mut candidates);
        let (parkable, refused) = split_parkable(&candidates, surfaces, rules);
        if parkable.is_empty() {
            return Ok((Vec::new(), refused));
        }
        Ok((self.park_terminal_tabs(&parkable)?, refused))
    }

    /// Every running terminal of this owner with the facts the park rules judge, its shell's
    /// children not yet read ([`read_children`]). `only`: just the terminals one of these tab
    /// surfaces shows.
    pub(crate) fn reclaim_candidates(
        &self,
        only: Option<&HashSet<SurfaceId>>,
    ) -> Vec<ReclaimCandidate> {
        let kept = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .kept_terminals()
            .unwrap_or_default();
        // An agent idle or done with a harness session id: a respawn resumes it
        // (`terminal_respawn/prefill.rs`), as the app's freeing tier judges it.
        let resumable: HashSet<TerminalPublicId> = self
            .list_agents(None, None)
            .into_iter()
            .filter(|agent| matches!(agent.state, AgentState::Idle | AgentState::Done))
            .filter(|agent| agent.agent_session_id.is_some())
            .map(|agent| agent.terminal_id)
            .collect();
        // Pinned and kept-awake workspaces keep their shells, as the app's planner keeps them.
        let presentation = self.presentation_snapshot();
        let rows: Vec<(TerminalPublicId, String, Vec<SurfaceId>, Arc<Surface>, bool)> = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let mut by_terminal: HashMap<TerminalPublicId, Vec<SurfaceId>> = HashMap::new();
            for (surface, content) in &state.resource_indexes.content_ids {
                if let ContentPublicId::Terminal(id) = content {
                    by_terminal.entry(id.clone()).or_default().push(*surface);
                }
            }
            by_terminal
                .into_iter()
                .filter(|(_, surfaces)| {
                    only.is_none_or(|only| surfaces.iter().any(|surface| only.contains(surface)))
                })
                .filter_map(|(id, surfaces)| {
                    let runtime = state.terminal_catalog.get(&id)?.clone();
                    if runtime.is_dead() {
                        return None;
                    }
                    let host = self.resource_terminal_host_identity(&runtime)?.terminal_id;
                    let workspace_kept =
                        terminal_workspace_kept(&state, &surfaces, &|key: &str| {
                            presentation
                                .workspace(key)
                                .is_some_and(|record| record.pinned || record.keep_awake)
                        });
                    Some((id, host, surfaces, runtime, workspace_kept))
                })
                .collect()
        };
        let placements = self.terminal_placements_by_host();
        rows.into_iter()
            .map(|(id, host, surfaces, runtime, workspace_kept)| {
                let views = placements.get(&host).map(Vec::as_slice).unwrap_or(&[]);
                let mut all_views = views.to_vec();
                all_views.extend(surfaces.iter().copied());
                let (attached, attach_epoch) = self.control_clients.attach_observation(&all_views);
                let command_running = runtime.terminal_command_activity().is_some();
                let pid = runtime.process_id();
                let shell = match runtime.spawn_argv().and_then(|argv| argv.into_iter().next()) {
                    Some(program) => park_eligibility::is_shell_program(&program),
                    None => pid
                        .and_then(crate::platform::process_executable)
                        .is_some_and(|program| park_eligibility::is_shell_program(&program)),
                };
                ReclaimCandidate {
                    host: host.clone(),
                    pid,
                    attach_epoch,
                    last_output_ms: runtime.terminal_last_output(),
                    facts: ParkFacts {
                        attached,
                        kept: kept.contains(&host),
                        workspace_kept,
                        saved_state_ready: park_eligibility::saved_state_ready(&runtime),
                        program_reported: runtime.shown_program_status().is_some(),
                        command_running,
                        prompt_since_ms: runtime.terminal_prompt_since(),
                        children: None,
                        used: command_running
                            || runtime.terminal_last_input().is_some()
                            || runtime.terminal_last_command().is_some(),
                        shell,
                        resumable_agent: resumable.contains(&id),
                    },
                    surfaces,
                }
            })
            .collect()
    }
}

/// Whether a terminal shown at `surfaces` is in a workspace `kept_key` keeps (pinned or kept
/// awake); a terminal none of whose surfaces is in a workspace counts as kept (an unknown
/// fact keeps it running).
fn terminal_workspace_kept(
    state: &State,
    surfaces: &[SurfaceId],
    kept_key: &dyn Fn(&str) -> bool,
) -> bool {
    let mut found = false;
    for surface in surfaces {
        let Some(workspace) = Mux::workspace_for_surface_in_state(state, *surface)
            .and_then(|workspace| state.workspace_by_id(workspace))
        else {
            continue;
        };
        found = true;
        if kept_key(&workspace.key) {
            return true;
        }
    }
    !found
}

#[cfg(test)]
#[path = "pty_reclaim_tests.rs"]
mod tests;
