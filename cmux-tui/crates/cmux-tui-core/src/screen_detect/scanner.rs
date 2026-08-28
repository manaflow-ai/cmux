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

/// Sampling cadence: per terminal per tick, one atomic revision read plus
/// one foreground process-group lookup (two proc syscalls). Viewport text
/// is only extracted on quiescence or an identity edge. The cadence also
/// bounds spawn-detection latency: a launched agent appears within one
/// tick plus the journal fold.
const SCAN_INTERVAL: Duration = Duration::from_millis(100);

/// Resolves a surface to its foreground process name; injectable so tests
/// drive detection without spawning agent-named processes.
pub(crate) type ProcessNameResolver = dyn Fn(&Surface) -> Option<String> + Send + Sync;

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
/// name for the terminal's PTY child. An exited terminal resolves to none.
fn foreground_process_name(surface: &Surface) -> Option<String> {
    if surface.terminal_exit().is_some() {
        return None;
    }
    crate::platform::foreground_process_name(surface.process_id()?)
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
    for (terminal_id, surface) in terminals {
        let Ok(revision) = surface.terminal_stream_revision() else { continue };
        let terminal_id = terminal_id.as_str();
        // Identity is resolved every tick: presence comes from the
        // foreground process, so a freshly launched agent is detected on
        // the next scan, never gated behind output quiescence.
        let manifest = resolver(&surface).and_then(|name| manifests.identify(&name));
        tracker.note_foreground_agent(terminal_id, manifest.map(|manifest| manifest.id()));
        // Observe after the identity edge so the immediate evaluation also
        // records its pacer timestamp before later output is debounced.
        let quiesced = tracker.observe_revision(terminal_id, revision, now);
        let emission = match manifest {
            None => {
                // Not an agent (or the agent exited). Closes a live
                // screen-derived entry; a terminal that never emitted
                // stays silent.
                tracker.record_detection(terminal_id, None)
            }
            Some(manifest) if quiesced => {
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
