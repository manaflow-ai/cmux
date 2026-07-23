use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote_protocol::{Lane, WireFrame};
use futures_util::future::join_all;
use tokio::sync::{Mutex, mpsc};

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

/// Presents several independently authenticated physical links as one frame
/// link. Outbound frames are routed by their encoded lane; dedicated reader
/// tasks avoid cancellation-corrupting a length-delimited stream.
pub struct LaneMuxLink {
    description: String,
    maximum: usize,
    routes: BTreeMap<Lane, Arc<dyn FrameLink>>,
    links: Vec<Arc<dyn FrameLink>>,
    incoming: Mutex<mpsc::Receiver<Result<Bytes, LinkError>>>,
    closed: AtomicBool,
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
        let mut routes = BTreeMap::new();
        let mut links = Vec::with_capacity(physical.len());
        let (incoming_tx, incoming) = mpsc::channel(1_024);
        for route in physical {
            if route.lanes.is_empty() {
                return Err(LinkError::Protocol("physical link has no assigned lanes".into()));
            }
            let allowed = route.lanes.iter().copied().collect::<BTreeSet<_>>();
            for lane in &allowed {
                if routes.insert(*lane, route.link.clone()).is_some() {
                    return Err(LinkError::Protocol(format!("lane {lane} is assigned twice")));
                }
            }
            let link = route.link;
            links.push(link.clone());
            let incoming_tx = incoming_tx.clone();
            tokio::spawn(async move {
                loop {
                    match link.receive().await {
                        Ok(Some(encoded)) => {
                            let validity = WireFrame::decode(&encoded)
                                .map_err(|error| LinkError::Protocol(error.to_string()))
                                .and_then(|frame| {
                                    if allowed.contains(&frame.lane) {
                                        Ok(encoded)
                                    } else {
                                        Err(LinkError::Protocol(format!(
                                            "lane {} arrived on the wrong physical link",
                                            frame.lane
                                        )))
                                    }
                                });
                            let failed = validity.is_err();
                            if incoming_tx.send(validity).await.is_err() || failed {
                                break;
                            }
                        }
                        Ok(None) => {
                            let _ = incoming_tx.send(Err(LinkError::Closed)).await;
                            break;
                        }
                        Err(error) => {
                            let _ = incoming_tx.send(Err(error)).await;
                            break;
                        }
                    }
                }
            });
        }
        drop(incoming_tx);
        for lane in Lane::ALL {
            if !routes.contains_key(&lane) {
                return Err(LinkError::Protocol(format!("lane {lane} has no physical link")));
            }
        }
        let maximum = links.iter().map(|link| link.maximum_frame_bytes()).min().unwrap();
        Ok(Self {
            description: description.into(),
            maximum,
            routes,
            links,
            incoming: Mutex::new(incoming),
            closed: AtomicBool::new(false),
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
        self.routes.get(&decoded.lane).expect("all lanes checked at construction").send(frame).await
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        match self.incoming.lock().await.recv().await {
            Some(result) => result.map(Some),
            None => Ok(None),
        }
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

    async fn wait_for_receive_calls(calls: &Semaphore, count: u32) {
        let permit = tokio::time::timeout(Duration::from_secs(1), calls.acquire_many(count))
            .await
            .expect("physical reader did not reach the deterministic gate")
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
}
