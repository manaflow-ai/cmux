//! The media session's encode runs off its loop: input is injected while a frame encodes
//! (stream.rs's `encode_off_loop_tests`, moved out of the file to keep it in budget).

use super::*;
use crate::carrier::{Carrier, DatagramDeparture, Incoming, MediaQueueStats};
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, PrincipalClass};
use cmux_rd_core::session::StartRequest;
use cmux_rd_proto::{InputEvent, InputPacket};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::Duration;

#[derive(Default)]
struct Seen {
    encode_started: AtomicBool,
    injected: AtomicBool,
    encode_returned: AtomicBool,
    injected_before_encode_returned: AtomicBool,
}

struct FakeDesktop {
    seen: Arc<Seen>,
    /// Never readable: this desktop reports no damage.
    quiet: (UnixStream, UnixStream),
}

impl Desktop for FakeDesktop {
    fn size(&self) -> (u32, u32) {
        (64, 64)
    }
    fn fd(&self) -> RawFd {
        self.quiet.1.as_raw_fd()
    }
    fn drain(&mut self, _out: &mut Vec<Rect>) -> Res<()> {
        Ok(())
    }
    fn inject(&mut self, _event: &InputEvent) -> Res<()> {
        self.seen.injected.store(true, SeqCst);
        Ok(())
    }
    fn release_all(&mut self) -> Res<()> {
        Ok(())
    }
}

/// Its first encode blocks until the test releases it (at most 5 s), like a slow 4K encode.
struct BlockingEncoder {
    seen: Arc<Seen>,
    release: mpsc::Receiver<()>,
    first: bool,
}

impl FrameSource for BlockingEncoder {
    fn capture(&mut self, _damage: Rect) -> Res<()> {
        Ok(())
    }
    fn encode(&mut self, _force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        if std::mem::take(&mut self.first) {
            self.seen.encode_started.store(true, SeqCst);
            let _ = self.release.recv_timeout(Duration::from_secs(5));
            let injected = self.seen.injected.load(SeqCst);
            self.seen.injected_before_encode_returned.store(injected, SeqCst);
            self.seen.encode_returned.store(true, SeqCst);
        }
        out.extend_from_slice(&[0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00]);
        Ok(true)
    }
    fn set_bitrate(&mut self, _kbps: u32) {}
    fn kbps(&self) -> u32 {
        1000
    }
    fn encoder_name(&self) -> String {
        "blocking test encoder".into()
    }
}

/// Sends one key press once the encode started, releases the encode once the press was
/// injected, and stops the session once the encode returned.
struct FakeCarrier {
    seen: Arc<Seen>,
    release: Option<mpsc::Sender<()>>,
    sent_input: bool,
    queue_stats: Option<MediaQueueStats>,
    /// Always readable, so the loop keeps reading.
    ready: (UnixStream, UnixStream),
}

impl Carrier for FakeCarrier {
    fn drain_departures(&mut self, _out: &mut Vec<crate::carrier::DatagramDeparture>) {}

    fn departure_overflows(&self) -> u64 {
        0
    }

    fn fds(&self) -> Vec<RawFd> {
        vec![self.ready.1.as_raw_fd()]
    }
    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        if self.seen.encode_started.load(SeqCst) && !self.sent_input {
            self.sent_input = true;
            let mut d = DatagramHeader {
                flags: 0,
                kind: DatagramKind::Input,
                stream: 0,
                frame: 0,
                index: 0,
                count: 0,
                fec_count: 0,
                transport_seq: 0,
            }
            .encode()
            .to_vec();
            let packet = InputPacket {
                first_seq: 1,
                events: vec![InputEvent::Key { usage: 4, down: true }],
            };
            d.extend_from_slice(&packet.encode());
            out.push(Incoming::Datagram(d));
        }
        if self.seen.injected.load(SeqCst) {
            if let Some(release) = self.release.take() {
                let _ = release.send(());
            }
        }
        if self.seen.encode_returned.load(SeqCst) {
            out.push(Incoming::Control(Box::new(Control::Stop)));
        }
        Ok(())
    }
    fn send_datagram(&mut self, _datagram: &[u8]) -> std::io::Result<()> {
        Ok(())
    }
    fn send_datagram_frame(
        &mut self,
        _datagrams: Vec<Vec<u8>>,
        _droppable: bool,
    ) -> std::io::Result<()> {
        Ok(())
    }
    fn media_queue_stats(&self) -> Option<MediaQueueStats> {
        self.queue_stats
    }
    fn send_control(&mut self, _control: &Control) -> std::io::Result<()> {
        Ok(())
    }
}

fn cfg() -> SessionCfg {
    SessionCfg {
        display: String::new(),
        display_pick: None,
        window: None,
        max_fps: 60,
        encode_profile: Default::default(),
        start_kbps: 1000,
        max_kbps: 2000,
        pin_kbps: None,
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
        rtt_tail_probe: false,
        resolution_ladder: false,
        max_qp: cmux_rd_core::resolution::DEFAULT_MAX_QP,
        max_width: None,
        show_cursor: true,
        capture: crate::capture_backend::CaptureBackend::default(),
    }
}

#[test]
fn viewer_input_is_injected_while_a_frame_encodes() {
    let seen = Arc::new(Seen::default());
    let (release_tx, release_rx) = mpsc::channel();
    let desktop =
        FakeDesktop { seen: seen.clone(), quiet: UnixStream::pair().expect("socket pair") };
    let encoder = BlockingEncoder { seen: seen.clone(), release: release_rx, first: true };
    let mut session = MediaSession::with_desktop(
        Box::new(desktop),
        Box::new(encoder),
        &cfg(),
        1200,
        &[],
        Box::new(crate::upstream::NoSink),
    )
    .expect("session");
    let ready = UnixStream::pair().expect("socket pair");
    use std::io::Write;
    (&ready.0).write_all(&[1]).expect("make the carrier readable");
    let mut carrier = FakeCarrier {
        seen: seen.clone(),
        release: Some(release_tx),
        sent_input: false,
        queue_stats: None,
        ready,
    };
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
    assert!(table.may_inject_input(id, &viewer));
    let reason = session.run(&mut carrier, &mut table, id, &viewer);
    assert_eq!(reason, "stopped by viewer");
    assert!(seen.injected.load(SeqCst), "the key press was never injected");
    assert!(
        seen.injected_before_encode_returned.load(SeqCst),
        "the key press waited for the encode to finish"
    );
}

/// cmux#50591: a viewer that negotiated `h264.baseline` (OpenH264) gets Constrained Baseline
/// whatever `--profile` says; any other viewer keeps the host's profile.
#[test]
fn an_openh264_viewer_gets_constrained_baseline() {
    use cmux_rd_core::service::caps::{CLOCK, H264_BASELINE};
    let high = SessionCfg { profile: "high".into(), ..cfg() };
    let asked = [CLOCK.to_owned(), H264_BASELINE.to_owned()];
    assert_eq!(super::session_cfg(&high, &asked).profile, "baseline");
    assert_eq!(super::session_cfg(&high, &[CLOCK.to_owned()]).profile, "high");
    assert!(super::offers_h264_baseline("videotoolbox"));
    assert!(super::offers_h264_baseline("openh264"));
    assert!(!super::offers_h264_baseline("vp9"));
}

#[test]
fn a_pending_send_queue_blocks_the_next_encoded_frame() {
    let carrier = FakeCarrier {
        seen: Arc::new(Seen::default()),
        release: None,
        sent_input: false,
        queue_stats: Some(MediaQueueStats {
            queue_frames: 1,
            queue_datagrams: 4,
            ..MediaQueueStats::default()
        }),
        ready: UnixStream::pair().expect("socket pair"),
    };
    assert!(encoded_frame_waits_for_queues(&carrier, None, false));
    assert!(!encoded_frame_waits_for_queues(&carrier, None, true));
}

/// Like `LinkCarrier`: `send_datagram` only enqueues; a receipt appears when the transport
/// writes the datagram, stamped with that write's time.
#[derive(Default)]
struct EnqueueOnlyCarrier {
    queued: Vec<Vec<u8>>,
    receipts: Vec<DatagramDeparture>,
}

impl EnqueueOnlyCarrier {
    /// The transport writes everything queued at `departed_us`.
    fn transmit(&mut self, departed_us: u64) {
        for datagram in self.queued.drain(..) {
            let (header, _) = DatagramHeader::decode(&datagram).expect("header");
            self.receipts.push(DatagramDeparture {
                header,
                departed_us,
                wire_bytes: datagram.len(),
            });
        }
    }
}

impl Carrier for EnqueueOnlyCarrier {
    fn drain_departures(&mut self, out: &mut Vec<DatagramDeparture>) {
        out.append(&mut self.receipts);
    }
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
        self.queued.push(datagram.to_vec());
        Ok(())
    }
    fn send_datagram_frame(
        &mut self,
        datagrams: Vec<Vec<u8>>,
        _droppable: bool,
    ) -> std::io::Result<()> {
        self.queued.extend(datagrams);
        Ok(())
    }
    fn send_control(&mut self, _control: &Control) -> std::io::Result<()> {
        Ok(())
    }
}

/// Review F1 on #44555: a datagram the carrier accepted but has not written has not departed.
#[test]
fn an_enqueued_datagram_has_no_departure_until_its_receipt() {
    let header = DatagramHeader {
        flags: 0,
        kind: DatagramKind::Video,
        stream: 0,
        frame: 7,
        index: 0,
        count: 1,
        fec_count: 0,
        transport_seq: 19,
    };
    let mut carrier = EnqueueOnlyCarrier::default();
    carrier.send_datagram(&header.encode()).expect("enqueued");
    let mut receipts = Vec::new();
    let mut stamps = Vec::new();
    drain_departures(&mut carrier, &mut receipts, |h, at| stamps.push((*h, at)));
    assert!(stamps.is_empty(), "send_datagram returning is an enqueue, not a departure");

    carrier.transmit(1_234_567);
    receipts.clear();
    drain_departures(&mut carrier, &mut receipts, |h, at| stamps.push((*h, at)));
    assert_eq!(stamps, vec![(header, 1_234_567)], "stamped with the receipt's own time");
    assert_eq!(receipts.len(), 1);
}

/// Encodes instantly: every frame is a tiny IDR access unit.
struct InstantEncoder;

impl FrameSource for InstantEncoder {
    fn capture(&mut self, _damage: Rect) -> Res<()> {
        Ok(())
    }
    fn encode(&mut self, _force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        out.extend_from_slice(&[0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00]);
        Ok(true)
    }
    fn set_bitrate(&mut self, _kbps: u32) {}
    fn kbps(&self) -> u32 {
        1000
    }
    fn encoder_name(&self) -> String {
        "instant test encoder".into()
    }
}

/// Like the link's carrier: an empty media queue, frames handed over whole. Records when the
/// first video datagram left, then stops the session (or gives up after `give_up`).
struct FirstFrameCarrier {
    started: std::time::Instant,
    give_up: Duration,
    first_video: Option<Duration>,
    queue_stats: Option<MediaQueueStats>,
    ready: (UnixStream, UnixStream),
}

impl FirstFrameCarrier {
    fn note(&mut self, datagram: &[u8]) {
        let video = DatagramHeader::decode(datagram)
            .is_ok_and(|(h, _)| matches!(h.kind, DatagramKind::Video));
        if video && self.first_video.is_none() {
            self.first_video = Some(self.started.elapsed());
        }
    }
}

impl Carrier for FirstFrameCarrier {
    fn drain_departures(&mut self, _out: &mut Vec<DatagramDeparture>) {}
    fn departure_overflows(&self) -> u64 {
        0
    }
    fn fds(&self) -> Vec<RawFd> {
        vec![self.ready.1.as_raw_fd()]
    }
    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        if self.first_video.is_some() || self.started.elapsed() > self.give_up {
            out.push(Incoming::Control(Box::new(Control::Stop)));
        }
        Ok(())
    }
    fn send_datagram(&mut self, datagram: &[u8]) -> std::io::Result<()> {
        self.note(datagram);
        Ok(())
    }
    fn send_datagram_frame(
        &mut self,
        datagrams: Vec<Vec<u8>>,
        _droppable: bool,
    ) -> std::io::Result<()> {
        for d in &datagrams {
            self.note(d);
        }
        Ok(())
    }
    fn media_queue_stats(&self) -> Option<MediaQueueStats> {
        self.queue_stats
    }
    fn send_control(&mut self, _control: &Control) -> std::io::Result<()> {
        Ok(())
    }
}

/// How long after `run` starts the first keyframe's first datagram leaves, with an encoder
/// that takes no time.
fn first_keyframe_after(queue_stats: Option<MediaQueueStats>) -> Option<Duration> {
    let desktop = FakeDesktop {
        seen: Arc::new(Seen::default()),
        quiet: UnixStream::pair().expect("socket pair"),
    };
    let fps = 30;
    let mut session = MediaSession::with_desktop(
        Box::new(desktop),
        Box::new(InstantEncoder),
        &SessionCfg { max_fps: fps, ..cfg() },
        1200,
        &[],
        Box::new(crate::upstream::NoSink),
    )
    .expect("session");
    let ready = UnixStream::pair().expect("socket pair");
    use std::io::Write;
    (&ready.0).write_all(&[1]).expect("make the carrier readable");
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
    let mut carrier = FirstFrameCarrier {
        started: std::time::Instant::now(),
        give_up: Duration::from_secs(6),
        first_video: None,
        queue_stats,
        ready,
    };
    let reason = session.run(&mut carrier, &mut table, id, &viewer);
    assert_eq!(reason, "stopped by viewer");
    carrier.first_video
}

/// The first keyframe leaves within one frame interval (30 fps: 33 ms) of the session's start,
/// over a carrier with no media queue and over one with an empty one (the link).
#[test]
fn the_first_keyframe_leaves_within_one_frame_interval() {
    let interval = Duration::from_millis(1000 / 30);
    for stats in [None, Some(MediaQueueStats::default())] {
        let first = first_keyframe_after(stats);
        eprintln!("first keyframe after {first:?} (queue stats {stats:?})");
        let first = first.expect("no keyframe left in 6 s");
        assert!(first <= interval, "first keyframe after {first:?}, over {interval:?}");
    }
}

/// [`InstantEncoder`] that, like OpenH264, only makes Constrained Baseline.
struct BaselineOnlyEncoder;

impl FrameSource for BaselineOnlyEncoder {
    fn capture(&mut self, damage: Rect) -> Res<()> {
        InstantEncoder.capture(damage)
    }
    fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        InstantEncoder.encode(force_idr, pts_us, out)
    }
    fn set_bitrate(&mut self, _kbps: u32) {}
    fn kbps(&self) -> u32 {
        1000
    }
    fn encoder_name(&self) -> String {
        "baseline-only test encoder".into()
    }
    fn constrained_baseline(&self) -> bool {
        true
    }
}

fn opened_for_high(frames: Box<dyn FrameSource>) -> OpenedDesktop {
    let desktop = FakeDesktop {
        seen: Arc::new(Seen::default()),
        quiet: UnixStream::pair().expect("socket pair"),
    };
    OpenedDesktop {
        desktop: Box::new(desktop),
        frames,
        cursor: false,
        profile: "high".into(),
        open_us: 0,
        ready_us: 0,
    }
}

/// The desktop `cmux-rd serve` opened during the handshake (for the host's `high`) serves a
/// `h264.baseline` viewer when its encoder only makes Constrained Baseline (OpenH264): opening
/// it again put 340-410 ms between the viewer's start and the first keyframe. An encoder that
/// honours the profile (VAAPI, x264, VideoToolbox) still opens again for baseline.
#[test]
fn a_baseline_viewer_keeps_the_handshakes_desktop_when_the_encoder_only_makes_baseline() {
    let openh264 = opened_for_high(Box::new(BaselineOnlyEncoder));
    assert!(openh264.serves_profile("baseline"));
    assert!(openh264.serves_profile("high"));
    let hardware = opened_for_high(Box::new(InstantEncoder));
    assert!(!hardware.serves_profile("baseline"));
    assert!(hardware.serves_profile("high"));
}
