//! Status line segments: template token expansion, the resolved segment view,
//! and the background worker that re-runs segment commands and pokes the app.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_tui_core::backoff::Backoff;
use cmux_tui_core::wake;
use crossbeam_channel::Sender as SyncSender;
use ratatui::style::Color;

use crate::app::events::{AppEvent, EventCancellation, send_bounded_cancelable};
use crate::app::status_command::{
    RunningStatusCommand, capture_status_output, kill_running_status_command,
    strip_escape_sequences,
};

/// Resolved left and right status segments, in draw order.
pub(super) type ResolvedStatusSegments = (Vec<StatusSegmentView>, Vec<StatusSegmentView>);

/// The values one status template expansion can interpolate.
pub(super) struct StatusTemplateValues<'a> {
    pub(super) session: &'a str,
    pub(super) workspace: &'a str,
    pub(super) screen: &'a str,
    pub(super) screens: &'a str,
    pub(super) title: &'a str,
    pub(super) user: &'a str,
}

/// Expand `{variable}` tokens in one left-to-right pass, so an inserted
/// value is never rescanned: a workspace literally named `{screens}` stays
/// `{screens}` in the output. Unknown tokens stay literal.
pub(super) fn expand_status_tokens(template: &str, values: &StatusTemplateValues<'_>) -> String {
    let mut result = String::with_capacity(template.len() + 16);
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        result.push_str(&rest[..start]);
        let candidate = &rest[start..];
        let Some(end) = candidate.find('}') else {
            result.push_str(candidate);
            return result;
        };
        match &candidate[1..end] {
            "session" => result.push_str(values.session),
            "workspace" => result.push_str(values.workspace),
            "screen" => result.push_str(values.screen),
            "screens" => result.push_str(values.screens),
            "title" => result.push_str(values.title),
            "user" => result.push_str(values.user),
            _ => result.push_str(&candidate[..=end]),
        }
        rest = &candidate[end + 1..];
    }
    result.push_str(rest);
    result
}

/// One status segment resolved for drawing.
#[derive(Clone)]
pub(crate) struct StatusSegmentView {
    pub(crate) text: String,
    pub(crate) fg: Option<Color>,
    pub(crate) bg: Option<Color>,
}

/// Shared stop signal for status workers. `raise` ends every wait of the
/// generation at once: the interval waits and blocked pokes see the
/// cancellation channel close, and each running command is killed (its
/// process group on Unix, its job on Windows), which ends its capture
/// through the exit and end-of-output events.
pub(super) struct StatusWorkerStop {
    pub(super) cancellation: EventCancellation,
    /// The commands running now. One stays here only while its capture owns
    /// it (the group leader unreaped, the job handle open), so `raise` never
    /// kills a reused id.
    pub(super) running: Mutex<Vec<RunningStatusCommand>>,
}

impl StatusWorkerStop {
    pub(super) fn new() -> Self {
        Self { cancellation: EventCancellation::new(), running: Mutex::new(Vec::new()) }
    }

    pub(super) fn raise(&self) {
        self.cancellation.cancel();
        for command in self.running.lock().unwrap().drain(..) {
            kill_running_status_command(command);
        }
    }

    pub(super) fn is_raised(&self) -> bool {
        self.cancellation.stop.load(Ordering::Acquire)
    }

    /// Track a started command so `raise` kills it. False when the stop was
    /// already raised: the caller kills the command itself.
    pub(super) fn track(&self, command: RunningStatusCommand) -> bool {
        let mut running = self.running.lock().unwrap();
        if self.is_raised() {
            return false;
        }
        running.push(command);
        true
    }

    /// Forget a command before its capture reaps or kills it.
    pub(super) fn untrack(&self, command: RunningStatusCommand) {
        self.running.lock().unwrap().retain(|running| *running != command);
    }

    /// Wait until raised or `deadline`; returns whether raised.
    pub(super) fn wait_until(&self, deadline: Instant) -> bool {
        // The channel never carries a message: `raise` closes it.
        // wakeup-allow: deadline one wait per run, until the segment's next run on the wake grid
        let _ = self.cancellation.receiver.recv_deadline(deadline);
        self.is_raised()
    }
}

/// Per-segment status worker: runs one command on its own interval, so one
/// slow command never delays another segment, and publishes on change.
/// Each next run is a `wake::deadline` (a whole-second grid with 10%
/// leeway), so segments and the daemon's own deadlines share wakes. The shared
/// `poke` flag coalesces redraw events: when several segments change
/// together, only one event is sent until the event loop consumes it.
pub(super) struct StatusSegmentWorker {
    pub(super) index: usize,
    pub(super) argv: Vec<String>,
    pub(super) interval: Duration,
    pub(super) outputs: Arc<Mutex<HashMap<usize, String>>>,
    pub(super) generation: Arc<AtomicU64>,
    pub(super) poke: Arc<AtomicBool>,
    pub(super) events: SyncSender<AppEvent>,
    pub(super) stop: Arc<StatusWorkerStop>,
}

/// The longest pause between checks of a command that survived SIGKILL.
const STUCK_COMMAND_RECHECK_MAX: Duration = Duration::from_secs(300);

pub(super) fn run_status_segment_loop(worker: StatusSegmentWorker) {
    const STATUS_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
    let StatusSegmentWorker { index, argv, interval, outputs, generation, poke, events, stop } =
        worker;
    let mut unreaped: Option<cmux_process::Child> = None;
    let mut stuck_recheck = Backoff::new(interval, STUCK_COMMAND_RECHECK_MAX.max(interval));
    let mut next_run = Instant::now();
    while !stop.is_raised() {
        // A previous command stuck in uninterruptible kernel I/O survives
        // SIGKILL; never stack another process behind it, and reap it once
        // the kernel releases it, so stuck processes stay bounded at one
        // per segment with no lasting zombie. Its checks back off: the
        // kernel gives no event for the release.
        // A reaped predecessor is dropped by the reassignment below.
        if let Some(child) = unreaped.as_mut()
            // wakeup-allow: backoff a command that survived SIGKILL; checks back off to 5 min, the kernel gives no release event
            && matches!(child.try_wait(), Ok(None))
        {
            if stop.wait_until(Instant::now() + stuck_recheck.next_delay()) {
                return;
            }
            continue;
        }
        stuck_recheck.reset();
        if stop.wait_until(next_run) {
            return;
        }
        let (output, stuck_child) = run_status_command(&argv, STATUS_COMMAND_TIMEOUT, &stop);
        unreaped = stuck_child;
        if stop.is_raised() {
            return;
        }
        let changed = {
            let mut map = outputs.lock().unwrap();
            if map.get(&index) != Some(&output) {
                map.insert(index, output);
                true
            } else {
                false
            }
        };
        if changed {
            generation.fetch_add(1, Ordering::Release);
            send_status_poke(&poke, &events, &stop);
        }
        next_run = next_status_run(interval);
    }
}

/// When a segment runs again: `interval` from now, on the shared wake grid.
pub(super) fn next_status_run(interval: Duration) -> Instant {
    let (now, ticks) = (Instant::now(), wake::Ticks::now());
    now + wake::deadline(ticks, interval, wake::Policy::FlexibleNoSooner).wait_from(ticks)
}

/// Deliver one coalesced status redraw poke. When another worker's poke is
/// already queued, that draw reads the same shared outputs. A full event
/// queue makes this wait for room (or the stop), never retry on a timer.
pub(super) fn send_status_poke(
    poke: &AtomicBool,
    events: &SyncSender<AppEvent>,
    stop: &StatusWorkerStop,
) {
    if poke.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() {
        return;
    }
    if send_bounded_cancelable(events, AppEvent::StatusCommandsUpdated, &stop.cancellation).is_err()
    {
        poke.store(false, Ordering::Release);
    }
}

/// The `USER` environment value, read once: template expansion runs on the
/// draw path and the value cannot change within one process.
pub(super) fn cached_status_user() -> &'static str {
    static USER: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    USER.get_or_init(|| {
        std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_default()
    })
}

/// Run one status command with a bounded runtime and return its last
/// nonempty stdout line, stripped of escape sequences and length-capped.
/// On Unix the pipe is non-blocking and drained from the capture loop,
/// which wakes on output, the child's exit or the deadline while the child
/// runs in its own process group (a timeout or stop kills the whole tree);
/// on Windows a reader thread keeps the output's tail while the capture
/// waits for the exit, and the job kills the tree. Raising `stop` kills the
/// command, so the call returns at once.
///
/// Returns the segment text plus the child when it could not be reaped
/// (stuck in uninterruptible kernel I/O); the segment loop keeps at most
/// one such child and never starts another command behind it.
pub(super) fn run_status_command(
    argv: &[String],
    timeout: Duration,
    stop: &StatusWorkerStop,
) -> (String, Option<cmux_process::Child>) {
    const MAX_STATUS_OUTPUT_CHARS: usize = 200;
    let (captured, stuck_child) = capture_status_output(argv, timeout, stop);
    let text = String::from_utf8_lossy(&captured);
    let line = text.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("").trim();
    (strip_escape_sequences(line).chars().take(MAX_STATUS_OUTPUT_CHARS).collect(), stuck_child)
}
