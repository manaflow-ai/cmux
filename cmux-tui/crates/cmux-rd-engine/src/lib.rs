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

mod loss;

use std::collections::BTreeMap;

use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_core::flow::{FlowAction, FrameGate, Rect};
use cmux_rd_core::input::InputApplier;
use cmux_rd_core::packetize::{PacketizeError, Packetizer, parity_for};
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, FRAME_PREFIX_LEN, Feedback, FrameBody, HEADER_LEN, InputEvent,
    InputPacket, MAX_DATAGRAM_VPC, REF_NONE, flags,
};

pub use loss::LossMeter;

/// Frames kept for NACK resends.
pub const HISTORY_FRAMES: usize = 16;
/// Datagrams resent per feedback, so a hostile feedback cannot amplify.
pub const MAX_RESENDS_PER_FEEDBACK: usize = 64;
/// Shortest time between two forced keyframes.
pub const MIN_FORCED_IDR_INTERVAL_US: u64 = 250_000;
/// Most streams per peer (the viewer's CMUX_RD_SESSION_MAX_STREAMS).
pub const MAX_STREAMS: usize = 16;
/// Share of the target that popup streams may take together, in percent.
pub const POPUP_SHARE_PERCENT: u64 = 20;
/// Floor of one popup stream's bitrate.
pub const MIN_POPUP_KBPS: u32 = 300;

/// Limits of one media session.
#[derive(Debug, Clone, Copy)]
pub struct EngineConfig {
    /// The streamed size; the first frame and recovery frames cover all of it.
    pub width: u32,
    pub height: u32,
    pub max_fps: u32,
    pub start_bps: u64,
    pub max_bps: u64,
    /// The link's datagram size for this session (1152 or 1332).
    pub max_datagram: usize,
    /// The path class until the link reports path events.
    pub path: PathKind,
    /// How long a missing input event may block later ones.
    pub input_gap_timeout_us: u64,
    /// The main display stream (0 by convention); more with `add_stream`.
    pub stream: u16,
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
            max_datagram: MAX_DATAGRAM_VPC,
            path: PathKind::ViaCloudRegion,
            input_gap_timeout_us: 200_000,
            stream: 0,
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
    /// The congestion controller's target for this frame.
    pub target_kbps: u32,
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
}

/// Why a stream cannot be added.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamError {
    /// The stream id is in use.
    Exists(u16),
    /// The session already has the most streams a viewer accepts.
    TooMany,
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

/// One display stream: its own frame gate, NACK history and keyframe state.
#[derive(Debug)]
struct StreamState {
    width: u32,
    height: u32,
    gate: FrameGate,
    history: BTreeMap<u32, Vec<Vec<u8>>>,
    last_frame: u32,
    force_idr: bool,
    last_forced_idr_us: Option<u64>,
    /// The first damage covers the whole stream.
    started: bool,
}

impl StreamState {
    fn new(width: u32, height: u32, max_fps: u32) -> Self {
        Self {
            width,
            height,
            gate: FrameGate::new(1, max_fps.max(1)),
            history: BTreeMap::new(),
            last_frame: 0,
            force_idr: true,
            last_forced_idr_us: None,
            started: false,
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
}

impl MediaEngine {
    pub fn new(cfg: EngineConfig, now_us: u64) -> Self {
        let cc_cfg =
            CcConfig { start_bps: cfg.start_bps, max_bps: cfg.max_bps, ..CcConfig::default() };
        let mut streams = BTreeMap::new();
        streams.insert(cfg.stream, StreamState::new(cfg.width, cfg.height, cfg.max_fps));
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
            cfg,
        }
    }

    /// Adds a display stream (a popup surface) of `width` x `height`. Its
    /// first damage covers the whole stream and is an IDR.
    pub fn add_stream(&mut self, stream: u16, width: u32, height: u32) -> Result<(), StreamError> {
        if self.streams.contains_key(&stream) {
            return Err(StreamError::Exists(stream));
        }
        if self.streams.len() >= MAX_STREAMS {
            return Err(StreamError::TooMany);
        }
        self.streams.insert(stream, StreamState::new(width, height, self.cfg.max_fps));
        Ok(())
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

    fn request(&self, stream: u16, action: FlowAction) -> Option<EncodeRequest> {
        let state = self.streams.get(&stream)?;
        match action {
            FlowAction::Encode { damage, frame } => Some(EncodeRequest {
                stream,
                frame,
                damage,
                force_idr: state.force_idr,
                target_kbps: self.target_kbps(stream),
            }),
            FlowAction::Wait => None,
        }
    }

    /// The main stream's first frame: the whole surface, an IDR.
    pub fn start(&mut self, now_us: u64) -> Option<EncodeRequest> {
        let main = self.cfg.stream;
        self.damage(main, Rect { x: 0, y: 0, width: 0, height: 0 }, now_us)
    }

    /// New damage from the source on `stream` (`None` for an unknown stream).
    pub fn damage(&mut self, stream: u16, rect: Rect, now_us: u64) -> Option<EncodeRequest> {
        let state = self.streams.get_mut(&stream)?;
        let rect = if state.started { rect } else { state.full() };
        state.started = true;
        let action = state.gate.damage(rect, now_us);
        self.request(stream, action)
    }

    /// Advances time: a frame held by an fps cap may be due (the first one).
    pub fn poll(&mut self, now_us: u64) -> Option<EncodeRequest> {
        let ids: Vec<u16> = self.streams.keys().copied().collect();
        for stream in ids {
            let action = self.streams.get_mut(&stream).map(|s| s.gate.poll(now_us))?;
            if let Some(req) = self.request(stream, action) {
                return Some(req);
            }
        }
        None
    }

    /// When `poll` or `tick` must run next: a frame held by an fps cap, or
    /// input held behind a gap. `None` while nothing is pending (an idle
    /// source needs no wakeup).
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.streams
            .values()
            .filter_map(|s| s.gate.next_deadline_us())
            .chain(self.applier.next_deadline_us())
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
        let Some(state) = self.streams.get_mut(&req.stream) else { return Ok(Output::default()) };
        let Some(enc) = encoded.filter(|e| !e.access_unit.is_empty()) else {
            state.gate.clear_in_flight();
            return Ok(Output::default());
        };
        let body = FrameBody {
            t_capture_us: enc.t_capture_us,
            ref_frame: if enc.idr { REF_NONE } else { state.last_frame },
            access_unit: enc.access_unit,
        };
        let data_shards =
            (body.access_unit.len() + FRAME_PREFIX_LEN).div_ceil(self.packetizer.shard_len());
        let parity = parity_for(data_shards, loss, enc.idr);
        let flags = if enc.idr { flags::KEYFRAME } else { 0 };
        self.packetizer.set_stream(req.stream);
        let packets = match self.packetizer.packetize(req.frame, flags, &body, parity) {
            Ok(p) => p,
            Err(PacketizeError::FrameTooLarge) => {
                // Drop it and start over from a keyframe at half the bitrate,
                // instead of ending the session.
                state.force_idr = true;
                state.gate.clear_in_flight();
                return Ok(Output { halve_bitrate: true, ..Output::default() });
            }
            Err(e) => return Err(e),
        };
        for i in 0..packets.datagrams.len() {
            let seq = packets.first_transport_seq.wrapping_add(i as u16);
            self.cc.on_sent(seq, now_us);
            self.loss_meter.on_sent(seq);
        }
        state.history.insert(req.frame, packets.datagrams.clone());
        while state.history.len() > HISTORY_FRAMES {
            state.history.pop_first();
        }
        state.force_idr = false;
        state.last_frame = req.frame;
        self.frames += 1;
        self.keyframes += u64::from(enc.idr);
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
            _ => {}
        }
        out
    }

    /// Feedback of one stream: arrivals and loss feed the shared controller;
    /// NACKs, acks and recovery requests apply to that stream.
    fn on_feedback(&mut self, stream: u16, fb: &Feedback, now_us: u64, out: &mut Output) {
        let settled = self.loss_meter.on_arrivals(fb.arrivals.iter().map(|a| a.transport_seq));
        if let Some(lost) = settled {
            self.loss = 0.8 * self.loss + 0.2 * lost;
        }
        self.cc.on_feedback(&fb.arrivals, settled.unwrap_or(0.0), now_us);
        self.last_feedback_us = now_us;
        let Some(state) = self.streams.get_mut(&stream) else { return };
        let mut budget = MAX_RESENDS_PER_FEEDBACK;
        for nack in &fb.nacks {
            let Some(datagrams) = state.history.get(&nack.frame) else { continue };
            for &i in &nack.indexes {
                if budget == 0 {
                    break;
                }
                if let Some(d) = datagrams.get(usize::from(i)) {
                    out.datagrams.push(d.clone());
                    budget -= 1;
                }
            }
        }
        let mut action = state.gate.ack(fb.acked_frame, now_us);
        let idr_allowed = state
            .last_forced_idr_us
            .is_none_or(|t| now_us.saturating_sub(t) >= MIN_FORCED_IDR_INTERVAL_US);
        if fb.need_recovery && idr_allowed {
            state.last_forced_idr_us = Some(now_us);
            state.force_idr = true;
            state.gate.clear_in_flight();
            let full = state.full();
            action = state.gate.damage(full, now_us);
        }
        out.encode = self.request(stream, action);
    }

    /// Advances time for input: a missing event is skipped after its timeout.
    pub fn tick(&mut self, may_inject: bool, now_us: u64) -> Output {
        let mut out = Output::default();
        let events = self.applier.tick(now_us);
        if may_inject {
            out.inject = events;
            out.release_all = self.applier.take_skipped_gap();
        }
        out
    }

    /// Forgets held input (control ended or the session stopped); the source
    /// releases every key and button it holds.
    pub fn reset_input(&mut self) {
        self.applier.reset();
    }

    /// How long the viewer has sent no feedback.
    pub fn silent_for_us(&self, now_us: u64) -> u64 {
        now_us.saturating_sub(self.last_feedback_us)
    }

    pub fn stats(&self) -> EngineStats {
        EngineStats {
            frames: self.frames,
            keyframes: self.keyframes,
            loss: self.loss,
            target_bps: self.cc.target_bps(),
        }
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
