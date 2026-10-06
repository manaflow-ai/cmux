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
    /// The display stream this engine sends (0 for the main surface).
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

/// Counters for the stats control message.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EngineStats {
    pub frames: u64,
    pub keyframes: u64,
    /// Smoothed loss fraction, 0 to 1.
    pub loss: f64,
    pub target_bps: u64,
}

/// The media state of one viewer of one source.
#[derive(Debug)]
pub struct MediaEngine {
    cfg: EngineConfig,
    gate: FrameGate,
    cc: CongestionController,
    packetizer: Packetizer,
    applier: InputApplier,
    history: BTreeMap<u32, Vec<Vec<u8>>>,
    loss_meter: LossMeter,
    loss: f64,
    last_frame: u32,
    force_idr: bool,
    last_forced_idr_us: Option<u64>,
    last_feedback_us: u64,
    frames: u64,
    keyframes: u64,
}

impl MediaEngine {
    pub fn new(cfg: EngineConfig, now_us: u64) -> Self {
        let cc_cfg =
            CcConfig { start_bps: cfg.start_bps, max_bps: cfg.max_bps, ..CcConfig::default() };
        Self {
            gate: FrameGate::new(1, cfg.max_fps.max(1)),
            cc: CongestionController::new(cc_cfg, cfg.path),
            packetizer: Packetizer::new(cfg.stream, cfg.max_datagram),
            applier: InputApplier::new(cfg.input_gap_timeout_us),
            history: BTreeMap::new(),
            loss_meter: LossMeter::default(),
            loss: 0.0,
            last_frame: 0,
            force_idr: true,
            last_forced_idr_us: None,
            last_feedback_us: now_us,
            frames: 0,
            keyframes: 0,
            cfg,
        }
    }

    fn full(&self) -> Rect {
        Rect { x: 0, y: 0, width: self.cfg.width, height: self.cfg.height }
    }

    fn request(&self, action: FlowAction) -> Option<EncodeRequest> {
        match action {
            FlowAction::Encode { damage, frame } => Some(EncodeRequest {
                frame,
                damage,
                force_idr: self.force_idr,
                target_kbps: u32::try_from(self.cc.target_bps() / 1000).unwrap_or(u32::MAX),
            }),
            FlowAction::Wait => None,
        }
    }

    /// The first frame: the whole surface, an IDR.
    pub fn start(&mut self, now_us: u64) -> Option<EncodeRequest> {
        let action = self.gate.damage(self.full(), now_us);
        self.request(action)
    }

    /// New damage from the source.
    pub fn damage(&mut self, rect: Rect, now_us: u64) -> Option<EncodeRequest> {
        let action = self.gate.damage(rect, now_us);
        self.request(action)
    }

    /// Advances time: a frame held by the fps cap may be due.
    pub fn poll(&mut self, now_us: u64) -> Option<EncodeRequest> {
        let action = self.gate.poll(now_us);
        self.request(action)
    }

    /// When `poll` or `tick` must run next (the fps cap or a held input gap).
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.gate.next_deadline_us()
    }

    /// The source encoded `req` (`None` or an empty access unit: nothing to
    /// send, the gate opens again). Returns the frame's datagrams.
    pub fn encoded(
        &mut self,
        req: &EncodeRequest,
        encoded: Option<Encoded>,
        now_us: u64,
    ) -> Result<Output, PacketizeError> {
        let Some(enc) = encoded.filter(|e| !e.access_unit.is_empty()) else {
            self.gate.clear_in_flight();
            return Ok(Output::default());
        };
        let body = FrameBody {
            t_capture_us: enc.t_capture_us,
            ref_frame: if enc.idr { REF_NONE } else { self.last_frame },
            access_unit: enc.access_unit,
        };
        let data_shards =
            (body.access_unit.len() + FRAME_PREFIX_LEN).div_ceil(self.packetizer.shard_len());
        let parity = parity_for(data_shards, self.loss, enc.idr);
        let flags = if enc.idr { flags::KEYFRAME } else { 0 };
        let packets = match self.packetizer.packetize(req.frame, flags, &body, parity) {
            Ok(p) => p,
            Err(PacketizeError::FrameTooLarge) => {
                // Drop it and start over from a keyframe at half the bitrate,
                // instead of ending the session.
                self.force_idr = true;
                self.gate.clear_in_flight();
                return Ok(Output { halve_bitrate: true, ..Output::default() });
            }
            Err(e) => return Err(e),
        };
        for i in 0..packets.datagrams.len() {
            let seq = packets.first_transport_seq.wrapping_add(i as u16);
            self.cc.on_sent(seq, now_us);
            self.loss_meter.on_sent(seq);
        }
        self.history.insert(req.frame, packets.datagrams.clone());
        while self.history.len() > HISTORY_FRAMES {
            self.history.pop_first();
        }
        self.force_idr = false;
        self.last_frame = req.frame;
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
                self.on_feedback(&fb, now_us, &mut out);
            }
            _ => {}
        }
        out
    }

    fn on_feedback(&mut self, fb: &Feedback, now_us: u64, out: &mut Output) {
        let settled = self.loss_meter.on_arrivals(fb.arrivals.iter().map(|a| a.transport_seq));
        if let Some(lost) = settled {
            self.loss = 0.8 * self.loss + 0.2 * lost;
        }
        self.cc.on_feedback(&fb.arrivals, settled.unwrap_or(0.0), now_us);
        self.last_feedback_us = now_us;
        let mut budget = MAX_RESENDS_PER_FEEDBACK;
        for nack in &fb.nacks {
            let Some(datagrams) = self.history.get(&nack.frame) else { continue };
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
        let mut action = self.gate.ack(fb.acked_frame, now_us);
        let idr_allowed = self
            .last_forced_idr_us
            .is_none_or(|t| now_us.saturating_sub(t) >= MIN_FORCED_IDR_INTERVAL_US);
        if fb.need_recovery && idr_allowed {
            self.last_forced_idr_us = Some(now_us);
            self.force_idr = true;
            self.gate.clear_in_flight();
            action = self.gate.damage(self.full(), now_us);
        }
        out.encode = self.request(action);
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
