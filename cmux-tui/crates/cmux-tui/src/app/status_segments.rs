//! Status line segments: template token expansion, the resolved segment view,
//! and the background worker that re-runs segment commands and pokes the app.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use crossbeam_channel::Sender as SyncSender;
use ratatui::style::Color;

use crate::app::events::AppEvent;
use crate::app::status_command::{capture_status_output, strip_escape_sequences};

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

/// Shared stop signal for status workers. `raise` wakes idle waiters
/// immediately, so retiring a worker never waits out a sleep interval, and
/// an idle worker wakes once per interval instead of polling.
pub(super) struct StatusWorkerStop {
    pub(super) raised: AtomicBool,
    pub(super) lock: Mutex<()>,
    pub(super) condvar: Condvar,
}

impl StatusWorkerStop {
    pub(super) fn new() -> Self {
        Self { raised: AtomicBool::new(false), lock: Mutex::new(()), condvar: Condvar::new() }
    }

    pub(super) fn raise(&self) {
        self.raised.store(true, Ordering::Release);
        let _guard = self.lock.lock().unwrap();
        self.condvar.notify_all();
    }

    pub(super) fn is_raised(&self) -> bool {
        self.raised.load(Ordering::Acquire)
    }

    /// Wait until raised or the duration elapses; returns whether raised.
    pub(super) fn wait_timeout(&self, duration: Duration) -> bool {
        let deadline = Instant::now() + duration;
        let mut guard = self.lock.lock().unwrap();
        while !self.is_raised() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            let (next, _) = self.condvar.wait_timeout(guard, remaining).unwrap();
            guard = next;
        }
        self.is_raised()
    }
}

/// Per-segment status worker: runs one command on its own interval, so one
/// slow command never delays another segment, and publishes on change.
/// The capture path checks the stop flag every poll tick and the idle wait
/// is condvar-based, so a stopped worker exits within milliseconds and an
/// idle worker never busy-polls. The shared `poke` flag coalesces redraw
/// events: when several segments change together, only one event is sent
/// until the event loop consumes it.
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

pub(super) fn run_status_segment_loop(worker: StatusSegmentWorker) {
    const STATUS_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
    let StatusSegmentWorker { index, argv, interval, outputs, generation, poke, events, stop } =
        worker;
    let mut pending_notify = false;
    let mut unreaped: Option<std::process::Child> = None;
    while !stop.is_raised() {
        // A previous command stuck in uninterruptible kernel I/O survives
        // SIGKILL; never stack another process behind it, and reap it once
        // the kernel releases it, so stuck processes stay bounded at one
        // per segment with no lasting zombie.
        // A reaped predecessor is dropped by the reassignment below.
        if let Some(child) = unreaped.as_mut()
            && matches!(child.try_wait(), Ok(None))
        {
            if stop.wait_timeout(interval) {
                return;
            }
            continue;
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
            pending_notify = true;
        }
        try_send_status_poke(&poke, &events, &mut pending_notify);
        // Sleep out the interval, but wake on a short cadence while a poke
        // is still pending so a transiently full event queue delays the
        // update by moments, not by the configured interval. The command
        // itself never re-runs before its interval elapses.
        let deadline = Instant::now() + interval;
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            let wait =
                if pending_notify { remaining.min(Duration::from_millis(500)) } else { remaining };
            if stop.wait_timeout(wait) {
                return;
            }
            try_send_status_poke(&poke, &events, &mut pending_notify);
        }
    }
}

/// Attempt to deliver one coalesced status redraw poke. Clears
/// `pending_notify` when this worker's poke was delivered or another
/// worker's poke is already in flight (that draw reads the same shared
/// outputs); releases the poke on a full queue so the retry stays possible.
pub(super) fn try_send_status_poke(
    poke: &AtomicBool,
    events: &SyncSender<AppEvent>,
    pending_notify: &mut bool,
) {
    if !*pending_notify {
        return;
    }
    if poke.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_ok() {
        if events.try_send(AppEvent::StatusCommandsUpdated).is_ok() {
            *pending_notify = false;
        } else {
            poke.store(false, Ordering::Release);
        }
    } else {
        *pending_notify = false;
    }
}

/// Run one status command with a bounded runtime and return its last
/// nonempty stdout line, stripped of escape sequences and length-capped.
/// The capture path uses no reader thread: on Unix the pipe is
/// non-blocking and drained from this loop while the child runs in its own
/// process group (a timeout or stop kills the whole tree), and on Windows
/// stdout goes to a temporary file, which reads without blocking on
/// writers. Setting `stop` makes the call return within one poll tick.
/// The `USER` environment value, read once: template expansion runs on the
/// draw path and the value cannot change within one process.
pub(super) fn cached_status_user() -> &'static str {
    static USER: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    USER.get_or_init(|| {
        std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_default()
    })
}

/// Returns the segment text plus the child when it could not be reaped
/// (stuck in uninterruptible kernel I/O); the segment loop keeps at most
/// one such child and never starts another command behind it.
pub(super) fn run_status_command(
    argv: &[String],
    timeout: Duration,
    stop: &StatusWorkerStop,
) -> (String, Option<std::process::Child>) {
    const MAX_STATUS_OUTPUT_CHARS: usize = 200;
    let (captured, stuck_child) = capture_status_output(argv, timeout, stop);
    let text = String::from_utf8_lossy(&captured);
    let line = text.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or("").trim();
    (strip_escape_sequences(line).chars().take(MAX_STATUS_OUTPUT_CHARS).collect(), stuck_child)
}
