//! The media engine every `cmux.rd/1` source shares (rd change C7 step 2;
//! plans/cmux-next/remote-desktop-c7.md): the desktop host (cmux-rd-host)
//! and the remote browser host (cmux-remote-browser) feed it damage, encoded
//! frames and received datagrams; it answers with encode requests, datagrams
//! to send and input to inject. It owns the frame gate (one frame in flight,
//! fps cap, damage coalescing), the congestion controller, the packetizer
//! with adaptive FEC, a bounded NACK history, loss measurement, rate-limited
//! recovery keyframes and the exactly-once input applier. No I/O, no
//! threads, no capture and no codec: every time is the caller's monotonic
//! clock in microseconds, and each source keeps its own I/O loop, capture
//! and encoder.

mod outage;

use std::collections::{BTreeMap, VecDeque};

use cmux_rd_core::cc::{CcConfig, CongestionController, OutageEnd, PathKind, UltraConfig};
use cmux_rd_core::flow::{FlowAction, FrameGate, Rect};
use cmux_rd_core::input::InputApplier;
use cmux_rd_core::packetize::{PacketizeError, Packetizer, parity_for};
use cmux_rd_core::probe::{ProbeConfig, ProbePlanner, ProbeReason};
pub use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_core::profile::refine_after_us;
use cmux_rd_core::reassembly::{CompleteFrame, Reassembler};
use cmux_rd_core::resolution::{LadderConfig, Picture, ResolutionLadder};
use cmux_rd_proto::{
    Arrival, ClockEstimate, ClockPing, ClockPong, DatagramHeader, DatagramKind, FRAME_PREFIX_LEN,
    Feedback, FrameBody, HEADER_LEN, InputEvent, InputPacket, MAX_ARRIVALS, MAX_DATAGRAM_VPC,
    REF_NONE, flags,
};

pub use cmux_rd_core::loss::LossMeter;

/// Frames kept for NACK resends.
pub const HISTORY_FRAMES: usize = 16;
/// Keep a short, bounded RTT history so queueing spikes do not set the window,
/// and an earlier, faster route cannot constrain a slower route forever.
const ACK_RTT_WINDOW_US: u64 = 1_000_000;
const ACK_RTT_SAMPLES: usize = 64;
/// Datagrams resent per feedback, so a hostile feedback cannot amplify.
pub const MAX_RESENDS_PER_FEEDBACK: usize = 64;
/// Shortest time between two forced keyframes.
pub const MIN_FORCED_IDR_INTERVAL_US: u64 = 250_000;
/// How long a stream's newest frame may go unacknowledged before the host
/// resends it (a tail-loss probe). On a datagram path a frame whose every
/// datagram was lost leaves the viewer nothing to NACK and the gate nothing
/// to open on; the probe recovers it. A received frame's resend is dropped by
/// the viewer's reassembler.
pub const TAIL_PROBE_US: u64 = 250_000;
/// Probes before the host stops resending and starts over from a keyframe.
pub const TAIL_PROBES: u32 = 3;
/// With [`EngineConfig::rtt_tail_probe`], the shortest wait before a tail probe.
pub const TAIL_PROBE_MIN_US: u64 = 5_000;
/// The window the idle-link copy measures the host's recent sends over (one
/// second: its bytes compare with the target's bits per second).
pub const IDLE_COPY_WINDOW_US: u64 = 1_000_000;
/// A frame of one data shard goes out with a parity copy while the last
/// [`IDLE_COPY_WINDOW_US`]'s frame bytes stay under this share of the
/// controller's target, in percent: losing either copy then costs no
/// tail-probe wait, and the copy costs under 1 % of the link.
pub const IDLE_COPY_PERCENT: u64 = 1;
/// Frames the idle-link copy remembers (more than a second at any frame rate).
const IDLE_COPY_FRAMES: usize = 512;
/// Most streams per peer (the viewer's CMUX_RD_SESSION_MAX_STREAMS).
/// Measured: each popup stream runs its own video encoder on the host (`pump.rs` `add_stream`),
/// and popups share [`POPUP_SHARE_PERCENT`] (20 %) of the target with a floor of
/// [`MIN_POPUP_KBPS`] each: 16 x 300 kbps = 4.8 Mbps, the whole share of a 24 Mbps target. Past
/// that every popup's floor takes from the main stream. Derived from these constants, not timed.
pub const MAX_STREAMS: usize = 16;
/// Share of the target that popup streams may take together, in percent.
pub const POPUP_SHARE_PERCENT: u64 = 20;
/// Floor of one popup stream's bitrate.
pub const MIN_POPUP_KBPS: u32 = 300;
/// Keep idle capacity fresh without making probes a background stream.
const IDLE_PROBE_INTERVAL_US: u64 = 1_000_000;
/// Keep the deliberate sender window to one quarter of the viewer's measured
/// reassembly queue. The other three quarters remain available for frames held
/// by loss and reordering. At the benchmark's <=512 KiB encoded-frame budget,
/// 16 slots allocate at most 8 MiB; MAX_PENDING_BYTES remains the hard byte cap
/// when larger keyframes are allowed.
const MAX_FRAMES_IN_FLIGHT: u32 = (cmux_rd_core::reassembly::MAX_PENDING_FRAMES / 4) as u32;

/// Limits of one media session.
#[derive(Debug, Clone, Copy)]
pub struct EngineConfig {
    /// The streamed size; the first frame and recovery frames cover all of it.
    pub width: u32,
    pub height: u32,
    pub max_fps: u32,
    pub start_bps: u64,
    pub max_bps: u64,
    /// The controller never targets below this. Equal to `max_bps`, it pins the target: a
    /// measurement holds one rate however the path's delay and loss move.
    pub min_bps: u64,
    /// The link's datagram size for this session (1152 or 1332).
    pub max_datagram: usize,
    /// The path class until the link reports path events.
    pub path: PathKind,
    /// How long a missing input event may block later ones.
    pub input_gap_timeout_us: u64,
    /// The main display stream (0 by convention); more with `add_stream`.
    pub stream: u16,
    /// Frames of each display stream that may be unacknowledged at once (at least one):
    /// one keeps the latency lowest on a short path; a path whose round trip spans
    /// several frame intervals needs more (`frames_in_flight_for`).
    pub frames_in_flight: u32,
    /// After injected input, frames skip the frame-rate cap for a short window
    /// (`cmux_rd_core::flow::INPUT_FRAME_WINDOW_US`), so the input's effect goes out as soon
    /// as the capture delivers it instead of on the next interval.
    pub input_frame_now: bool,
    /// Tail-loss probes wait a round trip, not [`TAIL_PROBE_US`] (design D6): the first
    /// probe goes `max(2 x smoothed ack RTT + 4 x its deviation, TAIL_PROBE_MIN_US)`
    /// after the frame's last datagram left (at most [`TAIL_PROBE_US`]), each later one
    /// twice the one before (at most [`TAIL_PROBE_US`]), and the keyframe that ends the
    /// probes comes when it does today, `(TAIL_PROBES + 1) x TAIL_PROBE_US` after the
    /// frame went out. Off by default: probes sent sooner add resends to the path.
    pub rtt_tail_probe: bool,
    /// The resolution ladder for the main stream (design D5): below the bits-per-pixel
    /// floor its encoded picture gets smaller, not blurrier, and each request carries the
    /// picture and its QP ceiling. `None` (the default): every frame is the full stream.
    pub resolution_ladder: Option<LadderConfig>,
}

impl Default for EngineConfig {
    fn default() -> Self {
        let cc = CcConfig::default();
        Self {
            width: 1920,
            height: 1080,
            max_fps: 60,
            start_bps: cc.start_bps,
            max_bps: cc.max_bps,
            min_bps: cc.min_bps,
            max_datagram: MAX_DATAGRAM_VPC,
            path: PathKind::ViaCloudRegion,
            input_gap_timeout_us: 200_000,
            stream: 0,
            frames_in_flight: 1,
            input_frame_now: false,
            rtt_tail_probe: false,
            resolution_ladder: None,
        }
    }
}

/// Capture and encode this frame now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodeRequest {
    /// The display stream (0 the main surface; popups and tiles have their own).
    pub stream: u16,
    pub frame: u32,
    /// The region that changed (the source may encode more).
    pub damage: Rect,
    /// Encode an IDR (first frame, recovery, or after a dropped frame).
    pub force_idr: bool,
    /// Why `force_idr` is set, for the source's timing log.
    pub idr_reason: Option<IdrReason>,
    /// The congestion controller's target for this frame.
    pub target_kbps: u32,
    /// The picture to encode, from the resolution ladder: its size (the source scales the
    /// stream to it) and QP ceiling. `None` without a ladder: the full stream, no ceiling.
    pub picture: Option<Picture>,
    /// The encoder settings for this frame (`MediaEngine::set_profile`; standard by default).
    pub profile: EncodeProfile,
    /// Ultra only: the screen went still, so this frame re-encodes the unchanged picture at a
    /// low QP (visually lossless) instead of carrying new damage.
    pub refine: bool,
}

/// Why the engine asks for a keyframe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdrReason {
    /// A stream's first frame.
    Start,
    /// The viewer's feedback asked for recovery (a lost or unreferenced frame).
    Recovery,
    /// The newest frame stayed unacknowledged through every tail probe.
    TailProbe,
    /// The last frame was too large to packetize and was dropped.
    TooLarge,
    /// Frames queued in the host's pacer through an outage were dropped unsent (D12).
    Outage,
    /// The resolution ladder changed the encoded size.
    Resize,
}

impl IdrReason {
    pub fn as_str(self) -> &'static str {
        match self {
            IdrReason::Start => "start",
            IdrReason::Recovery => "recovery",
            IdrReason::TailProbe => "tail_probe",
            IdrReason::TooLarge => "too_large",
            IdrReason::Outage => "outage",
            IdrReason::Resize => "resize",
        }
    }
}

/// One encoded frame from the source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Encoded {
    /// The access unit (Annex-B).
    pub access_unit: Vec<u8>,
    /// The encoder produced an IDR.
    pub idr: bool,
    /// Source monotonic time of the pixels.
    pub t_capture_us: u64,
}

/// What the source does after one engine call.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Output {
    /// Datagrams to send now, in order (frame shards, resends, input acks).
    pub datagrams: Vec<Vec<u8>>,
    /// Input to inject, in order, already applied exactly once.
    pub inject: Vec<InputEvent>,
    /// Release every key and button the viewer holds (input skipped a gap).
    pub release_all: bool,
    /// Encode this frame next.
    pub encode: Option<EncodeRequest>,
    /// The last frame was too large to send: halve the encoder's bitrate.
    pub halve_bitrate: bool,
    /// The path came back from an outage (D12): the controller held its rate and
    /// every stream's gate stopped waiting for stale acknowledgements. Datagrams
    /// still queued in the host's pacer are stale; the host may drop them.
    pub outage_ended: Option<OutageEnd>,
    /// Complete upstream media frames (stream, frame) from the viewer (rd change C4).
    pub upstream: Vec<(u16, CompleteFrame)>,
}

/// Why a stream cannot be added.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamError {
    /// The stream id is in use.
    Exists(u16),
    /// The session already has the most streams a viewer accepts.
    TooMany,
    /// A tile stream names a surface stream that does not exist.
    NoSurface(u16),
}

impl StreamError {
    /// The `stream_refused` reason for this error.
    pub fn reason(self) -> &'static str {
        match self {
            Self::Exists(_) => "in_use",
            Self::TooMany => "too_many",
            Self::NoSurface(_) => "no_surface",
        }
    }
}

/// Counters for the stats control message.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EngineStats {
    pub frames: u64,
    pub keyframes: u64,
    /// Smoothed loss fraction, 0 to 1.
    pub loss: f64,
    pub target_bps: u64,
}

/// Upstream feedback interval while upstream media flows.
const UPSTREAM_FEEDBACK_US: u64 = 50_000;
/// How long an upstream frame may wait for missing shards.
const UPSTREAM_DEADLINE_US: u64 = 200_000;
/// How long before an upstream frame's gaps are NACKed.
const UPSTREAM_NACK_AFTER_US: u64 = 5_000;

/// One upstream media stream (rd change C4): the host's receiver.
#[derive(Debug)]
struct Upstream {
    reassembler: Reassembler,
    arrivals: VecDeque<Arrival>,
    released_since_feedback: bool,
    last_feedback_us: Option<u64>,
}

impl Upstream {
    fn new() -> Self {
        Self {
            reassembler: Reassembler::with_nack_after(UPSTREAM_DEADLINE_US, UPSTREAM_NACK_AFTER_US),
            arrivals: VecDeque::new(),
            released_since_feedback: false,
            last_feedback_us: None,
        }
    }

    fn push(&mut self, header: &DatagramHeader, payload: &[u8], now_us: u64) -> Vec<CompleteFrame> {
        if self.arrivals.len() >= 8 * MAX_ARRIVALS {
            self.arrivals.pop_front();
        }
        self.arrivals
            .push_back(Arrival { transport_seq: header.transport_seq, arrival_us: now_us as u32 });
        let released = self.reassembler.push(header, payload, now_us);
        self.released_since_feedback |= !released.is_empty();
        released
    }

    fn due(&self, now_us: u64) -> bool {
        let interval_passed = self
            .last_feedback_us
            .is_none_or(|last| now_us.saturating_sub(last) >= UPSTREAM_FEEDBACK_US);
        self.released_since_feedback
            || self
                .reassembler
                .next_nack_us(UPSTREAM_NACK_AFTER_US, UPSTREAM_FEEDBACK_US)
                .is_some_and(|deadline| now_us >= deadline)
            || (interval_passed && (!self.arrivals.is_empty() || self.reassembler.need_recovery()))
    }

    fn feedback(&mut self, stream: u16, now_us: u64) -> Option<Vec<u8>> {
        if !self.due(now_us) {
            return None;
        }
        self.released_since_feedback = false;
        self.last_feedback_us = Some(now_us);
        let take = self.arrivals.len().min(MAX_ARRIVALS);
        let nacks =
            self.reassembler.take_nacks(now_us, UPSTREAM_NACK_AFTER_US, UPSTREAM_FEEDBACK_US);
        let fb = Feedback {
            acked_frame: self.reassembler.last_released(),
            decode_us: 0,
            need_recovery: self.reassembler.need_recovery(),
            arrivals: self.arrivals.drain(..take).collect(),
            nacks,
        };
        let mut d = Vec::with_capacity(HEADER_LEN + 256);
        DatagramHeader {
            flags: 0,
            kind: DatagramKind::Feedback,
            stream,
            frame: 0,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: 0,
        }
        .encode_into(&mut d);
        d.extend_from_slice(&fb.encode());
        Some(d)
    }

    fn next_deadline_us(&self) -> Option<u64> {
        if self.released_since_feedback {
            return Some(0);
        }
        let feedback = (!self.arrivals.is_empty() || self.reassembler.need_recovery())
            .then(|| self.last_feedback_us.map_or(0, |l| l.saturating_add(UPSTREAM_FEEDBACK_US)));
        [
            feedback,
            self.reassembler.next_expiry_us(),
            self.reassembler.next_nack_us(UPSTREAM_NACK_AFTER_US, UPSTREAM_FEEDBACK_US),
        ]
        .into_iter()
        .flatten()
        .min()
    }
}

/// One display stream: its own frame gate, NACK history and keyframe state.
#[derive(Debug)]
struct StreamState {
    width: u32,
    height: u32,
    gate: FrameGate,
    history: BTreeMap<u32, Vec<Vec<u8>>>,
    last_frame: u32,
    /// The next frame is a keyframe, and why.
    force_idr: Option<IdrReason>,
    last_forced_idr_us: Option<u64>,
    /// The first damage covers the whole stream.
    started: bool,
    /// A tile stream's surface stream (rd change C3).
    tile_of: Option<u16>,
    /// When the newest frame went out, or was last probed, while it is unacknowledged.
    probe_from_us: Option<u64>,
    /// Tail-loss probes sent for the newest frame.
    probes: u32,
    /// When the newest frame went out (its encode), while it is unacknowledged:
    /// with `rtt_tail_probe`, the probes end in a keyframe this long after as today.
    unacked_since_us: Option<u64>,
    /// The newest frame's last datagram: its departure starts the probe wait.
    last_seq: Option<u16>,
    /// When each recent frame's last datagram first left, for the probe's RTT
    /// samples (a probed frame's entry is dropped: its ack is ambiguous).
    departed_at_us: BTreeMap<u32, u64>,
    /// Host monotonic send time for recent frames, used to measure the
    /// viewer's cumulative acknowledgement round trip on carriers that do
    /// not expose a path probe (the development socket/proxy path).
    sent_at_us: BTreeMap<u32, u64>,
    /// Bytes of the stream's last keyframe: what starting over costs (D12).
    last_keyframe_bytes: usize,
    /// The resolution ladder (main stream only, when the session asks for one).
    ladder: Option<ResolutionLadder>,
    /// Ultra: when a refinement frame is due if no damage arrives first (one frame interval
    /// after the newest frame was sent).
    refine_due_us: Option<u64>,
    /// The gate's pending damage is a refinement (no new damage joined it).
    refine_pending: bool,
}

impl StreamState {
    fn new(width: u32, height: u32, max_fps: u32, frames_in_flight: u32) -> Self {
        Self {
            width,
            height,
            gate: FrameGate::new(frames_in_flight.max(1), max_fps.max(1)),
            history: BTreeMap::new(),
            last_frame: 0,
            force_idr: Some(IdrReason::Start),
            last_forced_idr_us: None,
            started: false,
            tile_of: None,
            probe_from_us: None,
            probes: 0,
            unacked_since_us: None,
            last_seq: None,
            departed_at_us: BTreeMap::new(),
            sent_at_us: BTreeMap::new(),
            last_keyframe_bytes: 0,
            refine_due_us: None,
            refine_pending: false,
            ladder: None,
        }
    }

    /// Applies a new picture from the ladder: its frame-rate cap now, and a keyframe when
    /// the size changed (the encoder starts a new session at the new size).
    fn apply_picture(&mut self, before: Picture, after: Picture) {
        self.gate.set_max_fps(after.fps);
        if (after.width, after.height) != (before.width, before.height) {
            self.force_idr.get_or_insert(IdrReason::Resize);
        }
    }

    fn full(&self) -> Rect {
        Rect { x: 0, y: 0, width: self.width, height: self.height }
    }
}

/// The media state of one viewer of one source: several display streams
/// (the main surface, popups) share one congestion controller, one
/// transport sequence space and one input channel.
#[derive(Debug)]
pub struct MediaEngine {
    cfg: EngineConfig,
    streams: BTreeMap<u16, StreamState>,
    cc: CongestionController,
    packetizer: Packetizer,
    applier: InputApplier,
    loss_meter: LossMeter,
    loss: f64,
    last_feedback_us: u64,
    frames: u64,
    keyframes: u64,
    clock: Option<ClockEstimate>,
    /// Recent cumulative frame-ack round trips: (observation time, round trip).
    ack_rtts: VecDeque<(u64, u64)>,
    /// The carrier's last path round trip, when it measures one.
    path_rtt_us: Option<u64>,
    /// Smoothed frame-ack round trip and its deviation, from the frame's last
    /// departure when the host reports it (`datagram_sent`), else its encode.
    ack_srtt_us: Option<u64>,
    ack_rttvar_us: u64,
    /// Recent frames' send time and bytes (every stream), for the idle-link copy.
    recent_sends: VecDeque<(u64, u64)>,
    /// The bytes in `recent_sends`.
    recent_bytes: u64,
    upstreams: BTreeMap<u16, Upstream>,
    /// The encoder profile every request carries.
    profile: EncodeProfile,
    /// Bounded startup/idle capacity probes share the media transport sequence
    /// space and the controller's departure accounting.
    probe_planner: ProbePlanner,
    probe_generation: Option<u64>,
    last_probe_start_us: Option<u64>,
}

impl MediaEngine {
    pub fn new(cfg: EngineConfig, now_us: u64) -> Self {
        let cc_cfg = CcConfig {
            start_bps: cfg.start_bps,
            max_bps: cfg.max_bps,
            min_bps: cfg.min_bps,
            ..CcConfig::default()
        };
        let mut streams = BTreeMap::new();
        let mut main = StreamState::new(cfg.width, cfg.height, cfg.max_fps, cfg.frames_in_flight);
        main.ladder = cfg
            .resolution_ladder
            .map(|l| ResolutionLadder::new(l, cfg.width, cfg.height, cfg.max_fps));
        streams.insert(cfg.stream, main);
        Self {
            streams,
            cc: CongestionController::new(cc_cfg, cfg.path),
            packetizer: Packetizer::new(cfg.stream, cfg.max_datagram),
            applier: InputApplier::new(cfg.input_gap_timeout_us),
            loss_meter: LossMeter::default(),
            loss: 0.0,
            last_feedback_us: now_us,
            frames: 0,
            keyframes: 0,
            clock: None,
            ack_rtts: VecDeque::new(),
            path_rtt_us: None,
            ack_srtt_us: None,
            ack_rttvar_us: 0,
            recent_sends: VecDeque::new(),
            recent_bytes: 0,
            upstreams: BTreeMap::new(),
            profile: EncodeProfile::Standard,
            probe_planner: ProbePlanner::new(ProbeConfig::for_datagram(
                cfg.stream,
                cfg.max_datagram,
            )),
            probe_generation: None,
            last_probe_start_us: None,
            cfg,
        }
    }

    /// The viewer offered cap `fec.blocks`: frames over one FEC block keep their parity,
    /// split across interleaved blocks (design D6). Off by default, since a viewer without
    /// it refuses those headers.
    pub fn set_fec_blocks(&mut self, on: bool) {
        self.packetizer.set_fec_blocks(on);
    }

    /// The encoder profile requests carry from now on. Leaving ultra drops any refinement
    /// that was due.
    pub fn set_profile(&mut self, profile: EncodeProfile) {
        self.cc.configure_ultra(UltraConfig {
            max_wire_bps: u64::from(cmux_rd_core::profile::max_kbps(
                profile,
                Some(self.cfg.max_bps.saturating_div(1000) as u32),
                cmux_rd_core::profile::ULTRA_MAX_KBPS,
            )) * 1000,
            ..UltraConfig::default()
        });
        self.cc.set_profile(profile);
        self.profile = profile;
        if !profile.is_ultra() {
            for state in self.streams.values_mut() {
                state.refine_due_us = None;
            }
        }
    }

    pub fn profile(&self) -> EncodeProfile {
        self.profile
    }

    /// Adds a display stream (a popup surface) of `width` x `height`. Its
    /// first damage covers the whole stream and is an IDR.
    pub fn add_stream(&mut self, stream: u16, width: u32, height: u32) -> Result<(), StreamError> {
        if self.streams.contains_key(&stream) || self.upstreams.contains_key(&stream) {
            return Err(StreamError::Exists(stream));
        }
        if self.streams.len() >= MAX_STREAMS {
            return Err(StreamError::TooMany);
        }
        self.streams.insert(
            stream,
            StreamState::new(width, height, self.cfg.max_fps, self.cfg.frames_in_flight),
        );
        Ok(())
    }

    /// Changes the in-flight bound for every live display stream. New streams use the same bound.
    pub fn set_frames_in_flight(&mut self, frames_in_flight: u32) {
        let frames_in_flight = frames_in_flight.max(1);
        self.cfg.frames_in_flight = frames_in_flight;
        for state in self.streams.values_mut() {
            state.gate.set_max_in_flight(frames_in_flight);
        }
    }

    /// Adapts the host's send window to its carrier RTT, or recent frame ACKs
    /// while the carrier has no RTT measurement. The caller supplies its current
    /// route's measurement each time, or None after falling back to a socket.
    pub fn update_frames_in_flight_from_rtt(&mut self, path_rtt_us: Option<u64>) {
        self.path_rtt_us = path_rtt_us;
        if let Some(rtt_us) = path_rtt_us.or_else(|| self.ack_rtt_us()) {
            self.set_frames_in_flight(frames_in_flight_for(rtt_us, self.cfg.max_fps).max(2));
            // A measured LAN round trip starts the target high (until the first overuse).
            self.cc.on_rtt(rtt_us);
        }
    }

    /// A paced datagram from `encoded` really left now: the controller times it from
    /// here, so pacing is not read as path delay. Other datagrams need no call.
    pub fn datagram_sent(&mut self, datagram: &[u8], now_us: u64) {
        if let Ok((header, _)) = DatagramHeader::decode(datagram) {
            self.datagram_departed(&header, now_us);
        }
    }

    /// A datagram left at `now_us`, known by its header: the form a carrier's departure
    /// receipt (`DatagramDeparture`) gives, stamped at the transport write, not the enqueue.
    pub fn datagram_departed(&mut self, header: &DatagramHeader, now_us: u64) {
        if header.kind == DatagramKind::Probe {
            self.probe_planner.record_departure(header.transport_seq, now_us);
        }
        if matches!(header.kind, DatagramKind::Video | DatagramKind::Fec | DatagramKind::Probe) {
            self.cc.on_departed(header.transport_seq, now_us);
        }
        if matches!(header.kind, DatagramKind::Video | DatagramKind::Fec) {
            let rtt_probe = self.cfg.rtt_tail_probe;
            if let Some(state) = self.streams.get_mut(&header.stream)
                && header.frame == state.last_frame
                && state.last_seq == Some(header.transport_seq)
            {
                // The newest frame's last datagram (or a resend of it) left: the
                // viewer can answer from here on, so the probe waits from here.
                if rtt_probe && state.probe_from_us.is_some() {
                    state.probe_from_us = Some(now_us);
                }
                if state.probes == 0 {
                    state.departed_at_us.entry(header.frame).or_insert(now_us);
                }
            }
        }
    }

    /// The tail-probe wait before probe number `probes + 1` (`rtt_tail_probe`).
    fn rtt_probe_wait_us(&self, probes: u32) -> u64 {
        let first = self.ack_srtt_us.map_or(TAIL_PROBE_US, |srtt| {
            srtt.saturating_mul(2)
                .saturating_add(self.ack_rttvar_us.saturating_mul(4))
                .clamp(TAIL_PROBE_MIN_US, TAIL_PROBE_US)
        });
        first.saturating_mul(1 << probes.min(16)).min(TAIL_PROBE_US)
    }

    /// When a stream's tail probe (or the keyframe that ends the probes) is due,
    /// while its newest frame is unacknowledged.
    fn tail_probe_due_us(&self, s: &StreamState) -> Option<u64> {
        let from = s.probe_from_us.filter(|_| s.gate.in_flight() > 0)?;
        if !self.cfg.rtt_tail_probe {
            return Some(from.saturating_add(TAIL_PROBE_US));
        }
        let probe = from.saturating_add(self.rtt_probe_wait_us(s.probes));
        Some(match s.unacked_since_us {
            Some(since) => probe.min(since.saturating_add(Self::probe_give_up_us())),
            None => probe,
        })
    }

    /// How long the newest frame stays unacknowledged before its probes end in a
    /// keyframe: today's fixed schedule, `TAIL_PROBES` probes and one more wait.
    fn probe_give_up_us() -> u64 {
        TAIL_PROBE_US.saturating_mul(u64::from(TAIL_PROBES) + 1)
    }

    /// The controller's target now (all display streams together).
    pub fn target_bps(&self) -> u64 {
        // The host passes this value to the pacer. Ultra's encoder target is
        // media-only; pacing must reserve the same held budget for media,
        // repairs, and probes. Standard: the controller's target.
        self.cc.wire_budget_bps()
    }

    /// The rate the strict Ultra pacer releases datagrams at (the probed capacity; see
    /// `CongestionController::pacing_bps`). Standard: [`Self::target_bps`].
    pub fn pacing_bps(&self) -> u64 {
        self.cc.pacing_bps()
    }

    /// Adds a lossless tile stream (rd change C3) for surface stream `of`:
    /// the source encodes tile top-offs of static regions into its requests'
    /// access units; every frame carries `flags::TILE` and the surface
    /// stream's latest frame as `ref_frame` (the frame the tiles apply on
    /// top of). Send only when welcome lists the `tile` cap.
    pub fn add_tile_stream(
        &mut self,
        stream: u16,
        of: u16,
        width: u32,
        height: u32,
    ) -> Result<(), StreamError> {
        if !self.streams.contains_key(&of) {
            return Err(StreamError::NoSurface(of));
        }
        self.add_stream(stream, width, height)?;
        if let Some(state) = self.streams.get_mut(&stream) {
            state.tile_of = Some(of);
        }
        Ok(())
    }

    /// Accepts upstream media (microphone, camera, screen share; rd change
    /// C4) from the viewer on `stream`. Upstream frames are released in
    /// `Output::upstream` even without control (the service's permission
    /// for mic and camera is the service's check, not rd's input gate).
    pub fn add_upstream(&mut self, stream: u16) -> Result<(), StreamError> {
        // One id names one stream in both directions: the viewer routes the
        // host's feedback for this stream by its id (rd-ffi session).
        if self.upstreams.contains_key(&stream) || self.streams.contains_key(&stream) {
            return Err(StreamError::Exists(stream));
        }
        // Any number: an upstream is a reassembler whose frames wait at most
        // UPSTREAM_DEADLINE_US.
        self.upstreams.insert(stream, Upstream::new());
        Ok(())
    }

    /// Stops accepting upstream media on `stream`.
    pub fn remove_upstream(&mut self, stream: u16) {
        self.upstreams.remove(&stream);
    }

    /// The next feedback datagram for an upstream stream (acknowledgement,
    /// NACKs, arrivals for the viewer's congestion controller), or `None`
    /// when none is due. Call again until it returns `None`.
    pub fn upstream_feedback(&mut self, now_us: u64) -> Option<Vec<u8>> {
        self.upstreams.iter_mut().find_map(|(&stream, u)| u.feedback(stream, now_us))
    }

    /// Removes a display stream and its frame state.
    pub fn remove_stream(&mut self, stream: u16) {
        self.streams.remove(&stream);
    }

    /// The target of one stream: popups share at most
    /// [`POPUP_SHARE_PERCENT`] of the controller's target (each at least
    /// [`MIN_POPUP_KBPS`] when the target allows it); the main stream gets the rest.
    fn target_kbps(&self, stream: u16) -> u32 {
        let total = u32::try_from(self.cc.target_bps() / 1000).unwrap_or(u32::MAX);
        let popups = u32::try_from(self.streams.len().saturating_sub(1)).unwrap_or(u32::MAX);
        if popups == 0 {
            return total;
        }
        let share = u32::try_from(u64::from(total) * POPUP_SHARE_PERCENT / 100).unwrap_or(u32::MAX);
        let each = (share / popups).max(MIN_POPUP_KBPS).min(total / (popups + 1));
        if stream == self.cfg.stream { total.saturating_sub(each * popups) } else { each }
    }

    fn request(&mut self, stream: u16, action: FlowAction) -> Option<EncodeRequest> {
        let target_kbps = self.target_kbps(stream);
        let profile = self.cc.profile();
        let state = self.streams.get_mut(&stream)?;
        match action {
            FlowAction::Encode { damage, frame } => {
                // A refinement is only a refinement while no new damage joined it, and never
                // stands in for a keyframe.
                let refine = std::mem::take(&mut state.refine_pending)
                    && profile.is_ultra()
                    && state.force_idr.is_none();
                Some(EncodeRequest {
                    stream,
                    frame,
                    damage,
                    force_idr: state.force_idr.is_some(),
                    idr_reason: state.force_idr,
                    target_kbps,
                    picture: state.ladder.as_ref().map(ResolutionLadder::picture),
                    profile,
                    refine,
                })
            }
            FlowAction::Wait => None,
        }
    }

    /// Ultra: once a stream's refinement is due, its gate gets the whole surface as damage,
    /// marked as a refinement; the gate releases it now or when its cap and in-flight bound
    /// allow, as any frame.
    fn gate_poll(&mut self, stream: u16, now_us: u64) -> Option<FlowAction> {
        let ultra = self.profile.is_ultra();
        let state = self.streams.get_mut(&stream)?;
        let due = state.refine_due_us.is_some_and(|due| now_us >= due);
        if ultra && due && state.tile_of.is_none() {
            state.refine_due_us = None;
            // Damage already waiting in the gate means the screen is not still: that frame
            // goes first, and its `encoded` schedules the refinement again.
            if state.gate.has_pending() {
                return Some(state.gate.poll(now_us));
            }
            state.refine_pending = true;
            let full = state.full();
            return Some(state.gate.damage(full, now_us));
        }
        Some(state.gate.poll(now_us))
    }

    /// The main stream's first frame: the whole surface, an IDR.
    pub fn start(&mut self, now_us: u64) -> Option<EncodeRequest> {
        self.start_probe(ProbeReason::Startup, now_us);
        let main = self.cfg.stream;
        self.damage(main, Rect { x: 0, y: 0, width: 0, height: 0 }, now_us)
    }

    /// New damage from the source on `stream` (`None` for an unknown stream).
    pub fn damage(&mut self, stream: u16, rect: Rect, now_us: u64) -> Option<EncodeRequest> {
        self.follow_target(stream, now_us);
        let state = self.streams.get_mut(&stream)?;
        let rect = if state.started { rect } else { state.full() };
        state.started = true;
        // New damage: this frame is not a refinement, and the next one waits for stillness.
        state.refine_pending = false;
        state.refine_due_us = None;
        let action = state.gate.damage(rect, now_us);
        self.request(stream, action)
    }

    /// Advances time: a frame held by an fps cap may be due (the first one), or (ultra) a
    /// still screen's refinement frame.
    pub fn poll(&mut self, now_us: u64) -> Option<EncodeRequest> {
        let ids: Vec<u16> = self.streams.keys().copied().collect();
        for stream in ids {
            self.follow_target(stream, now_us);
            let action = self.gate_poll(stream, now_us)?;
            if let Some(req) = self.request(stream, action) {
                return Some(req);
            }
        }
        None
    }

    /// Moves `stream`'s resolution ladder to the controller's current target.
    fn follow_target(&mut self, stream: u16, now_us: u64) {
        let bps = u64::from(self.target_kbps(stream)) * 1000;
        let Some(state) = self.streams.get_mut(&stream) else { return };
        let Some(ladder) = state.ladder.as_mut() else { return };
        let before = ladder.picture();
        if let Some(after) = ladder.update(bps, now_us) {
            state.apply_picture(before, after);
        }
    }

    /// The picture `stream` encodes now (`None` without a resolution ladder).
    pub fn picture(&self, stream: u16) -> Option<Picture> {
        self.streams.get(&stream)?.ladder.as_ref().map(ResolutionLadder::picture)
    }

    /// When `poll` or `tick` must run next: a frame held by an fps cap, or
    /// input held behind a gap. `None` while nothing is pending (an idle
    /// source needs no wakeup).
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.streams
            .values()
            .filter_map(|s| s.gate.next_deadline_us())
            .chain(self.applier.next_deadline_us())
            .chain(self.upstreams.values().filter_map(Upstream::next_deadline_us))
            .chain(self.streams.values().filter_map(|s| self.tail_probe_due_us(s)))
            .chain(
                self.streams
                    .values()
                    .filter(|_| self.profile.is_ultra())
                    .filter_map(|s| s.refine_due_us),
            )
            // A startup probe is emitted by the caller's next tick. Once a
            // refinement is scheduled, its media deadline wins so the probe
            // train cannot mask the encoder's one-frame interval.
            .chain(self.probe_due_us().filter(|_| {
                self.profile.is_ultra()
                    && self.frames == 0
                    && !self.streams.values().any(|state| state.refine_due_us.is_some())
            }))
            .chain(
                (self.profile.is_ultra() && self.frames == 0)
                    .then(|| {
                        self.last_probe_start_us.map(|t| t.saturating_add(IDLE_PROBE_INTERVAL_US))
                    })
                    .flatten(),
            )
            .min()
    }

    /// The source encoded `req` (`None` or an empty access unit: nothing to
    /// send, the stream's gate opens again). Returns the frame's datagrams.
    pub fn encoded(
        &mut self,
        req: &EncodeRequest,
        encoded: Option<Encoded>,
        now_us: u64,
    ) -> Result<Output, PacketizeError> {
        let loss = self.loss;
        let idle_link = self.idle_link(now_us);
        let surface_frame = self
            .streams
            .get(&req.stream)
            .and_then(|s| s.tile_of)
            .and_then(|of| self.streams.get(&of))
            .map(|s| if s.last_frame == 0 { REF_NONE } else { s.last_frame });
        let target_bps = u64::from(self.target_kbps(req.stream)) * 1000;
        let Some(state) = self.streams.get_mut(&req.stream) else { return Ok(Output::default()) };
        let Some(enc) = encoded.filter(|e| !e.access_unit.is_empty()) else {
            // The encoder dropped the frame: its change still has to reach the viewer. A drop
            // is not a loss: no rate cut and no keyframe. With a ladder it says the picture is
            // too large for the rate, so the ladder steps down (D3, D5).
            state.gate.clear_in_flight();
            state.gate.requeue(req.damage);
            if let Some(ladder) = state.ladder.as_mut() {
                let before = ladder.picture();
                if let Some(after) = ladder.encoder_dropped(target_bps, now_us) {
                    state.apply_picture(before, after);
                }
            }
            return Ok(Output::default());
        };
        let tile = state.tile_of.is_some();
        let body = FrameBody {
            t_capture_us: enc.t_capture_us,
            ref_frame: match surface_frame {
                Some(video_frame) => video_frame,
                None if enc.idr => REF_NONE,
                None => state.last_frame,
            },
            access_unit: enc.access_unit,
        };
        let data_shards =
            (body.access_unit.len() + FRAME_PREFIX_LEN).div_ceil(self.packetizer.shard_len());
        // Tile frames are standalone, so they get keyframe-grade protection.
        // While the link is away (the controller is frozen through an outage), parity
        // only adds bytes to the burst that waits for the link to come back.
        let parity = if self.cc.frozen() {
            0
        } else {
            let parity = parity_for(data_shards, loss, enc.idr || tile);
            // A one-datagram frame (a key press's) whose only copy is lost waits for
            // the tail probe; on a nearly idle link a second copy is cheaper.
            if data_shards == 1 && idle_link { parity.max(1) } else { parity }
        };
        let flags = if tile {
            flags::TILE
        } else if enc.idr {
            flags::KEYFRAME
        } else {
            0
        };
        self.packetizer.set_stream(req.stream);
        let packets = match self.packetizer.packetize(req.frame, flags, &body, parity) {
            Ok(p) => p,
            Err(PacketizeError::FrameTooLarge) => {
                // Drop it and start over from a keyframe at half the bitrate,
                // instead of ending the session.
                state.force_idr = Some(IdrReason::TooLarge);
                state.gate.clear_in_flight();
                return Ok(Output { halve_bitrate: true, ..Output::default() });
            }
            Err(e) => return Err(e),
        };
        let mut frame_bytes: u64 = 0;
        for (i, d) in packets.datagrams.iter().enumerate() {
            let seq = packets.first_transport_seq.wrapping_add(i as u16);
            self.cc.on_sent_bytes(seq, now_us, d.len());
            self.loss_meter.on_sent(seq);
            frame_bytes = frame_bytes.saturating_add(d.len() as u64);
        }
        self.recent_sends.push_back((now_us, frame_bytes));
        self.recent_bytes = self.recent_bytes.saturating_add(frame_bytes);
        while self.recent_sends.len() > IDLE_COPY_FRAMES {
            if let Some((_, bytes)) = self.recent_sends.pop_front() {
                self.recent_bytes = self.recent_bytes.saturating_sub(bytes);
            }
        }
        if enc.idr && !tile {
            state.last_keyframe_bytes = packets.datagrams.iter().map(Vec::len).sum();
        }
        state.history.insert(req.frame, packets.datagrams.clone());
        state.sent_at_us.insert(req.frame, now_us);
        while state.sent_at_us.len() > HISTORY_FRAMES {
            state.sent_at_us.pop_first();
        }
        while state.departed_at_us.len() > HISTORY_FRAMES {
            state.departed_at_us.pop_first();
        }
        state.last_seq = packets
            .datagrams
            .last()
            .and_then(|d| DatagramHeader::decode(d).ok())
            .map(|(h, _)| h.transport_seq);
        state.unacked_since_us = Some(now_us);
        while state.history.len() > HISTORY_FRAMES {
            state.history.pop_first();
        }
        // Only a frame asked for as a keyframe (or one that is independent anyway) answers a
        // pending keyframe. A recovery that came in while an older P-frame request was still
        // being encoded (or an outage drop that asked for one while a frame was finishing on
        // the encode thread) stays pending, so the next request is the keyframe: clearing it
        // here lost the recovery, and a viewer that moved routes waited for another ask.
        if req.force_idr || enc.idr || tile {
            state.force_idr = None;
        }
        state.last_frame = req.frame;
        // Ultra: a frame that carried damage is refined once the screen stays still for one
        // frame interval; a refinement is the last word until new damage.
        state.refine_due_us = (self.profile.is_ultra() && !req.refine && !tile)
            .then(|| now_us.saturating_add(refine_after_us(self.cfg.max_fps)));
        state.probe_from_us = Some(now_us);
        state.probes = 0;
        self.frames += 1;
        self.keyframes += u64::from(enc.idr && !tile);
        Ok(Output { datagrams: packets.datagrams, ..Output::default() })
    }

    /// One datagram from the viewer. `may_inject` is the session table's
    /// input gate for this viewer now.
    pub fn on_datagram(&mut self, datagram: &[u8], may_inject: bool, now_us: u64) -> Output {
        let mut out = Output::default();
        let Ok((header, payload)) = DatagramHeader::decode(datagram) else { return out };
        match header.kind {
            DatagramKind::Input => {
                let Ok(packet) = InputPacket::decode(payload) else { return out };
                if may_inject {
                    out.inject = self.applier.accept(&packet, now_us);
                    out.release_all = self.applier.take_skipped_gap();
                    self.note_input(&out, now_us);
                } else {
                    // Discard and acknowledge: a view-only viewer stops
                    // repeating, and a late repeat never applies after
                    // control is granted.
                    self.applier.refuse(&packet);
                }
                out.datagrams.push(self.input_ack());
            }
            DatagramKind::Feedback => {
                let Ok(fb) = Feedback::decode(payload) else { return out };
                self.on_feedback(header.stream, &fb, now_us, &mut out);
            }
            DatagramKind::UpMedia => {
                let rtt = self.rtt_us();
                if let Some(u) = self.upstreams.get_mut(&header.stream) {
                    let stream = header.stream;
                    // The viewer's repairs cross the same path: size the wait from it too.
                    u.reassembler.set_path_rtt_us(rtt);
                    out.upstream =
                        u.push(&header, payload, now_us).into_iter().map(|f| (stream, f)).collect();
                }
            }
            DatagramKind::ClockPing => {
                let Ok(ping) = ClockPing::decode(payload) else { return out };
                if ping.estimate.is_some() {
                    self.clock = ping.estimate;
                }
                out.datagrams.push(self.clock_pong(&ping, now_us));
            }
            _ => {}
        }
        out
    }

    /// Feedback of one stream: arrivals and loss feed the shared controller;
    /// NACKs, acks and recovery requests apply to that stream.
    fn on_feedback(&mut self, stream: u16, fb: &Feedback, now_us: u64, out: &mut Output) {
        let settled =
            self.loss_meter.on_arrivals(fb.arrivals.iter().map(|a| a.transport_seq), now_us);
        if let Some(lost) = settled {
            self.loss = 0.8 * self.loss + 0.2 * lost;
        }
        let congestion_loss = self.loss_meter.take_congestion_loss(now_us).unwrap_or(0.0);
        self.cc.on_feedback(&fb.arrivals, congestion_loss, now_us);
        if let Some(end) = self.cc.take_outage_end() {
            for state in self.streams.values_mut() {
                state.gate.clear_in_flight();
            }
            out.outage_ended = Some(end);
        }
        if let Some(estimate) = self.probe_planner.on_feedback(now_us, &fb.arrivals)
            && self.probe_generation.is_some_and(|generation| {
                self.cc.on_probe_capacity(generation, estimate.capacity_bps)
            })
        {
            self.last_probe_start_us = Some(now_us);
        }
        self.last_feedback_us = now_us;
        let Some(state) = self.streams.get_mut(&stream) else { return };
        if fb.acked_frame > 0
            && let Some(sent_at_us) = state.sent_at_us.remove(&fb.acked_frame)
        {
            let sample = now_us.saturating_sub(sent_at_us);
            // The probe's round trip counts from the frame's last departure, so a
            // large frame's pacing does not stretch it; a probed frame has no entry.
            let probed = state.probes > 0 && fb.acked_frame == state.last_frame;
            let probe_sample = match state.departed_at_us.get(&fb.acked_frame) {
                Some(&departed) => Some(now_us.saturating_sub(departed)),
                None if !probed => Some(sample),
                None => None,
            };
            // Sample each cumulative ACK once. Repeated keepalives and reordered
            // feedback must not turn an old frame's age into a new RTT sample.
            state.sent_at_us.retain(|frame, _| *frame > fb.acked_frame);
            state.departed_at_us.retain(|frame, _| *frame > fb.acked_frame);
            if let Some(s) = probe_sample {
                match self.ack_srtt_us {
                    None => {
                        self.ack_srtt_us = Some(s);
                        self.ack_rttvar_us = s / 2;
                    }
                    Some(srtt) => {
                        self.ack_rttvar_us = (3 * self.ack_rttvar_us + srtt.abs_diff(s)) / 4;
                        self.ack_srtt_us = Some((7 * srtt + s) / 8);
                    }
                }
            }
            self.ack_rtts.retain(|(at, _)| now_us.saturating_sub(*at) <= ACK_RTT_WINDOW_US);
            self.ack_rtts.push_back((now_us, sample));
            while self.ack_rtts.len() > ACK_RTT_SAMPLES {
                self.ack_rtts.pop_front();
            }
        }
        // While the path is away (D12) only the newest frame is repaired, as an outage
        // end sends only the newest frame: an older frame's resend lands in the hold's
        // burst behind it, while the newest one is what the viewer waits on (a key press's
        // echo lost in the hold would otherwise wait for the path to be proven back).
        let away = self.cc.frozen();
        let mut budget = MAX_RESENDS_PER_FEEDBACK;
        for nack in &fb.nacks {
            if away && nack.frame != state.last_frame {
                continue;
            }
            let Some(datagrams) = state.history.get(&nack.frame) else { continue };
            for &i in &nack.indexes {
                if budget == 0 {
                    break;
                }
                if let Some(d) = datagrams.get(usize::from(i)) {
                    if let Ok((header, _)) = DatagramHeader::decode(d) {
                        self.cc.on_retransmitted(header.transport_seq);
                        // The viewer reports the repair under this sequence: count the
                        // original as path loss now.
                        self.loss_meter.on_resent(header.transport_seq);
                    }
                    out.datagrams.push(d.clone());
                    budget -= 1;
                }
            }
        }
        let idr_allowed = state
            .last_forced_idr_us
            .is_none_or(|t| now_us.saturating_sub(t) >= MIN_FORCED_IDR_INTERVAL_US);
        // While the path is away (D12) a keyframe would only join the hold; the viewer
        // keeps asking until a frame it can decode arrives, so the ask waits for the path.
        if fb.need_recovery && idr_allowed && !self.cc.frozen() {
            // Set the keyframe up before the gate polls, so the one poll below hands it out.
            // Polling twice (ack, then damage) let the ack hand pending damage a frame number
            // and the second poll answer Wait over it: that frame was never encoded.
            state.last_forced_idr_us = Some(now_us);
            state.force_idr = Some(IdrReason::Recovery);
            state.gate.clear_in_flight();
            let full = state.full();
            state.gate.requeue(full);
        }
        let action = state.gate.ack(fb.acked_frame, now_us);
        out.encode = self.request(stream, action);
    }

    /// Tail-loss recovery: a stream whose newest frame has gone unacknowledged
    /// for [`TAIL_PROBE_US`] gets that frame resent, up to [`TAIL_PROBES`] times;
    /// then the gate opens for a keyframe. With `rtt_tail_probe` the probes come a
    /// round trip apart, backing off, and the keyframe at the same time as without.
    /// An ack ends it (the gate has nothing in flight), so a stream that is
    /// acknowledged never probes.
    fn probe_tails(&mut self, now_us: u64, out: &mut Output) {
        let ids: Vec<u16> = self.streams.keys().copied().collect();
        let rtt_probe = self.cfg.rtt_tail_probe;
        for stream in ids {
            let due = self.streams.get(&stream).and_then(|s| self.tail_probe_due_us(s));
            let Some(state) = self.streams.get_mut(&stream) else { continue };
            if state.gate.in_flight() == 0 {
                state.probe_from_us = None;
                state.unacked_since_us = None;
                continue;
            }
            let Some(due) = due else { continue };
            if now_us < due {
                continue;
            }
            if self.cc.frozen() {
                // The path is away (D12): a probe would only join the hold. The wait
                // starts over when it is back, and a long hold spends no probes.
                state.probe_from_us = Some(now_us);
                if rtt_probe {
                    state.unacked_since_us = Some(now_us);
                }
                continue;
            }
            let probe = if rtt_probe {
                state
                    .unacked_since_us
                    .is_none_or(|since| now_us.saturating_sub(since) < Self::probe_give_up_us())
            } else {
                state.probes < TAIL_PROBES
            };
            if probe {
                state.probes = state.probes.saturating_add(1);
                state.probe_from_us = Some(now_us);
                // The ack of a probed frame may answer either copy: no RTT sample.
                state.departed_at_us.remove(&state.last_frame);
                if let Some(datagrams) = state.history.get(&state.last_frame) {
                    for d in datagrams.iter().take(MAX_RESENDS_PER_FEEDBACK) {
                        if let Ok((header, _)) = DatagramHeader::decode(d) {
                            self.cc.on_retransmitted(header.transport_seq);
                        }
                        out.datagrams.push(d.clone());
                    }
                }
                continue;
            }
            // One encode per tick: a second stream's keyframe waits for the next.
            if out.encode.is_some() {
                continue;
            }
            state.probe_from_us = None;
            state.unacked_since_us = None;
            state.last_forced_idr_us = Some(now_us);
            state.force_idr = Some(IdrReason::TailProbe);
            state.gate.clear_in_flight();
            let full = state.full();
            let action = state.gate.damage(full, now_us);
            out.encode = self.request(stream, action);
        }
    }

    /// Advances time for input: a missing event is skipped after its timeout.
    pub fn tick(&mut self, may_inject: bool, now_us: u64) -> Output {
        let mut out = Output::default();
        for (&stream, u) in &mut self.upstreams {
            let released = u.reassembler.tick(now_us);
            u.released_since_feedback |= !released.is_empty();
            out.upstream.extend(released.into_iter().map(|f| (stream, f)));
        }
        self.emit_probe(now_us, &mut out);
        if self.profile.is_ultra() && self.probe_planner.active().is_none() && self.idle(now_us) {
            let due = self
                .last_probe_start_us
                .is_none_or(|started| now_us.saturating_sub(started) >= IDLE_PROBE_INTERVAL_US);
            if due {
                self.start_probe(ProbeReason::Idle, now_us);
                self.emit_probe(now_us, &mut out);
            }
        }
        self.probe_tails(now_us, &mut out);
        let events = self.applier.tick(now_us);
        if may_inject {
            out.inject = events;
            out.release_all = self.applier.take_skipped_gap();
            self.note_input(&out, now_us);
        }
        out
    }

    fn idle(&self, _now_us: u64) -> bool {
        self.streams.values().all(|state| state.gate.in_flight() == 0)
    }

    fn start_probe(&mut self, reason: ProbeReason, now_us: u64) {
        if !self.profile.is_ultra() || self.probe_planner.active().is_some() {
            return;
        }
        if self.probe_planner.start(reason, now_us).is_some() {
            self.probe_generation = Some(self.cc.probe_generation());
            self.last_probe_start_us = Some(now_us);
        }
    }

    /// When the active train's next datagram may leave; `None` once the whole train left
    /// (it then only waits for feedback) or with no train.
    fn probe_due_us(&self) -> Option<u64> {
        self.probe_planner
            .active()
            .filter(|train| train.emitted_packets < train.packet_count)
            .and_then(|_| self.probe_planner.next_deadline_us())
    }

    /// Emits the whole due probe train in one tick. The host wakes at millisecond
    /// granularity, so a train spaced below that would leave one datagram per wakeup and
    /// measure the wakeup rate, not the path. The train leaves back to back instead (at
    /// most `MAX_PROBE_BYTES`); the planner times each datagram from its socket departure
    /// (`datagram_sent`) and reads the path's capacity from the arrival dispersion. The
    /// planner's spacing then only orders the enqueue stamps.
    fn emit_probe(&mut self, now_us: u64, out: &mut Output) {
        let Some(first) = self.probe_due_us() else { return };
        if now_us < first {
            return;
        }
        while let Some(due) = self.probe_due_us() {
            let seq = self.packetizer.reserve_transport_seq(1);
            let Some(probe) = self.probe_planner.next_packet(due.max(now_us), seq) else { return };
            self.cc.on_sent_bytes(probe.transport_seq, now_us, probe.bytes.len());
            out.datagrams.push(probe.bytes);
        }
    }

    /// Input goes to the source now: with `input_frame_now`, every stream's gate opens its
    /// input window.
    fn note_input(&mut self, out: &Output, now_us: u64) {
        if self.cfg.input_frame_now && !out.inject.is_empty() {
            for state in self.streams.values_mut() {
                state.gate.input(now_us);
            }
        }
    }

    /// Forgets held input (control ended or the session stopped); the source
    /// releases every key and button it holds.
    pub fn reset_input(&mut self) {
        self.applier.reset();
    }

    /// The viewer's latest clock estimate (host = viewer + offset), from its
    /// pings (rd change C8); `None` until the viewer has one.
    pub fn clock(&self) -> Option<ClockEstimate> {
        self.clock
    }

    /// How long the viewer has sent no feedback.
    pub fn silent_for_us(&self, now_us: u64) -> u64 {
        now_us.saturating_sub(self.last_feedback_us)
    }

    /// Whether D12 has classified the feedback path as Away. While frozen, the
    /// host keeps its bitrate and lets the bounded media queue apply newest-wins
    /// replacement instead of holding the encoder behind stale queue depth.
    pub fn outage_frozen(&self) -> bool {
        self.cc.frozen()
    }

    pub fn stats(&self) -> EngineStats {
        EngineStats {
            frames: self.frames,
            keyframes: self.keyframes,
            loss: self.loss,
            target_bps: self.cc.target_bps(),
        }
    }

    /// Returns the minimum recent cumulative frame-ack RTT. The history ages
    /// out when a new ACK advances, so an earlier short route cannot constrain
    /// a slower route for the rest of the session.
    /// True while the frames sent over the last [`IDLE_COPY_WINDOW_US`] are
    /// under [`IDLE_COPY_PERCENT`] of the controller's target, so a small
    /// frame may go out with a copy. Forgets frames older than the window.
    fn idle_link(&mut self, now_us: u64) -> bool {
        while let Some(&(at, bytes)) = self.recent_sends.front() {
            if now_us.saturating_sub(at) < IDLE_COPY_WINDOW_US {
                break;
            }
            self.recent_sends.pop_front();
            self.recent_bytes = self.recent_bytes.saturating_sub(bytes);
        }
        // A full history may have dropped frames still inside the window: not idle.
        if self.recent_sends.len() >= IDLE_COPY_FRAMES {
            return false;
        }
        let window_bits = self.recent_bytes.saturating_mul(8).saturating_mul(100);
        // The window is one second, so the target's bits per second are its bits.
        window_bits < self.cc.target_bps().saturating_mul(IDLE_COPY_PERCENT)
    }

    pub fn ack_rtt_us(&self) -> Option<u64> {
        self.ack_rtts.iter().map(|(_, rtt)| *rtt).min()
    }

    /// The round trip the viewer-input (upstream) NACK wait is sized from: the
    /// larger of the carrier's path round trip and the smoothed frame-ack
    /// round trip plus four times its variation (`ack_srtt_us`). The host's
    /// own recovery timers ([`TAIL_PROBE_US`], [`MIN_FORCED_IDR_INTERVAL_US`])
    /// stay fixed: sized from the round trip, the tail probe fired inside
    /// 50-100 ms Wi-Fi holds and its resends and keyframes burst out when the
    /// hold lifted (about +50 ms on slow presses).
    pub fn rtt_us(&self) -> Option<u64> {
        let acks = self.ack_srtt_us.map(|s| s.saturating_add(self.ack_rttvar_us.saturating_mul(4)));
        match (self.path_rtt_us, acks) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (a, b) => a.or(b),
        }
    }

    /// Answers a clock ping at once (receive and send time are the same call).
    fn clock_pong(&mut self, ping: &ClockPing, now_us: u64) -> Vec<u8> {
        let pong = ClockPong {
            seq: ping.seq,
            t_viewer_us: ping.t_viewer_us,
            t_host_rx_us: now_us,
            t_host_tx_us: now_us,
        };
        let header = DatagramHeader {
            flags: 0,
            kind: DatagramKind::ClockPong,
            stream: 0,
            frame: 0,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: 0,
        };
        let mut d = Vec::with_capacity(HEADER_LEN + 28);
        header.encode_into(&mut d);
        d.extend_from_slice(&pong.encode());
        d
    }

    fn input_ack(&mut self) -> Vec<u8> {
        let header = DatagramHeader {
            flags: 0,
            kind: DatagramKind::InputAck,
            stream: 0,
            frame: 0,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: self.packetizer.reserve_transport_seq(1),
        };
        let mut d = Vec::with_capacity(HEADER_LEN + 4);
        header.encode_into(&mut d);
        d.extend_from_slice(&self.applier.applied().to_le_bytes());
        d
    }
}

/// Frames in flight for a path with this round trip at this frame rate: enough to
/// cover the round trip plus one being encoded, bounded by the viewer's measured
/// reassembly queue. This is the frame-space equivalent of a BDP window. The
/// bound leaves queue depth and pending-payload headroom for loss and reordering.
pub fn frames_in_flight_for(rtt_us: u64, max_fps: u32) -> u32 {
    let interval_us = 1_000_000 / u64::from(max_fps.max(1));
    let covering = rtt_us.div_ceil(interval_us.max(1));
    covering.saturating_add(1).min(u64::from(MAX_FRAMES_IN_FLIGHT)) as u32
}
