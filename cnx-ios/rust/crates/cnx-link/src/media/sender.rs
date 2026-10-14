//! The Mac's half of the media core: frames in, RTP out, RTCP back.
//! Pure and clocked by the caller ([`SenderCore`]); [`run`] drives it on a
//! carrier.
//!
//! webrtc-rs's interceptors answer NACKs (the responder keeps the history)
//! and write sender reports. What it has no part for is bandwidth
//! estimation: this core stamps the transport-wide sequence number itself
//! (so it knows each packet's send time), reads the receiver's TWCC
//! feedback, and feeds the delay-based controller `cmux.rd/1` already uses
//! (`cmux-rd-core`). Its target and in-flight window drive the Mac's
//! encoder and frame skipping.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use bytes::Bytes;
use cmux_rd_core::cc::{CcConfig, CongestionController, PathKind};
use cmux_rd_core::loss::LossMeter;
use cmux_rd_proto::Arrival;
use tokio::sync::{broadcast, mpsc, watch};
use webrtc::rtcp::payload_feedbacks::full_intra_request::FullIntraRequest;
use webrtc::rtcp::payload_feedbacks::picture_loss_indication::PictureLossIndication;
use webrtc::rtcp::transport_feedbacks::transport_layer_cc::TransportLayerCc;
use webrtc::rtcp::transport_feedbacks::transport_layer_nack::TransportLayerNack;
use webrtc::rtp::header::Header;
use webrtc::rtp::packet::Packet;

use super::{MediaCarrier, OutgoingFrame, RTP_PAYLOAD_MTU, RtcpPackets, SenderState, h264, twcc};

/// Shortest time between two keyframe requests passed to the source.
pub const MIN_KEYFRAME_INTERVAL_US: u64 = 250_000;
/// A sent packet no feedback mentioned after this long no longer counts as
/// in flight.
const IN_FLIGHT_EXPIRY_US: u64 = 1_000_000;

#[derive(Debug, Clone, Copy)]
pub struct SenderConfig {
    pub cc: CcConfig,
    pub ssrc: u32,
    pub payload_type: u8,
    /// The smallest in-flight window, so one keyframe can always go out.
    pub window_floor_bytes: u64,
}

impl Default for SenderConfig {
    fn default() -> Self {
        Self {
            // The phone's page: 804x1444 at up to 60 fps. Start where the rd
            // stream's text pages sit and let feedback find the path.
            cc: CcConfig {
                min_bps: 250_000,
                max_bps: 20_000_000,
                start_bps: 2_500_000,
                relay_max_bps: 20_000_000,
                overuse_threshold_us: 2_000.0,
            },
            ssrc: 0x636e_7876, // "cnxv"; the WebRTC carrier sets its own.
            payload_type: super::DEFAULT_PAYLOAD_TYPE,
            window_floor_bytes: 96 * 1024,
        }
    }
}

/// What one RTCP compound asks of the sender.
#[derive(Debug, Default)]
pub struct RtcpOutcome {
    /// The receiver asked for a keyframe (PLI or FIR), rate limited.
    pub keyframe: bool,
}

/// Something the source should act on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SenderEvent {
    Keyframe,
}

#[derive(Debug, Clone, Copy)]
struct Sent {
    bytes: u64,
    at_us: u64,
}

#[derive(Debug)]
pub struct SenderCore {
    config: SenderConfig,
    ext_id: u8,
    packetizer: h264::Packetizer,
    seq: u16,
    twcc_seq: u16,
    sent: HashMap<u16, Sent>,
    sent_order: VecDeque<u16>,
    in_flight: u64,
    cc: CongestionController,
    loss_meter: LossMeter,
    loss: f64,
    feedback_delay_us: u64,
    last_keyframe_us: Option<u64>,
    keyframe_requests: u64,
    packets_sent: u64,
    nacks_received: u64,
}

impl SenderCore {
    pub fn new(config: SenderConfig, twcc_ext_id: u8) -> Self {
        Self {
            config,
            ext_id: twcc_ext_id,
            packetizer: h264::Packetizer::default(),
            seq: rand_u16(),
            twcc_seq: 0,
            sent: HashMap::new(),
            sent_order: VecDeque::new(),
            in_flight: 0,
            cc: CongestionController::new(config.cc, PathKind::DirectWan),
            loss_meter: LossMeter::default(),
            loss: 0.0,
            feedback_delay_us: 0,
            last_keyframe_us: None,
            keyframe_requests: 0,
            packets_sent: 0,
            nacks_received: 0,
        }
    }

    /// The RTP packets of one frame, stamped and recorded as sent at `now_us`.
    pub fn frame(&mut self, frame: &OutgoingFrame, now_us: u64) -> Vec<Packet> {
        let timestamp = super::rtp_timestamp(frame.capture_us);
        let payloads = self.packetizer.payloads(&frame.access_unit, RTP_PAYLOAD_MTU);
        let last = payloads.len().saturating_sub(1);
        let mut packets = Vec::with_capacity(payloads.len());
        for (i, payload) in payloads.into_iter().enumerate() {
            let mut packet = Packet {
                header: Header {
                    version: 2,
                    marker: i == last,
                    payload_type: self.config.payload_type,
                    sequence_number: self.seq,
                    timestamp,
                    ssrc: self.config.ssrc,
                    ..Header::default()
                },
                payload,
            };
            self.seq = self.seq.wrapping_add(1);
            self.stamp(&mut packet, now_us);
            self.packets_sent += 1;
            packets.push(packet);
        }
        packets
    }

    /// Gives `packet` the next transport-wide sequence number and records it.
    fn stamp(&mut self, packet: &mut Packet, now_us: u64) {
        let seq = self.twcc_seq;
        self.twcc_seq = self.twcc_seq.wrapping_add(1);
        let _ = packet.header.set_extension(self.ext_id, Bytes::copy_from_slice(&seq.to_be_bytes()));
        let bytes = (packet.payload.len() + 32) as u64;
        self.cc.on_sent(seq, now_us);
        self.loss_meter.on_sent(seq);
        if let Some(old) = self.sent.insert(seq, Sent { bytes, at_us: now_us }) {
            self.in_flight = self.in_flight.saturating_sub(old.bytes);
        }
        self.sent_order.push_back(seq);
        self.in_flight += bytes;
        self.expire(now_us);
    }

    fn expire(&mut self, now_us: u64) {
        while let Some(&oldest) = self.sent_order.front() {
            match self.sent.get(&oldest) {
                Some(sent) if now_us.saturating_sub(sent.at_us) < IN_FLIGHT_EXPIRY_US => break,
                Some(sent) => {
                    self.in_flight = self.in_flight.saturating_sub(sent.bytes);
                    self.sent.remove(&oldest);
                }
                None => {}
            }
            self.sent_order.pop_front();
        }
    }

    /// Applies one RTCP compound received at `now_us`.
    pub fn on_rtcp(&mut self, packets: &RtcpPackets, now_us: u64) -> RtcpOutcome {
        let mut outcome = RtcpOutcome::default();
        for packet in packets {
            let any = packet.as_any();
            if let Some(cc) = any.downcast_ref::<TransportLayerCc>() {
                self.on_twcc(cc, now_us);
            } else if any.downcast_ref::<TransportLayerNack>().is_some() {
                // The NACK responder interceptor resends; count it.
                self.nacks_received += 1;
            } else if any.downcast_ref::<PictureLossIndication>().is_some()
                || any.downcast_ref::<FullIntraRequest>().is_some()
            {
                self.keyframe_requests += 1;
                let allowed = self
                    .last_keyframe_us
                    .is_none_or(|t| now_us.saturating_sub(t) >= MIN_KEYFRAME_INTERVAL_US);
                if allowed {
                    self.last_keyframe_us = Some(now_us);
                    outcome.keyframe = true;
                }
            }
        }
        self.expire(now_us);
        outcome
    }

    fn on_twcc(&mut self, feedback: &TransportLayerCc, now_us: u64) {
        let results = twcc::results(feedback);
        let mut arrivals = Vec::with_capacity(results.len());
        let mut newest_delay = None;
        for result in &results {
            if let Some(sent) = self.sent.remove(&result.seq) {
                self.in_flight = self.in_flight.saturating_sub(sent.bytes);
                if result.arrival_us.is_some() {
                    newest_delay = Some(now_us.saturating_sub(sent.at_us));
                }
            }
            if let Some(arrival) = result.arrival_us {
                arrivals.push(Arrival { transport_seq: result.seq, arrival_us: arrival as u32 });
            }
        }
        let settled = self.loss_meter.on_arrivals(arrivals.iter().map(|a| a.transport_seq));
        if let Some(lost) = settled {
            self.loss = 0.8 * self.loss + 0.2 * lost;
        }
        self.cc.on_feedback(&arrivals, settled.unwrap_or(0.0), now_us);
        if let Some(delay) = newest_delay {
            self.feedback_delay_us = if self.feedback_delay_us == 0 {
                delay
            } else {
                (self.feedback_delay_us * 7 + delay) / 8
            };
        }
    }

    /// Bytes the path may hold before the source should skip frames: the
    /// target rate over the feedback delay plus a margin.
    pub fn window_bytes(&self) -> u64 {
        let horizon_us = self.feedback_delay_us.max(30_000) + 60_000;
        (self.cc.target_bps() * horizon_us / 8_000_000).max(self.config.window_floor_bytes)
    }

    pub fn state(&self) -> SenderState {
        SenderState {
            target_bps: self.cc.target_bps(),
            in_flight_bytes: self.in_flight,
            congested: self.in_flight > self.window_bytes(),
            loss: self.loss,
            feedback_delay_us: self.feedback_delay_us,
            keyframe_requests: self.keyframe_requests,
            packets_sent: self.packets_sent,
            nacks_received: self.nacks_received,
        }
    }
}

fn rand_u16() -> u16 {
    let mut bytes = [0u8; 2];
    let _ = getrandom::fill(&mut bytes);
    u16::from_le_bytes(bytes)
}

/// Drives a [`SenderCore`] on `carrier` until the carrier ends or every
/// [`super::VideoOut`] handle is gone.
pub(crate) async fn run(
    carrier: Arc<dyn MediaCarrier>,
    config: SenderConfig,
    mut frames: mpsc::Receiver<(u64, OutgoingFrame)>,
    state: watch::Sender<SenderState>,
    keyframes: broadcast::Sender<()>,
) {
    let epoch = std::time::Instant::now();
    let mut core = SenderCore::new(config, carrier.twcc_ext_id());
    let mut ticker = tokio::time::interval(std::time::Duration::from_millis(100));
    loop {
        tokio::select! {
            frame = frames.recv() => {
                let Some((_, frame)) = frame else { return };
                let packets = core.frame(&frame, super::micros_since(epoch));
                for packet in &packets {
                    if carrier.send_rtp(packet).await.is_err() {
                        return;
                    }
                }
            }
            rtcp = carrier.recv_rtcp() => {
                let Some(rtcp) = rtcp else { return };
                let outcome = core.on_rtcp(&rtcp, super::micros_since(epoch));
                if outcome.keyframe {
                    let _ = keyframes.send(());
                }
            }
            _ = ticker.tick() => {
                core.expire(super::micros_since(epoch));
            }
        }
        state.send_replace(core.state());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media::h264::tests::access_unit;
    use crate::media::twcc::Recorder;
    use webrtc::rtcp::transport_feedbacks::transport_layer_nack::nack_pairs_from_sequence_numbers;

    fn twcc_seq(packet: &Packet) -> u16 {
        let ext = packet.header.get_extension(super::super::DEFAULT_TWCC_EXT_ID).unwrap();
        u16::from_be_bytes([ext[0], ext[1]])
    }

    #[test]
    fn frames_get_consecutive_sequence_numbers_a_marker_and_the_capture_timestamp() {
        let mut core = SenderCore::new(SenderConfig::default(), super::super::DEFAULT_TWCC_EXT_ID);
        let a = core.frame(&OutgoingFrame { access_unit: access_unit(true, 4000, 3), capture_us: 1_000_000 }, 0);
        let b = core.frame(&OutgoingFrame { access_unit: access_unit(false, 200, 4), capture_us: 1_016_000 }, 16_000);
        assert!(a.len() > 3 && b.len() == 1);
        let all: Vec<_> = a.iter().chain(&b).collect();
        for pair in all.windows(2) {
            assert_eq!(pair[1].header.sequence_number, pair[0].header.sequence_number.wrapping_add(1));
            assert_eq!(twcc_seq(pair[1]), twcc_seq(pair[0]).wrapping_add(1));
        }
        assert!(a.last().unwrap().header.marker && !a[0].header.marker);
        assert_eq!(a[0].header.timestamp, 90_000);
        assert_eq!(b[0].header.timestamp, 91_440);
        assert!(core.state().in_flight_bytes > 4000);
    }

    #[test]
    fn pli_and_fir_ask_for_a_keyframe_at_most_every_250_ms() {
        let mut core = SenderCore::new(SenderConfig::default(), 1);
        let nack: RtcpPackets = vec![Box::new(TransportLayerNack {
            sender_ssrc: 0,
            media_ssrc: core.config.ssrc,
            nacks: nack_pairs_from_sequence_numbers(&[3, 5]),
        })];
        assert!(!core.on_rtcp(&nack, 30_000).keyframe);
        assert_eq!(core.state().nacks_received, 1);
        let pli: RtcpPackets = vec![Box::new(PictureLossIndication { sender_ssrc: 0, media_ssrc: 1 })];
        assert!(core.on_rtcp(&pli, 40_000).keyframe);
        assert!(!core.on_rtcp(&pli, 100_000).keyframe);
        let fir: RtcpPackets = vec![Box::new(FullIntraRequest { sender_ssrc: 0, media_ssrc: 1, fir: vec![] })];
        assert!(core.on_rtcp(&fir, 300_000).keyframe);
        assert_eq!(core.state().keyframe_requests, 3);
    }

    /// No feedback (a stalled path): the in-flight window fills and the
    /// source is told to skip frames; feedback reopens it.
    #[test]
    fn a_stalled_path_marks_the_sender_congested_until_feedback_arrives() {
        let mut core = SenderCore::new(SenderConfig::default(), 1);
        let mut sent = Vec::new();
        let mut now = 0;
        while !core.state().congested {
            sent.extend(core.frame(&OutgoingFrame { access_unit: access_unit(false, 20_000, 5), capture_us: now }, now));
            now += 16_667;
            assert!(now < 2_000_000);
        }
        let mut recorder = Recorder::new(9);
        for p in &sent {
            recorder.record(1, twcc_seq(p), now as i64);
        }
        core.on_rtcp(&recorder.build_feedback_packet(), now + 5_000);
        assert!(!core.state().congested);
        assert_eq!(core.state().in_flight_bytes, 0);
        assert!(core.state().feedback_delay_us > 0);
    }

    /// A path that delivers about 1 Mbit/s: the receiver's TWCC feedback
    /// drives the target down from its 2.5 Mbit/s start.
    #[test]
    fn twcc_feedback_from_a_slow_path_lowers_the_target() {
        let mut core = SenderCore::new(SenderConfig::default(), 1);
        let mut recorder = Recorder::new(9);
        let path_bps = 1_000_000.0;
        let mut queue_free_us = 0.0f64;
        let mut now = 0u64;
        let mut pending: Vec<(u16, i64)> = Vec::new();
        for frame in 0..300u64 {
            now = frame * 16_667;
            let bytes = (core.state().target_bps / 8 / 60) as usize;
            let packets = core.frame(&OutgoingFrame { access_unit: access_unit(frame % 120 == 0, bytes, 5), capture_us: now }, now);
            for p in &packets {
                let size = (p.payload.len() + 40) as f64 * 8.0;
                queue_free_us = queue_free_us.max(now as f64) + size / path_bps * 1e6;
                pending.push((twcc_seq(p), queue_free_us as i64 + 20_000));
            }
            if frame % 3 == 2 {
                let (arrived, rest): (Vec<_>, Vec<_>) = pending.iter().partition(|(_, at)| *at <= now as i64);
                pending = rest;
                for (seq, at) in arrived {
                    recorder.record(1, seq, at);
                }
                core.on_rtcp(&recorder.build_feedback_packet(), now + 10_000);
            }
        }
        let target = core.state().target_bps;
        assert!(target < 1_300_000, "target {target} after {now} us");
    }
}
