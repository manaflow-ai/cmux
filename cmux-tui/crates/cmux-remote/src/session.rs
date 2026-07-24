use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use cmux_remote_protocol::{
    FrameDecodeError, FrameFlags, Lane, MAX_FRAME_PAYLOAD, MAX_WIRE_FRAME_BYTES, SessionId,
    WireFrame,
};
use tokio::sync::{mpsc, oneshot};

use crate::link::{FrameLink, LinkError};

const RECONNECT_CLEANUP_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Copy)]
pub struct SessionLimits {
    pub replay_frames_per_lane: usize,
    pub replay_bytes_per_lane: usize,
    pub delivery_frames_per_lane: usize,
    pub delivery_bytes_per_lane: usize,
    pub queued_frames_per_lane: usize,
    pub queued_bytes_per_lane: usize,
}

impl Default for SessionLimits {
    fn default() -> Self {
        Self {
            replay_frames_per_lane: 4_096,
            replay_bytes_per_lane: 16 * 1024 * 1024,
            delivery_frames_per_lane: 64,
            delivery_bytes_per_lane: 256 * 1024,
            queued_frames_per_lane: 256,
            queued_bytes_per_lane: 8 * 1024 * 1024,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceivedFrame {
    pub generation: u64,
    pub lane: Lane,
    pub stream: u64,
    pub sequence: u64,
    pub flags: FrameFlags,
    pub payload: Bytes,
}

#[derive(Clone)]
pub struct ReliableSession {
    shared: Arc<SharedState>,
    link: Arc<dyn FrameLink>,
    scheduler: ScheduledSender,
    ack_senders: [mpsc::Sender<()>; 4],
    closed: Arc<AtomicBool>,
    generation: u64,
}

struct CloseUncommittedLink(Option<Arc<dyn FrameLink>>);

impl CloseUncommittedLink {
    fn disarm(mut self) {
        self.0.take();
    }
}

impl Drop for CloseUncommittedLink {
    fn drop(&mut self) {
        let Some(link) = self.0.take() else { return };
        let Ok(runtime) = tokio::runtime::Handle::try_current() else { return };
        runtime.spawn(async move {
            let _ = tokio::time::timeout(RECONNECT_CLEANUP_TIMEOUT, link.close()).await;
        });
    }
}

impl fmt::Debug for ReliableSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ReliableSession")
            .field("session", &self.shared.session)
            .field("generation", &self.generation)
            .field("link", &self.link.description())
            .finish_non_exhaustive()
    }
}

impl ReliableSession {
    pub fn new(session: SessionId, link: Arc<dyn FrameLink>, limits: SessionLimits) -> Self {
        let shared = Arc::new(SharedState {
            session,
            limits,
            transition: tokio::sync::RwLock::new(()),
            lane_sends: std::array::from_fn(|_| tokio::sync::Mutex::new(())),
            outbound_progress: std::array::from_fn(|_| tokio::sync::Notify::new()),
            state: Mutex::new(ReliabilityState::new()),
        });
        Self::from_parts(shared, link, 0)
    }

    fn from_parts(shared: Arc<SharedState>, link: Arc<dyn FrameLink>, generation: u64) -> Self {
        let scheduler = ScheduledSender::spawn(link.clone(), shared.limits);
        let ack_senders = Lane::ALL.map(|lane| {
            let (sender, receiver) = mpsc::channel(1);
            tokio::spawn(run_ack_sender(
                shared.clone(),
                scheduler.clone(),
                generation,
                lane,
                receiver,
            ));
            sender
        });
        Self {
            shared,
            link,
            scheduler,
            ack_senders,
            closed: Arc::new(AtomicBool::new(false)),
            generation,
        }
    }

    pub fn session_id(&self) -> SessionId {
        self.shared.session
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn resume_cursors(&self) -> BTreeMap<Lane, u64> {
        let state = self.shared.state.lock().unwrap();
        Lane::ALL
            .into_iter()
            .map(|lane| {
                let cursor = if lane.replays_across_generations() {
                    state.inbound(lane).contiguous
                } else {
                    0
                };
                (lane, cursor)
            })
            .collect()
    }

    pub fn outstanding_reliable_frames(&self, lane: Lane) -> usize {
        self.shared.state.lock().unwrap().outbound(lane).replay.len()
    }

    pub fn next_outbound_sequence(&self, lane: Lane) -> u64 {
        self.shared.state.lock().unwrap().outbound(lane).next_sequence
    }

    /// Compatibility hook for callers that reserved a sequence before an
    /// unscheduled failure. `send` already performs this rollback for queue
    /// admission failures; reconnectable failures stay in replay.
    pub fn rollback_unscheduled(&self, lane: Lane, sequence: u64) -> bool {
        let Ok(_lane_send) = self.shared.lane_sends[lane_index(lane)].try_lock() else {
            return false;
        };
        let Ok(_transition) = self.shared.transition.try_read() else {
            return false;
        };
        let mut state = self.shared.state.lock().unwrap();
        if state.generation != self.generation {
            return false;
        }
        let rolled_back = state.rollback_unscheduled(lane, sequence);
        drop(state);
        if rolled_back {
            self.shared.outbound_progress[lane_index(lane)].notify_waiters();
        }
        rolled_back
    }

    pub async fn send(
        &self,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, SessionError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(SessionError::Link(LinkError::Closed));
        }
        if payload.len() > MAX_FRAME_PAYLOAD {
            return Err(SessionError::PayloadTooLarge(payload.len()));
        }
        let _lane_send = self.shared.lane_sends[lane_index(lane)].lock().await;
        let _transition = self.shared.transition.read().await;
        if self.closed.load(Ordering::Acquire) {
            return Err(SessionError::Link(LinkError::Closed));
        }
        let (sequence, encoded) = {
            let mut state = self.shared.state.lock().unwrap();
            state.require_generation(self.generation)?;
            let acknowledgement = state.inbound(lane).contiguous;
            let outbound = state.outbound_mut(lane);
            let sequence = outbound.next_sequence;
            let next_sequence =
                sequence.checked_add(1).ok_or(SessionError::SequenceExhausted(lane))?;
            let frame = WireFrame {
                session: self.shared.session,
                generation: self.generation,
                lane,
                flags: flags.union(FrameFlags::RELIABLE),
                sequence,
                acknowledgement,
                stream,
                payload: payload.to_vec(),
            };
            let encoded = Bytes::from(frame.encode().map_err(SessionError::Frame)?);
            outbound.push(frame, encoded.len(), self.shared.limits)?;
            outbound.next_sequence = next_sequence;
            (sequence, encoded)
        };
        match self.scheduler.send(lane, encoded).await {
            Ok(()) => Ok(sequence),
            Err(error) => {
                if error.is_definitely_unscheduled() {
                    let mut state = self.shared.state.lock().unwrap();
                    if state.generation == self.generation {
                        let rolled_back = state.rollback_unscheduled(lane, sequence);
                        debug_assert!(rolled_back);
                        drop(state);
                        if rolled_back {
                            self.shared.outbound_progress[lane_index(lane)].notify_waiters();
                        }
                    }
                }
                Err(error.into_session_error())
            }
        }
    }

    /// Apply acknowledgement-based flow control without turning a temporary
    /// delivery or replay window limit into a service-stream failure.
    pub(crate) async fn send_with_backpressure(
        &self,
        lane: Lane,
        stream: u64,
        payload: Bytes,
        flags: FrameFlags,
    ) -> Result<u64, SessionError> {
        let frame_overhead = MAX_WIRE_FRAME_BYTES - MAX_FRAME_PAYLOAD;
        loop {
            let progress = self.shared.outbound_progress[lane_index(lane)].notified();
            tokio::pin!(progress);
            progress.as_mut().enable();
            match self.send(lane, stream, payload.clone(), flags).await {
                Err(error)
                    if self.can_wait_for_outbound_capacity(
                        lane,
                        &payload,
                        frame_overhead,
                        &error,
                    ) =>
                {
                    progress.await;
                }
                result => return result,
            }
        }
    }

    fn can_wait_for_outbound_capacity(
        &self,
        lane: Lane,
        payload: &Bytes,
        frame_overhead: usize,
        error: &SessionError,
    ) -> bool {
        let encoded_bytes = payload.len().checked_add(frame_overhead);
        match error {
            SessionError::DeliveryWindowFull(full_lane) if *full_lane == lane => {
                self.shared.limits.delivery_frames_per_lane > 0
                    && encoded_bytes
                        .is_some_and(|bytes| bytes <= self.shared.limits.delivery_bytes_per_lane)
            }
            SessionError::ReplayFull(full_lane) if *full_lane == lane => {
                lane.replays_across_generations()
                    && self.shared.limits.replay_frames_per_lane > 0
                    && encoded_bytes
                        .is_some_and(|bytes| bytes <= self.shared.limits.replay_bytes_per_lane)
            }
            _ => false,
        }
    }

    pub async fn receive(&self) -> Result<Option<ReceivedFrame>, SessionError> {
        loop {
            let Some(encoded) = self.link.receive().await.map_err(SessionError::Link)? else {
                return Ok(None);
            };
            let frame = WireFrame::decode(&encoded).map_err(SessionError::Frame)?;
            if frame.session != self.shared.session {
                return Err(SessionError::WrongSession);
            }
            if frame.generation != self.generation {
                return Err(SessionError::StaleGeneration {
                    expected: self.generation,
                    actual: frame.generation,
                });
            }

            let _transition = self.shared.transition.read().await;
            let deliver = {
                let mut state = self.shared.state.lock().unwrap();
                state.require_generation(self.generation)?;
                if state.apply_ack(frame.lane, frame.acknowledgement)? {
                    self.shared.outbound_progress[lane_index(frame.lane)].notify_waiters();
                }
                if frame.flags.contains(FrameFlags::ACK_ONLY) {
                    false
                } else {
                    let inbound = state.inbound_mut(frame.lane);
                    if frame.sequence == 0 {
                        return Err(SessionError::ZeroSequence);
                    }
                    let expected = inbound.contiguous.saturating_add(1);
                    if frame.sequence < expected {
                        false
                    } else if frame.sequence > expected {
                        return Err(SessionError::SequenceGap {
                            lane: frame.lane,
                            expected,
                            actual: frame.sequence,
                        });
                    } else {
                        inbound.contiguous = frame.sequence;
                        true
                    }
                }
            };

            if frame.flags.contains(FrameFlags::ACK_ONLY) {
                continue;
            }
            if !deliver {
                // A duplicate remains safe to suppress only after its
                // acknowledgement is physically accepted. Otherwise surface
                // the transport failure so the caller starts recovery.
                if let Err(error) = self.send_ack(frame.lane).await {
                    let terminal_ack_failure = matches!(
                        &error,
                        SessionError::Link(_)
                            | SessionError::LinkMessage(_)
                            | SessionError::SchedulerClosed
                    );
                    if frame.lane != Lane::Control
                        || !frame.flags.contains(FrameFlags::REPLAY)
                        || !terminal_ack_failure
                        || !self.link.terminal_control_drain_active()
                    {
                        return Err(error);
                    }
                }
                continue;
            }
            // Sequence state is committed above. Once that happens, suppressing
            // a newly delivered payload because the reverse-direction ACK write
            // failed loses application data. Return the frame now; the next
            // receive or outbound send observes the failed carrier and drives
            // reconnect. This is also what makes authenticated session-close
            // reliable when the sender closes immediately after writing it.
            // ACK production is coalesced on a dedicated lane actor. Delivering
            // application bytes does not wait for the reverse socket write,
            // which keeps terminal input latency independent of ACK flushing.
            let _ = self.ack_senders[lane_index(frame.lane)].try_send(());
            return Ok(Some(ReceivedFrame {
                generation: frame.generation,
                lane: frame.lane,
                stream: frame.stream,
                sequence: frame.sequence,
                flags: frame.flags,
                payload: Bytes::from(frame.payload),
            }));
        }
    }

    async fn send_ack(&self, lane: Lane) -> Result<(), SessionError> {
        let encoded = encode_ack(&self.shared, self.generation, lane)?;
        self.scheduler.send(lane, encoded).await.map_err(ScheduleError::into_session_error)
    }

    /// Attach the reliability state to a freshly authenticated physical link.
    ///
    /// `peer_resume` is the last contiguous sequence the peer reports for
    /// each lane. Acknowledged frames are discarded and later frames replay
    /// in order with a new connection generation.
    pub async fn reconnect(
        &self,
        link: Arc<dyn FrameLink>,
        peer_resume: &BTreeMap<Lane, u64>,
    ) -> Result<Self, SessionError> {
        let generation = self.generation.checked_add(1).ok_or(SessionError::GenerationExhausted)?;
        self.reconnect_to(link, peer_resume, generation).await
    }

    /// Reattach at a caller-allocated generation. Generations are monotonic,
    /// but need not be contiguous: a cancelled connection attempt burns its
    /// generation so a later attempt cannot collide with a daemon that already
    /// committed the cancelled attempt.
    pub(crate) async fn reconnect_to(
        &self,
        link: Arc<dyn FrameLink>,
        peer_resume: &BTreeMap<Lane, u64>,
        generation: u64,
    ) -> Result<Self, SessionError> {
        let _transition = self.shared.transition.write().await;
        let (staged, replay) = {
            let state = self.shared.state.lock().unwrap();
            state.require_generation(self.generation)?;
            if generation <= self.generation {
                return Err(SessionError::StaleGeneration {
                    expected: self.generation.saturating_add(1),
                    actual: generation,
                });
            }
            let mut staged = state.clone();
            staged.generation = generation;
            let mut replay = Vec::new();
            for lane in lane_priority_order() {
                if !lane.replays_across_generations() {
                    staged.reset_lane_for_generation(lane);
                    continue;
                }
                let acknowledgement = staged.inbound(lane).contiguous;
                staged.apply_ack(lane, peer_resume.get(&lane).copied().unwrap_or(0))?;
                let outbound = staged.outbound_mut(lane);
                for entry in &mut outbound.replay {
                    entry.frame.generation = generation;
                    entry.frame.acknowledgement = acknowledgement;
                    entry.frame.flags = entry.frame.flags.union(FrameFlags::REPLAY);
                    let encoded = Bytes::from(entry.frame.encode().map_err(SessionError::Frame)?);
                    entry.bytes = encoded.len();
                    replay.push((lane, encoded));
                }
                outbound.replay_bytes = outbound.replay.iter().map(|entry| entry.bytes).sum();
            }
            (staged, replay)
        };

        let close_uncommitted = CloseUncommittedLink(Some(link.clone()));
        let reconnected = Self::from_parts(self.shared.clone(), link, generation);
        for (lane, frame) in replay {
            reconnected
                .scheduler
                .send(lane, frame)
                .await
                .map_err(ScheduleError::into_session_error)?;
        }
        let mut state = self.shared.state.lock().unwrap();
        state.require_generation(self.generation)?;
        *state = staged;
        drop(state);
        for progress in &self.shared.outbound_progress {
            progress.notify_waiters();
        }
        close_uncommitted.disarm();
        Ok(reconnected)
    }

    pub async fn close(&self) -> Result<(), SessionError> {
        self.closed.store(true, Ordering::Release);
        for progress in &self.shared.outbound_progress {
            progress.notify_waiters();
        }
        self.link.close().await.map_err(SessionError::Link)
    }
}

fn encode_ack(shared: &SharedState, generation: u64, lane: Lane) -> Result<Bytes, SessionError> {
    let acknowledgement = {
        let state = shared.state.lock().unwrap();
        state.require_generation(generation)?;
        state.inbound(lane).contiguous
    };
    let frame = WireFrame {
        session: shared.session,
        generation,
        lane,
        flags: FrameFlags::ACK_ONLY,
        sequence: 0,
        acknowledgement,
        stream: 0,
        payload: Vec::new(),
    };
    Ok(Bytes::from(frame.encode().map_err(SessionError::Frame)?))
}

async fn run_ack_sender(
    shared: Arc<SharedState>,
    scheduler: ScheduledSender,
    generation: u64,
    lane: Lane,
    mut requested: mpsc::Receiver<()>,
) {
    while requested.recv().await.is_some() {
        while requested.try_recv().is_ok() {}
        let Ok(encoded) = encode_ack(&shared, generation, lane) else { return };
        if scheduler.send(lane, encoded).await.is_err() {
            return;
        }
    }
}

struct SharedState {
    session: SessionId,
    limits: SessionLimits,
    transition: tokio::sync::RwLock<()>,
    lane_sends: [tokio::sync::Mutex<()>; 4],
    outbound_progress: [tokio::sync::Notify; 4],
    state: Mutex<ReliabilityState>,
}

#[derive(Clone)]
struct ReliabilityState {
    generation: u64,
    outbound: BTreeMap<Lane, OutboundLane>,
    inbound: BTreeMap<Lane, InboundLane>,
}

impl ReliabilityState {
    fn new() -> Self {
        Self {
            generation: 0,
            outbound: Lane::ALL.into_iter().map(|lane| (lane, OutboundLane::default())).collect(),
            inbound: Lane::ALL.into_iter().map(|lane| (lane, InboundLane::default())).collect(),
        }
    }

    fn require_generation(&self, generation: u64) -> Result<(), SessionError> {
        if self.generation == generation {
            Ok(())
        } else {
            Err(SessionError::StaleGeneration { expected: self.generation, actual: generation })
        }
    }

    fn outbound(&self, lane: Lane) -> &OutboundLane {
        self.outbound.get(&lane).expect("all lanes initialized")
    }

    fn outbound_mut(&mut self, lane: Lane) -> &mut OutboundLane {
        self.outbound.get_mut(&lane).expect("all lanes initialized")
    }

    fn inbound(&self, lane: Lane) -> &InboundLane {
        self.inbound.get(&lane).expect("all lanes initialized")
    }

    fn inbound_mut(&mut self, lane: Lane) -> &mut InboundLane {
        self.inbound.get_mut(&lane).expect("all lanes initialized")
    }

    fn apply_ack(&mut self, lane: Lane, acknowledgement: u64) -> Result<bool, SessionError> {
        let outbound = self.outbound_mut(lane);
        if acknowledgement >= outbound.next_sequence {
            return Err(SessionError::InvalidAcknowledgement {
                lane,
                acknowledgement,
                next_sequence: outbound.next_sequence,
            });
        }
        let delivery_len = outbound.delivery.len();
        while outbound.delivery.front().is_some_and(|entry| entry.sequence <= acknowledgement) {
            let entry = outbound.delivery.pop_front().unwrap();
            outbound.delivery_bytes = outbound.delivery_bytes.saturating_sub(entry.bytes);
        }
        while outbound.replay.front().is_some_and(|entry| entry.frame.sequence <= acknowledgement) {
            let entry = outbound.replay.pop_front().unwrap();
            outbound.replay_bytes = outbound.replay_bytes.saturating_sub(entry.bytes);
        }
        Ok(outbound.delivery.len() != delivery_len)
    }

    fn reset_lane_for_generation(&mut self, lane: Lane) {
        self.outbound.insert(lane, OutboundLane::default());
        self.inbound.insert(lane, InboundLane::default());
    }

    fn rollback_unscheduled(&mut self, lane: Lane, sequence: u64) -> bool {
        let outbound = self.outbound_mut(lane);
        if outbound.next_sequence != sequence.saturating_add(1) {
            return false;
        }
        if outbound.delivery.back().map(|entry| entry.sequence) != Some(sequence) {
            return false;
        }
        if lane.replays_across_generations()
            && outbound.replay.back().map(|entry| entry.frame.sequence) != Some(sequence)
        {
            return false;
        }
        let delivery = outbound.delivery.pop_back().expect("back entry was checked");
        outbound.delivery_bytes = outbound.delivery_bytes.saturating_sub(delivery.bytes);
        if lane.replays_across_generations() {
            let entry = outbound.replay.pop_back().expect("back entry was checked");
            outbound.replay_bytes = outbound.replay_bytes.saturating_sub(entry.bytes);
        }
        outbound.next_sequence = sequence;
        true
    }
}

#[derive(Clone)]
struct OutboundLane {
    next_sequence: u64,
    delivery: VecDeque<DeliveryEntry>,
    delivery_bytes: usize,
    replay: VecDeque<ReplayEntry>,
    replay_bytes: usize,
}

impl OutboundLane {
    fn push(
        &mut self,
        frame: WireFrame,
        bytes: usize,
        limits: SessionLimits,
    ) -> Result<(), SessionError> {
        if self.delivery.len() >= limits.delivery_frames_per_lane
            || self.delivery_bytes.saturating_add(bytes) > limits.delivery_bytes_per_lane
        {
            return Err(SessionError::DeliveryWindowFull(frame.lane));
        }
        if frame.lane.replays_across_generations()
            && (self.replay.len() >= limits.replay_frames_per_lane
                || self.replay_bytes.saturating_add(bytes) > limits.replay_bytes_per_lane)
        {
            return Err(SessionError::ReplayFull(frame.lane));
        }
        self.delivery_bytes += bytes;
        self.delivery.push_back(DeliveryEntry { sequence: frame.sequence, bytes });
        if frame.lane.replays_across_generations() {
            self.replay_bytes += bytes;
            self.replay.push_back(ReplayEntry { frame, bytes });
        }
        Ok(())
    }
}

impl Default for ReliabilityState {
    fn default() -> Self {
        Self::new()
    }
}

impl Default for OutboundLane {
    fn default() -> Self {
        Self {
            next_sequence: 1,
            delivery: VecDeque::new(),
            delivery_bytes: 0,
            replay: VecDeque::new(),
            replay_bytes: 0,
        }
    }
}

#[derive(Clone, Default)]
struct InboundLane {
    contiguous: u64,
}

#[derive(Clone)]
struct ReplayEntry {
    frame: WireFrame,
    bytes: usize,
}

#[derive(Clone)]
struct DeliveryEntry {
    sequence: u64,
    bytes: usize,
}

#[derive(Clone)]
struct ScheduledSender {
    queues: Arc<QueueSenders>,
    budgets: Arc<[AtomicUsize; 4]>,
    limits: SessionLimits,
}

impl ScheduledSender {
    fn spawn(link: Arc<dyn FrameLink>, limits: SessionLimits) -> Self {
        let (interactive_tx, interactive_rx) = mpsc::channel(limits.queued_frames_per_lane);
        let (control_tx, control_rx) = mpsc::channel(limits.queued_frames_per_lane);
        let (bulk_tx, bulk_rx) = mpsc::channel(limits.queued_frames_per_lane);
        let (tunnel_tx, tunnel_rx) = mpsc::channel(limits.queued_frames_per_lane);
        let queues = Arc::new(QueueSenders {
            interactive: interactive_tx,
            control: control_tx,
            bulk: bulk_tx,
            tunnel: tunnel_tx,
        });
        let budgets = Arc::new(std::array::from_fn(|_| AtomicUsize::new(0)));
        let (failed_tx, failed_rx) = tokio::sync::watch::channel(false);
        // Each lane owns an independent physical send loop. LaneMuxLink can
        // therefore progress dedicated carriers concurrently; a FrameLink
        // backed by one writer may still serialize inside its implementation.
        for (lane, receiver) in [
            (Lane::Interactive, interactive_rx),
            (Lane::Control, control_rx),
            (Lane::Bulk, bulk_rx),
            (Lane::Tunnel, tunnel_rx),
        ] {
            tokio::spawn(run_lane_sender(
                link.clone(),
                lane,
                receiver,
                budgets.clone(),
                failed_tx.clone(),
                failed_rx.clone(),
            ));
        }
        Self { queues, budgets, limits }
    }

    async fn send(&self, lane: Lane, frame: Bytes) -> Result<(), ScheduleError> {
        let budget = &self.budgets[lane_index(lane)];
        budget
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
                current
                    .checked_add(frame.len())
                    .filter(|next| *next <= self.limits.queued_bytes_per_lane)
            })
            .map_err(|_| ScheduleError::Unscheduled(SessionError::QueueFull(lane)))?;
        let bytes = frame.len();
        let (completion, result) = oneshot::channel();
        if self.queues.get(lane).send(ScheduledFrame { lane, frame, completion }).await.is_err() {
            budget.fetch_sub(bytes, Ordering::AcqRel);
            return Err(ScheduleError::Ambiguous(SessionError::SchedulerClosed));
        }
        match result.await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(message)) => Err(ScheduleError::Ambiguous(SessionError::LinkMessage(message))),
            Err(_) => Err(ScheduleError::Ambiguous(SessionError::SchedulerClosed)),
        }
    }
}

async fn run_lane_sender(
    link: Arc<dyn FrameLink>,
    lane: Lane,
    mut receiver: mpsc::Receiver<ScheduledFrame>,
    budgets: Arc<[AtomicUsize; 4]>,
    failed_tx: tokio::sync::watch::Sender<bool>,
    mut failed_rx: tokio::sync::watch::Receiver<bool>,
) {
    loop {
        let scheduled = tokio::select! {
            biased;
            changed = failed_rx.changed() => {
                if changed.is_ok() && *failed_rx.borrow() {
                    fail_pending(&mut receiver, &budgets, "physical link failed");
                    return;
                }
                continue;
            }
            scheduled = receiver.recv() => {
                let Some(scheduled) = scheduled else { return; };
                scheduled
            }
        };
        debug_assert_eq!(scheduled.lane, lane);
        budgets[lane_index(lane)].fetch_sub(scheduled.frame.len(), Ordering::AcqRel);
        let result = link.send(scheduled.frame).await.map_err(|error| error.to_string());
        let failed = result.is_err();
        let _ = scheduled.completion.send(result);
        if failed {
            failed_tx.send_replace(true);
            fail_pending(&mut receiver, &budgets, "physical link failed");
            return;
        }
    }
}

fn fail_pending(
    receiver: &mut mpsc::Receiver<ScheduledFrame>,
    budgets: &[AtomicUsize; 4],
    message: &str,
) {
    while let Ok(frame) = receiver.try_recv() {
        budgets[lane_index(frame.lane)].fetch_sub(frame.frame.len(), Ordering::AcqRel);
        let _ = frame.completion.send(Err(message.into()));
    }
}

enum ScheduleError {
    Unscheduled(SessionError),
    Ambiguous(SessionError),
}

impl ScheduleError {
    fn is_definitely_unscheduled(&self) -> bool {
        matches!(self, Self::Unscheduled(_))
    }

    fn into_session_error(self) -> SessionError {
        match self {
            Self::Unscheduled(error) | Self::Ambiguous(error) => error,
        }
    }
}

struct QueueSenders {
    interactive: mpsc::Sender<ScheduledFrame>,
    control: mpsc::Sender<ScheduledFrame>,
    bulk: mpsc::Sender<ScheduledFrame>,
    tunnel: mpsc::Sender<ScheduledFrame>,
}

impl QueueSenders {
    fn get(&self, lane: Lane) -> &mpsc::Sender<ScheduledFrame> {
        match lane {
            Lane::Interactive => &self.interactive,
            Lane::Control => &self.control,
            Lane::Bulk => &self.bulk,
            Lane::Tunnel => &self.tunnel,
        }
    }
}

struct ScheduledFrame {
    lane: Lane,
    frame: Bytes,
    completion: oneshot::Sender<Result<(), String>>,
}

fn lane_index(lane: Lane) -> usize {
    lane as usize
}

fn lane_priority_order() -> [Lane; 4] {
    [Lane::Interactive, Lane::Control, Lane::Tunnel, Lane::Bulk]
}

#[derive(Debug)]
pub enum SessionError {
    Link(LinkError),
    LinkMessage(String),
    Frame(FrameDecodeError),
    PayloadTooLarge(usize),
    DeliveryWindowFull(Lane),
    ReplayFull(Lane),
    QueueFull(Lane),
    SchedulerClosed,
    SequenceExhausted(Lane),
    GenerationExhausted,
    WrongSession,
    StaleGeneration { expected: u64, actual: u64 },
    ZeroSequence,
    SequenceGap { lane: Lane, expected: u64, actual: u64 },
    InvalidAcknowledgement { lane: Lane, acknowledgement: u64, next_sequence: u64 },
}

impl fmt::Display for SessionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Link(error) => write!(formatter, "{error}"),
            Self::LinkMessage(message) => write!(formatter, "link failed: {message}"),
            Self::Frame(error) => write!(formatter, "invalid session frame: {error}"),
            Self::PayloadTooLarge(size) => {
                write!(formatter, "session payload is {size} bytes, maximum is {MAX_FRAME_PAYLOAD}")
            }
            Self::DeliveryWindowFull(lane) => {
                write!(formatter, "{lane} delivery window is full")
            }
            Self::ReplayFull(lane) => write!(formatter, "{lane} replay buffer is full"),
            Self::QueueFull(lane) => write!(formatter, "{lane} outbound queue is full"),
            Self::SchedulerClosed => formatter.write_str("outbound scheduler closed"),
            Self::SequenceExhausted(lane) => write!(formatter, "{lane} sequence exhausted"),
            Self::GenerationExhausted => formatter.write_str("connection generation exhausted"),
            Self::WrongSession => formatter.write_str("frame belongs to another session"),
            Self::StaleGeneration { expected, actual } => {
                write!(formatter, "stale connection generation {actual}, current is {expected}")
            }
            Self::ZeroSequence => formatter.write_str("data frame has sequence zero"),
            Self::SequenceGap { lane, expected, actual } => {
                write!(formatter, "{lane} sequence gap: expected {expected}, got {actual}")
            }
            Self::InvalidAcknowledgement { lane, acknowledgement, next_sequence } => write!(
                formatter,
                "{lane} acknowledgement {acknowledgement} exceeds last sent sequence {}",
                next_sequence.saturating_sub(1)
            ),
        }
    }
}

impl std::error::Error for SessionError {}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicBool;

    use async_trait::async_trait;
    use tokio::sync::{Mutex as AsyncMutex, Semaphore};

    use super::*;
    use crate::link::{LaneMuxLink, LinkRoute, test_support};

    struct GatedRecordingLink {
        first: AtomicBool,
        closed: AtomicBool,
        entered: Semaphore,
        release: Semaphore,
        sent: AsyncMutex<Vec<Lane>>,
    }

    struct RejectingLink;

    struct ReceiveThenRejectAckLink {
        incoming: AsyncMutex<Option<Bytes>>,
    }

    struct GatedAckLink {
        incoming: AsyncMutex<mpsc::UnboundedReceiver<Bytes>>,
        send_entered: Semaphore,
    }

    #[async_trait]
    impl FrameLink for RejectingLink {
        fn description(&self) -> &str {
            "rejecting"
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            Err(LinkError::Closed)
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            std::future::pending().await
        }

        async fn close(&self) -> Result<(), LinkError> {
            Ok(())
        }
    }

    #[async_trait]
    impl FrameLink for ReceiveThenRejectAckLink {
        fn description(&self) -> &str {
            "receive-then-reject-ack"
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            Err(LinkError::Transport("reverse path closed".into()))
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            Ok(self.incoming.lock().await.take())
        }

        async fn close(&self) -> Result<(), LinkError> {
            Ok(())
        }
    }

    #[async_trait]
    impl FrameLink for GatedAckLink {
        fn description(&self) -> &str {
            "gated-ack"
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            self.send_entered.add_permits(1);
            std::future::pending().await
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            Ok(self.incoming.lock().await.recv().await)
        }

        async fn close(&self) -> Result<(), LinkError> {
            Ok(())
        }
    }

    impl GatedRecordingLink {
        fn new() -> Self {
            Self {
                first: AtomicBool::new(true),
                closed: AtomicBool::new(false),
                entered: Semaphore::new(0),
                release: Semaphore::new(0),
                sent: AsyncMutex::new(Vec::new()),
            }
        }
    }

    #[async_trait]
    impl FrameLink for GatedRecordingLink {
        fn description(&self) -> &str {
            "gated-recording"
        }

        fn maximum_frame_bytes(&self) -> usize {
            128 * 1024
        }

        async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
            if self.first.swap(false, Ordering::AcqRel) {
                self.entered.add_permits(1);
                self.release.acquire().await.unwrap().forget();
            }
            self.sent.lock().await.push(WireFrame::decode(&frame).unwrap().lane);
            Ok(())
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            std::future::pending().await
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.closed.store(true, Ordering::Release);
            self.release.add_permits(1);
            Ok(())
        }
    }

    #[tokio::test]
    async fn blocked_bulk_send_does_not_block_interactive_lane() {
        let link = Arc::new(GatedRecordingLink::new());
        let session =
            ReliableSession::new(SessionId([1; 16]), link.clone(), SessionLimits::default());

        let first = tokio::spawn({
            let session = session.clone();
            async move {
                session.send(Lane::Bulk, 1, Bytes::from_static(b"first"), FrameFlags::empty()).await
            }
        });
        link.entered.acquire().await.unwrap().forget();

        let input = tokio::spawn({
            let session = session.clone();
            async move {
                session
                    .send(Lane::Interactive, 2, Bytes::from_static(b"key"), FrameFlags::empty())
                    .await
            }
        });
        tokio::time::timeout(Duration::from_secs(1), input)
            .await
            .expect("interactive send waited for blocked bulk")
            .unwrap()
            .unwrap();
        assert!(!first.is_finished());
        assert_eq!(*link.sent.lock().await, [Lane::Interactive]);

        link.release.add_permits(1);

        first.await.unwrap().unwrap();
        let sent = link.sent.lock().await.clone();
        assert_eq!(sent, [Lane::Interactive, Lane::Bulk]);
    }

    #[tokio::test]
    async fn committed_frame_is_delivered_when_its_ack_write_fails() {
        let session_id = SessionId([15; 16]);
        let frame = WireFrame {
            session: session_id,
            generation: 0,
            lane: Lane::Control,
            flags: FrameFlags::RELIABLE.union(FrameFlags::SESSION_CLOSE),
            sequence: 1,
            acknowledgement: 0,
            stream: 0,
            payload: Vec::new(),
        };
        let link = Arc::new(ReceiveThenRejectAckLink {
            incoming: AsyncMutex::new(Some(Bytes::from(frame.encode().unwrap()))),
        });
        let session = ReliableSession::new(session_id, link, SessionLimits::default());

        let received = session.receive().await.unwrap().unwrap();
        assert_eq!(received.sequence, 1);
        assert!(received.flags.contains(FrameFlags::SESSION_CLOSE));
    }

    #[tokio::test]
    async fn duplicate_replay_ack_failure_does_not_hide_admitted_session_close() {
        let session_id = SessionId([17; 16]);
        let (incoming_tx, incoming_rx) = mpsc::unbounded_channel();
        let physical = Arc::new(GatedAckLink {
            incoming: AsyncMutex::new(incoming_rx),
            send_entered: Semaphore::new(0),
        });
        let mux = Arc::new(
            LaneMuxLink::new(
                "duplicate replay terminal drain",
                vec![LinkRoute { lanes: Lane::ALL.to_vec(), link: physical.clone() }],
            )
            .unwrap(),
        );
        let session = ReliableSession::new(session_id, mux.clone(), SessionLimits::default());
        let first = WireFrame {
            session: session_id,
            generation: 0,
            lane: Lane::Control,
            flags: FrameFlags::RELIABLE,
            sequence: 1,
            acknowledgement: 0,
            stream: 2,
            payload: b"once".to_vec(),
        };
        incoming_tx.send(Bytes::from(first.encode().unwrap())).unwrap();
        assert_eq!(session.receive().await.unwrap().unwrap().payload, b"once".as_slice());
        physical.send_entered.acquire().await.unwrap().forget();

        let duplicate = WireFrame { flags: first.flags.union(FrameFlags::REPLAY), ..first };
        let close = WireFrame {
            session: session_id,
            generation: 0,
            lane: Lane::Control,
            flags: FrameFlags::RELIABLE.union(FrameFlags::SESSION_CLOSE),
            sequence: 2,
            acknowledgement: 0,
            stream: 0,
            payload: Vec::new(),
        };
        incoming_tx.send(Bytes::from(duplicate.encode().unwrap())).unwrap();
        incoming_tx.send(Bytes::from(close.encode().unwrap())).unwrap();
        drop(incoming_tx);

        let received = tokio::time::timeout(Duration::from_secs(1), session.receive())
            .await
            .expect("session close remained hidden behind duplicate ACK")
            .expect("duplicate ACK failure hid the admitted session close")
            .expect("session ended before the admitted session close");
        assert_eq!(received.sequence, 2);
        assert!(received.flags.contains(FrameFlags::SESSION_CLOSE));
    }

    async fn assert_replay_full_does_not_skip_sequence(session_byte: u8) {
        let limits = SessionLimits { replay_frames_per_lane: 1, ..SessionLimits::default() };
        let (sender_link, peer_link) = test_support::pair(128 * 1024);
        let sender =
            ReliableSession::new(SessionId([session_byte; 16]), Arc::new(sender_link), limits);
        let peer = ReliableSession::new(SessionId([session_byte; 16]), Arc::new(peer_link), limits);

        assert_eq!(
            sender
                .send(Lane::Control, 7, Bytes::from_static(b"one"), FrameFlags::empty())
                .await
                .unwrap(),
            1
        );
        assert_eq!(peer.receive().await.unwrap().unwrap().sequence, 1);

        assert!(matches!(
            sender.send(Lane::Control, 7, Bytes::from_static(b"two"), FrameFlags::empty()).await,
            Err(SessionError::ReplayFull(Lane::Control))
        ));
        assert_eq!(sender.next_outbound_sequence(Lane::Control), 2);
        assert_eq!(sender.outstanding_reliable_frames(Lane::Control), 1);

        peer.send(Lane::Control, 8, Bytes::from_static(b"ack carrier"), FrameFlags::empty())
            .await
            .unwrap();
        assert_eq!(sender.receive().await.unwrap().unwrap().payload, b"ack carrier".as_slice());
        assert_eq!(sender.outstanding_reliable_frames(Lane::Control), 0);

        assert_eq!(
            sender
                .send(Lane::Control, 7, Bytes::from_static(b"two"), FrameFlags::empty())
                .await
                .unwrap(),
            2
        );
        let received = peer.receive().await.unwrap().unwrap();
        assert_eq!(received.sequence, 2);
        assert_eq!(received.payload, b"two".as_slice());
    }

    #[tokio::test]
    async fn client_replay_full_then_success_does_not_create_sequence_gap() {
        assert_replay_full_does_not_skip_sequence(11).await;
    }

    #[tokio::test]
    async fn server_replay_full_then_success_does_not_create_sequence_gap() {
        assert_replay_full_does_not_skip_sequence(12).await;
    }

    #[tokio::test]
    async fn closing_session_releases_replay_backpressure_waiters() {
        let limits = SessionLimits { replay_frames_per_lane: 1, ..SessionLimits::default() };
        let (sender_link, peer_link) = test_support::pair(128 * 1024);
        let sender = ReliableSession::new(SessionId([18; 16]), Arc::new(sender_link), limits);
        let peer = ReliableSession::new(SessionId([18; 16]), Arc::new(peer_link), limits);

        sender.send(Lane::Bulk, 7, Bytes::from_static(b"one"), FrameFlags::empty()).await.unwrap();
        assert_eq!(peer.receive().await.unwrap().unwrap().payload, b"one".as_slice());
        let blocked = tokio::spawn({
            let sender = sender.clone();
            async move {
                sender
                    .send_with_backpressure(
                        Lane::Bulk,
                        7,
                        Bytes::from_static(b"two"),
                        FrameFlags::empty(),
                    )
                    .await
            }
        });
        tokio::task::yield_now().await;
        assert!(!blocked.is_finished());

        sender.close().await.unwrap();
        let error = tokio::time::timeout(Duration::from_secs(1), blocked)
            .await
            .expect("replay backpressure waiter survived session close")
            .unwrap()
            .unwrap_err();
        assert!(matches!(error, SessionError::Link(LinkError::Closed)));
    }

    #[tokio::test]
    async fn tunnel_delivery_window_backpressures_until_ack() {
        let limits = SessionLimits::default();
        let (sender_link, peer_link) = test_support::pair(128 * 1024);
        let sender = ReliableSession::new(SessionId([19; 16]), Arc::new(sender_link), limits);
        let peer = ReliableSession::new(SessionId([19; 16]), Arc::new(peer_link), limits);
        let payload = Bytes::from(vec![0; MAX_FRAME_PAYLOAD]);

        for expected_sequence in 1..=5 {
            assert_eq!(
                sender
                    .send_with_backpressure(Lane::Tunnel, 7, payload.clone(), FrameFlags::empty(),)
                    .await
                    .unwrap(),
                expected_sequence
            );
            assert_eq!(peer.receive().await.unwrap().unwrap().sequence, expected_sequence);
        }

        let blocked = tokio::spawn({
            let sender = sender.clone();
            let payload = payload.clone();
            async move {
                sender.send_with_backpressure(Lane::Tunnel, 7, payload, FrameFlags::empty()).await
            }
        });
        tokio::task::yield_now().await;
        assert!(!blocked.is_finished(), "unacknowledged tunnel bytes escaped the delivery window");

        let receive_acks = tokio::spawn({
            let sender = sender.clone();
            async move { sender.receive().await }
        });
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), blocked)
                .await
                .expect("tunnel send remained blocked after its delivery acknowledgement")
                .unwrap()
                .unwrap(),
            6
        );
        receive_acks.abort();
        assert_eq!(peer.receive().await.unwrap().unwrap().sequence, 6);
    }

    #[tokio::test]
    async fn queue_admission_failure_rolls_back_sequence_and_replay() {
        let limits = SessionLimits { queued_bytes_per_lane: 512, ..SessionLimits::default() };
        let (sender_link, peer_link) = test_support::pair(128 * 1024);
        let sender = ReliableSession::new(SessionId([13; 16]), Arc::new(sender_link), limits);
        let peer = ReliableSession::new(SessionId([13; 16]), Arc::new(peer_link), limits);

        assert!(matches!(
            sender.send(Lane::Control, 1, Bytes::from(vec![0; 1_024]), FrameFlags::empty()).await,
            Err(SessionError::QueueFull(Lane::Control))
        ));
        assert_eq!(sender.next_outbound_sequence(Lane::Control), 1);
        assert_eq!(sender.outstanding_reliable_frames(Lane::Control), 0);

        assert_eq!(
            sender
                .send(Lane::Control, 1, Bytes::from_static(b"fits"), FrameFlags::empty())
                .await
                .unwrap(),
            1
        );
        let received = peer.receive().await.unwrap().unwrap();
        assert_eq!(received.sequence, 1);
        assert_eq!(received.payload, b"fits".as_slice());

        assert!(matches!(
            sender.send(Lane::Tunnel, 2, Bytes::from(vec![0; 1_024]), FrameFlags::empty()).await,
            Err(SessionError::QueueFull(Lane::Tunnel))
        ));
        assert_eq!(sender.next_outbound_sequence(Lane::Tunnel), 1);
        assert_eq!(
            sender
                .send(Lane::Tunnel, 2, Bytes::from_static(b"tunnel fits"), FrameFlags::empty())
                .await
                .unwrap(),
            1
        );
        let tunnel = peer.receive().await.unwrap().unwrap();
        assert_eq!(tunnel.sequence, 1);
        assert_eq!(tunnel.payload, b"tunnel fits".as_slice());
    }

    #[tokio::test]
    async fn reconnect_replays_only_frames_after_peer_cursor() {
        let (client_link, server_link) = test_support::pair(128 * 1024);
        let client = ReliableSession::new(
            SessionId([2; 16]),
            Arc::new(client_link),
            SessionLimits::default(),
        );
        let server = ReliableSession::new(
            SessionId([2; 16]),
            Arc::new(server_link),
            SessionLimits::default(),
        );
        client
            .send(Lane::Control, 7, Bytes::from_static(b"one"), FrameFlags::empty())
            .await
            .unwrap();
        assert_eq!(server.receive().await.unwrap().unwrap().payload, b"one".as_slice());
        client
            .send(Lane::Control, 7, Bytes::from_static(b"two"), FrameFlags::empty())
            .await
            .unwrap();

        let (new_client_link, new_server_link) = test_support::pair(128 * 1024);
        let client = client
            .reconnect(Arc::new(new_client_link), &BTreeMap::from([(Lane::Control, 1)]))
            .await
            .unwrap();
        let server = server.reconnect(Arc::new(new_server_link), &BTreeMap::new()).await.unwrap();
        let replay = server.receive().await.unwrap().unwrap();
        assert_eq!(replay.sequence, 2);
        assert_eq!(replay.payload, b"two".as_slice());
        assert!(replay.flags.contains(FrameFlags::REPLAY));
        assert_eq!(client.outstanding_reliable_frames(Lane::Control), 1);
    }

    #[tokio::test]
    async fn failed_reconnect_keeps_old_session_usable_and_retryable() {
        let (old_link, old_peer) = test_support::pair(128 * 1024);
        let session =
            ReliableSession::new(SessionId([14; 16]), Arc::new(old_link), SessionLimits::default());
        session
            .send(Lane::Control, 1, Bytes::from_static(b"one"), FrameFlags::empty())
            .await
            .unwrap();
        let first = WireFrame::decode(&old_peer.receive().await.unwrap().unwrap()).unwrap();
        assert_eq!(first.sequence, 1);

        assert!(matches!(
            session.reconnect(Arc::new(RejectingLink), &BTreeMap::new()).await,
            Err(SessionError::LinkMessage(_))
        ));
        assert_eq!(session.generation(), 0);
        assert_eq!(session.next_outbound_sequence(Lane::Control), 2);
        assert_eq!(session.outstanding_reliable_frames(Lane::Control), 1);

        assert_eq!(
            session
                .send(Lane::Control, 1, Bytes::from_static(b"two"), FrameFlags::empty())
                .await
                .unwrap(),
            2
        );
        let second = WireFrame::decode(&old_peer.receive().await.unwrap().unwrap()).unwrap();
        assert_eq!(second.generation, 0);
        assert_eq!(second.sequence, 2);

        let (retry_link, retry_peer) = test_support::pair(128 * 1024);
        let replacement = session.reconnect(Arc::new(retry_link), &BTreeMap::new()).await.unwrap();
        assert_eq!(replacement.generation(), 1);
        for expected in [b"one".as_slice(), b"two".as_slice()] {
            let replay = WireFrame::decode(&retry_peer.receive().await.unwrap().unwrap()).unwrap();
            assert_eq!(replay.generation, 1);
            assert!(replay.flags.contains(FrameFlags::REPLAY));
            assert_eq!(replay.payload, expected);
        }
    }

    #[tokio::test]
    async fn cancelled_reconnect_can_retry_at_a_later_generation() {
        let (old_link, _old_peer) = test_support::pair(128 * 1024);
        let session =
            ReliableSession::new(SessionId([16; 16]), Arc::new(old_link), SessionLimits::default());
        session
            .send(Lane::Control, 1, Bytes::from_static(b"replay me"), FrameFlags::empty())
            .await
            .unwrap();

        let blocked = Arc::new(GatedRecordingLink::new());
        let attempt = tokio::spawn({
            let session = session.clone();
            let blocked = blocked.clone();
            async move { session.reconnect_to(blocked, &BTreeMap::new(), 1).await }
        });
        blocked.entered.acquire().await.unwrap().forget();
        attempt.abort();
        assert!(attempt.await.unwrap_err().is_cancelled());
        tokio::time::timeout(Duration::from_secs(1), async {
            while !blocked.closed.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("cancelled reconnect did not close its uncommitted link");

        let (retry_link, retry_peer) = test_support::pair(128 * 1024);
        let replacement =
            session.reconnect_to(Arc::new(retry_link), &BTreeMap::new(), 2).await.unwrap();
        assert_eq!(replacement.generation(), 2);
        let replay = WireFrame::decode(&retry_peer.receive().await.unwrap().unwrap()).unwrap();
        assert_eq!(replay.generation, 2);
        assert_eq!(replay.payload, b"replay me");
        assert!(replay.flags.contains(FrameFlags::REPLAY));
    }

    #[tokio::test]
    async fn reconnect_discards_ambiguous_tunnel_frame_and_starts_a_new_sequence_epoch() {
        let (client_link, _old_server_link) = test_support::pair(128 * 1024);
        let client = ReliableSession::new(
            SessionId([3; 16]),
            Arc::new(client_link),
            SessionLimits::default(),
        );
        let ambiguous = client
            .send(Lane::Tunnel, 9, Bytes::from_static(b"possibly delivered"), FrameFlags::empty())
            .await
            .unwrap();
        assert_eq!(ambiguous, 1);
        assert_eq!(client.outstanding_reliable_frames(Lane::Tunnel), 0);

        let (new_client_link, new_server_link) = test_support::pair(128 * 1024);
        let client = client
            .reconnect(Arc::new(new_client_link), &BTreeMap::from([(Lane::Tunnel, 0)]))
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(25), new_server_link.receive())
                .await
                .is_err(),
            "ambiguous tunnel bytes were replayed"
        );

        let next = client
            .send(Lane::Tunnel, 11, Bytes::from_static(b"new tunnel"), FrameFlags::empty())
            .await
            .unwrap();
        assert_eq!(next, 1);
        let frame = WireFrame::decode(&new_server_link.receive().await.unwrap().unwrap()).unwrap();
        assert_eq!(frame.generation, 1);
        assert_eq!(frame.sequence, 1);
        assert_eq!(frame.payload, b"new tunnel");
        assert!(!frame.flags.contains(FrameFlags::REPLAY));
    }

    #[tokio::test]
    async fn duplicate_reliable_frame_is_acknowledged_but_not_delivered_twice() {
        let (client_link, server_link) = test_support::pair(128 * 1024);
        let server = ReliableSession::new(
            SessionId([5; 16]),
            Arc::new(server_link),
            SessionLimits::default(),
        );
        let frame = WireFrame {
            session: SessionId([5; 16]),
            generation: 0,
            lane: Lane::Control,
            flags: FrameFlags::RELIABLE,
            sequence: 1,
            acknowledgement: 0,
            stream: 2,
            payload: b"once".to_vec(),
        };
        let encoded = Bytes::from(frame.encode().unwrap());
        client_link.send(encoded.clone()).await.unwrap();
        assert_eq!(server.receive().await.unwrap().unwrap().payload, b"once".as_slice());
        client_link.send(encoded).await.unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(25), server.receive()).await.is_err());
    }

    #[tokio::test]
    async fn stale_connection_is_generation_fenced() {
        let (left, _right) = test_support::pair(128 * 1024);
        let original =
            ReliableSession::new(SessionId([4; 16]), Arc::new(left), SessionLimits::default());
        let (new_left, _new_right) = test_support::pair(128 * 1024);
        let _replacement = original.reconnect(Arc::new(new_left), &BTreeMap::new()).await.unwrap();
        assert!(matches!(
            original.send(Lane::Control, 0, Bytes::new(), FrameFlags::empty()).await,
            Err(SessionError::StaleGeneration { .. })
        ));
    }
}
