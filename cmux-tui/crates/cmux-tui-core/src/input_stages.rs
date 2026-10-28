//! A terminal key's stages across processes: when the daemon
//! received the key press, when its bytes reached the PTY and when the read
//! that echoes them came back, stamped on the trace clock
//! (`cmux_trace::clock`, `CLOCK_UPTIME_RAW` on macOS, the app's
//! `NSEvent.timestamp` clock). The output event that carries the key's
//! `flow` also carries these stamps and the time it
//! was sent, so the app's input latency slot fills `daemonReceived`,
//! `ptyWritten`, `echoRead` and `echoSent`, as Chromium's `EventMetrics`
//! takes each dispatch stage's time in the process that saw it
//! (cc/metrics/event_metrics.h).
//!
//! Each terminal has one fixed [`InputStageRing`] of atomics: arming,
//! stamping and reading are atomic loads and stores over
//! [`INPUT_STAGE_RING`] entries, with no lock and no allocation, from the
//! send handler, the PTY reader and the attach writer threads.

use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

/// Key presses one terminal tracks at once. A newer press past this takes
/// the oldest entry; one that had no echo yet is counted
/// ([`InputStageRing::overwritten`]).
pub(crate) const INPUT_STAGE_RING: usize = 16;

/// A press whose echo is read later than this after the daemon received it
/// had no echo (`InputLatencyTracker.contentDeadlineNanos` in the app): its
/// entry is dropped and counted ([`InputStageRing::no_echo`]).
pub(crate) const NO_ECHO_NS: u64 = 500_000_000;

/// Now on the trace clock, in ns.
pub(crate) fn now_ns() -> u64 {
    cmux_trace::clock::now_ns()
}

/// The stamps go to the app only where they are on its clock: macOS's
/// `CLOCK_UPTIME_RAW`. A daemon on another OS serves a remote app, whose
/// clock they do not share. Tests read them on every OS.
pub(crate) const STAMPS_SHARE_APP_CLOCK: bool = cfg!(test)
    || matches!(cmux_trace::clock::ClockDomain::CURRENT, cmux_trace::clock::ClockDomain::UptimeRaw);

/// One key press's daemon-side stamps (trace-clock ns, 0: not reached).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct KeyStages {
    /// The daemon received the `send` that carries the press.
    pub(crate) received_ns: u64,
    /// Its bytes reached the PTY (a hosted terminal: the host's write).
    pub(crate) written_ns: u64,
    /// The PTY read that echoes them (a hosted terminal: the host's read).
    pub(crate) read_ns: u64,
    /// Presses this terminal lost so far: entries a newer press took before
    /// their echo, and echoes past [`NO_ECHO_NS`] ([`InputStageRing::lost`]).
    pub(crate) lost: u64,
}

#[derive(Debug, Default)]
struct Entry {
    /// The press's flow, published last; 0 while the entry is free or being written.
    flow: AtomicU64,
    received: AtomicU64,
    written: AtomicU64,
    read: AtomicU64,
}

/// One terminal's key presses on their way to their echo (module docs).
#[derive(Debug, Default)]
pub(crate) struct InputStageRing {
    entries: [Entry; INPUT_STAGE_RING],
    next: AtomicUsize,
    overwritten: AtomicU64,
    no_echo: AtomicU64,
}

impl InputStageRing {
    /// The daemon received the press `flow` at `received_ns` (0 for either:
    /// nothing). Call it before the bytes go to the PTY: their echo can be
    /// read before the write returns. A press already in the ring (its later
    /// bytes in another `send`) keeps its first receive.
    // perf-hot: 0.05us terminal-key
    pub(crate) fn received(&self, flow: u64, received_ns: u64) {
        if flow == 0 || received_ns == 0 || self.find(flow).is_some() {
            return;
        }
        let entry = &self.entries[self.next.fetch_add(1, Ordering::Relaxed) % INPUT_STAGE_RING];
        let previous = entry.flow.swap(0, Ordering::AcqRel);
        if previous != 0 && entry.read.load(Ordering::Relaxed) == 0 {
            self.overwritten.fetch_add(1, Ordering::Relaxed);
        }
        entry.received.store(received_ns, Ordering::Relaxed);
        entry.written.store(0, Ordering::Relaxed);
        entry.read.store(0, Ordering::Relaxed);
        entry.flow.store(flow, Ordering::Release);
    }

    /// The press `flow`'s bytes reached the PTY at `written_ns`.
    pub(crate) fn written(&self, flow: u64, written_ns: u64) {
        if let Some(entry) = self.find(flow) {
            let _ =
                entry.written.compare_exchange(0, written_ns, Ordering::Relaxed, Ordering::Relaxed);
        }
    }

    /// The read at `read_ns` echoes the press `flow`. The first echo counts;
    /// one later than [`NO_ECHO_NS`] after the receive drops the entry.
    // perf-hot: 0.05us terminal-key
    pub(crate) fn echoed(&self, flow: u64, read_ns: u64) {
        self.stamp_echo(flow, None, read_ns);
    }

    /// A hosted terminal's echo of `flow`: the host's own PTY write and read
    /// times replace the daemon's hand-off to the host (0: the host sent none).
    pub(crate) fn host_echoed(&self, flow: u64, written_ns: u64, read_ns: u64) {
        self.stamp_echo(flow, (written_ns != 0).then_some(written_ns), read_ns);
    }

    fn stamp_echo(&self, flow: u64, written_ns: Option<u64>, read_ns: u64) {
        let Some(entry) = self.find(flow) else { return };
        let received = entry.received.load(Ordering::Relaxed);
        if read_ns < received || read_ns - received > NO_ECHO_NS {
            if entry.flow.compare_exchange(flow, 0, Ordering::AcqRel, Ordering::Relaxed).is_ok() {
                self.no_echo.fetch_add(1, Ordering::Relaxed);
            }
            return;
        }
        if let Some(written) = written_ns {
            entry.written.store(written, Ordering::Relaxed);
        }
        let _ = entry.read.compare_exchange(0, read_ns, Ordering::Release, Ordering::Relaxed);
    }

    /// The stamps of `flow` once its echo was read; `None` before that, or
    /// when a newer press took its entry.
    // perf-hot: 0.05us terminal-key
    pub(crate) fn stages(&self, flow: u64) -> Option<KeyStages> {
        let entry = self.find(flow)?;
        let stages = KeyStages {
            received_ns: entry.received.load(Ordering::Relaxed),
            written_ns: entry.written.load(Ordering::Relaxed),
            read_ns: entry.read.load(Ordering::Acquire),
            lost: self.lost(),
        };
        // A press that took the entry meanwhile wrote some of these: not this flow's. The fence
        // keeps the reads above before the check (a seqlock read).
        std::sync::atomic::fence(Ordering::Acquire);
        (stages.read_ns != 0 && entry.flow.load(Ordering::Relaxed) == flow).then_some(stages)
    }

    /// Presses whose entry a newer one took before their echo came.
    pub(crate) fn overwritten(&self) -> u64 {
        self.overwritten.load(Ordering::Relaxed)
    }

    /// Presses whose echo came later than [`NO_ECHO_NS`].
    pub(crate) fn no_echo(&self) -> u64 {
        self.no_echo.load(Ordering::Relaxed)
    }

    /// Presses lost either way, sent with each echo's stages so the app
    /// counts what the ring dropped.
    pub(crate) fn lost(&self) -> u64 {
        self.overwritten().wrapping_add(self.no_echo())
    }

    fn find(&self, flow: u64) -> Option<&Entry> {
        if flow == 0 {
            return None;
        }
        self.entries.iter().find(|entry| entry.flow.load(Ordering::Acquire) == flow)
    }
}

#[cfg(test)]
mod tests {
    use super::{INPUT_STAGE_RING, InputStageRing, KeyStages, NO_ECHO_NS};

    #[test]
    fn input_stages_a_press_reads_its_stamps_once_echoed() {
        let ring = InputStageRing::default();
        ring.received(42, 100);
        assert_eq!(ring.stages(42), None, "no echo yet");
        ring.written(42, 150);
        ring.written(42, 999);
        ring.echoed(42, 400);
        ring.echoed(42, 900);
        assert_eq!(
            ring.stages(42),
            Some(KeyStages { received_ns: 100, written_ns: 150, read_ns: 400, lost: 0 }),
            "the first write and the first echo count"
        );
        assert_eq!(ring.stages(7), None);
        assert_eq!(ring.stages(0), None);
    }

    #[test]
    fn input_stages_a_press_sent_in_two_parts_keeps_its_first_receive() {
        let ring = InputStageRing::default();
        ring.received(42, 100);
        ring.received(42, 200);
        ring.echoed(42, 300);
        assert_eq!(ring.stages(42).map(|stages| stages.received_ns), Some(100));
        assert_eq!(ring.overwritten(), 0);
    }

    #[test]
    fn input_stages_flow_zero_or_no_clock_arms_nothing() {
        let ring = InputStageRing::default();
        ring.received(0, 100);
        ring.received(42, 0);
        ring.echoed(42, 200);
        assert_eq!(ring.stages(42), None);
        assert_eq!(ring.overwritten(), 0);
    }

    #[test]
    fn input_stages_a_full_ring_drops_the_oldest_and_counts_it() {
        let ring = InputStageRing::default();
        for flow in 1..=INPUT_STAGE_RING as u64 {
            ring.received(flow, flow * 10);
        }
        ring.echoed(1, 20);
        assert_eq!(ring.overwritten(), 0);
        // Takes press 1's entry (echoed: not counted), then press 2's (not echoed: counted).
        ring.received(100, 1_000);
        ring.received(101, 1_000);
        assert_eq!(ring.overwritten(), 1);
        assert_eq!(ring.stages(1), None, "its entry went to a newer press");
        ring.echoed(2, 1_100);
        assert_eq!(ring.stages(2), None);
        ring.echoed(101, 1_200);
        assert_eq!(ring.stages(101).map(|stages| (stages.read_ns, stages.lost)), Some((1_200, 1)));
    }

    #[test]
    fn input_stages_an_echo_past_the_window_drops_the_entry() {
        let ring = InputStageRing::default();
        ring.received(42, 1_000);
        ring.echoed(42, 1_000 + NO_ECHO_NS + 1);
        assert_eq!(ring.stages(42), None);
        assert_eq!(ring.no_echo(), 1);
        ring.echoed(42, 1_000 + NO_ECHO_NS + 2);
        assert_eq!(ring.no_echo(), 1, "counted once");
    }

    #[test]
    fn input_stages_a_hosts_stamps_replace_the_hand_off() {
        let ring = InputStageRing::default();
        ring.received(42, 100);
        ring.written(42, 120);
        ring.host_echoed(42, 130, 300);
        assert_eq!(
            ring.stages(42),
            Some(KeyStages { received_ns: 100, written_ns: 130, read_ns: 300, lost: 0 })
        );
        ring.received(43, 400);
        ring.written(43, 420);
        ring.host_echoed(43, 0, 500);
        assert_eq!(
            ring.stages(43).map(|stages| stages.written_ns),
            Some(420),
            "an older host sent none"
        );
    }

    #[test]
    fn input_stages_threads_never_read_another_press_stamps() {
        let ring = std::sync::Arc::new(InputStageRing::default());
        let writer = {
            let ring = ring.clone();
            std::thread::spawn(move || {
                for flow in 1..20_000u64 {
                    ring.received(flow, flow * 1_000);
                    ring.written(flow, flow * 1_000 + 1);
                    ring.echoed(flow, flow * 1_000 + 2);
                }
            })
        };
        for flow in (1..20_000u64).cycle().take(200_000) {
            if let Some(stages) = ring.stages(flow) {
                assert_eq!(stages.received_ns, flow * 1_000, "flow {flow}");
            }
        }
        writer.join().unwrap();
    }
}
