//! The holder's trace recording ([`wire::capability::TRACE_CONTROL`]): a
//! granted TRACE_START and TRACE_STOP drive the process's tracer, and the
//! recording ends with the link that started it, as a Perfetto tracing
//! session ends when its consumer disconnects
//! (perfetto `src/tracing/service/tracing_service_impl.cc`,
//! `DisconnectConsumer`). Nothing here does disk I/O on the holder's loop.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use super::{Holder, error_code};
use crate::wire::{self, Kind};

/// What the holder does with a granted [`Kind::TraceStart`] and
/// [`Kind::TraceStop`]: the seam between the wire and the process's
/// tracer. Every call runs on the holder's loop and must not block.
pub trait TraceControl {
    /// Whether this process records traces: only then does the holder
    /// grant [`wire::capability::TRACE_CONTROL`].
    fn available(&self) -> bool;
    /// Start recording `request.categories` within `request.budget_bytes`:
    /// at once, or once its ring is ready ([`Self::poll`]).
    fn start(&mut self, request: wire::TraceStart) -> Result<(), String>;
    /// Stop the recording, or the start still waiting for its ring.
    fn stop(&mut self) -> Result<(), String>;
    /// The result of a start that waited for its ring, the turn it ran.
    fn poll(&mut self) -> Option<Result<(), String>> {
        None
    }
}

/// The process's own tracer (`cmux_trace`). The first start maps the
/// recording ring on the one-shot `cmux-holder-trace-map` thread, which
/// wakes the loop when it is done; the start then runs in memory. The map
/// thread starts through cmux_threads at Utility (QOS_CLASS_UTILITY on
/// macOS), never at the loop's echo class.
pub struct ProcessTrace {
    /// Set by the map thread once the recording ring is mapped.
    mapped: Arc<AtomicBool>,
    /// The map thread was started.
    mapping: bool,
    /// The categories of a start waiting for the map thread.
    waiting: Option<u64>,
    /// Wakes the holder's loop (its self-pipe).
    wake: fn(),
    /// Maps the recording ring, on the map thread.
    map: fn(),
}

impl ProcessTrace {
    /// The tracer of this process; `wake` wakes the loop that polls it.
    pub fn new(wake: fn()) -> Self {
        Self::with_map(wake, map_ring)
    }

    fn with_map(wake: fn(), map: fn()) -> Self {
        Self { mapped: Arc::default(), mapping: false, waiting: None, wake, map }
    }

    /// Bytes of the holder's recording ring ("Sizes by role"): what a
    /// TRACE_START's `budget_bytes` must leave room for.
    pub fn recording_bytes() -> u64 {
        cmux_trace::RingLayout::of(cmux_trace::Role::Holder.recording_sizes()).total_bytes as u64
    }

    fn start_now(categories: u64) -> Result<(), String> {
        cmux_trace::start_recording(categories).map(drop).map_err(|error| error.to_string())
    }
}

impl TraceControl for ProcessTrace {
    fn available(&self) -> bool {
        cmux_trace::status().is_some()
    }

    fn start(&mut self, request: wire::TraceStart) -> Result<(), String> {
        let bytes = Self::recording_bytes();
        if request.budget_bytes != 0 && bytes > request.budget_bytes {
            return Err(format!(
                "the holder's recording ring is {bytes} bytes, over its budget of {}",
                request.budget_bytes
            ));
        }
        if self.waiting.is_some() {
            return Err(cmux_trace::TraceError::AlreadyRecording.to_string());
        }
        if self.mapped.load(Ordering::Acquire) {
            return Self::start_now(request.categories);
        }
        if !self.mapping {
            let (mapped, wake, map) = (self.mapped.clone(), self.wake, self.map);
            // supervise-allow: one-shot map of the trace ring; a panic leaves the ring unmapped, so this trace request stays waiting and the holder's terminals are not touched.
            cmux_threads::spawn(
                "cmux-holder-trace-map",
                cmux_threads::ThreadQos::Utility,
                move || {
                    map();
                    mapped.store(true, Ordering::Release);
                    wake();
                },
            )
            .map_err(|error| format!("map the recording ring: {error}"))?;
            self.mapping = true;
        }
        self.waiting = Some(request.categories);
        Ok(())
    }

    fn stop(&mut self) -> Result<(), String> {
        if self.waiting.take().is_some() {
            return Ok(());
        }
        cmux_trace::stop().map(drop).map_err(|error| error.to_string())
    }

    fn poll(&mut self) -> Option<Result<(), String>> {
        if self.waiting.is_none() || !self.mapped.load(Ordering::Acquire) {
            return None;
        }
        self.waiting.take().map(Self::start_now)
    }
}

/// Maps the recording ring; a failure shows in the start that follows.
fn map_ring() {
    let _ = cmux_trace::prepare_recording();
}

impl Holder {
    /// Send granted TRACE_START and TRACE_STOP frames to `trace` instead of
    /// the process's tracer ([`ProcessTrace`]).
    pub fn set_trace_control(&mut self, trace: Box<dyn TraceControl>) {
        self.trace = trace;
    }

    /// Whether the link was granted `capability` ([`wire::capability`]).
    pub(super) fn granted(&self, capability: u32) -> bool {
        self.link.as_ref().is_some_and(|link| link.granted & capability != 0)
    }

    /// The [`wire::capability`] bits this holder serves: TRACE_CONTROL only
    /// while its tracer records ([`TraceControl::available`]).
    pub(super) fn served_capabilities(&self) -> u32 {
        let mut served = wire::capability::SUPPORTED;
        if !self.trace.available() {
            served &= !wire::capability::TRACE_CONTROL;
        }
        served
    }

    /// Handle a TRACE_START or TRACE_STOP of a link granted TRACE_CONTROL.
    pub(super) fn trace_frame(&mut self, kind: Kind, payload: &[u8]) -> Result<(), (u16, String)> {
        let result = if kind == Kind::TraceStart {
            let request = wire::TraceStart::decode(payload)
                .map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
            let started = self.trace.start(request);
            // A refused start leaves the running recording as it was.
            self.link_recording |= started.is_ok();
            started
        } else {
            // Stopped, or none ran.
            self.link_recording = false;
            self.trace.stop()
        };
        result.map_err(|why| (error_code::TRACE_FAILED, why))
    }

    /// Report a start that waited for its ring and then failed.
    pub(super) fn poll_trace(&mut self) {
        if let Some(Err(why)) = self.trace.poll() {
            self.link_recording = false;
            self.refuse(Kind::TraceStart as u16, 0, error_code::TRACE_FAILED, &why);
        }
    }

    /// The link that started the recording is gone: its consumer is, so
    /// the recording stops. A new daemon starts its own.
    pub(super) fn end_link_recording(&mut self) {
        if std::mem::take(&mut self.link_recording) {
            let _ = self.trace.stop();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;

    /// The lib's unit tests start no `cmux_trace` tracer: the map thread
    /// maps nothing, and the waiting start fails on the poll.
    fn mapped(trace: &ProcessTrace) {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !trace.mapped.load(Ordering::Acquire) {
            assert!(Instant::now() < deadline, "the map thread never ended");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn a_start_waits_for_its_ring_and_a_stop_before_it_cancels_it() {
        let mut trace = ProcessTrace::new(|| {});
        assert!(!trace.available());
        let request = wire::TraceStart { categories: 1, budget_bytes: 0 };
        trace.start(request).unwrap();
        assert!(trace.start(request).is_err(), "one start waits at a time");
        trace.stop().unwrap();
        mapped(&trace);
        assert_eq!(trace.poll(), None, "the cancelled start never runs");

        assert!(trace.start(request).is_err(), "mapped: it runs at once and finds no tracer");
        let mut waiting = ProcessTrace::new(|| {});
        waiting.start(request).unwrap();
        mapped(&waiting);
        let failed = waiting.poll().expect("the start ran").unwrap_err();
        assert_eq!(failed, cmux_trace::TraceError::NotInitialized.to_string());
    }

    /// The loop runs at USER_INTERACTIVE, and the map
    /// thread it starts runs at UTILITY, not at the class it inherits.
    #[test]
    fn the_map_thread_runs_at_utility_below_the_loop() {
        use cmux_threads::{LiveQos, QosChange, ThreadQos};
        static SEEN: std::sync::Mutex<Option<LiveQos>> = std::sync::Mutex::new(None);
        fn record() {
            *SEEN.lock().unwrap() = Some(cmux_threads::current());
        }
        std::thread::spawn(|| {
            if cfg!(target_vendor = "apple") {
                assert_eq!(
                    cmux_threads::set_current(ThreadQos::UserInteractive),
                    QosChange::Applied
                );
            }
            let mut trace = ProcessTrace::with_map(|| {}, record);
            trace.start(wire::TraceStart { categories: 1, budget_bytes: 0 }).unwrap();
            mapped(&trace);
        })
        .join()
        .unwrap();
        let seen = SEEN.lock().unwrap().expect("the map ran");
        if cfg!(target_vendor = "apple") {
            assert_eq!(seen, LiveQos::Class(ThreadQos::Utility));
        }
    }
}
