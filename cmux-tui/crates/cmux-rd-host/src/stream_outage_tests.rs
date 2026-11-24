//! D12 detector, host half: when an outage ends, a queued frame that never started goes
//! no further when it is larger than a keyframe (its missing receipts are not loss and the
//! newest frame goes out next as a keyframe); a frame that started finishes, and a queue
//! smaller than a keyframe goes out as it is, with no keyframe.

use super::*;
use crate::carrier::{Carrier, Incoming};
use crate::wire::Control;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, PrincipalClass};
use cmux_rd_core::session::StartRequest;
use cmux_rd_proto::{flags, Arrival, Feedback, InputEvent};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub(super) struct QuietDesktop(pub(super) (UnixStream, UnixStream));

impl Desktop for QuietDesktop {
    fn size(&self) -> (u32, u32) {
        (640, 480)
    }
    fn fd(&self) -> RawFd {
        self.0 .1.as_raw_fd()
    }
    fn drain(&mut self, _out: &mut Vec<Rect>) -> Res<()> {
        Ok(())
    }
    fn inject(&mut self, _event: &InputEvent) -> Res<()> {
        Ok(())
    }
    fn release_all(&mut self) -> Res<()> {
        Ok(())
    }
}

/// Encodes the n-th frame at `sizes[n]` bytes (the last size after that). Records
/// each encode's `force_idr`.
pub(super) struct SizedEncoder {
    pub(super) sizes: Vec<usize>,
    pub(super) forced: Arc<Mutex<Vec<bool>>>,
}

impl FrameSource for SizedEncoder {
    fn capture(&mut self, _damage: Rect) -> Res<()> {
        Ok(())
    }
    fn encode(&mut self, force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        let mut forced = self.forced.lock().expect("lock");
        let len = self.sizes[forced.len().min(self.sizes.len() - 1)];
        forced.push(force_idr);
        out.extend((0..len).map(|i| i as u8));
        Ok(force_idr)
    }
    fn set_bitrate(&mut self, _kbps: u32) {}
    fn kbps(&self) -> u32 {
        1000
    }
    fn encoder_name(&self) -> String {
        "sized test encoder".into()
    }
}

#[derive(Default)]
pub(super) struct RecordingCarrier {
    pub(super) sent: Vec<Vec<u8>>,
}

impl Carrier for RecordingCarrier {
    fn drain_departures(&mut self, _out: &mut Vec<crate::carrier::DatagramDeparture>) {}
    fn departure_overflows(&self) -> u64 {
        0
    }
    fn fds(&self) -> Vec<RawFd> {
        Vec::new()
    }
    fn receive(&mut self, _out: &mut Vec<Incoming>) -> Result<(), String> {
        Ok(())
    }
    fn send_datagram(&mut self, datagram: &[u8]) -> std::io::Result<()> {
        self.sent.push(datagram.to_vec());
        Ok(())
    }
    fn send_datagram_frame(
        &mut self,
        datagrams: Vec<Vec<u8>>,
        _droppable: bool,
    ) -> std::io::Result<()> {
        self.sent.extend(datagrams);
        Ok(())
    }
    fn send_control(&mut self, _control: &Control) -> std::io::Result<()> {
        Ok(())
    }
}

pub(super) fn header(d: &[u8]) -> DatagramHeader {
    DatagramHeader::decode(d).expect("header").0
}

pub(super) fn feedback(arrivals: Vec<Arrival>, acked_frame: u32) -> Vec<u8> {
    let mut d = DatagramHeader {
        flags: 0,
        kind: DatagramKind::Feedback,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode()
    .to_vec();
    d.extend_from_slice(&Feedback { arrivals, acked_frame, ..Feedback::default() }.encode());
    d
}

/// Hands the next finished encode to `send_encoded` (at most 5 s).
fn send_next_frame(session: &mut MediaSession, carrier: &mut RecordingCarrier) {
    let before = carrier.sent.len();
    for _ in 0..500 {
        wait_readable(&[session.encoder.fd()], Some(10_000_000)).expect("wait");
        session.send_encoded(carrier).expect("send");
        if carrier.sent.len() > before {
            return;
        }
    }
    panic!("no frame was sent");
}

struct Outage {
    session: MediaSession,
    carrier: RecordingCarrier,
    table: SessionTable,
    id: SessionId,
    viewer: Principal,
    forced: Arc<Mutex<Vec<bool>>>,
    /// Datagrams sent before the outage ended.
    sent: usize,
    /// The frame that started before the radio went away, and the one queued behind it.
    started_frame: u32,
    unstarted_frame: u32,
}

impl Outage {
    fn feedback(&mut self, arrivals: Vec<Arrival>, acked_frame: u32) {
        let d = feedback(arrivals, acked_frame);
        self.session.on_datagram(&mut self.carrier, &d, &self.table, self.id, &self.viewer);
    }
}

/// A small keyframe answered at once; then a 200 KB frame the pacer starts, and a frame
/// of `unstarted` bytes queued behind it; the radio goes away for longer than the outage
/// threshold and the started frame's head is answered at once when it is back.
fn outage_with_queue(unstarted: usize) -> Outage {
    let forced = Arc::new(Mutex::new(Vec::new()));
    let cfg = SessionCfg {
        display: String::new(),
        display_pick: None,
        window: None,
        max_fps: 60,
        encode_profile: Default::default(),
        start_kbps: 2_000,
        max_kbps: 4_000,
        preset: String::new(),
        profile: String::new(),
        codec: String::new(),
        openh264_lib: None,
        content: "screen".into(),
        threads: 1,
        stats_every_ms: 1000,
        settle_us: 0,
        upstream_record: None,
        upstream_record_max_bytes: 0,
        frames_in_flight: 3,
        input_frame_now: false,
        rtt_tail_probe: false,
        resolution_ladder: false,
        max_qp: cmux_rd_core::resolution::DEFAULT_MAX_QP,
        max_width: None,
        show_cursor: true,
        capture: crate::capture_backend::CaptureBackend::default(),
    };
    let mut session = MediaSession::with_desktop(
        Box::new(QuietDesktop(UnixStream::pair().expect("socket pair"))),
        Box::new(SizedEncoder {
            sizes: vec![800, 200_000, unstarted, 800],
            forced: forced.clone(),
        }),
        &cfg,
        1200,
        &[],
        Box::new(crate::upstream::NoSink),
    )
    .expect("session");
    session.pacer = Some(Pacer::new());
    let viewer = Principal {
        user: "owner".into(),
        install: "test".into(),
        class: PrincipalClass::User,
        interactive: true,
    };
    let mut table = SessionTable::new(HostPolicy {
        enabled: true,
        owner_user: viewer.user.clone(),
        grants: Vec::new(),
        consent: ConsentRule::AskOthers,
        unattended_allowed: true,
    });
    let id = table
        .start(StartRequest {
            key: "k",
            caller: Some(&viewer),
            for_client: None,
            mode: Mode::Control,
            console_user: None,
            now_ms: 0,
        })
        .expect("session starts");
    let mut t = Outage {
        session,
        carrier: RecordingCarrier::default(),
        table,
        id,
        viewer,
        forced,
        sent: 0,
        started_frame: 0,
        unstarted_frame: 0,
    };

    // The path works: a small first frame is answered at once.
    let first = t.session.engine.start(now_us()).expect("first frame");
    t.session.encoder.submit(first);
    send_next_frame(&mut t.session, &mut t.carrier);
    let answered: Vec<Arrival> = t
        .carrier
        .sent
        .iter()
        .map(|d| Arrival { transport_seq: header(d).transport_seq, arrival_us: 1_000 })
        .collect();
    let first_frame = header(&t.carrier.sent[0]).frame;
    t.feedback(answered, first_frame);
    let before = t.carrier.sent.len();

    // A large frame: the pacer sends its head at once and holds the rest; the next
    // frame queues behind it.
    std::thread::sleep(Duration::from_millis(20));
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    let large = t.session.engine.damage(0, small, now_us()).expect("second frame");
    t.session.encoder.submit(large);
    send_next_frame(&mut t.session, &mut t.carrier);
    t.started_frame = header(&t.carrier.sent[before]).frame;
    std::thread::sleep(Duration::from_millis(20));
    let next = t.session.engine.damage(0, small, now_us()).expect("third frame");
    t.unstarted_frame = next.frame;
    t.session.encoder.submit(next);
    send_next_frame(&mut t.session, &mut t.carrier);
    let head = t.carrier.sent[before..].to_vec();
    assert!(
        head.iter().all(|d| header(d).frame == t.started_frame),
        "the third frame has not started"
    );

    // The radio goes away for longer than the outage threshold, then the head's
    // receipts arrive at once.
    std::thread::sleep(Duration::from_millis(150));
    let arrivals = head
        .iter()
        .map(|d| Arrival { transport_seq: header(d).transport_seq, arrival_us: 190_000 })
        .collect();
    t.feedback(arrivals, first_frame);
    t.sent = t.carrier.sent.len();
    t
}

fn queued_frames(session: &MediaSession) -> Vec<u32> {
    let mut frames: Vec<u32> = session
        .pacer
        .as_ref()
        .map_or(Vec::new(), |p| p.queued().map(|d| header(d).frame).collect());
    frames.dedup();
    frames
}

#[test]
fn an_outage_end_drops_an_unstarted_frame_larger_than_a_keyframe_and_finishes_the_started_one() {
    let mut t = outage_with_queue(60_000);
    assert_eq!(queued_frames(&t.session), vec![t.started_frame], "only the started frame stays");
    assert_eq!(t.session.paced.0.iter().filter(|f| f.frame == t.unstarted_frame).count(), 0);

    // The started frame finishes, then the newest frame goes out as a keyframe.
    while !t.session.pacer.as_ref().is_some_and(Pacer::is_empty) {
        std::thread::sleep(Duration::from_millis(2));
        t.session.send_paced(&mut t.carrier).expect("send paced");
    }
    let rest = t.carrier.sent[t.sent..].to_vec();
    assert!(rest.iter().all(|d| header(d).frame == t.started_frame), "a dropped datagram went out");
    send_next_frame(&mut t.session, &mut t.carrier);
    let fresh = t.carrier.sent[t.sent + rest.len()..].to_vec();
    let h = header(&fresh[0]);
    assert!(h.frame > t.unstarted_frame, "{} after {}", h.frame, t.unstarted_frame);
    assert_ne!(h.flags & flags::KEYFRAME, 0, "the next frame is a keyframe");
    assert_eq!(t.forced.lock().expect("lock").as_slice(), &[true, false, false, true]);

    // Their receipts, then a quiet feedback after the reorder grace: no loss.
    let arrivals = rest
        .iter()
        .chain(&fresh)
        .map(|d| Arrival { transport_seq: header(d).transport_seq, arrival_us: 200_000 })
        .collect();
    t.feedback(arrivals, h.frame);
    std::thread::sleep(Duration::from_millis(120));
    t.feedback(Vec::new(), h.frame);
    assert_eq!(t.session.engine.stats().loss, 0.0, "dropped datagrams read as loss");
}

#[test]
fn an_outage_end_sends_a_queue_smaller_than_a_keyframe_and_forces_none() {
    let mut t = outage_with_queue(100);
    assert_eq!(queued_frames(&t.session), vec![t.started_frame, t.unstarted_frame]);
    while !t.session.pacer.as_ref().is_some_and(Pacer::is_empty) {
        std::thread::sleep(Duration::from_millis(2));
        t.session.send_paced(&mut t.carrier).expect("send paced");
    }
    assert_eq!(header(t.carrier.sent.last().expect("sent")).frame, t.unstarted_frame);
    let small = Rect { x: 1, y: 1, width: 10, height: 10 };
    if let Some(req) = t.session.engine.damage(0, small, now_us()) {
        t.session.encoder.submit(req);
    }
    send_next_frame(&mut t.session, &mut t.carrier);
    let h = header(t.carrier.sent.last().expect("sent"));
    assert_eq!(h.flags & flags::KEYFRAME, 0, "no keyframe without a drop");
    assert_eq!(t.forced.lock().expect("lock").as_slice(), &[true, false, false, false]);
}
