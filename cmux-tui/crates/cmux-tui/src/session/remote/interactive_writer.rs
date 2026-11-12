//! The ordered write actor for one remote connection: its bounded queue, the worker thread that
//! sends each message, write-completion waits by sequence, and the input latency metrics.

use super::*;

pub(super) struct InteractiveWrite {
    message: String,
    enqueued_at: Instant,
    sequence: u64,
    measure_latency: bool,
}

impl Drop for InteractiveWrite {
    fn drop(&mut self) {
        zeroize_string(&mut self.message);
    }
}

#[derive(Clone)]
pub(super) struct InteractiveWriteFailure {
    pub(super) kind: io::ErrorKind,
    message: String,
}

impl InteractiveWriteFailure {
    fn from_error(error: &io::Error) -> Self {
        Self { kind: error.kind(), message: error.to_string() }
    }

    fn to_error(&self) -> io::Error {
        io::Error::new(self.kind, self.message.clone())
    }
}

#[derive(Default)]
pub(super) struct InteractiveWriteQueueState {
    pub(super) writes: VecDeque<InteractiveWrite>,
    pub(super) queued_bytes: usize,
    last_enqueued_sequence: u64,
    pub(super) last_written_sequence: u64,
    closed: bool,
    pub(super) writer_closed: bool,
    pub(super) failure: Option<InteractiveWriteFailure>,
}

pub(super) struct InteractiveWriteMetrics {
    latency_buckets: [AtomicU64; INTERACTIVE_LATENCY_BUCKET_UPPER_US.len()],
    write_failures: AtomicU64,
    backpressure_rejections: AtomicU64,
}

impl Default for InteractiveWriteMetrics {
    fn default() -> Self {
        Self {
            latency_buckets: std::array::from_fn(|_| AtomicU64::new(0)),
            write_failures: AtomicU64::new(0),
            backpressure_rejections: AtomicU64::new(0),
        }
    }
}

impl InteractiveWriteMetrics {
    pub(super) fn record_latency(&self, latency: Duration) {
        let micros = u64::try_from(latency.as_micros()).unwrap_or(u64::MAX);
        let bucket = INTERACTIVE_LATENCY_BUCKET_UPPER_US
            .partition_point(|upper_bound| *upper_bound < micros)
            .min(self.latency_buckets.len() - 1);
        self.latency_buckets[bucket].fetch_add(1, Ordering::Relaxed);
    }

    pub(super) fn snapshot(&self) -> InteractiveWriteMetricsSnapshot {
        let histogram = self
            .latency_buckets
            .iter()
            .zip(INTERACTIVE_LATENCY_BUCKET_UPPER_US)
            .map(|(samples, upper_bound_micros)| InteractiveLatencyBucket {
                upper_bound: Duration::from_micros(upper_bound_micros),
                samples: samples.load(Ordering::Relaxed),
            })
            .collect::<Vec<_>>();
        let samples = histogram.iter().map(|bucket| bucket.samples).sum();
        InteractiveWriteMetricsSnapshot {
            p50: latency_percentile(&histogram, samples, 50),
            p95: latency_percentile(&histogram, samples, 95),
            p99: latency_percentile(&histogram, samples, 99),
            histogram,
            samples,
            write_failures: self.write_failures.load(Ordering::Relaxed),
            backpressure_rejections: self.backpressure_rejections.load(Ordering::Relaxed),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InteractiveLatencyBucket {
    pub(crate) upper_bound: Duration,
    pub(crate) samples: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InteractiveWriteMetricsSnapshot {
    pub(crate) histogram: Vec<InteractiveLatencyBucket>,
    pub(crate) samples: u64,
    pub(crate) write_failures: u64,
    pub(crate) backpressure_rejections: u64,
    pub(crate) p50: Option<Duration>,
    pub(crate) p95: Option<Duration>,
    pub(crate) p99: Option<Duration>,
}

fn latency_percentile(
    histogram: &[InteractiveLatencyBucket],
    samples: u64,
    percentile: u64,
) -> Option<Duration> {
    if samples == 0 {
        return None;
    }
    let target = samples.saturating_mul(percentile).div_ceil(100);
    let mut cumulative = 0_u64;
    histogram.iter().find_map(|bucket| {
        cumulative = cumulative.saturating_add(bucket.samples);
        (cumulative >= target).then_some(bucket.upper_bound)
    })
}

pub(super) struct InteractiveWriterShared {
    pub(super) state: Mutex<InteractiveWriteQueueState>,
    changed: Condvar,
    metrics: InteractiveWriteMetrics,
    #[cfg(test)]
    wait_until_written_gate: Mutex<Option<InteractiveWaitUntilWrittenGate>>,
}

#[cfg(test)]
struct InteractiveWaitUntilWrittenGate {
    entered: Sender<u64>,
    resume: Receiver<()>,
}

pub(super) struct InteractiveWriter {
    pub(super) shared: Arc<InteractiveWriterShared>,
    abort: Arc<dyn RemoteTransportAbort>,
}

impl InteractiveWriter {
    // Control requests use this actor too, then wait for their sequence. This
    // keeps a mutation from overtaking input already accepted from the PTY lane.
    pub(super) fn spawn(
        writer: Box<dyn RemoteMessageWriter>,
        abort: Arc<dyn RemoteTransportAbort>,
    ) -> io::Result<Self> {
        let shared = Arc::new(InteractiveWriterShared {
            state: Mutex::new(InteractiveWriteQueueState::default()),
            changed: Condvar::new(),
            metrics: InteractiveWriteMetrics::default(),
            #[cfg(test)]
            wait_until_written_gate: Mutex::new(None),
        });
        let worker_shared = shared.clone();
        std::thread::Builder::new()
            .name("remote-input-writer".into())
            .spawn(move || interactive_writer_worker(worker_shared, writer))?;
        Ok(Self { shared, abort })
    }

    pub(super) fn enqueue(&self, message: String, measure_latency: bool) -> io::Result<u64> {
        let mut write =
            InteractiveWrite { message, enqueued_at: Instant::now(), sequence: 0, measure_latency };
        let message_bytes = write.message.len();
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| io::Error::other("interactive writer queue is poisoned"))?;
        if let Some(failure) = &state.failure {
            return Err(failure.to_error());
        }
        if state.closed {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "interactive writer is closed"));
        }
        if state.writes.len() >= INTERACTIVE_WRITE_QUEUE_CAPACITY
            || message_bytes > INTERACTIVE_WRITE_QUEUE_BYTES.saturating_sub(state.queued_bytes)
        {
            if measure_latency {
                self.shared.metrics.backpressure_rejections.fetch_add(1, Ordering::Relaxed);
            }
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "interactive writer queue is full",
            ));
        }
        let sequence = state
            .last_enqueued_sequence
            .checked_add(1)
            .ok_or_else(|| io::Error::other("interactive writer sequence space is exhausted"))?;
        state.last_enqueued_sequence = sequence;
        state.queued_bytes += message_bytes;
        write.sequence = sequence;
        state.writes.push_back(write);
        drop(state);
        self.shared.changed.notify_one();
        Ok(sequence)
    }

    pub(super) fn last_enqueued_sequence(&self) -> io::Result<Option<u64>> {
        let state = self
            .shared
            .state
            .lock()
            .map_err(|_| io::Error::other("interactive writer queue is poisoned"))?;
        Ok((state.last_enqueued_sequence != 0).then_some(state.last_enqueued_sequence))
    }

    pub(super) fn wait_until_written(&self, sequence: u64, timeout: Duration) -> io::Result<()> {
        #[cfg(test)]
        self.await_wait_until_written_gate(sequence);
        let deadline = Instant::now() + timeout;
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| io::Error::other("interactive writer queue is poisoned"))?;
        loop {
            if state.last_written_sequence >= sequence {
                return Ok(());
            }
            if let Some(failure) = &state.failure {
                return Err(failure.to_error());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "ordered remote write did not complete before its deadline",
                ));
            }
            let (next, timeout) = self
                .shared
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(|poison| poison.into_inner());
            state = next;
            if timeout.timed_out()
                && state.last_written_sequence < sequence
                && state.failure.is_none()
            {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "ordered remote write did not complete before its deadline",
                ));
            }
        }
    }

    #[cfg(test)]
    pub(super) fn gate_next_wait_until_written(&self) -> (Receiver<u64>, Sender<()>) {
        let (entered_tx, entered_rx) = channel();
        let (resume_tx, resume_rx) = channel();
        let previous =
            self.shared.wait_until_written_gate.lock().unwrap().replace(
                InteractiveWaitUntilWrittenGate { entered: entered_tx, resume: resume_rx },
            );
        assert!(previous.is_none(), "interactive write wait gate was already installed");
        (entered_rx, resume_tx)
    }

    #[cfg(test)]
    fn await_wait_until_written_gate(&self, sequence: u64) {
        let gate = self.shared.wait_until_written_gate.lock().unwrap().take();
        if let Some(gate) = gate {
            gate.entered.send(sequence).unwrap();
            gate.resume.recv().unwrap();
        }
    }

    pub(super) fn metrics(&self) -> InteractiveWriteMetricsSnapshot {
        self.shared.metrics.snapshot()
    }

    fn request_close(&self) {
        let mut state = self.shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
        state.closed = true;
        drop(state);
        self.shared.changed.notify_one();
    }

    pub(super) fn abort(&self, error: &io::Error) {
        {
            let mut state = self.shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
            state.closed = true;
            state.failure.get_or_insert_with(|| InteractiveWriteFailure::from_error(error));
            state.writes.clear();
            state.queued_bytes = 0;
        }
        self.shared.changed.notify_all();
        let _ = self.abort.abort();
    }

    pub(super) fn close(&self) {
        self.request_close();
        let deadline = Instant::now() + remote_write_timeout();
        let mut state = self.shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
        while !state.writer_closed {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            let (next, timeout) = self
                .shared
                .changed
                .wait_timeout(state, remaining)
                .unwrap_or_else(|poison| poison.into_inner());
            state = next;
            if timeout.timed_out() {
                break;
            }
        }
        let writer_closed = state.writer_closed;
        drop(state);
        if !writer_closed {
            self.abort(&io::Error::new(
                io::ErrorKind::TimedOut,
                "remote writer did not close before its deadline",
            ));
        }
    }
}

impl Drop for InteractiveWriter {
    fn drop(&mut self) {
        self.request_close();
        let writer_closed =
            self.shared.state.lock().unwrap_or_else(|poison| poison.into_inner()).writer_closed;
        if !writer_closed {
            self.abort(&io::Error::new(
                io::ErrorKind::BrokenPipe,
                "remote writer owner was dropped",
            ));
        }
    }
}

fn interactive_writer_worker(
    shared: Arc<InteractiveWriterShared>,
    mut writer: Box<dyn RemoteMessageWriter>,
) {
    loop {
        let write = {
            let mut state = shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
            while state.writes.is_empty() && !state.closed && state.failure.is_none() {
                state = shared.changed.wait(state).unwrap_or_else(|poison| poison.into_inner());
            }
            let Some(write) = state.writes.pop_front() else {
                drop(state);
                let _ = writer.close();
                let mut state = shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
                state.writer_closed = true;
                drop(state);
                shared.changed.notify_all();
                return;
            };
            state.queued_bytes = state.queued_bytes.saturating_sub(write.message.len());
            write
        };

        let result = writer.send(&write.message);
        match result {
            Ok(()) => {
                if write.measure_latency {
                    shared.metrics.record_latency(write.enqueued_at.elapsed());
                }
                let mut state = shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
                state.last_written_sequence = write.sequence;
                drop(state);
                shared.changed.notify_all();
            }
            Err(error) => {
                if write.measure_latency {
                    shared.metrics.write_failures.fetch_add(1, Ordering::Relaxed);
                }
                let _ = writer.close();
                let mut state = shared.state.lock().unwrap_or_else(|poison| poison.into_inner());
                state.failure.get_or_insert_with(|| InteractiveWriteFailure::from_error(&error));
                state.writes.clear();
                state.queued_bytes = 0;
                state.writer_closed = true;
                drop(state);
                shared.changed.notify_all();
                return;
            }
        }
    }
}
