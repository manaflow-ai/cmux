//! Daemon-side screen-detection scanner.
//!
//! Detection semantics derived from herdr (https://github.com/herdrdev/herdr),
//! Apache-2.0, commit 7b675f42af35, modified by manaflow.
//!
//! One session-owned thread samples every live PTY's coalesced output
//! revision on a fixed cadence. A terminal that stays on one revision for
//! the debounce window is quiesced: its foreground process name picks a
//! manifest and the viewport tail plus OSC title are evaluated. The
//! tracker turns per-scan states into edge-triggered journal emissions.

use std::collections::HashSet;
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

use super::ScreenDetectTracker;
use super::manifest::{DetectionInput, ManifestSet};
use crate::mux::Mux;
use crate::surface::Surface;

/// Sampling cadence: per terminal per tick, one atomic revision read plus
/// one foreground process-group lookup (two proc syscalls). Viewport text
/// is only extracted on quiescence or an identity edge. The cadence also
/// bounds spawn-detection latency: a launched agent appears within one
/// tick plus the journal fold.
const SCAN_INTERVAL: Duration = Duration::from_millis(100);

/// Result of resolving a terminal's foreground process.
///
/// `Unknown` is distinct from `Exited`: process lookup can fail transiently
/// while the terminal is still live. Treating that miss as an exit would emit
/// a false Done edge and remove a valid roster entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ProcessLookup {
    Name(String),
    Exited,
    Unknown,
}

/// Resolves a surface to its foreground process; injectable so tests drive
/// detection without spawning agent-named processes.
pub(crate) type ProcessNameResolver = dyn Fn(&Surface) -> ProcessLookup + Send + Sync;

pub(crate) fn start(mux: &Arc<Mux>) {
    let weak = Arc::downgrade(mux);
    let spawned = std::thread::Builder::new()
        .name("mux-screen-detect".into())
        .spawn(move || run_scanner(weak));
    if let Err(error) = spawned {
        eprintln!("cmux-tui: screen-detection scanner did not start: {error}");
    }
}

fn run_scanner(weak: Weak<Mux>) {
    let mut tracker = ScreenDetectTracker::default();
    let manifests = ManifestSet::bundled();
    loop {
        {
            let Some(mux) = weak.upgrade() else { return };
            if mux.daemon_shutdown_requested() {
                return;
            }
            scan(&mux, &mut tracker, manifests, Instant::now(), &foreground_process_lookup);
        }
        // Fixed sampling cadence (the debounce clock), not a synchronization
        // substitute: nothing waits on this thread.
        std::thread::sleep(SCAN_INTERVAL);
    }
}

/// Production resolver: the foreground process-group leader's executable
/// name for the terminal's PTY child. An exited terminal is terminal state;
/// unavailable process metadata is a retryable lookup miss.
fn foreground_process_lookup(surface: &Surface) -> ProcessLookup {
    if surface.terminal_exit().is_some() {
        return ProcessLookup::Exited;
    }
    let Some(process_id) = surface.process_id() else {
        return ProcessLookup::Unknown;
    };
    crate::platform::foreground_process_name(process_id)
        .map(ProcessLookup::Name)
        .unwrap_or(ProcessLookup::Unknown)
}

/// One scan pass over the live terminal catalog. Pure over its inputs
/// besides journal emission, so tests call it directly with a stub
/// resolver and a controlled clock.
pub(crate) fn scan(
    mux: &Mux,
    tracker: &mut ScreenDetectTracker,
    manifests: &ManifestSet,
    now: Instant,
    resolver: &ProcessNameResolver,
) {
    let (catalog_revision, terminals) = mux.screen_detect_terminals();
    // Terminal membership changes are infrequent relative to output ticks.
    // Rebuild the live index only when the catalog revision changes, so the
    // steady-state scanner does not perform an O(terminals) retention sweep.
    if tracker.catalog_revision_changed(catalog_revision) {
        let live_ids: HashSet<&str> = terminals.iter().map(|(id, _)| id.as_str()).collect();
        tracker.retain_terminals(|terminal_id| live_ids.contains(terminal_id));
        tracker.note_catalog_revision(catalog_revision);
    }
    for (terminal_public_id, surface) in terminals.iter() {
        let Ok(revision) = surface.terminal_stream_revision() else { continue };
        let terminal_id = terminal_public_id.as_str();
        let quiesced = tracker.observe_revision(terminal_id, revision, now);
        let lookup_due =
            tracker.should_lookup_foreground_agent(terminal_id, surface.process_id(), now);
        if !lookup_due {
            continue;
        }
        let mut exited = false;
        let mut unknown = false;
        let mut identity_edge = false;
        let mut detected_manifest = None;
        // Identity refreshes are coalesced per terminal. A PID change clears
        // the cached identity immediately, and the bounded refresh catches
        // same-PID `exec` replacements without a lookup on every tick.
        match resolver(&surface) {
            ProcessLookup::Name(name) => {
                let manifest = manifests.identify(&name);
                detected_manifest = manifest;
                identity_edge = tracker
                    .note_foreground_agent(terminal_id, manifest.map(|manifest| manifest.id()));
            }
            ProcessLookup::Exited => {
                identity_edge = tracker.note_foreground_agent(terminal_id, None);
                exited = true;
            }
            ProcessLookup::Unknown => {
                let prior_agent = tracker
                    .invalidate_foreground_identity(terminal_id)
                    .or_else(|| mux.agent_roster_agent_for_terminal(&terminal_public_id));
                // Unknown process identity is a fail-closed state. Retire a
                // detected row instead of leaving it live indefinitely when
                // process metadata is unavailable. A later successful lookup
                // can create a fresh generation through the normal identity
                // edge path.
                if mux.agent_roster_source_for_terminal(&terminal_public_id)
                    == Some(crate::AgentSource::Detected)
                {
                    if let Some(agent) = prior_agent
                        && !mux.screen_detect_pending_for_terminal(&terminal_public_id)
                    {
                        let _ = mux.append_screen_detect_event(&super::ScreenDetectEmission {
                            terminal_id: terminal_id.to_string(),
                            agent,
                            state: crate::AgentState::Done,
                        });
                    }
                }
                unknown = true;
            }
        }
        if identity_edge {
            // A pending emission belongs to the prior foreground identity.
            // Remove it before admitting state for the new generation.
            mux.discard_screen_detect_pending_for_terminal(&terminal_public_id);
            tracker.clear_pending_emission(terminal_id);
        }
        if let Some(pending) = tracker.pending_emission(terminal_id) {
            if mux.append_screen_detect_event(&pending).is_ok() {
                // The durable row was staged by the original failed append.
                // Clear it after this in-memory retry succeeds to prevent a
                // duplicate admission with a new idempotency key.
                mux.discard_screen_detect_pending_for_terminal(&terminal_public_id);
                tracker.clear_pending_emission(terminal_id);
            }
            if tracker.pending_emission(terminal_id).is_some() {
                continue;
            }
        } else if mux.agent_hook_pending_for_terminal(&terminal_public_id)
            && tracker.pending_retry_due(terminal_id, now)
        {
            // Actively retry the durable row. The registry row owns its
            // original idempotency key, so retries cannot duplicate events.
            let _ = mux.retry_pending_agent_hooks_for_terminal(&terminal_public_id);
            if mux.agent_hook_pending_for_terminal(&terminal_public_id) {
                // A queued emission must be admitted before newer screen
                // states, otherwise retry order can invert the roster.
                tracker.defer_pending_retry(terminal_id, now);
                continue;
            }
            tracker.clear_pending_retry(terminal_id);
        }
        if unknown {
            // Keep the prior identity and roster state. The next scan can
            // retry process lookup without emitting a false Done edge.
            continue;
        }
        if !tracker.foreground_identity_known(terminal_id) {
            // No successful process lookup has established an identity yet.
            // Screen text alone must not promote a stale or unknown process.
            continue;
        }
        if tracker.has_live_emission(terminal_id)
            && !matches!(
                mux.agent_roster_source_for_terminal(&terminal_public_id),
                Some(crate::AgentSource::Detected) | Some(crate::AgentSource::Hook)
            )
        {
            // A hook can claim and later release a terminal while the
            // foreground process remains unchanged. Re-arm the screen state
            // when the durable roster no longer has a stronger owner, so the
            // detected entry returns on the next scan instead of waiting for
            // the long stale-state interval.
            tracker.clear_emitted_state(terminal_id);
        }
        let stale_rearm = tracker.rearm_stale_emission(terminal_id, now);
        // `detected_manifest` comes from the lookup performed for this scan.
        // Never attribute screen text from a cached process name.
        let manifest = detected_manifest;
        let emission = if exited {
            // Exit is a confirmed identity edge. Close a live screen-derived
            // entry; a terminal that never emitted stays silent.
            tracker.record_detection(terminal_id, None)
        } else {
            match manifest {
                None => {
                    // A known non-agent process closes a live screen-derived
                    // entry; a terminal that never emitted stays silent.
                    tracker.record_detection(terminal_id, None)
                }
                Some(manifest) if quiesced || identity_edge || stale_rearm => {
                    let Ok(Ok(screen)) =
                        surface.try_with_terminal(|terminal| terminal.viewport_text())
                    else {
                        tracker.retry_detection(terminal_id, now);
                        continue;
                    };
                    let title = surface.title();
                    let detection = manifest.detect(DetectionInput {
                        screen: &screen,
                        osc_title: &title,
                        // OSC 9;4 progress is not captured server-side yet;
                        // progress-region rules simply never match.
                        osc_progress: "",
                    });
                    tracker.record_detection(terminal_id, Some((manifest.id(), detection)))
                }
                Some(_) => None,
            }
        };
        if let Some(emission) = emission {
            if mux.append_screen_detect_event(&emission).is_err() {
                // append_screen_detect_event stages the exact ingress and
                // idempotency key durably. Keep an in-memory fallback only
                // if that staging also failed.
                if !mux.screen_detect_pending_for_terminal(&terminal_public_id) {
                    tracker.stage_failed_emission(emission);
                }
            }
        }
    }
}
