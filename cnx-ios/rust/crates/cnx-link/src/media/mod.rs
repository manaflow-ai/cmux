//! The media lane (cnx-ios/verify/browser-video-track.md): real-time video
//! from the Mac to the phone as RTP, beside the link's reliable channels.
//!
//! One transport-agnostic core does the media work, and a carrier only
//! moves packets:
//!
//! - [`sender::SenderCore`] (Mac): H.264 packetization (RFC 6184 via the
//!   `rtp` crate), transport-wide sequence numbers, a NACK history, the
//!   delay-based congestion controller shared with `cmux.rd/1`
//!   (`cmux-rd-core`, fed by TWCC feedback), PLI and FIR as keyframe
//!   requests, and an in-flight window that tells the source when to skip
//!   a frame instead of queueing it.
//! - [`receiver::ReceiverCore`] (phone): a reorder buffer that releases a
//!   frame the moment it is complete (no playout delay), NACKs for gaps,
//!   TWCC feedback (the `interceptor` crate's recorder), and PLI when a
//!   frame is given up, after which only a keyframe is released.
//!
//! Carriers ([`MediaCarrier`]):
//!
//! - [`CarrierKind::WebRtcTrack`]: a video track on the link's own peer
//!   connection (SRTP, same ICE and TURN session). See
//!   [`crate::dial::webrtc`].
//! - [`CarrierKind::WireGuardUdp`]: RTP and RTCP as plain datagrams on
//!   overlay UDP inside the WireGuard tunnel ([`wireguard::WgCarrier`]), with
//!   the same webrtc-rs interceptors bound to the socket and no SRTP
//!   (WireGuard encrypts).
//!
//! The lane is negotiated per carrier: the phone lists [`VIDEO_LANE`] in its
//! offer's lanes and the Mac lists it back only when it attached a sender.
//! A link without the lane carries video the old way (rd shards on a
//! reliable channel).

use std::sync::Arc;

use futures_util::future::BoxFuture;
use tokio::sync::{Mutex, mpsc, watch};

pub mod h264;
pub mod receiver;
pub mod resend;
pub mod sender;
pub mod tag;
pub mod track;
pub mod twcc;
pub mod wireguard;

pub use receiver::{ReceivedFrame, ReceiverConfig, ReceiverCore};
pub use sender::{SenderConfig, SenderCore, SenderEvent};

pub use ::webrtc::rtcp;
pub use ::webrtc::rtp;

/// The lane name in the signaling offer and answer (PROTOCOL.md "Lanes").
pub const VIDEO_LANE: &str = "video";
/// RTP clock of the video stream (RFC 6184).
pub const CLOCK_RATE: u32 = 90_000;
/// Largest RTP payload. Leaves room for the RTP header (12), the one-byte
/// header extension block (8), SRTP's tag (10) and the tunnel or TURN
/// framing on a 1280-byte IPv6 path.
pub const RTP_PAYLOAD_MTU: usize = 1100;
/// The transport-wide sequence number header extension (TWCC).
pub const TWCC_URI: &str = "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01";
/// The extension id a carrier without SDP uses.
pub const DEFAULT_TWCC_EXT_ID: u8 = 1;
/// The dynamic payload type a carrier without SDP uses.
pub const DEFAULT_PAYLOAD_TYPE: u8 = 102;

pub type RtcpPackets = Vec<Box<dyn rtcp::packet::Packet + Send + Sync>>;

/// How a lane's packets travel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CarrierKind {
    /// A video track on the link's WebRTC peer connection.
    WebRtcTrack,
    /// RTP in overlay UDP inside the WireGuard tunnel.
    WireGuardUdp,
}

impl CarrierKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::WebRtcTrack => "webrtc-track",
            Self::WireGuardUdp => "wireguard-udp",
        }
    }
}

#[derive(Debug, Clone, thiserror::Error, PartialEq, Eq)]
pub enum MediaError {
    #[error("this carrier does not carry media yet")]
    Unsupported,
    #[error("the media lane is closed")]
    Closed,
    #[error("media: {0}")]
    Other(String),
}

/// Moves RTP one way and RTCP back. The Mac's carrier sends RTP and reads
/// RTCP; the phone's reads RTP and sends RTCP. A method a side never uses
/// may stay pending forever.
pub trait MediaCarrier: Send + Sync + 'static {
    fn kind(&self) -> CarrierKind;
    /// The negotiated id of the TWCC header extension.
    fn twcc_ext_id(&self) -> u8;
    /// The largest RTP payload this carrier moves in one packet without
    /// fragmenting.
    fn max_payload(&self) -> usize {
        RTP_PAYLOAD_MTU
    }
    /// Counts the path's network changes (a WireGuard roam on either side),
    /// for carriers whose path can change under them without a new
    /// negotiation. The receiver asks for a keyframe after each; the sender
    /// forgets what was in flight on the old path.
    fn path_changes(&self) -> Option<watch::Receiver<u64>> {
        None
    }
    fn send_rtp<'a>(&'a self, packet: &'a rtp::packet::Packet) -> BoxFuture<'a, Result<(), MediaError>>;
    fn send_rtcp(&self, packets: RtcpPackets) -> BoxFuture<'_, Result<(), MediaError>>;
    /// The next RTP packet; `None` once the carrier ends.
    fn recv_rtp(&self) -> BoxFuture<'_, Option<rtp::packet::Packet>>;
    /// The next RTCP compound; `None` once the carrier ends.
    fn recv_rtcp(&self) -> BoxFuture<'_, Option<RtcpPackets>>;
}

/// Microseconds since `epoch` (the cores' injected clock).
pub(crate) fn micros_since(epoch: std::time::Instant) -> u64 {
    u64::try_from(epoch.elapsed().as_micros()).unwrap_or(u64::MAX)
}

/// The RTP timestamp of a host capture time (host monotonic microseconds).
pub fn rtp_timestamp(capture_us: u64) -> u32 {
    (u128::from(capture_us) * u128::from(CLOCK_RATE) / 1_000_000) as u32
}

/// The capture time (host microseconds) of `rtp_ts`, given the host's clock
/// now: the newest time at or before `host_now_us` with that timestamp.
pub fn capture_us_from_rtp(rtp_ts: u32, host_now_us: u64) -> u64 {
    let now_ts = rtp_timestamp(host_now_us);
    // Signed: a timestamp slightly ahead of the estimate of the host's
    // clock (an offset error larger than the frame's age) is "now", not
    // 2^32 ticks (13 hours) behind.
    let behind_ticks = now_ts.wrapping_sub(rtp_ts) as i32;
    if behind_ticks <= 0 {
        return host_now_us;
    }
    host_now_us.saturating_sub(behind_ticks as u64 * 1_000_000 / u64::from(CLOCK_RATE))
}

/// One frame for the lane (Mac side).
#[derive(Debug, Clone)]
pub struct OutgoingFrame {
    /// H.264 Annex-B access unit.
    pub access_unit: bytes::Bytes,
    /// Host monotonic capture time in microseconds; becomes the RTP timestamp.
    pub capture_us: u64,
}

/// What the Mac's source hears from the lane.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SenderState {
    /// The congestion controller's target.
    pub target_bps: u64,
    /// Bytes sent and not yet reported by feedback.
    pub in_flight_bytes: u64,
    /// Skip the next frame at the source rather than queue it.
    pub congested: bool,
    /// Loss among packets the last feedback settled (0.0 to 1.0).
    pub loss: f64,
    /// Smoothed time from sending a packet to hearing of its arrival.
    pub feedback_delay_us: u64,
    /// Keyframe requests (PLI, FIR) received so far.
    pub keyframe_requests: u64,
    pub packets_sent: u64,
    pub nacks_received: u64,
}

/// The Mac side of a lane: one source at a time owns it. A newer
/// [`VideoOut::claim`] preempts the older one, whose `preempted` fires.
#[derive(Clone)]
pub struct VideoOut {
    inner: Arc<OutInner>,
}

struct OutInner {
    kind: CarrierKind,
    frames: mpsc::Sender<(u64, OutgoingFrame)>,
    owner: watch::Sender<u64>,
    state: watch::Receiver<SenderState>,
    keyframes: tokio::sync::broadcast::Sender<()>,
    next_claim: std::sync::atomic::AtomicU64,
}

impl std::fmt::Debug for VideoOut {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VideoOut").field("kind", &self.inner.kind).finish_non_exhaustive()
    }
}

/// One source's hold on the lane.
pub struct VideoClaim {
    id: u64,
    inner: Arc<OutInner>,
    owner: watch::Receiver<u64>,
    pub keyframes: tokio::sync::broadcast::Receiver<()>,
}

impl VideoOut {
    /// Runs the sender core on `carrier` until the carrier ends or `closed`
    /// (the link's close state) says the link closed.
    pub fn start(
        carrier: Arc<dyn MediaCarrier>,
        config: SenderConfig,
        closed: Option<watch::Receiver<Option<String>>>,
    ) -> Self {
        let (frames_tx, frames_rx) = mpsc::channel(4);
        let (state_tx, state_rx) = watch::channel(SenderState {
            target_bps: config.cc.start_bps,
            in_flight_bytes: 0,
            congested: false,
            loss: 0.0,
            feedback_delay_us: 0,
            keyframe_requests: 0,
            packets_sent: 0,
            nacks_received: 0,
        });
        let (keyframes, _) = tokio::sync::broadcast::channel(8);
        let inner = Arc::new(OutInner {
            kind: carrier.kind(),
            frames: frames_tx,
            owner: watch::channel(0).0,
            state: state_rx,
            keyframes: keyframes.clone(),
            next_claim: std::sync::atomic::AtomicU64::new(1),
        });
        tokio::spawn(sender::run(carrier, config, frames_rx, state_tx, keyframes, closed));
        Self { inner }
    }

    pub fn kind(&self) -> CarrierKind {
        self.inner.kind
    }

    /// Takes the lane; the previous claim (if any) is preempted.
    pub fn claim(&self) -> VideoClaim {
        let id = self.inner.next_claim.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.inner.owner.send_replace(id);
        VideoClaim {
            id,
            inner: Arc::clone(&self.inner),
            owner: self.inner.owner.subscribe(),
            keyframes: self.inner.keyframes.subscribe(),
        }
    }

    pub fn state(&self) -> SenderState {
        *self.inner.state.borrow()
    }

    /// Whether the sender task still runs.
    pub fn is_closed(&self) -> bool {
        self.inner.frames.is_closed()
    }
}

impl VideoClaim {
    /// Whether this claim still owns the lane.
    pub fn owns(&self) -> bool {
        *self.owner.borrow() == self.id
    }

    /// Resolves when a newer claim takes the lane.
    pub async fn preempted(&mut self) {
        let id = self.id;
        let _ = self.owner.wait_for(|owner| *owner != id).await;
    }

    /// Sends one frame. A preempted claim's frames are dropped.
    pub async fn send(&self, frame: OutgoingFrame) -> Result<(), MediaError> {
        if !self.owns() {
            return Err(MediaError::Closed);
        }
        self.inner.frames.send((self.id, frame)).await.map_err(|_| MediaError::Closed)
    }

    pub fn state(&self) -> SenderState {
        *self.inner.state.borrow()
    }

    /// Resolves with `true` once the lane is no longer congested (at once if
    /// it is not), or `false` when the lane's sender ended first.
    pub fn uncongested(&self) -> impl std::future::Future<Output = bool> + Send + 'static {
        let mut state = self.inner.state.clone();
        async move { state.wait_for(|s| !s.congested).await.is_ok() }
    }
}

impl Drop for VideoClaim {
    fn drop(&mut self) {
        // Release the lane only if this claim still holds it.
        let id = self.id;
        self.inner.owner.send_if_modified(|owner| {
            if *owner == id {
                *owner = 0;
                true
            } else {
                false
            }
        });
    }
}

/// Counters of the phone's receiver.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReceiverStats {
    pub packets: u64,
    pub bytes: u64,
    pub frames: u64,
    pub keyframes: u64,
    /// Frames given up (missing packets past the deadline) or skipped while
    /// waiting for a keyframe.
    pub frames_dropped: u64,
    pub plis_sent: u64,
    pub packets_recovered: u64,
}

/// The phone side of a lane. [`VideoIn::subscribe`] takes the frames from
/// every earlier subscriber; [`VideoIn::subscribe_shared`] gets them beside
/// the others (each viewer then keeps its own tab's, by [`tag`]).
#[derive(Clone)]
pub struct VideoIn {
    inner: Arc<InInner>,
}

pub(crate) struct InInner {
    kind: CarrierKind,
    subscribers: Mutex<Vec<mpsc::Sender<ReceivedFrame>>>,
    keyframe: mpsc::UnboundedSender<()>,
    stats: watch::Receiver<ReceiverStats>,
}

impl std::fmt::Debug for VideoIn {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("VideoIn").field("kind", &self.inner.kind).finish_non_exhaustive()
    }
}

/// A subscriber's frames; it ends when a newer exclusive subscriber takes
/// over or the lane closes.
pub struct VideoFrames {
    pub frames: mpsc::Receiver<ReceivedFrame>,
    keyframe: mpsc::UnboundedSender<()>,
}

impl VideoFrames {
    /// Asks the Mac for a keyframe (PLI): the decoder lost its state.
    pub fn request_keyframe(&self) {
        let _ = self.keyframe.send(());
    }
}

impl VideoIn {
    /// Runs the receiver core on `carrier` until the carrier ends or `closed`
    /// (the link's close state) says the link closed. `rtt` (the link's ping
    /// round trip) sets how long a gap may wait for a NACK.
    pub fn start(
        carrier: Arc<dyn MediaCarrier>,
        config: ReceiverConfig,
        rtt: Option<watch::Receiver<Option<std::time::Duration>>>,
        closed: Option<watch::Receiver<Option<String>>>,
    ) -> Self {
        let (keyframe_tx, keyframe_rx) = mpsc::unbounded_channel();
        let (stats_tx, stats_rx) = watch::channel(ReceiverStats::default());
        let inner = Arc::new(InInner {
            kind: carrier.kind(),
            subscribers: Mutex::new(Vec::new()),
            keyframe: keyframe_tx,
            stats: stats_rx,
        });
        tokio::spawn(receiver::run(carrier, config, Arc::clone(&inner), keyframe_rx, stats_tx, rtt, closed));
        Self { inner }
    }

    pub fn kind(&self) -> CarrierKind {
        self.inner.kind
    }

    /// Takes the frames from now on, from every earlier subscriber (and
    /// asks for a keyframe to start from).
    pub async fn subscribe(&self) -> VideoFrames {
        self.subscribe_with(true).await
    }

    /// Gets every frame from now on beside the other subscribers (and asks
    /// for a keyframe to start from). For viewers that keep only their own
    /// tab's frames ([`tag`]).
    pub async fn subscribe_shared(&self) -> VideoFrames {
        self.subscribe_with(false).await
    }

    async fn subscribe_with(&self, exclusive: bool) -> VideoFrames {
        let (tx, rx) = mpsc::channel(8);
        {
            let mut subscribers = self.inner.subscribers.lock().await;
            if exclusive {
                subscribers.clear();
            }
            subscribers.push(tx);
        }
        let _ = self.inner.keyframe.send(());
        VideoFrames { frames: rx, keyframe: self.inner.keyframe.clone() }
    }

    pub fn stats(&self) -> ReceiverStats {
        *self.inner.stats.borrow()
    }
}

/// The lane a dial produced: the Mac's sender or the phone's receiver.
#[derive(Clone, Debug)]
pub enum MediaLane {
    Out(VideoOut),
    In(VideoIn),
}

/// Resolves once `closed` (a link's close state) reports a close, or never
/// without one.
pub(crate) async fn link_closed(closed: &mut Option<watch::Receiver<Option<String>>>) {
    match closed.as_mut() {
        Some(state) => {
            let _ = state.wait_for(Option::is_some).await;
        }
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_timestamp_slightly_ahead_of_the_clock_estimate_is_now() {
        let now = 50_000_000;
        assert_eq!(capture_us_from_rtp(rtp_timestamp(now + 2_000), now), now);
        assert_eq!(capture_us_from_rtp(rtp_timestamp(now), now), now);
    }

    #[test]
    fn rtp_timestamps_round_trip_to_the_capture_time() {
        for capture in [0u64, 1_234_567, 47_721_858_833, 900_000_000_000] {
            for lag in [0u64, 16_000, 900_000] {
                let back = capture_us_from_rtp(rtp_timestamp(capture), capture + lag);
                assert!(back.abs_diff(capture) <= 12, "capture {capture} lag {lag} back {back}");
            }
        }
    }
}
