//! The viewer's sender for one upstream media stream (rd change C4b):
//! microphone, camera or screen share frames go to the host as `UpMedia`
//! shards with adaptive FEC. The host's upstream feedback (acked frame,
//! NACKs, arrival times) drives a delay-gradient congestion controller, a
//! pacing budget at its target bitrate, NACK resends from a bounded history
//! and keyframe requests. Nothing is queued to catch up: a frame over the
//! budget is dropped, and a stream with references then waits for the next
//! independent frame.

use std::collections::BTreeMap;

use cmux_rd_proto::{
    DatagramHeader, DatagramKind, DecodeError, FRAME_PREFIX_LEN, Feedback, FrameBody, REF_NONE,
    flags,
};

use crate::cc::{CcConfig, CongestionController, PathKind};
use crate::loss::LossMeter;
use crate::packetize::{PacketizeError, Packetizer, parity_for};

/// Frames kept for NACK resends.
pub const HISTORY_FRAMES: usize = 32;
/// Most datagram bytes kept for NACK resends.
pub const HISTORY_BYTES: usize = 2 << 20;
/// Datagrams resent per feedback, so a hostile feedback cannot amplify.
pub const MAX_RESENDS_PER_FEEDBACK: usize = 64;
/// Without feedback for this long while a frame is unacknowledged, the
/// sender paces at the controller's floor (the host or the path is gone).
pub const FEEDBACK_TIMEOUT_US: u64 = 500_000;
/// The pacing budget holds at most this much time at the target bitrate.
pub const BURST_US: u64 = 100_000;
/// The host asks for recovery in every feedback until it releases a
/// keyframe. A request is honored again only once the host acknowledged the
/// last independent frame or this long after it went out (it was lost).
pub const KEYFRAME_RETRY_US: u64 = 300_000;

/// Limits of one upstream stream.
#[derive(Debug, Clone, Copy)]
pub struct UpstreamConfig {
    /// The upstream stream id the host registered (`add_upstream`).
    pub stream: u16,
    /// The link's datagram size for this session (1152 or 1332).
    pub max_datagram: usize,
    pub cc: CcConfig,
    pub path: PathKind,
    /// Block FEC (Reed-Solomon parity) on a lossy path. Off for audio, which
    /// carries its own in-band FEC (Opus) and whose packets fit one shard.
    pub fec: bool,
}

/// Why a datagram from the host was not taken.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpstreamError {
    /// The bytes are not valid `cmux.rd/1` feedback.
    Invalid(DecodeError),
    /// A valid datagram that is not feedback for this stream.
    NotMine,
}

/// Counters for the status line.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UpstreamStats {
    pub frames_sent: u64,
    pub frames_dropped: u64,
    /// Newest frame the host completed (0 = none yet).
    pub acked_frame: u32,
    /// Smoothed loss fraction, 0 to 1.
    pub loss: f64,
    pub keyframe_requested: bool,
}

/// Sender state for one upstream stream.
#[derive(Debug)]
pub struct UpstreamSender {
    stream: u16,
    min_bps: u64,
    fec: bool,
    packetizer: Packetizer,
    cc: CongestionController,
    loss_meter: LossMeter,
    loss: f64,
    /// Number of the next frame sent (frame 0 means "none" in feedback).
    next_frame: u32,
    /// The newest frame sent, which the next dependent frame references.
    last_sent: Option<u32>,
    acked_frame: u32,
    /// A local drop broke the reference chain: dependent frames are dropped
    /// until an independent one.
    chain_broken: bool,
    keyframe_requested: bool,
    history: BTreeMap<u32, Vec<Vec<u8>>>,
    history_bytes: usize,
    /// Pacing budget in bits; may go negative after a large frame.
    budget_bits: i64,
    last_refill_us: Option<u64>,
    /// Last feedback, or the first send after the stream was idle.
    last_heard_us: Option<u64>,
    /// The newest independent frame sent and when.
    last_independent: Option<(u32, u64)>,
    frames_sent: u64,
    frames_dropped: u64,
}

impl UpstreamSender {
    pub fn new(config: UpstreamConfig) -> Self {
        let mut packetizer = Packetizer::new(config.stream, config.max_datagram);
        packetizer.set_upstream(true);
        Self {
            stream: config.stream,
            min_bps: config.cc.min_bps,
            fec: config.fec,
            packetizer,
            cc: CongestionController::new(config.cc, config.path),
            loss_meter: LossMeter::default(),
            loss: 0.0,
            next_frame: 1,
            last_sent: None,
            acked_frame: 0,
            // The encoder's first frame must be independent.
            chain_broken: true,
            keyframe_requested: true,
            history: BTreeMap::new(),
            history_bytes: 0,
            budget_bits: 0,
            last_refill_us: None,
            last_heard_us: None,
            last_independent: None,
            frames_sent: 0,
            frames_dropped: 0,
        }
    }

    /// The upstream stream id.
    pub fn stream(&self) -> u16 {
        self.stream
    }

    /// The bitrate the encoder should aim for at `now_us`: the controller's
    /// target, or its floor while the host has been silent for
    /// [`FEEDBACK_TIMEOUT_US`] with a frame unacknowledged.
    pub fn target_bps(&self, now_us: u64) -> u64 {
        if self.stale(now_us) {
            self.min_bps.min(self.cc.target_bps())
        } else {
            self.cc.target_bps()
        }
    }

    /// Whether the encoder should make its next frame independent (a
    /// keyframe): after a local drop or when the host asked for recovery.
    pub fn keyframe_requested(&self) -> bool {
        self.keyframe_requested
    }

    /// A path change resets the delay baseline and applies relay caps.
    pub fn set_path(&mut self, path: PathKind) {
        self.cc.on_path_changed(path);
    }

    /// Counters for the status line.
    pub fn stats(&self) -> UpstreamStats {
        UpstreamStats {
            frames_sent: self.frames_sent,
            frames_dropped: self.frames_dropped,
            acked_frame: self.acked_frame,
            loss: self.loss,
            keyframe_requested: self.keyframe_requested,
        }
    }

    /// Records a frame the caller dropped before sending (for example its
    /// send queue was full): the reference chain breaks as for a paced drop.
    pub fn drop_frame(&mut self) {
        self.frames_dropped += 1;
        self.chain_broken = true;
        self.keyframe_requested = true;
    }

    /// Sends one encoded frame captured at `t_capture_us`. `independent`
    /// frames reference no earlier frame (keyframes, and every audio packet);
    /// other frames reference the previous frame sent. Returns the datagrams
    /// to send now, in order, or `None` when the frame was dropped (over the
    /// pacing budget, or dependent on a dropped frame); a drop requests a
    /// keyframe.
    pub fn send_frame(
        &mut self,
        access_unit: &[u8],
        t_capture_us: u64,
        independent: bool,
        now_us: u64,
    ) -> Result<Option<Vec<Vec<u8>>>, PacketizeError> {
        self.refill(now_us);
        let dependent_on_drop = !independent && (self.chain_broken || self.last_sent.is_none());
        if dependent_on_drop || self.budget_bits < 0 {
            self.drop_frame();
            return Ok(None);
        }
        let body = FrameBody {
            t_capture_us,
            ref_frame: if independent { REF_NONE } else { self.last_sent.unwrap_or(REF_NONE) },
            access_unit: access_unit.to_vec(),
        };
        let data_shards =
            (FRAME_PREFIX_LEN + access_unit.len()).div_ceil(self.packetizer.shard_len());
        let parity = if self.fec { parity_for(data_shards, self.loss, independent) } else { 0 };
        let frame = self.next_frame;
        let frame_flags = if independent { flags::KEYFRAME } else { 0 };
        let packets = self.packetizer.packetize(frame, frame_flags, &body, parity)?;
        self.next_frame = self.next_frame.wrapping_add(1).max(1);
        let mut bits = 0i64;
        for (i, d) in packets.datagrams.iter().enumerate() {
            let seq = packets.first_transport_seq.wrapping_add(i as u16);
            self.cc.on_sent(seq, now_us);
            self.loss_meter.on_sent(seq);
            bits = bits.saturating_add(d.len() as i64 * 8);
        }
        self.budget_bits = self.budget_bits.saturating_sub(bits);
        if self.last_sent.is_none_or(|last| last <= self.acked_frame) {
            // The stream was idle: the feedback timeout starts now.
            self.last_heard_us = Some(now_us);
        }
        self.last_sent = Some(frame);
        if independent {
            self.last_independent = Some((frame, now_us));
            self.chain_broken = false;
            self.keyframe_requested = false;
        }
        self.frames_sent += 1;
        self.remember(frame, &packets.datagrams);
        Ok(Some(packets.datagrams))
    }

    /// Takes one datagram from the host. Feedback for this stream updates
    /// congestion control, loss, the acked frame and keyframe requests, and
    /// returns the NACKed datagrams to resend now.
    pub fn on_datagram(
        &mut self,
        datagram: &[u8],
        now_us: u64,
    ) -> Result<Vec<Vec<u8>>, UpstreamError> {
        let (header, payload) = match DatagramHeader::decode(datagram) {
            Ok(decoded) => decoded,
            // A kind this build does not know is some other handler's datagram.
            Err(DecodeError::Kind(_)) => return Err(UpstreamError::NotMine),
            Err(e) => return Err(UpstreamError::Invalid(e)),
        };
        if header.kind != DatagramKind::Feedback || header.stream != self.stream {
            return Err(UpstreamError::NotMine);
        }
        let fb = Feedback::decode(payload).map_err(UpstreamError::Invalid)?;
        let settled = self.loss_meter.on_arrivals(fb.arrivals.iter().map(|a| a.transport_seq));
        if let Some(lost) = settled {
            self.loss = 0.8 * self.loss + 0.2 * lost;
        }
        self.cc.on_feedback(&fb.arrivals, settled.unwrap_or(0.0), now_us);
        self.last_heard_us = Some(now_us);
        if fb.acked_frame > self.acked_frame && self.last_sent.is_some_and(|l| fb.acked_frame <= l)
        {
            self.acked_frame = fb.acked_frame;
            while let Some(entry) = self.history.first_entry() {
                if *entry.key() > self.acked_frame {
                    break;
                }
                let datagrams = entry.remove();
                self.history_bytes -= datagrams.iter().map(Vec::len).sum::<usize>();
            }
        }
        // Requests that predate the host's receipt of the last keyframe are
        // already answered.
        let answered = self.last_independent.is_some_and(|(frame, sent_us)| {
            fb.acked_frame < frame && now_us.saturating_sub(sent_us) < KEYFRAME_RETRY_US
        });
        if fb.need_recovery && !answered {
            self.keyframe_requested = true;
        }
        // Resends spend the pacing budget too, so NACKs never push the path
        // past the target.
        self.refill(now_us);
        let mut resends = Vec::new();
        for nack in &fb.nacks {
            let Some(datagrams) = self.history.get(&nack.frame) else { continue };
            for &i in &nack.indexes {
                if resends.len() >= MAX_RESENDS_PER_FEEDBACK || self.budget_bits < 0 {
                    return Ok(resends);
                }
                if let Some(d) = datagrams.get(usize::from(i)) {
                    self.budget_bits = self.budget_bits.saturating_sub(d.len() as i64 * 8);
                    resends.push(d.clone());
                }
            }
        }
        Ok(resends)
    }

    fn stale(&self, now_us: u64) -> bool {
        let unacked = self.last_sent.is_some_and(|last| last > self.acked_frame);
        unacked
            && self
                .last_heard_us
                .is_some_and(|heard| now_us.saturating_sub(heard) >= FEEDBACK_TIMEOUT_US)
    }

    /// Adds the target rate's bits for the time since the last send, up to
    /// [`BURST_US`] worth (at least one datagram).
    fn refill(&mut self, now_us: u64) {
        let target = self.target_bps(now_us);
        let cap = (target.saturating_mul(BURST_US) / 1_000_000)
            .max(self.packetizer.shard_len() as u64 * 8) as i64;
        let earned = self.last_refill_us.map_or(cap, |last| {
            let elapsed = now_us.saturating_sub(last);
            (u128::from(target) * u128::from(elapsed) / 1_000_000).min(cap as u128) as i64
        });
        self.last_refill_us = Some(now_us);
        self.budget_bits = self.budget_bits.saturating_add(earned).min(cap);
    }

    fn remember(&mut self, frame: u32, datagrams: &[Vec<u8>]) {
        let bytes: usize = datagrams.iter().map(Vec::len).sum();
        if bytes > HISTORY_BYTES {
            return;
        }
        self.history.insert(frame, datagrams.to_vec());
        self.history_bytes += bytes;
        while self.history.len() > HISTORY_FRAMES || self.history_bytes > HISTORY_BYTES {
            let Some((_, old)) = self.history.pop_first() else { break };
            self.history_bytes -= old.iter().map(Vec::len).sum::<usize>();
        }
    }
}
