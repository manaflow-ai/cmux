use super::*;

#[derive(Clone)]
pub(super) struct ProcessEventLog {
    inner: Arc<ProcessEventLogInner>,
}

struct ProcessEventLogInner {
    next_sequence: AtomicU64,
    history: StdMutex<EventHistory>,
    live: broadcast::Sender<RpcEvent>,
    retained_bytes_limit: AtomicUsize,
    /// Wakes output readers waiting for a held subscriber to catch up.
    room: Notify,
    /// How many output readers are waiting for room. The output drain pauses
    /// its deadlines while one waits: the output exists, the reader is slow.
    stalled: watch::Sender<usize>,
}

#[derive(Default)]
struct EventHistory {
    events: VecDeque<RpcEvent>,
    retained_bytes: usize,
    exit: Option<ExitOutcome>,
    terminal: Option<ProcessTerminalModel>,
    /// Cursors of the subscribers that hold output: the last sequence each
    /// has taken. Output reading waits rather than evict an event one of them
    /// has not taken, so a held subscriber never sees a replay gap. The
    /// process stream a client reserves before spawning holds; any later
    /// viewer does not, and keeps the lossy, bounded retention.
    holds: BTreeMap<u64, u64>,
    next_hold: u64,
    /// Output events readers have room for but not yet published: a reader
    /// with output in hand reserves one before it publishes, so stdout and
    /// stderr cannot both take the last room and publish past the limit.
    reserved: usize,
}

impl EventHistory {
    /// Whether one more output event fits, beside those already reserved,
    /// without evicting an event a held subscriber has not taken.
    fn has_room(&self, retained_bytes_limit: usize) -> bool {
        let Some(oldest) = self.holds.values().min().copied() else { return true };
        let mut pending = self.reserved;
        let mut pending_bytes = self.reserved.saturating_mul(MAX_OUTPUT_EVENT_BYTES);
        for event in self.events.iter().rev() {
            if event.sequence <= oldest {
                break;
            }
            pending += 1;
            pending_bytes = pending_bytes.saturating_add(event_size(event));
        }
        pending == 0
            || (pending < HELD_EVENT_WINDOW
                && pending_bytes.saturating_add(MAX_OUTPUT_EVENT_BYTES) <= retained_bytes_limit)
    }
}

/// Room for one output event, held from before a read until its output is
/// published (or the read ends).
pub(super) struct RoomReservation<'a>(&'a ProcessEventLogInner);

impl Drop for RoomReservation<'_> {
    fn drop(&mut self) {
        let mut history = self.0.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        history.reserved = history.reserved.saturating_sub(1);
        drop(history);
        self.0.room.notify_waiters();
    }
}

/// Counts one output reader as stalled until dropped (also when its task is
/// aborted mid-wait).
struct StallGuard<'a>(&'a watch::Sender<usize>);

impl<'a> StallGuard<'a> {
    pub(super) fn new(stalled: &'a watch::Sender<usize>) -> Self {
        stalled.send_modify(|count| *count += 1);
        Self(stalled)
    }
}

impl Drop for StallGuard<'_> {
    fn drop(&mut self) {
        self.0.send_modify(|count| *count = count.saturating_sub(1));
    }
}

struct ProcessTerminalModel {
    terminal: ghostty_vt::Terminal,
    render: ghostty_vt::RenderState,
    through_sequence: u64,
}

impl ProcessEventLog {
    pub(super) fn new(retained_bytes_limit: usize) -> Self {
        let (live, _) = broadcast::channel(PROCESS_BROADCAST_CAPACITY);
        Self {
            inner: Arc::new(ProcessEventLogInner {
                next_sequence: AtomicU64::new(1),
                history: StdMutex::new(EventHistory::default()),
                live,
                retained_bytes_limit: AtomicUsize::new(retained_bytes_limit),
                room: Notify::new(),
                stalled: watch::channel(0).0,
            }),
        }
    }

    /// Waits until a held subscriber can take one more output event without
    /// losing one, and reserves that room (checked and taken under one lock).
    /// Output readers call it once a read returned output and keep the
    /// reservation until they publish it, so a slow held reader slows the
    /// child (the reader reads no more, and the pipe fills) instead of
    /// dropping output. A reader still waiting for its pipe holds no room:
    /// with a budget of one event, a quiet stdout holding it would block a
    /// child writing only stderr for good.
    pub(super) async fn wait_for_room(&self) -> RoomReservation<'_> {
        let mut stall = None;
        loop {
            let notified = self.inner.room.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            let limit = self.inner.retained_bytes_limit.load(Ordering::Acquire);
            {
                let mut history =
                    self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                if history.has_room(limit) {
                    history.reserved += 1;
                    return RoomReservation(&self.inner);
                }
            }
            stall.get_or_insert_with(|| StallGuard::new(&self.inner.stalled));
            notified.await;
        }
    }

    pub(super) fn stalled(&self) -> watch::Receiver<usize> {
        self.inner.stalled.subscribe()
    }

    pub(super) fn publish_output(&self, process: ProcessId, stderr: bool, bytes: &[u8]) {
        let data = ByteString::from_bytes(bytes);
        self.publish(|sequence, history| {
            if let Some(terminal) = history.terminal.as_mut() {
                terminal.terminal.vt_write(bytes);
                terminal.through_sequence = sequence;
            }
            let event = if stderr {
                ProcessEvent::Stderr { process, sequence, data }
            } else {
                ProcessEvent::Stdout { process, sequence, data }
            };
            RpcEvent { sequence, event }
        });
    }

    pub(super) fn publish_exit(&self, process: ProcessId, outcome: ExitOutcome) {
        self.publish(|sequence, _| RpcEvent {
            sequence,
            event: ProcessEvent::Exit { process, code: outcome.code, signal: outcome.signal },
        });
    }

    pub(super) fn publish_output_truncated(
        &self,
        process: ProcessId,
        reason: ProcessOutputTruncationReason,
    ) {
        self.publish(|sequence, _| RpcEvent {
            sequence,
            event: ProcessEvent::OutputTruncated { process, sequence, reason },
        });
    }

    pub(super) fn set_retained_bytes_limit(&self, retained_bytes_limit: usize) {
        self.inner.retained_bytes_limit.store(retained_bytes_limit, Ordering::Release);
    }

    pub(super) fn enable_terminal(&self, cols: u16, rows: u16) -> Result<(), RpcError> {
        let terminal = ghostty_vt::Terminal::new(
            cols,
            rows,
            PROCESS_TERMINAL_SCROLLBACK_BYTES,
            ghostty_vt::Callbacks::default(),
        )
        .map_err(terminal_model_error)?;
        let render = ghostty_vt::RenderState::new().map_err(terminal_model_error)?;
        let mut history =
            self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if history.terminal.is_some() {
            return Err(RpcError::new("internal", "process terminal model is already initialized"));
        }
        if !history.events.is_empty() {
            return Err(RpcError::new(
                "internal",
                "process terminal model must be initialized before output",
            ));
        }
        history.terminal = Some(ProcessTerminalModel { terminal, render, through_sequence: 0 });
        Ok(())
    }

    pub(super) fn resize_terminal(
        &self,
        cols: u16,
        rows: u16,
        resize_pty: impl FnOnce() -> Result<(), RpcError>,
    ) -> Result<(), RpcError> {
        let mut history =
            self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let terminal = history
            .terminal
            .as_mut()
            .ok_or_else(|| RpcError::new("not-a-pty", "process does not own a PTY"))?;
        // The physical resize, VT model resize, output publication, and
        // snapshots all serialize on the event-history lock. Output caused by
        // SIGWINCH is therefore parsed at the new model size.
        resize_pty()?;
        terminal.terminal.resize(cols, rows, 0, 0).map_err(terminal_model_error)
    }

    pub(super) fn snapshot_terminal(
        &self,
        process: ProcessId,
    ) -> Result<ProcessTerminalSnapshot, RpcError> {
        let snapshot = {
            let mut history =
                self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let terminal = history
                .terminal
                .as_mut()
                .ok_or_else(|| RpcError::new("not-a-pty", "process does not own a PTY"))?;
            let cells = usize::from(terminal.terminal.cols())
                .saturating_mul(usize::from(terminal.terminal.rows()));
            if cells > MAX_PROCESS_TERMINAL_SNAPSHOT_CELLS {
                return Err(terminal_snapshot_too_large());
            }
            let ProcessTerminalModel { terminal, render, through_sequence } = terminal;
            render.update(terminal).map_err(terminal_model_error)?;
            let scrollback_rows = terminal.history_rows();
            let frame = render.build_frame().map_err(terminal_model_error)?;
            process_terminal_snapshot(process, &frame, scrollback_rows, *through_sequence)
        };
        let encoded_bytes = serde_json::to_vec(&snapshot)
            .map_err(|error| RpcError::new("terminal-snapshot-failed", error.to_string()))?
            .len();
        if encoded_bytes > MAX_PROCESS_TERMINAL_SNAPSHOT_BYTES {
            return Err(terminal_snapshot_too_large());
        }
        Ok(snapshot)
    }

    pub(super) fn catalog_state(
        &self,
    ) -> (ProcessState, ProcessReplayRange, Option<ProcessTerminalSize>) {
        let history = self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let next_sequence = self.inner.next_sequence.load(Ordering::Acquire);
        let state = history.exit.map_or(ProcessState::Running, |outcome| ProcessState::Exited {
            code: outcome.code,
            signal: outcome.signal,
        });
        let range = replay_range(&history, next_sequence, history.exit.is_some());
        let pty_size = history.terminal.as_ref().map(|terminal| ProcessTerminalSize {
            cols: terminal.terminal.cols(),
            rows: terminal.terminal.rows(),
        });
        (state, range, pty_size)
    }

    fn publish(&self, make_event: impl FnOnce(u64, &mut EventHistory) -> RpcEvent) {
        let mut history =
            self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        // Sequence allocation, retention, and broadcast publication share one
        // critical section with PTY model updates. Subscribers and terminal
        // snapshots therefore observe exactly the same total output order.
        let sequence = self.inner.next_sequence.fetch_add(1, Ordering::Relaxed);
        let event = make_event(sequence, &mut history);
        let retained = event_size(&event);
        if let ProcessEvent::Exit { code, signal, .. } = &event.event {
            history.exit = Some(ExitOutcome { code: *code, signal: *signal });
        }
        history.retained_bytes = history.retained_bytes.saturating_add(retained);
        history.events.push_back(event.clone());
        let retained_bytes_limit = self.inner.retained_bytes_limit.load(Ordering::Acquire);
        while history.events.len() > PROCESS_EVENT_CAPACITY
            || history.retained_bytes > retained_bytes_limit
        {
            let Some(evicted) = history.events.pop_front() else { break };
            history.retained_bytes = history.retained_bytes.saturating_sub(event_size(&evicted));
        }
        let _ = self.inner.live.send(event);
    }

    pub(super) fn subscribe(
        &self,
        after_sequence: u64,
        exited: bool,
    ) -> Result<ProcessSubscription, RpcError> {
        self.subscribe_inner(after_sequence, exited, false)
    }

    /// A subscription whose unread output the log keeps (see `holds`).
    pub(super) fn subscribe_holding(
        &self,
        after_sequence: u64,
    ) -> Result<ProcessSubscription, RpcError> {
        self.subscribe_inner(after_sequence, false, true)
    }

    fn subscribe_inner(
        &self,
        after_sequence: u64,
        exited: bool,
        hold: bool,
    ) -> Result<ProcessSubscription, RpcError> {
        let mut history =
            self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let next_sequence = self.inner.next_sequence.load(Ordering::Acquire);
        if after_sequence >= next_sequence {
            return Err(RpcError::new(
                "invalid-replay-cursor",
                format!("process has not produced sequence {after_sequence}"),
            ));
        }
        let exited = exited || history.exit.is_some();
        let range = replay_range(&history, next_sequence, exited);
        let replay_gap =
            range.first_available.map_or(after_sequence < range.last_produced, |first| {
                after_sequence.saturating_add(1) < first
            });
        if replay_gap {
            return Err(RpcError::new(
                "replay-unavailable",
                format!(
                    "requested process replay is outside retained range {:?}..={}",
                    range.first_available, range.last_produced
                ),
            )
            .with_details(RpcErrorDetails::ProcessReplayGap {
                requested_after: after_sequence,
                range,
            }));
        }
        let replay = history
            .events
            .iter()
            .filter(|event| event.sequence > after_sequence)
            .cloned()
            .collect();
        let live = self.inner.live.subscribe();
        let hold = hold.then(|| {
            let id = history.next_hold;
            history.next_hold += 1;
            history.holds.insert(id, after_sequence);
            id
        });
        Ok(ProcessSubscription {
            replay,
            live,
            events: self.clone(),
            last_delivered: after_sequence,
            terminal: exited,
            hold,
        })
    }

    pub(super) fn read(
        &self,
        process: ProcessId,
        after_sequence: u64,
        limit: u32,
        exited: bool,
    ) -> Result<WorkspaceResponse, RpcError> {
        if limit == 0 || limit > MAX_PROCESS_REPLAY_EVENTS {
            return Err(RpcError::new(
                "invalid-argument",
                format!("process replay limit must be between 1 and {MAX_PROCESS_REPLAY_EVENTS}"),
            ));
        }
        let history = self.inner.history.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let next_sequence = self.inner.next_sequence.load(Ordering::Acquire);
        let range = replay_range(&history, next_sequence, exited || history.exit.is_some());
        let replay_gap =
            range.first_available.map_or(after_sequence < range.last_produced, |first| {
                after_sequence.saturating_add(1) < first
            });
        if replay_gap {
            return Ok(WorkspaceResponse::ProcessReplayGap {
                process,
                requested_after: after_sequence,
                range,
            });
        }
        if after_sequence >= next_sequence {
            return Err(RpcError::new(
                "invalid-replay-cursor",
                format!("process has not produced sequence {after_sequence}"),
            ));
        }
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        let mut events = history
            .events
            .iter()
            .filter(|event| event.sequence > after_sequence)
            .take(limit.saturating_add(1))
            .cloned()
            .collect::<Vec<_>>();
        let has_more = events.len() > limit;
        events.truncate(limit);
        let next_cursor =
            has_more.then(|| events.last().map_or(after_sequence, |event| event.sequence));
        Ok(WorkspaceResponse::ProcessEvents { process, range, events, next_cursor })
    }
}

fn replay_range(history: &EventHistory, next_sequence: u64, exited: bool) -> ProcessReplayRange {
    ProcessReplayRange {
        first_available: history.events.front().map(|event| event.sequence),
        last_produced: next_sequence.saturating_sub(1),
        exited,
    }
}

pub struct ProcessSubscription {
    replay: VecDeque<RpcEvent>,
    live: broadcast::Receiver<RpcEvent>,
    events: ProcessEventLog,
    last_delivered: u64,
    terminal: bool,
    /// This subscription's entry in the log's `holds`, when it holds output.
    hold: Option<u64>,
}

impl Drop for ProcessSubscription {
    fn drop(&mut self) {
        if let Some(hold) = self.hold {
            self.events
                .inner
                .history
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .holds
                .remove(&hold);
            self.events.inner.room.notify_waiters();
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProcessSubscriptionError {
    Closed,
    ReplayGap { skipped: u64, requested_after: u64, range: ProcessReplayRange },
}

impl std::fmt::Display for ProcessSubscriptionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Closed => write!(formatter, "process event stream closed"),
            Self::ReplayGap { requested_after, range, .. } => write!(
                formatter,
                "process replay after {requested_after} is outside retained range {:?}..={}",
                range.first_available, range.last_produced
            ),
        }
    }
}

impl std::error::Error for ProcessSubscriptionError {}

impl ProcessSubscription {
    pub async fn recv(&mut self) -> Result<RpcEvent, ProcessSubscriptionError> {
        loop {
            if let Some(event) = self.replay.pop_front() {
                self.deliver(&event);
                return Ok(event);
            }
            if self.terminal {
                return Err(ProcessSubscriptionError::Closed);
            }
            match self.live.recv().await {
                Ok(event) if event.sequence <= self.last_delivered => continue,
                Ok(event) => {
                    self.deliver(&event);
                    return Ok(event);
                }
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    let history = self
                        .events
                        .inner
                        .history
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                    let first = history.events.front().map(|event| event.sequence);
                    let next_sequence = self.inner_next_sequence();
                    let range = replay_range(&history, next_sequence, history.exit.is_some());
                    let replay_gap = first
                        .map_or(self.last_delivered < range.last_produced, |first| {
                            self.last_delivered.saturating_add(1) < first
                        });
                    if replay_gap {
                        return Err(ProcessSubscriptionError::ReplayGap {
                            skipped,
                            requested_after: self.last_delivered,
                            range,
                        });
                    }
                    self.replay = history
                        .events
                        .iter()
                        .filter(|event| event.sequence > self.last_delivered)
                        .cloned()
                        .collect();
                }
                Err(broadcast::error::RecvError::Closed) => {
                    return Err(ProcessSubscriptionError::Closed);
                }
            }
        }
    }

    fn deliver(&mut self, event: &RpcEvent) {
        self.last_delivered = event.sequence;
        self.terminal |= event.event.is_terminal();
        if let Some(hold) = self.hold {
            if let Some(cursor) = self
                .events
                .inner
                .history
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .holds
                .get_mut(&hold)
            {
                *cursor = event.sequence;
            }
            self.events.inner.room.notify_waiters();
        }
    }

    fn inner_next_sequence(&self) -> u64 {
        self.events.inner.next_sequence.load(Ordering::Acquire)
    }
}
