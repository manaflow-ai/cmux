//! Daemon-side screen-detection scanner.
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

/// Sampling cadence: per terminal per tick, one atomic revision read. A
/// separate paced and budgeted foreground lookup selects the manifest.
/// Viewport text is only extracted on quiescence or an identity edge.
const SCAN_INTERVAL: Duration = Duration::from_millis(100);
/// Bound process-group lookups per sampling pass. The rotating start index
/// gives every terminal a turn when the live catalog is larger than this.
const MAX_FOREGROUND_LOOKUPS_PER_SCAN: usize = 64;

/// Result of resolving the foreground process. `Unavailable` is distinct
/// from `Exited`: procfs and platform lookups can fail transiently, and that
/// must not close a live agent row or turn a retry into a state edge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ProcessNameResolution {
    Name(String),
    Exited,
    Unavailable,
}

/// Resolves a surface to its foreground process name; injectable so tests
/// drive detection without spawning agent-named processes.
pub(crate) type ProcessNameResolver = dyn Fn(&Surface) -> ProcessNameResolution + Send + Sync;

pub(crate) fn start(mux: &Arc<Mux>) {
    let weak = Arc::downgrade(mux);
    let spawned = std::thread::Builder::new()
        .name("mux-screen-detect".into())
        .spawn(move || run_scanner(weak));
    if spawned.is_err() {
        eprintln!("cmux-tui: screen-detection scanner unavailable");
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
            scan(&mux, &mut tracker, manifests, Instant::now(), &foreground_process_name);
        }
        // Fixed sampling cadence (the debounce clock), not a synchronization
        // substitute: nothing waits on this thread.
        std::thread::sleep(SCAN_INTERVAL);
    }
}

/// Production resolver: the foreground process-group leader's executable
/// name for the terminal's PTY child. A missing terminal is exited; a failed
/// platform lookup is unavailable and is retried without changing identity.
fn foreground_process_name(surface: &Surface) -> ProcessNameResolution {
    if surface.terminal_exit().is_some() {
        return ProcessNameResolution::Exited;
    }
    let Some(pid) = surface.process_id() else {
        return ProcessNameResolution::Unavailable;
    };
    crate::platform::foreground_process_name(pid)
        .map(ProcessNameResolution::Name)
        .unwrap_or(ProcessNameResolution::Unavailable)
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
    let terminals = mux.screen_detect_terminals();
    // Build an index once. The tracker can contain thousands of retired
    // terminals, so scanning the live list for every tracked entry creates
    // an avoidable O(tracked × live) pass on every tick.
    let live_terminal_ids = terminals.iter().map(|(id, _)| id.as_str()).collect::<HashSet<_>>();
    tracker.retain_terminals(|terminal_id| live_terminal_ids.contains(terminal_id));
    let start = tracker.scan_start(terminals.len());
    let mut lookup_budget = MAX_FOREGROUND_LOOKUPS_PER_SCAN;
    for offset in 0..terminals.len() {
        let index = (start + offset) % terminals.len();
        let (terminal_id, surface) = &terminals[index];
        let Ok(revision) = surface.terminal_stream_revision() else { continue };
        let terminal_id = terminal_id.as_str();
        // Identity checks have their own per-terminal deadline and a global
        // budget. A stalled or very large terminal catalog cannot turn this
        // fixed-cadence thread into an unbounded procfs fan-out.
        let mut closes_identity = false;
        let mut identity_edge = false;
        let manifest = if lookup_budget > 0 && tracker.foreground_check_due(terminal_id, now) {
            lookup_budget -= 1;
            match resolver(surface) {
                ProcessNameResolution::Name(name) => {
                    let manifest = manifests.identify(&name);
                    tracker.note_foreground_check(terminal_id, now, false);
                    identity_edge = tracker
                        .note_foreground_agent(terminal_id, manifest.map(|manifest| manifest.id()));
                    closes_identity = manifest.is_none();
                    manifest
                }
                ProcessNameResolution::Exited => {
                    tracker.note_foreground_check(terminal_id, now, false);
                    identity_edge = tracker.note_foreground_agent(terminal_id, None);
                    closes_identity = true;
                    None
                }
                ProcessNameResolution::Unavailable => {
                    tracker.note_foreground_unavailable(terminal_id, now);
                    None
                }
            }
        } else {
            match tracker.cached_foreground_identity(terminal_id) {
                Some(Some(name)) => manifests.identify(&name),
                Some(None) | None => None,
            }
        };
        // Observe after the identity edge so the immediate evaluation also
        // records its pacer timestamp before later output is debounced.
        let quiesced = tracker.observe_revision(terminal_id, revision, now);
        let emission = match manifest {
            None if closes_identity => {
                // Not an agent (or the agent exited). Closes a live
                // screen-derived entry; a terminal that never emitted
                // stays silent.
                tracker.record_detection(terminal_id, None)
            }
            None => None,
            Some(manifest) if quiesced || identity_edge => {
                let Ok(Ok(screen)) = surface.try_with_terminal(|terminal| terminal.viewport_text())
                else {
                    tracker.note_evaluation_failure(terminal_id, now);
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
        };
        if let Some(emission) = emission {
            mux.append_screen_detect_event(&emission);
        }
    }
}
