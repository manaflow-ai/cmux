use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::future::pending;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote_protocol::{Lane, WireFrame};
use futures_util::future::join_all;
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore, mpsc, oneshot};

const INGRESS_BYTES_PER_LANE: usize = 8 * 1_024 * 1_024;
const INGRESS_ACCOUNTING_FLOOR_BYTES: usize = 1_024;
const INGRESS_FRAMES_PER_LANE: usize = INGRESS_BYTES_PER_LANE / INGRESS_ACCOUNTING_FLOOR_BYTES;
const PRIORITY_BURST_FRAMES: usize = 32;
const PRIORITY_LANES: [Lane; 4] = [Lane::Interactive, Lane::Control, Lane::Tunnel, Lane::Bulk];
const OUTBOUND_FRAMES_PER_LANE: usize = PRIORITY_BURST_FRAMES * PRIORITY_LANES.len();

/// An ordered binary-message link supplied by a direct transport or relay.
///
/// Authentication, encryption, replay, and service multiplexing live above
/// this boundary. Implementations must cap incoming frames before allocating.
#[async_trait]
pub trait FrameLink: Send + Sync {
    fn description(&self) -> &str;
    fn maximum_frame_bytes(&self) -> usize;
    async fn send(&self, frame: Bytes) -> Result<(), LinkError>;
    async fn receive(&self) -> Result<Option<Bytes>, LinkError>;
    async fn close(&self) -> Result<(), LinkError>;
}

#[derive(Debug)]
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

struct IngressFrame {
    encoded: Bytes,
    _permit: OwnedSemaphorePermit,
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

    async fn send(&self, encoded: Bytes) -> Result<(), ()> {
        let accounted = encoded.len().max(INGRESS_ACCOUNTING_FLOOR_BYTES);
        let permits = u32::try_from(accounted).expect("wire frames fit the ingress byte budget");
        let permit = self.budget.clone().acquire_many_owned(permits).await.map_err(|_| ())?;
        self.frames.send(IngressFrame { encoded, _permit: permit }).await.map_err(|_| ())
    }
}

struct Ingress {
    frames: PriorityReceivers<IngressFrame>,
    errors: mpsc::UnboundedReceiver<LinkError>,
}

impl Ingress {
    async fn receive(&mut self) -> Result<Option<Bytes>, LinkError> {
        if let Ok(error) = self.errors.try_recv() {
            return Err(error);
        }
        tokio::select! {
            biased;
            error = self.errors.recv() => match error {
                Some(error) => Err(error),
                None => Ok(self.frames.receive().await.map(|frame| frame.encoded)),
            },
            frame = self.frames.receive() => {
                Ok(frame.map(|frame| frame.encoded))
            }
        }
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
    receivers: [Option<mpsc::Receiver<T>>; 4],
    priority_deliveries: usize,
    fair_cursor: usize,
}

impl<T> PriorityReceivers<T> {
    fn new(receivers: [mpsc::Receiver<T>; 4]) -> Self {
        Self { receivers: receivers.map(Some), priority_deliveries: 0, fair_cursor: 0 }
    }

    fn try_receive(&mut self) -> Option<T> {
        if self.priority_deliveries < PRIORITY_BURST_FRAMES {
            for lane in PRIORITY_LANES {
                if let Some(item) = self.try_receive_lane(lane) {
                    self.priority_deliveries += 1;
                    return Some(item);
                }
            }
            return None;
        }

        for offset in 0..PRIORITY_LANES.len() {
            let index = (self.fair_cursor + offset) % PRIORITY_LANES.len();
            if let Some(item) = self.try_receive_lane(PRIORITY_LANES[index]) {
                self.fair_cursor = (index + 1) % PRIORITY_LANES.len();
                self.priority_deliveries = 0;
                return Some(item);
            }
        }
        None
    }

    fn try_receive_lane(&mut self, lane: Lane) -> Option<T> {
        let index = lane_index(lane);
        match self.receivers[index].as_mut()?.try_recv() {
            Ok(item) => Some(item),
            Err(mpsc::error::TryRecvError::Empty) => None,
            Err(mpsc::error::TryRecvError::Disconnected) => {
                self.receivers[index] = None;
                None
            }
        }
    }

    async fn receive(&mut self) -> Option<T> {
        loop {
            if let Some(item) = self.try_receive() {
                return Some(item);
            }
            if self.receivers.iter().all(Option::is_none) {
                return None;
            }

            let fair_selection = self.priority_deliveries >= PRIORITY_BURST_FRAMES;
            let (lane, item) = {
                let [interactive, control, bulk, tunnel] = &mut self.receivers;
                tokio::select! {
                    biased;
                    item = receive_or_pending(interactive) => (Lane::Interactive, item),
                    item = receive_or_pending(control) => (Lane::Control, item),
                    item = receive_or_pending(tunnel) => (Lane::Tunnel, item),
                    item = receive_or_pending(bulk) => (Lane::Bulk, item),
                }
            };
            let Some(item) = item else {
                self.receivers[lane_index(lane)] = None;
                continue;
            };
            if fair_selection {
                let index = PRIORITY_LANES.iter().position(|candidate| *candidate == lane).unwrap();
                self.fair_cursor = (index + 1) % PRIORITY_LANES.len();
                self.priority_deliveries = 0;
            } else {
                self.priority_deliveries += 1;
            }
            return Some(item);
        }
    }
}

async fn receive_or_pending<T>(receiver: &mut Option<mpsc::Receiver<T>>) -> Option<T> {
    match receiver {
        Some(receiver) => receiver.recv().await,
        None => pending().await,
    }
}

const fn lane_index(lane: Lane) -> usize {
    match lane {
        Lane::Interactive => 0,
        Lane::Control => 1,
        Lane::Bulk => 2,
        Lane::Tunnel => 3,
    }
}

fn spawn_outbound_dispatcher(
    link: Arc<dyn FrameLink>,
    lanes: &BTreeSet<Lane>,
) -> BTreeMap<Lane, OutboundSender> {
    let (interactive_tx, interactive_rx) = mpsc::channel(OUTBOUND_FRAMES_PER_LANE);
    let (control_tx, control_rx) = mpsc::channel(OUTBOUND_FRAMES_PER_LANE);
    let (bulk_tx, bulk_rx) = mpsc::channel(OUTBOUND_FRAMES_PER_LANE);
    let (tunnel_tx, tunnel_rx) = mpsc::channel(OUTBOUND_FRAMES_PER_LANE);
    let senders = [interactive_tx, control_tx, bulk_tx, tunnel_tx];
    let routes = lanes
        .iter()
        .map(|lane| (*lane, OutboundSender { frames: senders[lane_index(*lane)].clone() }))
        .collect();
    drop(senders);
    tokio::spawn(async move {
        let mut frames = PriorityReceivers::new([interactive_rx, control_rx, bulk_rx, tunnel_rx]);
        while let Some(frame) = frames.receive().await {
            let result = link.send(frame.encoded).await;
            let failed = result.is_err();
            let _ = frame.completion.send(result);
            if failed {
                break;
            }
        }
    });
    routes
}

/// Presents several independently authenticated physical links as one frame
/// link. Outbound frames are routed by their encoded lane; dedicated reader
/// tasks avoid cancellation-corrupting a length-delimited stream.
pub struct LaneMuxLink {
    description: String,
    maximum: usize,
    routes: BTreeMap<Lane, OutboundSender>,
    links: Vec<Arc<dyn FrameLink>>,
    incoming: Mutex<Ingress>,
    closed: AtomicBool,
    #[cfg(test)]
    outbound_admitted: Arc<Semaphore>,
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

        let maximum =
            physical_routes.iter().map(|route| route.link.maximum_frame_bytes()).min().unwrap();
        let links = physical_routes.iter().map(|route| route.link.clone()).collect::<Vec<_>>();
        let mut routes = BTreeMap::new();
        let (interactive_tx, interactive_rx) = IngressSender::channel();
        let (control_tx, control_rx) = IngressSender::channel();
        let (bulk_tx, bulk_rx) = IngressSender::channel();
        let (tunnel_tx, tunnel_rx) = IngressSender::channel();
        let ingress_senders = [interactive_tx, control_tx, bulk_tx, tunnel_tx];
        let (errors_tx, errors) = mpsc::unbounded_channel();
        for route in physical_routes {
            let allowed = route.lanes;
            let link = route.link;
            routes.extend(spawn_outbound_dispatcher(link.clone(), &allowed));
            let lane_senders = allowed
                .iter()
                .map(|lane| (*lane, ingress_senders[lane_index(*lane)].clone()))
                .collect::<BTreeMap<_, _>>();
            let errors_tx = errors_tx.clone();
            tokio::spawn(async move {
                loop {
                    match link.receive().await {
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
                                    if lane_senders
                                        .get(&lane)
                                        .expect("allowed lanes have ingress queues")
                                        .send(encoded)
                                        .await
                                        .is_err()
                                    {
                                        break;
                                    }
                                }
                                Err(error) => {
                                    let _ = errors_tx.send(error);
                                    break;
                                }
                            }
                        }
                        Ok(None) => {
                            let _ = errors_tx.send(LinkError::Closed);
                            break;
                        }
                        Err(error) => {
                            let _ = errors_tx.send(error);
                            break;
                        }
                    }
                }
            });
        }
        drop(errors_tx);
        drop(ingress_senders);
        Ok(Self {
            description: description.into(),
            maximum,
            routes,
            links,
            incoming: Mutex::new(Ingress {
                frames: PriorityReceivers::new([interactive_rx, control_rx, bulk_rx, tunnel_rx]),
                errors,
            }),
            closed: AtomicBool::new(false),
            #[cfg(test)]
            outbound_admitted: Arc::new(Semaphore::new(0)),
        })
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

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        if self.closed.load(Ordering::Acquire) {
            return Err(LinkError::Closed);
        }
        if frame.len() > self.maximum {
            return Err(LinkError::FrameTooLarge { actual: frame.len(), maximum: self.maximum });
        }
        let decoded =
            WireFrame::decode(&frame).map_err(|error| LinkError::Protocol(error.to_string()))?;
        let route = self.routes.get(&decoded.lane).expect("all lanes checked at construction");
        let completion = route.enqueue(frame).await?;
        #[cfg(test)]
        self.outbound_admitted.add_permits(1);
        completion.await.map_err(|_| LinkError::Closed)?
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        self.incoming.lock().await.receive().await
    }

    async fn close(&self) -> Result<(), LinkError> {
        if self.closed.swap(true, Ordering::AcqRel) {
            return Ok(());
        }
        let results = join_all(self.links.iter().map(|link| link.close())).await;
        for result in results {
            result?;
        }
        Ok(())
    }
}

#[cfg(test)]
pub mod test_support {
    use tokio::sync::mpsc;

    use super::*;

    pub struct MemoryLink {
        description: String,
        maximum: usize,
        incoming: Mutex<mpsc::Receiver<Bytes>>,
        outgoing: Mutex<Option<mpsc::Sender<Bytes>>>,
    }

    pub fn pair(maximum: usize) -> (MemoryLink, MemoryLink) {
        let (left_tx, left_rx) = mpsc::channel(16);
        let (right_tx, right_rx) = mpsc::channel(16);
        (
            MemoryLink {
                description: "memory:left".into(),
                maximum,
                incoming: Mutex::new(left_rx),
                outgoing: Mutex::new(Some(right_tx)),
            },
            MemoryLink {
                description: "memory:right".into(),
                maximum,
                incoming: Mutex::new(right_rx),
                outgoing: Mutex::new(Some(left_tx)),
            },
        )
    }

    #[async_trait]
    impl FrameLink for MemoryLink {
        fn description(&self) -> &str {
            &self.description
        }

        fn maximum_frame_bytes(&self) -> usize {
            self.maximum
        }

        async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
            if frame.len() > self.maximum {
                return Err(LinkError::FrameTooLarge {
                    actual: frame.len(),
                    maximum: self.maximum,
                });
            }
            self.outgoing
                .lock()
                .await
                .as_ref()
                .ok_or(LinkError::Closed)?
                .send(frame)
                .await
                .map_err(|_| LinkError::Closed)
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            Ok(self.incoming.lock().await.recv().await)
        }

        async fn close(&self) -> Result<(), LinkError> {
            self.outgoing.lock().await.take();
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use cmux_remote_protocol::{FrameFlags, SessionId};
    use tokio::sync::Semaphore;

    use super::*;
    use crate::link::test_support::pair;

    struct ControlledReceiveLink {
        description: String,
        maximum: usize,
        incoming: Mutex<mpsc::UnboundedReceiver<Bytes>>,
        receive_calls: Arc<Semaphore>,
    }

    struct ControlledReceiveHandle {
        incoming: mpsc::UnboundedSender<Bytes>,
        receive_calls: Arc<Semaphore>,
    }

    struct SerializedSendLink {
        writer: Mutex<()>,
        started: Arc<Semaphore>,
        release: Arc<Semaphore>,
        order: Arc<Mutex<Vec<(Lane, u64)>>>,
    }

    struct SerializedSendHandle {
        started: Arc<Semaphore>,
        release: Arc<Semaphore>,
        order: Arc<Mutex<Vec<(Lane, u64)>>>,
    }

    struct FailingSendLink {
        error: &'static str,
    }

    struct DropTrackedLink {
        receive_calls: Arc<Semaphore>,
        dropped: Arc<Semaphore>,
    }

    fn controlled_receive_link(
        description: &str,
        maximum: usize,
    ) -> (ControlledReceiveLink, ControlledReceiveHandle) {
        let (incoming, receiver) = mpsc::unbounded_channel();
        let receive_calls = Arc::new(Semaphore::new(0));
        (
            ControlledReceiveLink {
                description: description.into(),
                maximum,
                incoming: Mutex::new(receiver),
                receive_calls: receive_calls.clone(),
            },
            ControlledReceiveHandle { incoming, receive_calls },
        )
    }

    fn serialized_send_link() -> (SerializedSendLink, SerializedSendHandle) {
        let started = Arc::new(Semaphore::new(0));
        let release = Arc::new(Semaphore::new(0));
        let order = Arc::new(Mutex::new(Vec::new()));
        (
            SerializedSendLink {
                writer: Mutex::new(()),
                started: started.clone(),
                release: release.clone(),
                order: order.clone(),
            },
            SerializedSendHandle { started, release, order },
        )
    }

    #[async_trait]
    impl FrameLink for ControlledReceiveLink {
        fn description(&self) -> &str {
            &self.description
        }

        fn maximum_frame_bytes(&self) -> usize {
            self.maximum
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            Ok(())
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            self.receive_calls.add_permits(1);
            Ok(self.incoming.lock().await.recv().await)
        }

        async fn close(&self) -> Result<(), LinkError> {
            Ok(())
        }
    }

    #[async_trait]
    impl FrameLink for SerializedSendLink {
        fn description(&self) -> &str {
            "serialized-send"
        }

        fn maximum_frame_bytes(&self) -> usize {
            65_535
        }

        async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
            let _writer = self.writer.lock().await;
            let frame = WireFrame::decode(&frame)
                .map_err(|error| LinkError::Protocol(error.to_string()))?;
            self.order.lock().await.push((frame.lane, frame.sequence));
            self.started.add_permits(1);
            let permit = self.release.acquire().await.map_err(|_| LinkError::Closed)?;
            permit.forget();
            Ok(())
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            pending().await
        }

        async fn close(&self) -> Result<(), LinkError> {
            Ok(())
        }
    }

    #[async_trait]
    impl FrameLink for FailingSendLink {
        fn description(&self) -> &str {
            "failing-send"
        }

        fn maximum_frame_bytes(&self) -> usize {
            65_535
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            Err(LinkError::Transport(self.error.into()))
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            pending().await
        }

        async fn close(&self) -> Result<(), LinkError> {
            Ok(())
        }
    }

    #[async_trait]
    impl FrameLink for DropTrackedLink {
        fn description(&self) -> &str {
            "drop-tracked"
        }

        fn maximum_frame_bytes(&self) -> usize {
            65_535
        }

        async fn send(&self, _frame: Bytes) -> Result<(), LinkError> {
            Ok(())
        }

        async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
            self.receive_calls.add_permits(1);
            pending().await
        }

        async fn close(&self) -> Result<(), LinkError> {
            Ok(())
        }
    }

    impl Drop for DropTrackedLink {
        fn drop(&mut self) {
            self.dropped.add_permits(1);
        }
    }

    fn encoded_frame(lane: Lane, payload_bytes: usize) -> Bytes {
        WireFrame {
            session: SessionId::ZERO,
            generation: 1,
            lane,
            flags: FrameFlags::empty(),
            sequence: 1,
            acknowledgement: 0,
            stream: 1,
            payload: vec![lane as u8; payload_bytes],
        }
        .encode()
        .unwrap()
        .into()
    }

    fn sequenced_frame(lane: Lane, sequence: u64) -> Bytes {
        WireFrame {
            session: SessionId::ZERO,
            generation: 1,
            lane,
            flags: FrameFlags::empty(),
            sequence,
            acknowledgement: 0,
            stream: 1,
            payload: vec![lane as u8],
        }
        .encode()
        .unwrap()
        .into()
    }

    async fn wait_for_receive_calls(calls: &Semaphore, count: u32) {
        let permit = tokio::time::timeout(Duration::from_secs(1), calls.acquire_many(count))
            .await
            .expect("physical reader did not reach the deterministic gate")
            .unwrap();
        permit.forget();
    }

    async fn wait_for_signal(signal: &Semaphore, context: &str) {
        let permit = tokio::time::timeout(Duration::from_secs(1), signal.acquire())
            .await
            .unwrap_or_else(|_| panic!("timed out waiting for {context}"))
            .unwrap();
        permit.forget();
    }

    #[tokio::test]
    async fn one_physical_lane_eof_fails_the_aggregate_link() {
        let (interactive, interactive_peer) = pair(65_535);
        let (rest, _rest_peer) = pair(65_535);
        let mux = LaneMuxLink::new(
            "test-lanes",
            vec![
                LinkRoute { lanes: vec![Lane::Interactive], link: Arc::new(interactive) },
                LinkRoute {
                    lanes: vec![Lane::Control, Lane::Bulk, Lane::Tunnel],
                    link: Arc::new(rest),
                },
            ],
        )
        .unwrap();

        interactive_peer.close().await.unwrap();
        let result = tokio::time::timeout(Duration::from_secs(1), mux.receive()).await.unwrap();
        assert!(matches!(result, Err(LinkError::Closed)));
    }

    #[tokio::test]
    async fn receive_failure_is_sticky_across_physical_routes() {
        let (interactive, interactive_peer) = pair(65_535);
        let (rest, _rest_peer) = pair(65_535);
        let mux = LaneMuxLink::new(
            "test-lanes",
            vec![
                LinkRoute { lanes: vec![Lane::Interactive], link: Arc::new(interactive) },
                LinkRoute {
                    lanes: vec![Lane::Control, Lane::Bulk, Lane::Tunnel],
                    link: Arc::new(rest),
                },
            ],
        )
        .unwrap();

        interactive_peer.close().await.unwrap();
        let first = tokio::time::timeout(Duration::from_secs(1), mux.receive())
            .await
            .expect("aggregate receive did not observe physical EOF");
        assert!(matches!(first, Err(LinkError::Closed)));

        let send =
            tokio::time::timeout(Duration::from_secs(1), mux.send(encoded_frame(Lane::Bulk, 1)))
                .await
                .expect("post-terminal send remained blocked");
        assert!(matches!(send, Err(LinkError::Closed)), "post-terminal send succeeded: {send:?}");

        let repeated = tokio::time::timeout(Duration::from_secs(1), mux.receive())
            .await
            .expect("terminal receive error was not sticky");
        assert!(matches!(repeated, Err(LinkError::Closed)));
    }

    #[tokio::test]
    async fn send_failure_is_sticky_across_physical_routes() {
        let (rest, rest_handle) = serialized_send_link();
        let mux = Arc::new(
            LaneMuxLink::new(
                "test-lanes",
                vec![
                    LinkRoute {
                        lanes: vec![Lane::Interactive],
                        link: Arc::new(FailingSendLink { error: "writer failed" }),
                    },
                    LinkRoute {
                        lanes: vec![Lane::Control, Lane::Bulk, Lane::Tunnel],
                        link: Arc::new(rest),
                    },
                ],
            )
            .unwrap(),
        );

        let bulk_mux = mux.clone();
        let blocked_send =
            tokio::spawn(async move { bulk_mux.send(encoded_frame(Lane::Bulk, 1)).await });
        wait_for_signal(&rest_handle.started, "blocked cross-route send").await;

        let first = mux.send(encoded_frame(Lane::Interactive, 1)).await;
        assert!(
            matches!(first, Err(LinkError::Transport(ref message)) if message == "writer failed")
        );

        let send = tokio::time::timeout(Duration::from_secs(1), blocked_send)
            .await
            .expect("cross-route send remained blocked after terminal failure")
            .unwrap();
        assert!(
            matches!(send, Err(LinkError::Transport(ref message)) if message == "writer failed"),
            "cross-route send did not preserve the first failure: {send:?}",
        );

        let receive = tokio::time::timeout(Duration::from_secs(1), mux.receive())
            .await
            .expect("aggregate receive did not observe outbound failure");
        assert!(
            matches!(receive, Err(LinkError::Transport(ref message)) if message == "writer failed"),
            "aggregate receive did not preserve the first failure: {receive:?}",
        );
    }

    #[tokio::test]
    async fn close_cancels_blocked_send_and_receive() {
        let (physical, physical_handle) = serialized_send_link();
        let mux = Arc::new(
            LaneMuxLink::new(
                "single-physical",
                vec![LinkRoute { lanes: Lane::ALL.to_vec(), link: Arc::new(physical) }],
            )
            .unwrap(),
        );

        let send_mux = mux.clone();
        let blocked_send =
            tokio::spawn(async move { send_mux.send(encoded_frame(Lane::Bulk, 1)).await });
        wait_for_signal(&physical_handle.started, "blocked physical send").await;
        let receive_mux = mux.clone();
        let blocked_receive = tokio::spawn(async move { receive_mux.receive().await });
        tokio::task::yield_now().await;

        tokio::time::timeout(Duration::from_secs(1), mux.close())
            .await
            .expect("aggregate close remained blocked")
            .unwrap();
        let send = tokio::time::timeout(Duration::from_secs(1), blocked_send)
            .await
            .expect("close did not wake blocked send")
            .unwrap();
        let receive = tokio::time::timeout(Duration::from_secs(1), blocked_receive)
            .await
            .expect("close did not wake blocked receive")
            .unwrap();
        assert!(matches!(send, Err(LinkError::Closed)));
        assert!(matches!(receive, Err(LinkError::Closed)));
    }

    #[tokio::test]
    async fn drop_cancels_pending_physical_reader() {
        let receive_calls = Arc::new(Semaphore::new(0));
        let dropped = Arc::new(Semaphore::new(0));
        let physical = Arc::new(DropTrackedLink {
            receive_calls: receive_calls.clone(),
            dropped: dropped.clone(),
        });
        let mux = LaneMuxLink::new(
            "single-physical",
            vec![LinkRoute { lanes: Lane::ALL.to_vec(), link: physical.clone() }],
        )
        .unwrap();
        drop(physical);
        wait_for_receive_calls(&receive_calls, 1).await;

        drop(mux);
        wait_for_signal(&dropped, "physical link drop after aggregate drop").await;
    }

    #[tokio::test]
    async fn close_cancels_reader_blocked_on_saturated_ingress() {
        const BUFFERED_FRAMES: u32 = 1_025;
        const FRAME_BYTES: usize = 8 * 1_024;
        const WIRE_HEADER_BYTES: usize = 60;

        let (bulk, bulk_handle) = controlled_receive_link("bulk", FRAME_BYTES);
        let physical = Arc::new(bulk);
        let bulk_frame = encoded_frame(Lane::Bulk, FRAME_BYTES - WIRE_HEADER_BYTES);
        for _ in 0..BUFFERED_FRAMES {
            bulk_handle.incoming.send(bulk_frame.clone()).unwrap();
        }
        let mux = LaneMuxLink::new(
            "single-physical",
            vec![LinkRoute { lanes: Lane::ALL.to_vec(), link: physical.clone() }],
        )
        .unwrap();
        wait_for_receive_calls(&bulk_handle.receive_calls, BUFFERED_FRAMES).await;
        assert_eq!(Arc::strong_count(&physical), 4, "test did not reach blocked ingress state");

        tokio::time::timeout(Duration::from_secs(1), mux.close())
            .await
            .expect("aggregate close remained blocked behind saturated ingress")
            .unwrap();
        assert_eq!(Arc::strong_count(&physical), 2, "close retained reader or dispatcher tasks",);
        let receive = tokio::time::timeout(Duration::from_secs(1), mux.receive())
            .await
            .expect("close did not bypass saturated ingress");
        assert!(matches!(receive, Err(LinkError::Closed)));
    }

    #[tokio::test]
    async fn oversized_ingress_frame_is_rejected_without_waiting() {
        let (sender, _receiver) = IngressSender::channel();
        let oversized = Bytes::from(vec![0; INGRESS_BYTES_PER_LANE + 1]);
        let result = tokio::time::timeout(Duration::from_secs(1), sender.send(oversized))
            .await
            .expect("oversized ingress waited forever for an impossible semaphore permit");
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn dedicated_interactive_reader_bypasses_saturated_bulk_ingress() {
        const BUFFERED_FRAMES: u32 = 1_024;
        const FRAME_BYTES: usize = 8 * 1_024;
        const WIRE_HEADER_BYTES: usize = 60;

        let (interactive, interactive_handle) = controlled_receive_link("interactive", FRAME_BYTES);
        let (bulk, bulk_handle) = controlled_receive_link("bulk", FRAME_BYTES);
        let bulk_frame = encoded_frame(Lane::Bulk, FRAME_BYTES - WIRE_HEADER_BYTES);
        assert_eq!(bulk_frame.len(), FRAME_BYTES);
        for _ in 0..BUFFERED_FRAMES {
            bulk_handle.incoming.send(bulk_frame.clone()).unwrap();
        }

        let mux = LaneMuxLink::new(
            "test-lanes",
            vec![
                LinkRoute { lanes: vec![Lane::Interactive], link: Arc::new(interactive) },
                LinkRoute {
                    lanes: vec![Lane::Control, Lane::Bulk, Lane::Tunnel],
                    link: Arc::new(bulk),
                },
            ],
        )
        .unwrap();

        wait_for_receive_calls(&bulk_handle.receive_calls, BUFFERED_FRAMES + 1).await;
        wait_for_receive_calls(&interactive_handle.receive_calls, 1).await;
        interactive_handle.incoming.send(encoded_frame(Lane::Interactive, 1)).unwrap();

        wait_for_receive_calls(&interactive_handle.receive_calls, 1).await;
        let received = tokio::time::timeout(Duration::from_secs(1), mux.receive())
            .await
            .expect("interactive delivery remained blocked behind bulk ingress")
            .unwrap()
            .unwrap();
        assert_eq!(WireFrame::decode(&received).unwrap().lane, Lane::Interactive);
    }

    #[tokio::test]
    async fn aggregate_error_bypasses_saturated_ingress() {
        const BUFFERED_FRAMES: usize = 1_024;
        const FRAME_BYTES: usize = 8 * 1_024;
        const WIRE_HEADER_BYTES: usize = 60;

        let (_interactive_tx, interactive_rx) = IngressSender::channel();
        let (_control_tx, control_rx) = IngressSender::channel();
        let (bulk_tx, bulk_rx) = IngressSender::channel();
        let (_tunnel_tx, tunnel_rx) = IngressSender::channel();
        let (errors_tx, errors) = mpsc::unbounded_channel();
        let mut ingress = Ingress {
            frames: PriorityReceivers::new([interactive_rx, control_rx, bulk_rx, tunnel_rx]),
            errors,
        };
        let bulk_frame = encoded_frame(Lane::Bulk, FRAME_BYTES - WIRE_HEADER_BYTES);
        for _ in 0..BUFFERED_FRAMES {
            bulk_tx.send(bulk_frame.clone()).await.unwrap();
        }
        errors_tx.send(LinkError::Closed).unwrap();

        let result = tokio::time::timeout(Duration::from_secs(1), ingress.receive()).await.unwrap();
        assert!(matches!(result, Err(LinkError::Closed)));
    }

    #[tokio::test]
    async fn bounded_priority_bursts_do_not_starve_bulk_ingress() {
        let (interactive_tx, interactive_rx) = mpsc::channel(128);
        let (control_tx, control_rx) = mpsc::channel(128);
        let (bulk_tx, bulk_rx) = mpsc::channel(128);
        let (tunnel_tx, tunnel_rx) = mpsc::channel(128);
        for sequence in 0..100 {
            interactive_tx.send((Lane::Interactive, sequence)).await.unwrap();
        }
        bulk_tx.send((Lane::Bulk, 0)).await.unwrap();
        drop((interactive_tx, control_tx, bulk_tx, tunnel_tx));
        let mut receivers =
            PriorityReceivers::new([interactive_rx, control_rx, bulk_rx, tunnel_rx]);

        assert_eq!(receivers.receive().await.unwrap().0, Lane::Interactive);
        let mut bulk_delivery = None;
        for delivery in 2..=2 * (PRIORITY_BURST_FRAMES + 1) {
            if receivers.receive().await.unwrap().0 == Lane::Bulk {
                bulk_delivery = Some(delivery);
                break;
            }
        }
        assert!(bulk_delivery.is_some(), "bulk was starved by interactive ingress");
    }

    #[tokio::test]
    async fn shared_physical_writer_prioritizes_later_interactive_sends_without_starvation() {
        const INTERACTIVE_FRAMES: u64 = 100;

        let (physical, physical_handle) = serialized_send_link();
        let mux = Arc::new(
            LaneMuxLink::new(
                "single-physical",
                vec![LinkRoute { lanes: Lane::ALL.to_vec(), link: Arc::new(physical) }],
            )
            .unwrap(),
        );
        let admitted = mux.outbound_admitted.clone();
        let mut frames = vec![sequenced_frame(Lane::Bulk, 1), sequenced_frame(Lane::Bulk, 2)];
        frames.push(sequenced_frame(Lane::Tunnel, 1));
        frames.extend(
            (1..=INTERACTIVE_FRAMES).map(|sequence| sequenced_frame(Lane::Interactive, sequence)),
        );
        let total_frames = frames.len();
        let mut sends = Vec::with_capacity(total_frames);

        let first = frames.remove(0);
        let first_mux = mux.clone();
        sends.push(tokio::spawn(async move { first_mux.send(first).await }));
        wait_for_signal(&admitted, "first Bulk admission").await;
        wait_for_signal(&physical_handle.started, "first physical send").await;

        for frame in frames {
            let mux = mux.clone();
            sends.push(tokio::spawn(async move { mux.send(frame).await }));
            wait_for_signal(&admitted, "queued lane admission").await;
        }

        for _ in 1..total_frames {
            physical_handle.release.add_permits(1);
            wait_for_signal(&physical_handle.started, "next physical send").await;
        }
        physical_handle.release.add_permits(1);
        let results = tokio::time::timeout(Duration::from_secs(1), join_all(sends))
            .await
            .expect("serialized sends did not finish");
        assert!(results.into_iter().all(|result| result.unwrap().is_ok()));

        let order = physical_handle.order.lock().await.clone();
        assert_eq!(order.len(), total_frames);
        assert_eq!(order[0], (Lane::Bulk, 1));
        assert_eq!(order[1].0, Lane::Interactive, "later Interactive send lost priority");
        assert_eq!(
            order
                .iter()
                .filter_map(|(lane, sequence)| (*lane == Lane::Bulk).then_some(*sequence))
                .collect::<Vec<_>>(),
            vec![1, 2],
            "Bulk FIFO changed",
        );
        assert_eq!(
            order
                .iter()
                .filter_map(|(lane, sequence)| (*lane == Lane::Interactive).then_some(*sequence))
                .collect::<Vec<_>>(),
            (1..=INTERACTIVE_FRAMES).collect::<Vec<_>>(),
            "Interactive FIFO changed",
        );
        let second_bulk = order
            .iter()
            .position(|frame| *frame == (Lane::Bulk, 2))
            .expect("queued Bulk send was starved");
        assert!(
            second_bulk <= 3 * (PRIORITY_BURST_FRAMES + 1),
            "queued Bulk send exceeded the bounded priority window: {second_bulk}",
        );
    }

    #[tokio::test]
    async fn distinct_physical_writers_send_in_parallel() {
        let (interactive, interactive_handle) = serialized_send_link();
        let (bulk, bulk_handle) = serialized_send_link();
        let mux = Arc::new(
            LaneMuxLink::new(
                "isolated-physical",
                vec![
                    LinkRoute { lanes: vec![Lane::Interactive], link: Arc::new(interactive) },
                    LinkRoute {
                        lanes: vec![Lane::Control, Lane::Bulk, Lane::Tunnel],
                        link: Arc::new(bulk),
                    },
                ],
            )
            .unwrap(),
        );
        let admitted = mux.outbound_admitted.clone();

        let bulk_mux = mux.clone();
        let bulk_send =
            tokio::spawn(async move { bulk_mux.send(sequenced_frame(Lane::Bulk, 1)).await });
        wait_for_signal(&admitted, "Bulk admission").await;
        wait_for_signal(&bulk_handle.started, "Bulk physical send").await;

        let interactive_mux = mux.clone();
        let interactive_send = tokio::spawn(async move {
            interactive_mux.send(sequenced_frame(Lane::Interactive, 1)).await
        });
        wait_for_signal(&admitted, "Interactive admission").await;
        wait_for_signal(&interactive_handle.started, "parallel Interactive physical send").await;

        bulk_handle.release.add_permits(1);
        interactive_handle.release.add_permits(1);
        let (bulk_result, interactive_result) =
            tokio::time::timeout(Duration::from_secs(1), async {
                tokio::join!(bulk_send, interactive_send)
            })
            .await
            .expect("parallel physical sends did not finish");
        bulk_result.unwrap().unwrap();
        interactive_result.unwrap().unwrap();
    }
}
