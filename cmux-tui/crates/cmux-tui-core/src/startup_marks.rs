//! The daemon's startup timeline: one write-once time per step of the
//! server's start, measured from the binary's `main`, and the readiness flag
//! of the server that serves a mux. `identify {startup_marks: true}` reports
//! the timeline (`startup-marks-v1`), and the app records each step as a
//! `daemon.<step>` launch mark beside its own.
//!
//! Chrome records each startup milestone once per process against one
//! origin, the process start
//! (components/startup_metric_utils/common/startup_metric_utils.cc,
//! `RecordApplicationStartTime`, `RecordChromeMainEntryTime`); the store is a
//! fixed array of atomics, so a mark never allocates or takes a lock and a
//! repeated mark is one load.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

/// A step of the daemon's start, in the order the server reaches it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartupMark {
    /// The startup configuration was read (before the server starts).
    ConfigLoaded,
    /// The owner's process setup ran (`owner_start::prepare`).
    OwnerPrepared,
    /// The session socket is bound and answers as a restoring owner.
    SocketBound,
    /// The registry is open and its terminals adopted.
    MuxRestored,
    /// The local owner's event loop runs.
    OwnerEventLoop,
    /// The WebSocket control listener step is done (bound, or none asked).
    WebsocketReady,
    /// The launch snapshot writer step is done (`launch-snapshot-v1`).
    LaunchSnapshotWriterStarted,
    /// Every owner the lifecycle commands need is installed.
    LifecycleReady,
    /// The first `identify` answered once the lifecycle is ready; an
    /// `identify` a parked or early client sends before that is not counted,
    /// so this is always the last step.
    FirstIdentifyServed,
}

impl StartupMark {
    /// Every step, in the order the server reaches them.
    pub const ALL: [Self; 9] = [
        Self::ConfigLoaded,
        Self::OwnerPrepared,
        Self::SocketBound,
        Self::MuxRestored,
        Self::OwnerEventLoop,
        Self::WebsocketReady,
        Self::LaunchSnapshotWriterStarted,
        Self::LifecycleReady,
        Self::FirstIdentifyServed,
    ];

    /// The step's field in `identify`'s `startup_marks`.
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::ConfigLoaded => "config_loaded",
            Self::OwnerPrepared => "owner_prepared",
            Self::SocketBound => "socket_bound",
            Self::MuxRestored => "mux_restored",
            Self::OwnerEventLoop => "owner_event_loop",
            Self::WebsocketReady => "websocket_ready",
            Self::LaunchSnapshotWriterStarted => "launch_snapshot_writer_started",
            Self::LifecycleReady => "lifecycle_ready",
            Self::FirstIdentifyServed => "first_identify_served",
        }
    }

    const fn slot(self) -> usize {
        self as usize
    }
}

/// Advertised by a daemon whose mux has a startup timeline: `identify
/// {startup_marks: true}` then reports it.
pub const CAPABILITY: &str = "startup-marks-v1";

/// The wall-clock field of `identify`'s `startup_marks`: Unix microseconds
/// at the origin every step is measured from.
pub const MAIN_START_FIELD: &str = "main_start_unix_us";

/// One daemon's startup timeline: each step's first time, in microseconds
/// after `main` began.
pub struct StartupMarks {
    origin: Instant,
    origin_unix_us: u64,
    /// Microseconds after `origin` plus one, by step; 0 until reached.
    reached: [AtomicU64; StartupMark::ALL.len()],
}

impl StartupMarks {
    /// A timeline whose origin is now (the first statement of `main`).
    pub fn starting_now() -> Self {
        Self::starting_at(Instant::now(), SystemTime::now())
    }

    /// A timeline whose origin is `origin`, which the wall clock read as `wall`.
    pub fn starting_at(origin: Instant, wall: SystemTime) -> Self {
        let origin_unix_us = wall
            .duration_since(UNIX_EPOCH)
            .map_or(0, |since| u64::try_from(since.as_micros()).unwrap_or(u64::MAX));
        Self { origin, origin_unix_us, reached: std::array::from_fn(|_| AtomicU64::new(0)) }
    }

    /// Records `mark` now unless it was recorded before.
    pub fn mark(&self, mark: StartupMark) {
        if self.reached[mark.slot()].load(Ordering::Relaxed) == 0 {
            self.mark_at(mark, Instant::now());
        }
    }

    /// Records `mark` at `at` unless it was recorded before; a time before
    /// the origin counts as the origin.
    pub fn mark_at(&self, mark: StartupMark, at: Instant) {
        let micros = u64::try_from(at.saturating_duration_since(self.origin).as_micros())
            .unwrap_or(u64::MAX - 1);
        let _first = self.reached[mark.slot()].compare_exchange(
            0,
            micros.saturating_add(1),
            Ordering::Relaxed,
            Ordering::Relaxed,
        );
    }

    /// Microseconds after the origin at which `mark` was first recorded.
    pub fn reached(&self, mark: StartupMark) -> Option<u64> {
        self.reached[mark.slot()].load(Ordering::Relaxed).checked_sub(1)
    }

    /// `identify`'s `startup_marks`: the origin's wall clock and each reached
    /// step.
    pub fn wire(&self) -> Value {
        let mut fields = Map::with_capacity(StartupMark::ALL.len() + 1);
        fields.insert(MAIN_START_FIELD.into(), json!(self.origin_unix_us));
        for mark in StartupMark::ALL {
            if let Some(micros) = self.reached(mark) {
                fields.insert(mark.wire_name().into(), json!(micros));
            }
        }
        Value::Object(fields)
    }
}

/// The readiness and the startup timeline of the server that serves a mux.
/// A mux no daemon serves (tests, an in-process client) has no timeline.
#[derive(Default)]
pub(crate) struct ServerStartup {
    ready: AtomicBool,
    marks: OnceLock<Arc<StartupMarks>>,
}

impl ServerStartup {
    /// Records `LifecycleReady` before publishing readiness, so an identify
    /// that sees the server ready is timed after it.
    pub(crate) fn mark_ready(&self) {
        self.mark(StartupMark::LifecycleReady);
        self.ready.store(true, Ordering::Release);
    }

    pub(crate) fn is_ready(&self) -> bool {
        self.ready.load(Ordering::Acquire)
    }

    /// Adopts the serving daemon's timeline; only the first one is kept.
    pub(crate) fn install(&self, marks: Arc<StartupMarks>) {
        let _first = self.marks.set(marks);
    }

    /// Records `mark` once. `FirstIdentifyServed` counts only once the server
    /// is ready, so it never comes before `LifecycleReady`.
    pub(crate) fn mark(&self, mark: StartupMark) {
        if mark == StartupMark::FirstIdentifyServed && !self.is_ready() {
            return;
        }
        if let Some(marks) = self.marks.get() {
            marks.mark(mark);
        }
    }

    pub(crate) fn marks(&self) -> Option<&StartupMarks> {
        self.marks.get().map(Arc::as_ref)
    }
}

#[cfg(test)]
#[path = "startup_marks_tests.rs"]
mod tests;
