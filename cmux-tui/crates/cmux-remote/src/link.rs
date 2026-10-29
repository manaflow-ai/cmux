use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::future::pending;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote_protocol::{Lane, MAX_WIRE_FRAME_BYTES, WireFrame};
use futures_util::future::join_all;
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc, oneshot, watch};
use tokio::task::JoinHandle;

use crate::per_lane::PerLane;

const INGRESS_BYTES_PER_LANE: usize = 8 * 1_024 * 1_024;
const INGRESS_ACCOUNTING_FLOOR_BYTES: usize = 1_024;
const INGRESS_FRAMES_PER_LANE: usize = INGRESS_BYTES_PER_LANE / INGRESS_ACCOUNTING_FLOOR_BYTES;
const PRIORITY_BURST_FRAMES: usize = 32;
const PRIORITY_LANES: [Lane; 4] = [Lane::Interactive, Lane::Control, Lane::Tunnel, Lane::Bulk];
// ReliableSession owns one physical send loop per lane, so at most one caller
// per lane can wait for LaneMuxLink queue admission in production.
const OUTBOUND_FRAMES_PER_LANE: usize = PRIORITY_BURST_FRAMES * PRIORITY_LANES.len();
const _: () = assert!(MAX_WIRE_FRAME_BYTES <= INGRESS_BYTES_PER_LANE);

/// An ordered binary-message link supplied by a direct transport or relay.
///
/// Authentication, encryption, replay, and service multiplexing live above
/// this boundary. Implementations must cap incoming frames before allocating.
#[async_trait]
pub trait FrameLink: Send + Sync {
    fn description(&self) -> &str;
    fn maximum_frame_bytes(&self) -> usize;
    /// Returns true only while a terminal aggregate link still has admitted
    /// Control frames to deliver. Reliability uses this to defer one failed
    /// duplicate-replay ACK without weakening normal protocol errors.
    fn terminal_control_drain_active(&self) -> bool {
        false
    }
    async fn send(&self, frame: Bytes) -> Result<(), LinkError>;
    async fn receive(&self) -> Result<Option<Bytes>, LinkError>;
    async fn close(&self) -> Result<(), LinkError>;
}

#[derive(Clone, Debug)]
pub enum LinkError {
    Closed,
    FrameTooLarge { actual: usize, maximum: usize },
    Transport(String),
    Protocol(String),
}

impl fmt::Display for LinkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Closed => formatter.write_str("link is closed"),
            Self::FrameTooLarge { actual, maximum } => {
                write!(formatter, "link frame is {actual} bytes, maximum is {maximum}")
            }
            Self::Transport(message) => write!(formatter, "link transport failed: {message}"),
            Self::Protocol(message) => write!(formatter, "link protocol failed: {message}"),
        }
    }
}

impl std::error::Error for LinkError {}

pub struct LinkRoute {
    pub lanes: Vec<Lane>,
    pub link: Arc<dyn FrameLink>,
}

#[derive(Clone)]
struct LinkLifecycle {
    terminal: watch::Sender<Option<TerminalState>>,
    state: Arc<StdMutex<LifecycleState>>,
}

type PhysicalId = usize;

struct LifecycleState {
    terminal: Option<TerminalState>,
    admitted_by_physical: Vec<u64>,
    admitted_control_by_physical: Vec<u64>,
    delivered_control_by_physical: Vec<u64>,
    ingress_discarded: bool,
}

#[derive(Clone, Copy, Debug)]
struct TerminalFence {
    physical: PhysicalId,
    admitted_ordinal: u64,
}

#[derive(Clone, Debug)]
struct TerminalState {
    error: LinkError,
    origin_fence: Option<TerminalFence>,
    admitted_control_by_physical: Vec<u64>,
}

impl LinkLifecycle {
    fn new(physical_count: usize) -> Self {
        let (terminal, _) = watch::channel(None);
        Self {
            terminal,
            state: Arc::new(StdMutex::new(LifecycleState {
                terminal: None,
                admitted_by_physical: vec![0; physical_count],
                admitted_control_by_physical: vec![0; physical_count],
                delivered_control_by_physical: vec![0; physical_count],
                ingress_discarded: false,
            })),
        }
    }

    fn error(&self) -> Option<LinkError> {
        self.lock_state().terminal.as_ref().map(|terminal| terminal.error.clone())
    }

    fn subscribe(&self) -> watch::Receiver<Option<TerminalState>> {
        self.terminal.subscribe()
    }

    fn terminate(&self, error: LinkError) -> LinkError {
        self.terminate_with_origin(error, None).error
    }

    fn terminate_after_ingress(&self, error: LinkError, physical: PhysicalId) -> TerminalState {
        self.terminate_with_origin(error, Some(physical))
    }

    fn terminate_with_origin(&self, error: LinkError, origin: Option<PhysicalId>) -> TerminalState {
        let mut state = self.lock_state();
        if let Some(existing) = &state.terminal {
            return existing.clone();
        }
        let origin_fence = origin.and_then(|physical| {
            let admitted_ordinal = *state.admitted_by_physical.get(physical)?;
            Some(TerminalFence { physical, admitted_ordinal })
        });
        let terminal = TerminalState {
            error,
            origin_fence,
            admitted_control_by_physical: state.admitted_control_by_physical.clone(),
        };
        state.terminal = Some(terminal.clone());
        self.terminal.send_replace(Some(terminal.clone()));
        terminal
    }

    fn admit(
        &self,
        physical: PhysicalId,
        lane: Lane,
        encoded: Bytes,
        permit: OwnedSemaphorePermit,
        reservation: mpsc::Permit<'_, IngressFrame>,
    ) -> Result<(), LinkError> {
        let mut state = self.lock_state();
        if let Some(terminal) = &state.terminal {
            return Err(terminal.error.clone());
        }
        let unknown = || LinkError::Protocol(format!("physical link {physical} is unknown"));
        let ordinal = state
            .admitted_by_physical
            .get(physical)
            .ok_or_else(unknown)?
            .checked_add(1)
            .ok_or_else(|| LinkError::Protocol("physical ingress ordinal overflowed".into()))?;
        let control_ordinal = if lane == Lane::Control {
            Some(
                state
                    .admitted_control_by_physical
                    .get(physical)
                    .ok_or_else(unknown)?
                    .checked_add(1)
                    .ok_or_else(|| {
                        LinkError::Protocol("physical Control ingress ordinal overflowed".into())
                    })?,
            )
        } else {
            None
        };
        if let Some(admitted) = state.admitted_by_physical.get_mut(physical) {
            *admitted = ordinal;
        }
        if let Some(control_ordinal) = control_ordinal
            && let Some(admitted) = state.admitted_control_by_physical.get_mut(physical)
        {
            *admitted = control_ordinal;
        }
        reservation.send(IngressFrame {
            encoded,
            _permit: permit,
            physical,
            ordinal,
            control_ordinal,
        });
        Ok(())
    }

    fn delivered_control(&self, physical: PhysicalId, ordinal: u64) {
        let mut state = self.lock_state();
        let Some(delivered) = state.delivered_control_by_physical.get_mut(physical) else {
            return;
        };
        debug_assert_eq!(
            delivered.saturating_add(1),
            ordinal,
            "Control ingress was delivered out of physical admission order",
        );
        *delivered = ordinal;
    }

    fn discard_ingress(&self) {
        self.lock_state().ingress_discarded = true;
    }

    fn terminal_control_drain_active(&self) -> bool {
        let state = self.lock_state();
        let Some(terminal) = &state.terminal else {
            return false;
        };
        !state.ingress_discarded
            && terminal
                .admitted_control_by_physical
                .iter()
                .zip(&state.delivered_control_by_physical)
                .any(|(admitted, delivered)| delivered < admitted)
    }

    fn lock_state(&self) -> std::sync::MutexGuard<'_, LifecycleState> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

async fn wait_for_terminal(terminal: &mut watch::Receiver<Option<TerminalState>>) -> TerminalState {
    loop {
        if let Some(terminal) = terminal.borrow_and_update().clone() {
            return terminal;
        }
        if terminal.changed().await.is_err() {
            return TerminalState {
                error: LinkError::Closed,
                origin_fence: None,
                admitted_control_by_physical: Vec::new(),
            };
        }
    }
}

struct IngressFrame {
    encoded: Bytes,
    _permit: OwnedSemaphorePermit,
    physical: PhysicalId,
    ordinal: u64,
    control_ordinal: Option<u64>,
}

#[derive(Clone)]
struct IngressSender {
    frames: mpsc::Sender<IngressFrame>,
    budget: Arc<Semaphore>,
}

impl IngressSender {
    fn channel() -> (Self, mpsc::Receiver<IngressFrame>) {
        let (frames, receiver) = mpsc::channel(INGRESS_FRAMES_PER_LANE);
        (Self { frames, budget: Arc::new(Semaphore::new(INGRESS_BYTES_PER_LANE)) }, receiver)
    }

    async fn send_admitted(
        &self,
        encoded: Bytes,
        physical: PhysicalId,
        lane: Lane,
        lifecycle: &LinkLifecycle,
    ) -> Result<(), LinkError> {
        let accounted = encoded.len().max(INGRESS_ACCOUNTING_FLOOR_BYTES);
        if accounted > INGRESS_BYTES_PER_LANE {
            return Err(LinkError::FrameTooLarge {
                actual: encoded.len(),
                maximum: INGRESS_BYTES_PER_LANE,
            });
        }
        let permits = u32::try_from(accounted).map_err(|_| LinkError::FrameTooLarge {
            actual: encoded.len(),
            maximum: INGRESS_BYTES_PER_LANE,
        })?;
        let permit =
            self.budget.clone().acquire_many_owned(permits).await.map_err(|_| LinkError::Closed)?;
        let reservation = self.frames.reserve().await.map_err(|_| LinkError::Closed)?;
        lifecycle.admit(physical, lane, encoded, permit, reservation)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum IngressDisposition {
    Active,
    Discarded,
}

struct Ingress {
    frames: PriorityReceivers<IngressFrame>,
    terminal: watch::Receiver<Option<TerminalState>>,
    lifecycle: LinkLifecycle,
    physical_by_lane: PerLane<PhysicalId>,
    delivered_by_physical: Vec<u64>,
    delivered_control_by_physical: Vec<u64>,
    disposition: IngressDisposition,
}

impl Ingress {
    async fn receive(&mut self) -> Result<Option<Bytes>, LinkError> {
        loop {
            if self.disposition == IngressDisposition::Discarded {
                return Err(self
                    .terminal
                    .borrow_and_update()
                    .as_ref()
                    .map(|terminal| terminal.error.clone())
                    .unwrap_or(LinkError::Closed));
            }
            let terminal = { self.terminal.borrow_and_update().clone() };
            if let Some(terminal) = terminal {
                if terminal
                    .admitted_control_by_physical
                    .iter()
                    .zip(&self.delivered_control_by_physical)
                    .any(|(admitted, delivered)| delivered < admitted)
                {
                    let allowed = PerLane::from_fn(|lane| lane == Lane::Control);
                    let Some(frame) = self.frames.receive_from(allowed).await else {
                        debug_assert!(
                            terminal
                                .admitted_control_by_physical
                                .iter()
                                .zip(&self.delivered_control_by_physical)
                                .all(|(admitted, delivered)| delivered >= admitted),
                            "Control ingress closed before all admitted frames were delivered",
                        );
                        return Err(terminal.error);
                    };
                    return Ok(Some(self.deliver(frame)));
                }

                if let Some(fence) = terminal.origin_fence
                    && self
                        .delivered_by_physical
                        .get(fence.physical)
                        .is_some_and(|delivered| *delivered < fence.admitted_ordinal)
                {
                    let allowed = self.physical_by_lane.map(|physical| physical == fence.physical);
                    let Some(frame) = self.frames.receive_from(allowed).await else {
                        debug_assert_eq!(
                            self.delivered_by_physical.get(fence.physical).copied(),
                            Some(fence.admitted_ordinal),
                            "fenced physical ingress closed before all admitted frames were delivered",
                        );
                        return Err(terminal.error);
                    };
                    return Ok(Some(self.deliver(frame)));
                }

                return Err(terminal.error);
            }

            tokio::select! {
                biased;
                _ = wait_for_terminal(&mut self.terminal) => continue,
                frame = self.frames.receive() => {
                    return Ok(frame.map(|frame| self.deliver(frame)));
                }
            }
        }
    }

    fn deliver(&mut self, frame: IngressFrame) -> Bytes {
        debug_assert!(frame.ordinal > 0);
        if let Some(delivered) = self.delivered_by_physical.get_mut(frame.physical) {
            *delivered += 1;
        }
        if let Some(control_ordinal) = frame.control_ordinal {
            if let Some(delivered) = self.delivered_control_by_physical.get_mut(frame.physical) {
                debug_assert_eq!(
                    delivered.saturating_add(1),
                    control_ordinal,
                    "Control ingress was delivered out of queue order",
                );
                *delivered = control_ordinal;
            }
            self.lifecycle.delivered_control(frame.physical, control_ordinal);
        }
        frame.encoded
    }

    fn discard(&mut self) {
        self.disposition = IngressDisposition::Discarded;
        self.lifecycle.discard_ingress();
        self.frames.discard();
    }
}

struct OutboundFrame {
    encoded: Bytes,
    completion: oneshot::Sender<Result<(), LinkError>>,
}

#[derive(Clone)]
struct OutboundSender {
    frames: mpsc::Sender<OutboundFrame>,
}

impl OutboundSender {
    async fn enqueue(
        &self,
        encoded: Bytes,
    ) -> Result<oneshot::Receiver<Result<(), LinkError>>, LinkError> {
        let (completion, result) = oneshot::channel();
        self.frames
            .send(OutboundFrame { encoded, completion })
            .await
            .map_err(|_| LinkError::Closed)?;
        Ok(result)
    }
}

struct PhysicalRoute {
    lanes: BTreeSet<Lane>,
    link: Arc<dyn FrameLink>,
}

struct PriorityReceivers<T> {
    receivers: PerLane<Option<mpsc::Receiver<T>>>,
    priority_deliveries: usize,
    fair_cursor: usize,
}

impl<T> PriorityReceivers<T> {
    fn new(receivers: PerLane<mpsc::Receiver<T>>) -> Self {
        Self { receivers: receivers.map(Some), priority_deliveries: 0, fair_cursor: 0 }
    }

    fn discard(&mut self) {
        self.receivers = PerLane::from_fn(|_| None);
    }

    fn try_receive_from(&mut self, allowed: PerLane<bool>) -> Option<T> {
        if self.priority_deliveries < PRIORITY_BURST_FRAMES {
            for lane in PRIORITY_LANES {
                if *allowed.get(lane)
                    && let Some(item) = self.try_receive_lane(lane)
                {
                    self.priority_deliveries += 1;
                    return Some(item);
                }
            }
            return None;
        }

        for offset in 0..PRIORITY_LANES.len() {
            let index = (self.fair_cursor + offset) % PRIORITY_LANES.len();
            let Some(&lane) = PRIORITY_LANES.get(index) else { continue };
            if *allowed.get(lane)
                && let Some(item) = self.try_receive_lane(lane)
            {
                self.fair_cursor = (index + 1) % PRIORITY_LANES.len();
                self.priority_deliveries = 0;
                return Some(item);
            }
        }
        None
    }

    fn try_receive_lane(&mut self, lane: Lane) -> Option<T> {
        match self.receivers.get_mut(lane).as_mut()?.try_recv() {
            Ok(item) => Some(item),
            Err(mpsc::error::TryRecvError::Empty) => None,
            Err(mpsc::error::TryRecvError::Disconnected) => {
                *self.receivers.get_mut(lane) = None;
                None
            }
        }
    }

    async fn receive(&mut self) -> Option<T> {
        self.receive_from(PerLane::from_fn(|_| true)).await
    }

    async fn receive_from(&mut self, allowed: PerLane<bool>) -> Option<T> {
        loop {
            if let Some(item) = self.try_receive_from(allowed) {
                return Some(item);
            }
            if Lane::ALL
                .into_iter()
                .all(|lane| !*allowed.get(lane) || self.receivers.get(lane).is_none())
            {
                return None;
            }

            let fair_selection = self.priority_deliveries >= PRIORITY_BURST_FRAMES;
            let (lane, item) = {
                let PerLane { interactive, control, bulk, tunnel } = &mut self.receivers;
                tokio::select! {
                    biased;
                    item = receive_or_pending(interactive, allowed.interactive) => (Lane::Interactive, item),
                    item = receive_or_pending(control, allowed.control) => (Lane::Control, item),
                    item = receive_or_pending(tunnel, allowed.tunnel) => (Lane::Tunnel, item),
                    item = receive_or_pending(bulk, allowed.bulk) => (Lane::Bulk, item),
                }
            };
            let Some(item) = item else {
                *self.receivers.get_mut(lane) = None;
                continue;
            };
            if fair_selection {
                // Every lane is in PRIORITY_LANES.
                if let Some(index) = PRIORITY_LANES.iter().position(|candidate| *candidate == lane)
                {
                    self.fair_cursor = (index + 1) % PRIORITY_LANES.len();
                }
                self.priority_deliveries = 0;
            } else {
                self.priority_deliveries += 1;
            }
            return Some(item);
        }
    }
}

async fn receive_or_pending<T>(
    receiver: &mut Option<mpsc::Receiver<T>>,
    allowed: bool,
) -> Option<T> {
    match receiver {
        _ if !allowed => pending().await,
        Some(receiver) => receiver.recv().await,
        None => pending().await,
    }
}

fn spawn_outbound_dispatcher(
    link: Arc<dyn FrameLink>,
    lanes: &BTreeSet<Lane>,
    lifecycle: LinkLifecycle,
) -> (BTreeMap<Lane, OutboundSender>, JoinHandle<()>) {
    let (interactive_tx, interactive_rx) = mpsc::channel(OUTBOUND_FRAMES_PER_LANE);
    let (control_tx, control_rx) = mpsc::channel(OUTBOUND_FRAMES_PER_LANE);
    let (bulk_tx, bulk_rx) = mpsc::channel(OUTBOUND_FRAMES_PER_LANE);
    let (tunnel_tx, tunnel_rx) = mpsc::channel(OUTBOUND_FRAMES_PER_LANE);
    let senders = PerLane {
        interactive: interactive_tx,
        control: control_tx,
        bulk: bulk_tx,
        tunnel: tunnel_tx,
    };
    let routes = lanes
        .iter()
        .map(|lane| (*lane, OutboundSender { frames: senders.get(*lane).clone() }))
        .collect();
    drop(senders);
    let task = tokio::spawn(async move {
        let mut frames = PriorityReceivers::new(PerLane {
            interactive: interactive_rx,
            control: control_rx,
            bulk: bulk_rx,
            tunnel: tunnel_rx,
        });
        let mut terminal = lifecycle.subscribe();
        loop {
            let frame = tokio::select! {
                biased;
                _ = wait_for_terminal(&mut terminal) => return,
                frame = frames.receive() => {
                    let Some(frame) = frame else { return; };
                    frame
                }
            };
            let result = tokio::select! {
                biased;
                terminal = wait_for_terminal(&mut terminal) => {
                    let _ = frame.completion.send(Err(terminal.error));
                    return;
                }
                result = link.send(frame.encoded) => result,
            };
            match result {
                Ok(()) => {
                    let _ = frame.completion.send(Ok(()));
                }
                Err(error) => {
                    let error = lifecycle.terminate(error);
                    let _ = frame.completion.send(Err(error));
                    return;
                }
            }
        }
    });
    (routes, task)
}

#[derive(Clone, Debug)]
enum LinkCloseState {
    Pending,
    Complete,
    Failed(LinkError),
}

struct LinkCloseCompletionGuard {
    state: watch::Sender<LinkCloseState>,
    published: bool,
}

impl LinkCloseCompletionGuard {
    fn new(state: watch::Sender<LinkCloseState>) -> Self {
        Self { state, published: false }
    }

    fn publish(mut self, state: LinkCloseState) {
        self.state.send_replace(state);
        self.published = true;
    }
}

impl Drop for LinkCloseCompletionGuard {
    fn drop(&mut self) {
        if !self.published {
            self.state.send_replace(LinkCloseState::Failed(LinkError::Protocol(
                "lane mux shutdown task stopped".into(),
            )));
        }
    }
}

async fn wait_for_link_close(mut state: watch::Receiver<LinkCloseState>) -> Result<(), LinkError> {
    loop {
        match state.borrow().clone() {
            LinkCloseState::Pending => {}
            LinkCloseState::Complete => return Ok(()),
            LinkCloseState::Failed(error) => return Err(error),
        }
        state
            .changed()
            .await
            .map_err(|_| LinkError::Protocol("lane mux shutdown state stopped".into()))?;
    }
}

/// Presents several independently authenticated physical links as one frame
/// link. Outbound frames are routed by their encoded lane; dedicated reader
/// tasks avoid cancellation-corrupting a length-delimited stream.
pub struct LaneMuxLink {
    description: String,
    maximum: usize,
    routes: BTreeMap<Lane, OutboundSender>,
    links: Vec<Arc<dyn FrameLink>>,
    incoming: Arc<Mutex<Ingress>>,
    lifecycle: LinkLifecycle,
    tasks: StdMutex<Vec<JoinHandle<()>>>,
    closed: AtomicBool,
    close_state: watch::Sender<LinkCloseState>,
}

impl fmt::Debug for LaneMuxLink {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LaneMuxLink")
            .field("description", &self.description)
            .field("maximum", &self.maximum)
            .field("physical_links", &self.links.len())
            .finish_non_exhaustive()
    }
}

impl LaneMuxLink {
    pub fn new(
        description: impl Into<String>,
        physical: Vec<LinkRoute>,
    ) -> Result<Self, LinkError> {
        if physical.is_empty() {
            return Err(LinkError::Protocol("lane mux requires at least one link".into()));
        }
        let mut assigned = BTreeSet::new();
        let mut physical_routes: Vec<PhysicalRoute> = Vec::with_capacity(physical.len());
        for route in physical {
            if route.lanes.is_empty() {
                return Err(LinkError::Protocol("physical link has no assigned lanes".into()));
            }
            let lanes = route.lanes.into_iter().collect::<BTreeSet<_>>();
            for lane in &lanes {
                if !assigned.insert(*lane) {
                    return Err(LinkError::Protocol(format!("lane {lane} is assigned twice")));
                }
            }
            if let Some(existing) =
                physical_routes.iter_mut().find(|existing| Arc::ptr_eq(&existing.link, &route.link))
            {
                existing.lanes.extend(lanes);
            } else {
                physical_routes.push(PhysicalRoute { lanes, link: route.link });
            }
        }
        for lane in Lane::ALL {
            if !assigned.contains(&lane) {
                return Err(LinkError::Protocol(format!("lane {lane} has no physical link")));
            }
        }

        // Every lane has a physical link (checked above), so there is at least one.
        let Some(maximum) =
            physical_routes.iter().map(|route| route.link.maximum_frame_bytes()).min()
        else {
            return Err(LinkError::Protocol("lane mux has no physical link".into()));
        };
        let links = physical_routes.iter().map(|route| route.link.clone()).collect::<Vec<_>>();
        let physical_count = links.len();
        let mut routes = BTreeMap::new();
        let (interactive_tx, interactive_rx) = IngressSender::channel();
        let (control_tx, control_rx) = IngressSender::channel();
        let (bulk_tx, bulk_rx) = IngressSender::channel();
        let (tunnel_tx, tunnel_rx) = IngressSender::channel();
        let ingress_senders = PerLane {
            interactive: interactive_tx,
            control: control_tx,
            bulk: bulk_tx,
            tunnel: tunnel_tx,
        };
        let lifecycle = LinkLifecycle::new(physical_count);
        let mut tasks = Vec::with_capacity(physical_routes.len() * 2);
        let mut physical_by_lane = PerLane::from_fn(|_| usize::MAX);
        for (physical, route) in physical_routes.into_iter().enumerate() {
            let allowed = route.lanes;
            let link = route.link;
            for lane in &allowed {
                *physical_by_lane.get_mut(*lane) = physical;
            }
            let (outbound, dispatcher) =
                spawn_outbound_dispatcher(link.clone(), &allowed, lifecycle.clone());
            routes.extend(outbound);
            tasks.push(dispatcher);
            let lane_senders = allowed
                .iter()
                .map(|lane| (*lane, ingress_senders.get(*lane).clone()))
                .collect::<BTreeMap<_, _>>();
            let reader_lifecycle = lifecycle.clone();
            let reader = tokio::spawn(async move {
                let mut terminal = reader_lifecycle.subscribe();
                loop {
                    let received = tokio::select! {
                        biased;
                        _ = wait_for_terminal(&mut terminal) => return,
                        received = link.receive() => received,
                    };
                    match received {
                        Ok(Some(encoded)) => {
                            let validity = WireFrame::decode(&encoded)
                                .map_err(|error| LinkError::Protocol(error.to_string()))
                                .and_then(|frame| {
                                    if allowed.contains(&frame.lane) {
                                        Ok(frame.lane)
                                    } else {
                                        Err(LinkError::Protocol(format!(
                                            "lane {} arrived on the wrong physical link",
                                            frame.lane
                                        )))
                                    }
                                });
                            match validity {
                                Ok(lane) => {
                                    // Every allowed lane has an ingress queue.
                                    let Some(sender) = lane_senders.get(&lane) else {
                                        reader_lifecycle.terminate_after_ingress(
                                            LinkError::Protocol(format!(
                                                "lane {lane} has no ingress queue"
                                            )),
                                            physical,
                                        );
                                        return;
                                    };
                                    let admission = sender.send_admitted(
                                        encoded,
                                        physical,
                                        lane,
                                        &reader_lifecycle,
                                    );
                                    let result = tokio::select! {
                                        biased;
                                        _ = wait_for_terminal(&mut terminal) => return,
                                        result = admission => result,
                                    };
                                    match result {
                                        Ok(()) => {}
                                        Err(error) => {
                                            reader_lifecycle
                                                .terminate_after_ingress(error, physical);
                                            return;
                                        }
                                    }
                                }
                                Err(error) => {
                                    reader_lifecycle.terminate_after_ingress(error, physical);
                                    return;
                                }
                            }
                        }
                        Ok(None) => {
                            reader_lifecycle.terminate_after_ingress(LinkError::Closed, physical);
                            return;
                        }
                        Err(error) => {
                            reader_lifecycle.terminate_after_ingress(error, physical);
                            return;
                        }
                    }
                }
            });
            tasks.push(reader);
        }
        drop(ingress_senders);
        let (close_state, _) = watch::channel(LinkCloseState::Pending);
        Ok(Self {
            description: description.into(),
            maximum,
            routes,
            links,
            incoming: Arc::new(Mutex::new(Ingress {
                frames: PriorityReceivers::new(PerLane {
                    interactive: interactive_rx,
                    control: control_rx,
                    bulk: bulk_rx,
                    tunnel: tunnel_rx,
                }),
                terminal: lifecycle.subscribe(),
                lifecycle: lifecycle.clone(),
                physical_by_lane,
                delivered_by_physical: vec![0; physical_count],
                delivered_control_by_physical: vec![0; physical_count],
                disposition: IngressDisposition::Active,
            })),
            lifecycle,
            tasks: StdMutex::new(tasks),
            closed: AtomicBool::new(false),
            close_state,
        })
    }

    fn take_tasks(&self) -> Vec<JoinHandle<()>> {
        let mut tasks = self.tasks.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        std::mem::take(&mut *tasks)
    }
}

#[async_trait]
impl FrameLink for LaneMuxLink {
    fn description(&self) -> &str {
        &self.description
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.maximum
    }

    fn terminal_control_drain_active(&self) -> bool {
        self.lifecycle.terminal_control_drain_active()
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        if let Some(error) = self.lifecycle.error() {
            return Err(error);
        }
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::Closed);
        }
        if frame.len() > self.maximum {
            return Err(LinkError::FrameTooLarge { actual: frame.len(), maximum: self.maximum });
        }
        let decoded =
            WireFrame::decode(&frame).map_err(|error| LinkError::Protocol(error.to_string()))?;
        // Construction checks that every lane has a route.
        let route = self.routes.get(&decoded.lane).ok_or_else(|| {
            LinkError::Protocol(format!("lane {} has no physical route", decoded.lane))
        })?;
        let mut terminal = self.lifecycle.subscribe();
        let completion = tokio::select! {
            biased;
            terminal = wait_for_terminal(&mut terminal) => return Err(terminal.error),
            result = route.enqueue(frame) => match result {
                Ok(completion) => completion,
                Err(error) => return Err(self.lifecycle.error().unwrap_or(error)),
            },
        };
        tokio::select! {
            biased;
            terminal = wait_for_terminal(&mut terminal) => Err(terminal.error),
            result = completion => match result {
                Ok(result) => result,
                Err(_) => Err(self.lifecycle.error().unwrap_or(LinkError::Closed)),
            },
        }
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        self.incoming.lock().await.receive().await
    }

    async fn close(&self) -> Result<(), LinkError> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return wait_for_link_close(self.close_state.subscribe()).await;
        }
        self.lifecycle.terminate(LinkError::Closed);
        let tasks = self.take_tasks();
        let incoming = self.incoming.clone();
        let links = self.links.clone();
        let completion = LinkCloseCompletionGuard::new(self.close_state.clone());
        tokio::spawn(async move {
            let result: Result<(), LinkError> = async {
                for task in &tasks {
                    task.abort();
                }
                let _ = join_all(tasks).await;
                incoming.lock().await.discard();
                for result in join_all(links.iter().map(|link| link.close())).await {
                    result?;
                }
                Ok(())
            }
            .await;
            let outcome = match result {
                Ok(()) => LinkCloseState::Complete,
                Err(error) => LinkCloseState::Failed(error),
            };
            completion.publish(outcome);
        });
        wait_for_link_close(self.close_state.subscribe()).await
    }
}

impl Drop for LaneMuxLink {
    fn drop(&mut self) {
        self.lifecycle.terminate(LinkError::Closed);
        let tasks = self.tasks.get_mut().unwrap_or_else(|poisoned| poisoned.into_inner());
        for task in tasks.drain(..) {
            task.abort();
        }
    }
}
