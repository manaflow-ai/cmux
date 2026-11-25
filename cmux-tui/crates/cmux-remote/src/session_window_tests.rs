//! The per-lane delivery window over a link with a simulated round trip.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote_protocol::{FrameFlags, Lane, MAX_FRAME_PAYLOAD, MAX_WIRE_FRAME_BYTES, SessionId};
use tokio::sync::{Mutex, mpsc};
use tokio::time::Instant;

use super::{ReliableSession, SessionLimits};
use crate::link::{FrameLink, LinkError};

const MIB: usize = 1024 * 1024;
const ONE_WAY: Duration = Duration::from_millis(50);

/// One direction of an ordered link that delivers each frame `delay` after it
/// was sent, with no bandwidth limit: throughput over it is bounded only by
/// how much the sender keeps in flight per round trip.
struct DelayedLink {
    delay: Duration,
    outgoing: mpsc::UnboundedSender<(Instant, Bytes)>,
    incoming: Mutex<mpsc::UnboundedReceiver<(Instant, Bytes)>>,
}

fn delayed_pair(delay: Duration) -> (Arc<DelayedLink>, Arc<DelayedLink>) {
    let (left_tx, left_rx) = mpsc::unbounded_channel();
    let (right_tx, right_rx) = mpsc::unbounded_channel();
    (
        Arc::new(DelayedLink { delay, outgoing: left_tx, incoming: Mutex::new(right_rx) }),
        Arc::new(DelayedLink { delay, outgoing: right_tx, incoming: Mutex::new(left_rx) }),
    )
}

#[async_trait]
impl FrameLink for DelayedLink {
    fn description(&self) -> &str {
        "delayed test link"
    }

    fn maximum_frame_bytes(&self) -> usize {
        MAX_WIRE_FRAME_BYTES
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        self.outgoing.send((Instant::now() + self.delay, frame)).map_err(|_| LinkError::Closed)
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let Some((due, frame)) = self.incoming.lock().await.recv().await else {
            return Ok(None);
        };
        tokio::time::sleep_until(due).await;
        Ok(Some(frame))
    }

    async fn close(&self) -> Result<(), LinkError> {
        Ok(())
    }
}

fn sessions(limits: SessionLimits) -> (ReliableSession, ReliableSession) {
    let (left, right) = delayed_pair(ONE_WAY);
    let id = SessionId([7; 16]);
    (ReliableSession::new(id, left, limits), ReliableSession::new(id, right, limits))
}

/// Sends `total` bytes as full frames on the Bulk lane while the peer reads
/// them, and returns the payload rate in MiB/s of (paused, simulated) time.
async fn bulk_rate(limits: SessionLimits, total: usize) -> f64 {
    let (sender, receiver) = sessions(limits);
    let frames = total / MAX_FRAME_PAYLOAD;
    let reader = tokio::spawn(async move {
        let mut received = 0;
        while received < frames {
            let frame = receiver.receive().await.expect("receive").expect("frame");
            assert_eq!(frame.lane, Lane::Bulk);
            received += 1;
        }
        Instant::now()
    });
    // The sender applies the peer's acknowledgements as it receives them.
    let acknowledgements = {
        let sender = sender.clone();
        tokio::spawn(async move { while let Ok(Some(_)) = sender.receive().await {} })
    };
    let started = Instant::now();
    let payload = Bytes::from(vec![0x5a; MAX_FRAME_PAYLOAD]);
    for _ in 0..frames {
        sender
            .send_with_backpressure(Lane::Bulk, 1, payload.clone(), FrameFlags::empty())
            .await
            .expect("send");
    }
    let finished = reader.await.expect("reader");
    acknowledgements.abort();
    let seconds = finished.duration_since(started).as_secs_f64();
    (frames * MAX_FRAME_PAYLOAD) as f64 / MIB as f64 / seconds
}

#[test]
fn default_window_covers_the_bandwidth_delay_product_at_100ms() {
    let limits = SessionLimits::default();
    // `cmux remote cp` moves file data as base64, 3 bytes per 4 on the wire.
    let data_per_round_trip = limits.delivery_bytes_per_lane * 3 / 4;
    let rtt = 2 * ONE_WAY;
    let rate = data_per_round_trip as f64 / MIB as f64 / rtt.as_secs_f64();
    assert!(rate >= 15.0, "default window allows only {rate:.1} MiB/s at 100 ms RTT");
    // Full frames reach the byte bound before the frame bound.
    assert!(
        limits.delivery_frames_per_lane * MAX_WIRE_FRAME_BYTES >= limits.delivery_bytes_per_lane
    );
    // The window never outgrows the replay that retains its frames.
    assert!(limits.delivery_bytes_per_lane <= limits.replay_bytes_per_lane);
    assert!(limits.delivery_frames_per_lane <= limits.replay_frames_per_lane);
}

#[tokio::test(start_paused = true)]
async fn bulk_lane_fills_a_100ms_round_trip() {
    let rate = bulk_rate(SessionLimits::default(), 32 * MIB).await;
    assert!(rate >= 20.0, "bulk lane moved {rate:.1} MiB/s over a 100 ms round trip");
}

#[tokio::test(start_paused = true)]
async fn a_small_window_caps_the_rate_at_window_per_round_trip() {
    // The pre-fix default: 256 KiB per lane, the 1.6 MiB/s `cp` cap at 100 ms.
    let limits = SessionLimits {
        delivery_frames_per_lane: 64,
        delivery_bytes_per_lane: 256 * 1024,
        ..SessionLimits::default()
    };
    let rate = bulk_rate(limits, 8 * MIB).await;
    assert!(rate <= 2.6, "a 256 KiB window moved {rate:.1} MiB/s over a 100 ms round trip");
}

#[tokio::test(start_paused = true)]
async fn the_window_bounds_unacknowledged_bytes_when_the_peer_stops_reading() {
    let limits = SessionLimits::default();
    let (sender, _receiver) = sessions(limits);
    let writer = {
        let sender = sender.clone();
        tokio::spawn(async move {
            let payload = Bytes::from(vec![0x5a; MAX_FRAME_PAYLOAD]);
            loop {
                if sender
                    .send_with_backpressure(Lane::Bulk, 1, payload.clone(), FrameFlags::empty())
                    .await
                    .is_err()
                {
                    return;
                }
            }
        })
    };
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert!(!writer.is_finished(), "the writer waits for acknowledgements, it does not fail");
    let sent = usize::try_from(sender.next_outbound_sequence(Lane::Bulk) - 1).expect("count");
    assert!(sent > 0);
    assert!(sent * MAX_WIRE_FRAME_BYTES <= limits.delivery_bytes_per_lane);
    assert!((sent + 1) * MAX_WIRE_FRAME_BYTES > limits.delivery_bytes_per_lane);
    writer.abort();
}
