//! The media pump against a fake encoder and the viewer core the Mac client
//! links (cmux-rd-ffi): frames reach the viewer as complete frames, an idle
//! page costs nothing, damage coalesces onto the latest frame, recovery
//! encodes the held frame, and rb input arrives exactly once.

use std::cell::RefCell;
use std::rc::Rc;

use cmux_rd_core::flow::Rect;
use cmux_rd_engine::EngineConfig;
use cmux_rd_ffi::{Carrier, InputChannel, Session};
use cmux_rd_proto::{InputEvent as RdInput, flags};
use cmux_remote_browser::proto::InputEvent;
use cmux_remote_browser_host::pump::{FrameEncoder, Pump, PumpOut};

/// What the fake shim saw: frame ids encoded and frame ids released.
#[derive(Default)]
struct Log {
    encoded: Vec<(u32, bool)>,
    released: Vec<u32>,
}

/// A captured frame; dropping it releases its lease.
struct Frame {
    id: u32,
    log: Rc<RefCell<Log>>,
}

impl Drop for Frame {
    fn drop(&mut self) {
        self.log.borrow_mut().released.push(self.id);
    }
}

struct Fake {
    log: Rc<RefCell<Log>>,
    kbps: u32,
    fail_next: bool,
}

impl FrameEncoder for Fake {
    type Frame = Frame;

    fn encode(
        &mut self,
        frame: &Frame,
        _damage: Rect,
        force_idr: bool,
        _pts_us: i64,
        out: &mut Vec<u8>,
    ) -> Result<bool, String> {
        out.clear();
        if std::mem::take(&mut self.fail_next) {
            return Err("fake failure".into());
        }
        let idr = force_idr || self.log.borrow().encoded.is_empty();
        self.log.borrow_mut().encoded.push((frame.id, idr));
        out.extend_from_slice(&[0, 0, 0, 1, if idr { 0x65 } else { 0x41 }]);
        out.extend(std::iter::repeat_n(u8::try_from(frame.id % 251).unwrap_or(0), 3000));
        Ok(idr)
    }

    fn set_kbps(&mut self, kbps: u32) {
        self.kbps = kbps;
    }

    fn kbps(&self) -> u32 {
        self.kbps
    }
}

const W: u32 = 640;
const H: u32 = 400;

struct Rig {
    pump: Pump<Fake>,
    viewer: Session,
    log: Rc<RefCell<Log>>,
    now: u64,
    /// Complete frames the viewer got: (frame number, keyframe, first payload byte).
    got: Vec<(u32, bool, u8)>,
}

impl Rig {
    fn new() -> Self {
        let log = Rc::new(RefCell::new(Log::default()));
        let cfg = EngineConfig { width: W, height: H, max_fps: 60, ..EngineConfig::default() };
        let encoder = Fake { log: log.clone(), kbps: 4000, fail_next: false };
        Self {
            pump: Pump::new(cfg, encoder, 0),
            viewer: Session::new(Carrier::Datagram, 500_000, 50_000),
            log,
            now: 0,
            got: Vec::new(),
        }
    }

    fn frame(&self, id: u32) -> Frame {
        Frame { id, log: self.log.clone() }
    }

    fn advance(&mut self, us: u64) {
        self.now += us;
    }

    /// Delivers the pump's datagrams to the viewer and collects frames.
    fn deliver(&mut self, out: &PumpOut) {
        for d in &out.datagrams {
            self.viewer.push_datagram(d, self.now).expect("viewer accepts the datagram");
        }
        while let Some((stream, frame)) = self.viewer.pop_frame() {
            assert_eq!(stream, 0);
            let first = frame.body.access_unit.get(5).copied().unwrap_or(0);
            self.got.push((frame.frame, frame.flags & flags::KEYFRAME != 0, first));
        }
    }

    /// Sends every due viewer feedback datagram to the pump.
    fn feedback(&mut self) -> PumpOut {
        let mut all = PumpOut::default();
        self.viewer.tick(self.now);
        while let Some(d) = self.viewer.feedback(self.now) {
            let out = self.pump.datagram(&d, true, self.now);
            all.datagrams.extend(out.datagrams);
            all.input.extend(out.input);
            all.refresh |= out.refresh;
        }
        all
    }

    fn capture(&mut self, id: u32, damage: Rect) -> PumpOut {
        let frame = self.frame(id);
        let out = self.pump.frame(frame, damage, self.now, self.now);
        self.deliver(&out);
        out
    }
}

fn small() -> Rect {
    Rect { x: 200, y: 200, width: 32, height: 32 }
}

#[test]
fn start_without_a_frame_asks_for_a_refresh_and_the_first_frame_is_a_keyframe() {
    let mut rig = Rig::new();
    let start = rig.pump.start(0);
    assert!(start.refresh, "no captured frame yet: the capture must refresh");
    assert!(start.datagrams.is_empty());
    rig.advance(1000);
    let out = rig.capture(1, small());
    assert!(!out.datagrams.is_empty());
    assert_eq!(rig.got.len(), 1);
    assert!(rig.got[0].1, "the first frame is a keyframe");
    assert_eq!(rig.log.borrow().encoded, vec![(1, true)]);
}

#[test]
fn an_idle_page_sends_nothing_and_needs_no_wakeup() {
    let mut rig = Rig::new();
    rig.pump.start(0);
    rig.capture(1, small());
    rig.advance(20_000);
    rig.feedback();
    rig.advance(20_000);
    rig.feedback();
    let encoded = rig.log.borrow().encoded.len();
    for _ in 0..50 {
        rig.advance(100_000);
        let out = rig.pump.tick(true, rig.now);
        assert!(out.datagrams.is_empty(), "an idle page sends no datagram");
        assert!(!out.refresh);
    }
    assert_eq!(rig.pump.next_deadline_us(), None, "an idle pump needs no wakeup");
    assert_eq!(rig.log.borrow().encoded.len(), encoded, "an idle page encodes nothing");
}

#[test]
fn damage_while_a_frame_is_in_flight_is_encoded_from_the_latest_frame_after_the_ack() {
    let mut rig = Rig::new();
    rig.pump.start(0);
    rig.capture(1, small());
    // Two frames before the viewer acknowledged frame 1: the gate holds them.
    rig.advance(1000);
    rig.capture(2, small());
    rig.advance(1000);
    rig.capture(3, small());
    assert_eq!(rig.log.borrow().encoded.len(), 1, "one frame in flight");
    assert!(rig.log.borrow().released.contains(&1), "frame 1's lease went back");
    assert!(rig.log.borrow().released.contains(&2), "frame 2 was replaced by frame 3");
    assert!(!rig.log.borrow().released.contains(&3), "the latest frame is held");
    // The ack opens the gate: frame 3 (not 2) goes out without a refresh.
    for _ in 0..10 {
        rig.advance(20_000);
        let out = rig.feedback();
        assert!(!out.refresh, "the held frame serves the request");
        rig.deliver(&out);
        let tick = rig.pump.tick(true, rig.now);
        rig.deliver(&tick);
        if rig.log.borrow().encoded.len() == 2 {
            break;
        }
    }
    assert_eq!(rig.log.borrow().encoded.last().copied(), Some((3, false)));
    assert_eq!(rig.got.len(), 2);
    assert_eq!(rig.got[1].2, 3, "the viewer got frame 3's pixels");
}

#[test]
fn a_viewer_recovery_request_is_served_from_the_held_frame_as_a_keyframe() {
    let mut rig = Rig::new();
    rig.pump.start(0);
    rig.capture(1, small());
    rig.advance(300_000);
    rig.feedback();
    rig.viewer.request_keyframe(0).expect("stream 0");
    let mut served = false;
    for _ in 0..10 {
        rig.advance(300_000);
        let out = rig.feedback();
        assert!(!out.refresh, "recovery needs no new capture");
        rig.deliver(&out);
        if rig.log.borrow().encoded.len() == 2 {
            served = true;
            break;
        }
    }
    assert!(served, "the recovery request produced a frame");
    assert_eq!(rig.log.borrow().encoded.last().copied(), Some((1, true)));
    assert!(rig.got.last().is_some_and(|g| g.1), "the viewer got a keyframe");
}

#[test]
fn rb_input_in_service_events_arrives_once_in_order() {
    let mut rig = Rig::new();
    rig.pump.start(0);
    let mut input = InputChannel::new(Carrier::Datagram, 50_000);
    let down = br#"{"e":"pointer","surface":0,"kind":"down","x":12.0,"y":30.0,"button":0,"buttons":1,"click_count":1,"modifiers":0,"pointer_type":"mouse"}"#;
    let up = br#"{"e":"pointer","surface":0,"kind":"up","x":12.0,"y":30.0,"button":0,"buttons":0,"click_count":1,"modifiers":0,"pointer_type":"mouse"}"#;
    input.push(RdInput::Service { must_deliver: true, bytes: down.to_vec() });
    input.push(RdInput::Service { must_deliver: true, bytes: b"not json".to_vec() });
    input.push(RdInput::Service { must_deliver: true, bytes: up.to_vec() });
    let packet = input.packet(rig.now).expect("an input datagram");
    let first = rig.pump.datagram(&packet, true, rig.now);
    let again = rig.pump.datagram(&packet, true, rig.now);
    assert_eq!(first.input.len(), 2, "two rb events; the bad one is dropped");
    assert!(matches!(first.input[0], InputEvent::Pointer { .. }));
    assert!(again.input.is_empty(), "a repeated packet applies nothing");
    assert!(!first.datagrams.is_empty(), "the pump acknowledges input");
    assert_eq!(rig.pump.stats().bad_input, 1);
}

#[test]
fn an_encoder_failure_opens_the_gate_for_the_next_frame() {
    let mut rig = Rig::new();
    rig.pump.start(0);
    rig.capture(1, small());
    rig.advance(20_000);
    rig.feedback();
    rig.pump_encoder_fails_next();
    rig.advance(20_000);
    rig.capture(2, small());
    assert_eq!(rig.pump.stats().encode_errors, 1);
    rig.advance(20_000);
    rig.capture(3, small());
    assert_eq!(rig.log.borrow().encoded.last().map(|e| e.0), Some(3));
}

impl Rig {
    fn pump_encoder_fails_next(&mut self) {
        self.pump.encoder_mut().fail_next = true;
    }
}
