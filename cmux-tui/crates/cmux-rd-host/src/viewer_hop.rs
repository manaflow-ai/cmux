//! The viewer's reassembly in the `cmux-rd connect` process (design D7,
//! screen-share-under-100ms.md piece 5): the display stream's video and parity datagrams
//! never reach the app. This process reassembles them, runs the stream's NACK and
//! feedback timers, and hands the app complete frames ([`LocalFrame`]), one at a time:
//! the next frame goes once the app reports the last consumed ([`LocalReport::Consumed`]).
//! A frame still waiting here when a newer frame the app can decode without it is
//! complete (a keyframe or a recovery frame) is replaced, and counted. So no stage
//! between the network and the decoder holds more than one frame, and a dropped frame
//! only happens here, where the reference chain is known.
//!
//! No I/O: `connect.rs` feeds datagrams and reports in and writes what comes out.

use std::collections::VecDeque;

use cmux_rd_core::reassembly::CompleteFrame;
use cmux_rd_ffi::{Carrier, Receiver};
use cmux_rd_proto::{
    flags, DatagramHeader, DatagramKind, LocalCounters, LocalFrame, LocalReport, REF_NONE,
};

/// The display stream the app's pane decodes.
pub const HOP_STREAM: u16 = 0;
/// Frames waiting for the app before the oldest chain is given up: about 130 ms at
/// 60 Hz. Past it the app is not keeping up; waiting frames are dropped and the host is
/// asked for a keyframe, instead of latency growing without bound.
pub const MAX_WAITING: usize = 8;
/// A frame the app has not reported consumed after this long no longer holds the next
/// one (a report lost to a decoder error the app did not report).
pub const CREDIT_TIMEOUT_US: u64 = 250_000;

/// Counters for the hop, beside the reassembler's own.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct HopStats {
    /// Frames sent to the app.
    pub sent: u64,
    /// Waiting frames replaced by a newer frame the app could decode without them.
    pub replaced: u64,
    /// Frames dropped because the app fell [`MAX_WAITING`] frames behind, or that
    /// followed such a drop before the next keyframe or recovery frame.
    pub overrun: u64,
    /// Credits given back after [`CREDIT_TIMEOUT_US`] without a report.
    pub credit_timeouts: u64,
}

/// What one frame cost between release here and the glass, from the app's reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameTiming {
    /// Release here to the app's report that its decoder finished.
    pub release_to_decoded_us: Option<u64>,
    /// The decoder's own time for the frame.
    pub decode_us: Option<u32>,
    /// Release here to the drawable's presented time.
    pub release_to_presented_us: Option<u64>,
}

#[derive(Debug)]
struct Waiting {
    frame: CompleteFrame,
    release_us: u64,
}

#[derive(Debug, Clone, Copy)]
struct InFlight {
    frame: u32,
    sent_us: u64,
}

/// Release times of frames recently sent, for the app's reports (bounded).
const TIMING_SLOTS: usize = 64;

#[derive(Debug, Clone, Copy)]
struct SentFrame {
    frame: u32,
    release_us: u64,
    decoded_us: Option<u64>,
    decode_us: Option<u32>,
}

/// The display stream's receive side in the connect process.
#[derive(Debug)]
pub struct ViewerHop {
    receiver: Receiver,
    waiting: VecDeque<Waiting>,
    in_flight: Option<InFlight>,
    /// After an overrun, frames are dropped until one starts a new chain.
    awaiting_resume: bool,
    /// The pane is connected (`attach`): only then does a cut chain ask for a keyframe.
    attached: bool,
    /// Frames handed to the app, newest last (bounded): a recovery frame that references
    /// one of them decodes without anything waiting here.
    delivered: VecDeque<u32>,
    stats: HopStats,
    sent: VecDeque<SentFrame>,
    timings: Vec<FrameTiming>,
}

fn is_keyframe(frame: &CompleteFrame) -> bool {
    frame.flags & flags::KEYFRAME != 0 || frame.body.ref_frame == REF_NONE
}

impl ViewerHop {
    /// `deadline_us` and `nack_after_us` are the reassembler's, as the app's session used.
    pub fn new(deadline_us: u64, nack_after_us: u64) -> Self {
        Self {
            receiver: Receiver::for_stream(
                Carrier::Datagram,
                HOP_STREAM,
                deadline_us,
                nack_after_us,
            ),
            waiting: VecDeque::new(),
            in_flight: None,
            awaiting_resume: false,
            attached: false,
            delivered: VecDeque::new(),
            stats: HopStats::default(),
            sent: VecDeque::new(),
            timings: Vec::new(),
        }
    }

    /// Whether `datagram` is the hop's to reassemble (the stream's video and parity).
    pub fn takes(datagram: &[u8]) -> bool {
        DatagramHeader::decode(datagram).is_ok_and(|(h, _)| {
            h.stream == HOP_STREAM && matches!(h.kind, DatagramKind::Video | DatagramKind::Fec)
        })
    }

    /// One video or parity datagram from the link.
    pub fn push_datagram(&mut self, datagram: &[u8], now_us: u64) {
        // An invalid datagram is skipped, as the app's session did.
        let _ = self.receiver.push_datagram(datagram, now_us);
        self.collect(now_us);
    }

    /// Advances the reassembler's deadlines and the credit timeout.
    pub fn tick(&mut self, now_us: u64) {
        self.receiver.tick(now_us);
        self.collect(now_us);
        if let Some(f) = self.in_flight {
            if now_us.saturating_sub(f.sent_us) >= CREDIT_TIMEOUT_US {
                self.in_flight = None;
                self.stats.credit_timeouts += 1;
            }
        }
    }

    /// One report from the app.
    pub fn on_report(&mut self, report: LocalReport, now_us: u64) {
        match report {
            LocalReport::Consumed { stream: HOP_STREAM, frame, decode_us } => {
                if self.in_flight.is_some_and(|f| f.frame == frame) {
                    self.in_flight = None;
                }
                if decode_us > 0 {
                    self.receiver.note_decode(decode_us);
                }
                if let Some(s) = self.sent.iter_mut().find(|s| s.frame == frame) {
                    s.decoded_us = Some(now_us);
                    s.decode_us = (decode_us > 0).then_some(decode_us);
                }
            }
            LocalReport::Presented { stream: HOP_STREAM, frame, presented_us } => {
                if let Some(i) = self.sent.iter().position(|s| s.frame == frame) {
                    let s = self.sent[i];
                    self.timings.push(FrameTiming {
                        release_to_decoded_us: s.decoded_us.map(|d| d.saturating_sub(s.release_us)),
                        decode_us: s.decode_us,
                        release_to_presented_us: Some(presented_us.saturating_sub(s.release_us)),
                    });
                    // Older frames were replaced on the glass before they were shown.
                    self.sent.drain(..=i);
                }
            }
            LocalReport::KeyframeWanted { stream: HOP_STREAM } => self.receiver.request_keyframe(),
            _ => {}
        }
    }

    /// The next frame to write to the app, when the app holds none: the oldest waiting
    /// frame, encoded with the reassembler's counters.
    pub fn next_frame(&mut self, now_us: u64) -> Option<LocalFrame> {
        if self.in_flight.is_some() {
            return None;
        }
        let Waiting { frame, release_us } = self.waiting.pop_front()?;
        self.in_flight = Some(InFlight { frame: frame.frame, sent_us: now_us });
        self.stats.sent += 1;
        if self.delivered.len() >= TIMING_SLOTS {
            self.delivered.pop_front();
        }
        self.delivered.push_back(frame.frame);
        if self.sent.len() >= TIMING_SLOTS {
            self.sent.pop_front();
        }
        self.sent.push_back(SentFrame {
            frame: frame.frame,
            release_us,
            decoded_us: None,
            decode_us: None,
        });
        Some(LocalFrame {
            stream: HOP_STREAM,
            frame: frame.frame,
            flags: frame.flags,
            release_us,
            counters: self.counters(),
            body: frame.body,
        })
    }

    /// Feedback datagrams due now, for the link (the reassembler's NACKs, arrivals and
    /// keepalive, with the app's decode times).
    pub fn feedback(&mut self, now_us: u64) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        // Bounded: each call drains at most one message's worth of arrivals.
        for _ in 0..64 {
            let Some(d) = self.receiver.feedback(now_us) else { break };
            out.push(d);
        }
        out
    }

    /// When [`Self::tick`] and [`Self::feedback`] must run next.
    pub fn next_deadline_us(&self) -> u64 {
        let credit = self.in_flight.map_or(u64::MAX, |f| f.sent_us + CREDIT_TIMEOUT_US);
        self.receiver.next_deadline_us().min(credit)
    }

    pub fn stats(&self) -> HopStats {
        self.stats
    }

    /// Per-frame timings reported since the last call.
    pub fn take_timings(&mut self) -> Vec<FrameTiming> {
        std::mem::take(&mut self.timings)
    }

    fn counters(&self) -> LocalCounters {
        let r = self.receiver.stats();
        LocalCounters {
            acked_frame: r.acked_frame,
            need_recovery: r.need_recovery,
            frames_released: r.frames_released,
            frames_lost: r.frames_lost + self.stats.replaced + self.stats.overrun,
        }
    }

    fn collect(&mut self, now_us: u64) {
        while let Some(frame) = self.receiver.pop_frame() {
            self.release(frame, now_us);
        }
    }

    /// Whether the app decodes `frame` without any frame still waiting here: a keyframe,
    /// or a recovery frame whose reference the app already has. (A recovery frame names an
    /// acknowledged frame, and the reassembler acknowledges on release, so its reference
    /// may well be one still waiting here: then it is not.)
    fn decodes_alone(&self, frame: &CompleteFrame) -> bool {
        is_keyframe(frame)
            || (frame.flags & flags::RECOVERY != 0
                && self.delivered.contains(&frame.body.ref_frame))
    }

    /// The pane connected: a chain cut while nobody read asks for a keyframe now.
    pub fn attach(&mut self) {
        self.attached = true;
        if self.awaiting_resume {
            self.receiver.request_keyframe();
        }
    }

    fn release(&mut self, frame: CompleteFrame, now_us: u64) {
        if self.decodes_alone(&frame) {
            // The waiting frames would only be shown and then replaced.
            self.stats.replaced += self.waiting.len() as u64;
            self.waiting.clear();
            self.awaiting_resume = false;
        } else if self.awaiting_resume {
            self.stats.overrun += 1;
            return;
        } else if self.waiting.len() >= MAX_WAITING {
            self.stats.overrun += self.waiting.len() as u64 + 1;
            self.waiting.clear();
            self.awaiting_resume = true;
            // Before the pane connects nobody reads: no keyframe until it does.
            if self.attached {
                self.receiver.request_keyframe();
            }
            return;
        }
        self.waiting.push_back(Waiting { frame, release_us: now_us });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_rd_core::packetize::Packetizer;
    use cmux_rd_proto::{FrameBody, MAX_DATAGRAM_VPC};

    /// A host's stream 0: frames numbered from 1, each P-frame referencing the previous.
    struct Host {
        p: Packetizer,
        next: u32,
    }

    impl Host {
        fn new(stream: u16) -> Self {
            Self { p: Packetizer::new(stream, MAX_DATAGRAM_VPC), next: 1 }
        }

        fn datagrams(&mut self, key: bool, len: usize) -> Vec<Vec<u8>> {
            let frame = self.next;
            self.next += 1;
            let ref_frame = if key { REF_NONE } else { frame - 1 };
            let body = FrameBody { t_capture_us: 1, ref_frame, access_unit: vec![9; len] };
            let fl = if key { flags::KEYFRAME } else { 0 };
            self.p.packetize(frame, fl, &body, 0).expect("packetize").datagrams
        }

        fn send(&mut self, hop: &mut ViewerHop, key: bool, now: u64) {
            for d in self.datagrams(key, 3000) {
                assert!(ViewerHop::takes(&d));
                hop.push_datagram(&d, now);
            }
        }

        /// One recovery frame that references `ref_frame`.
        fn send_recovery(&mut self, hop: &mut ViewerHop, ref_frame: u32, now: u64) {
            let frame = self.next;
            self.next += 1;
            let body = FrameBody { t_capture_us: 1, ref_frame, access_unit: vec![9; 3000] };
            for d in
                self.p.packetize(frame, flags::RECOVERY, &body, 0).expect("packetize").datagrams
            {
                hop.push_datagram(&d, now);
            }
        }
    }

    fn consume(hop: &mut ViewerHop, frame: &LocalFrame, now: u64) {
        hop.on_report(
            LocalReport::Consumed { stream: 0, frame: frame.frame, decode_us: 3_000 },
            now,
        );
    }

    #[test]
    fn one_frame_at_a_time_then_the_next_once_consumed() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        let mut host = Host::new(0);
        host.send(&mut hop, true, 10);
        host.send(&mut hop, false, 20);
        let first = hop.next_frame(30).expect("the keyframe goes at once");
        assert!(hop.next_frame(31).is_none(), "the app holds one frame at most");
        consume(&mut hop, &first, 40);
        let second = hop.next_frame(41).expect("the next goes once the first was consumed");
        assert_eq!((first.frame, second.frame), (1, 2));
        assert_eq!(second.release_us, 20);
        assert_eq!(second.body.access_unit.len(), 3000);
        assert_eq!(hop.stats().sent, 2);
    }

    #[test]
    fn a_keyframe_replaces_the_frames_still_waiting() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        let mut host = Host::new(0);
        host.send(&mut hop, true, 0);
        let first = hop.next_frame(0).unwrap();
        host.send(&mut hop, false, 1);
        host.send(&mut hop, false, 2);
        host.send(&mut hop, true, 3);
        consume(&mut hop, &first, 4);
        let next = hop.next_frame(4).unwrap();
        assert_eq!(next.frame, 4, "the newest decodable frame, not the oldest waiting");
        assert_eq!(hop.stats().replaced, 2);
        assert_eq!(next.counters.frames_lost, 2);
    }

    #[test]
    fn an_app_that_stops_reading_costs_a_bounded_wait_and_one_keyframe_request() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        hop.attach();
        let mut host = Host::new(0);
        host.send(&mut hop, true, 0);
        let _held = hop.next_frame(0).unwrap();
        for _ in 0..(MAX_WAITING + 3) {
            host.send(&mut hop, false, 1);
        }
        assert!(hop.waiting.len() <= MAX_WAITING);
        assert!(hop.stats().overrun > 0);
        assert!(hop.receiver.need_recovery(), "the host is asked for a keyframe");
        // The next keyframe starts a new chain at once.
        host.send(&mut hop, true, 2);
        assert_eq!(hop.waiting.len(), 1);
    }

    #[test]
    fn a_lost_report_gives_the_credit_back_after_the_timeout() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        let mut host = Host::new(0);
        host.send(&mut hop, true, 0);
        host.send(&mut hop, false, 0);
        let _ = hop.next_frame(0).unwrap();
        assert!(hop.next_frame(1).is_none());
        assert!(hop.next_deadline_us() <= CREDIT_TIMEOUT_US);
        hop.tick(CREDIT_TIMEOUT_US);
        assert_eq!(hop.next_frame(CREDIT_TIMEOUT_US).unwrap().frame, 2);
        assert_eq!(hop.stats().credit_timeouts, 1);
    }

    #[test]
    fn reports_give_release_to_presented_per_frame() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        let mut host = Host::new(0);
        host.send(&mut hop, true, 1_000);
        let f = hop.next_frame(1_000).unwrap();
        hop.on_report(LocalReport::Consumed { stream: 0, frame: f.frame, decode_us: 4_000 }, 5_500);
        hop.on_report(
            LocalReport::Presented { stream: 0, frame: f.frame, presented_us: 13_000 },
            6_000,
        );
        assert_eq!(
            hop.take_timings(),
            vec![FrameTiming {
                release_to_decoded_us: Some(4_500),
                decode_us: Some(4_000),
                release_to_presented_us: Some(12_000),
            }]
        );
    }

    #[test]
    fn the_hop_sends_the_streams_feedback() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        let mut host = Host::new(0);
        host.send(&mut hop, true, 0);
        let fb = hop.feedback(1);
        assert!(!fb.is_empty());
        let (h, _) = DatagramHeader::decode(&fb[0]).unwrap();
        assert_eq!((h.kind, h.stream), (DatagramKind::Feedback, 0));
    }

    #[test]
    fn other_datagrams_pass_through() {
        let mut host = Host::new(1);
        let d = &host.datagrams(true, 100)[0];
        assert!(!ViewerHop::takes(d), "another stream's video stays the app's");
        assert!(!ViewerHop::takes(&[0u8; 3]));
    }

    #[test]
    fn a_recovery_frame_never_replaces_the_frame_it_references() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        let mut host = Host::new(0);
        host.send(&mut hop, true, 0);
        let first = hop.next_frame(0).unwrap();
        host.send(&mut hop, false, 1); // frame 2, waiting
        host.send_recovery(&mut hop, 2, 2); // frame 3 references the waiting frame 2
        consume(&mut hop, &first, 3);
        assert_eq!(hop.next_frame(3).unwrap().frame, 2, "its reference goes first");
        assert_eq!(hop.stats().replaced, 0);
    }

    #[test]
    fn a_recovery_frame_on_a_delivered_reference_replaces_the_waiting_ones() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        let mut host = Host::new(0);
        host.send(&mut hop, true, 0);
        let first = hop.next_frame(0).unwrap();
        host.send(&mut hop, false, 1);
        host.send(&mut hop, false, 2);
        host.send_recovery(&mut hop, first.frame, 3);
        consume(&mut hop, &first, 4);
        assert_eq!(hop.next_frame(4).unwrap().frame, 4);
        assert_eq!(hop.stats().replaced, 2);
    }

    #[test]
    fn no_keyframe_is_asked_for_before_the_pane_connects() {
        let mut hop = ViewerHop::new(200_000, 5_000);
        let mut host = Host::new(0);
        host.send(&mut hop, true, 0);
        for _ in 0..(MAX_WAITING + 3) {
            host.send(&mut hop, false, 1);
        }
        assert!(hop.stats().overrun > 0);
        assert!(!hop.receiver.need_recovery(), "nobody reads yet: no keyframe");
        hop.attach();
        assert!(hop.receiver.need_recovery(), "the pane connected: now one");
    }
}
