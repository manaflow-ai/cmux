//! D12 detector, host half: when an outage ends, what queued in the pacer during it never
//! goes out, its missing receipts are not loss, and the newest frame goes out next as a
//! keyframe.

use super::*;
use crate::carrier::{Carrier, Incoming};
use crate::wire::Control;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, PrincipalClass};
use cmux_rd_core::session::StartRequest;
use cmux_rd_proto::{flags, Arrival, DatagramHeader, DatagramKind, Feedback, InputEvent};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct QuietDesktop((UnixStream, UnixStream));

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

/// The first frame is a large keyframe (many datagrams, so the pacer holds most of
/// it); later frames are small. Records each encode's `force_idr`.
struct SizedEncoder {
    forced: Arc<Mutex<Vec<bool>>>,
}

impl FrameSource for SizedEncoder {
    fn capture(&mut self, _damage: Rect) -> Res<()> {
        Ok(())
    }
    fn encode(&mut self, force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        let mut forced = self.forced.lock().expect("lock");
        let len = if forced.len() == 1 { 60_000 } else { 800 };
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
struct RecordingCarrier {
    sent: Vec<Vec<u8>>,
}

impl Carrier for RecordingCarrier {
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
    fn send_control(&mut self, _control: &Control) -> std::io::Result<()> {
        Ok(())
    }
}

fn header(d: &[u8]) -> DatagramHeader {
    DatagramHeader::decode(d).expect("header").0
}

fn feedback(arrivals: Vec<Arrival>, acked_frame: u32) -> Vec<u8> {
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

#[test]
fn an_outage_end_drops_the_queued_datagrams_and_sends_the_newest_frame() {
    let forced = Arc::new(Mutex::new(Vec::new()));
    let cfg = SessionCfg {
        display: String::new(),
        max_fps: 60,
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
        frames_in_flight: 2,
        input_frame_now: false,
        max_width: None,
        capture: crate::capture_backend::CaptureBackend::default(),
    };
    let mut session = MediaSession::with_desktop(
        Box::new(QuietDesktop(UnixStream::pair().expect("socket pair"))),
        Box::new(SizedEncoder { forced: forced.clone() }),
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
    let mut carrier = RecordingCarrier::default();

    // The path works: a small first frame is answered at once.
    let first = session.engine.start(now_us()).expect("first frame");
    session.encoder.submit(first);
    send_next_frame(&mut session, &mut carrier);
    let answered: Vec<Arrival> = carrier
        .sent
        .iter()
        .map(|d| Arrival { transport_seq: header(d).transport_seq, arrival_us: 1_000 })
        .collect();
    let first_frame = header(&carrier.sent[0]).frame;
    session.on_datagram(&mut carrier, &feedback(answered, first_frame), &table, id, &viewer);
    let before = carrier.sent.len();

    // A large frame: the pacer sends its head at once and holds the rest.
    std::thread::sleep(Duration::from_millis(20));
    let whole = Rect { x: 0, y: 0, width: 640, height: 480 };
    let large = session.engine.damage(0, whole, now_us()).expect("second frame");
    session.encoder.submit(large);
    send_next_frame(&mut session, &mut carrier);
    let sent_first = carrier.sent[before..].to_vec();
    let queued = session.pacer.as_ref().map_or(0, Pacer::queued_bytes);
    assert!(queued > 0, "the pacer holds part of the frame");
    let stale_frame = header(&sent_first[0]).frame;

    // The radio goes away for longer than the outage threshold, then the head's
    // receipts arrive at once.
    std::thread::sleep(Duration::from_millis(150));
    let arrivals = sent_first
        .iter()
        .map(|d| Arrival { transport_seq: header(d).transport_seq, arrival_us: 170_000 })
        .collect();
    session.on_datagram(&mut carrier, &feedback(arrivals, first_frame), &table, id, &viewer);
    assert_eq!(session.pacer.as_ref().map_or(0, Pacer::queued_bytes), 0, "queue emptied");
    assert!(session.paced_logs.is_empty());
    session.send_paced(&mut carrier).expect("send paced");
    assert_eq!(
        carrier.sent.len(),
        before + sent_first.len(),
        "a datagram queued through the outage went out after it"
    );

    // The newest frame goes out next, as a keyframe.
    send_next_frame(&mut session, &mut carrier);
    let fresh: Vec<Vec<u8>> = carrier.sent[before + sent_first.len()..].to_vec();
    let h = header(&fresh[0]);
    assert!(h.frame > stale_frame, "{} after {stale_frame}", h.frame);
    assert_ne!(h.flags & flags::KEYFRAME, 0, "the next frame is a keyframe");
    assert_eq!(forced.lock().expect("lock").as_slice(), &[true, false, true]);

    // Its receipts, then a quiet feedback after the reorder grace: no loss.
    let fresh_arrivals = fresh
        .iter()
        .map(|d| Arrival { transport_seq: header(d).transport_seq, arrival_us: 180_000 })
        .collect();
    session.on_datagram(&mut carrier, &feedback(fresh_arrivals, h.frame), &table, id, &viewer);
    std::thread::sleep(Duration::from_millis(120));
    session.on_datagram(&mut carrier, &feedback(Vec::new(), h.frame), &table, id, &viewer);
    assert_eq!(session.engine.stats().loss, 0.0, "dropped datagrams read as loss");
}
