//! No wait on the first frame: a session runs (Welcome is out, input goes through) on a
//! desktop that has no picture yet; the start keyframe is encoded once the first frame
//! lands, and a display that never sends one still ends the session, later.

use super::*;
use crate::carrier::{Carrier, Incoming};
use crate::wire::Control;
use cmux_rd_core::policy::{ConsentRule, HostPolicy, Mode, PrincipalClass};
use cmux_rd_core::session::StartRequest;
use cmux_rd_proto::{InputEvent, InputPacket};
use std::io::Write;
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct Seen {
    /// The display has sent its first frame.
    has_frame: AtomicBool,
    injected: AtomicBool,
    /// A capture ran before the first frame (the macOS host fails it: "no captured frame yet").
    captured_without_frame: AtomicBool,
    /// Each encode's `force_idr`.
    encodes: Mutex<Vec<bool>>,
}

/// A display whose first frame comes only when the test says.
struct LateDesktop {
    seen: Arc<Seen>,
    wake: (UnixStream, UnixStream),
}

impl Desktop for LateDesktop {
    fn size(&self) -> (u32, u32) {
        (64, 64)
    }
    fn fd(&self) -> RawFd {
        self.wake.1.as_raw_fd()
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
    fn has_frame(&self) -> bool {
        self.seen.has_frame.load(SeqCst)
    }
}

struct RecordingEncoder(Arc<Seen>);

impl FrameSource for RecordingEncoder {
    fn capture(&mut self, _damage: Rect) -> Res<()> {
        if !self.0.has_frame.load(SeqCst) {
            self.0.captured_without_frame.store(true, SeqCst);
            return Err("no captured frame yet".into());
        }
        Ok(())
    }
    fn encode(&mut self, force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        self.0.encodes.lock().expect("lock").push(force_idr);
        out.extend_from_slice(&[0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00]);
        Ok(force_idr)
    }
    fn set_bitrate(&mut self, _kbps: u32) {}
    fn kbps(&self) -> u32 {
        1000
    }
    fn encoder_name(&self) -> String {
        "recording test encoder".into()
    }
}

/// Sends one key press at once; once it is injected (still no frame, no encode), the
/// display sends its first frame; once a frame was encoded, stops the session. With
/// `frame_comes: false` the display never sends one.
struct Viewer {
    seen: Arc<Seen>,
    display_wake: UnixStream,
    sent_input: bool,
    frame_comes: bool,
    /// Whether an encode had run when the key press was injected.
    encoded_before_input: Option<bool>,
    ready: (UnixStream, UnixStream),
}

impl Carrier for Viewer {
    fn fds(&self) -> Vec<RawFd> {
        vec![self.ready.1.as_raw_fd()]
    }
    fn receive(&mut self, out: &mut Vec<Incoming>) -> Result<(), String> {
        if !self.sent_input {
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
        if self.seen.injected.load(SeqCst) && self.encoded_before_input.is_none() {
            self.encoded_before_input = Some(!self.seen.encodes.lock().expect("lock").is_empty());
            if self.frame_comes {
                self.seen.has_frame.store(true, SeqCst);
                (&self.display_wake).write_all(&[1]).expect("wake the display");
            }
        }
        if !self.seen.encodes.lock().expect("lock").is_empty() {
            out.push(Incoming::Control(Control::Stop));
        }
        Ok(())
    }
    fn send_datagram(&mut self, _datagram: &[u8]) -> std::io::Result<()> {
        Ok(())
    }
    fn send_control(&mut self, _control: &Control) -> std::io::Result<()> {
        Ok(())
    }
}

fn cfg() -> SessionCfg {
    SessionCfg {
        display: String::new(),
        max_fps: 60,
        start_kbps: 1000,
        max_kbps: 2000,
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
    }
}

/// Runs a session on a display with no frame yet; returns the end reason and the viewer.
fn run(frame_comes: bool, first_frame_timeout_ns: u64) -> (String, Viewer, Arc<Seen>) {
    let seen = Arc::new(Seen::default());
    let wake = UnixStream::pair().expect("socket pair");
    let display_wake = wake.0.try_clone().expect("clone");
    let desktop = LateDesktop { seen: seen.clone(), wake };
    // The session opens (and serve sends Welcome) with no frame from the display.
    let mut session = MediaSession::with_desktop(
        Box::new(desktop),
        Box::new(RecordingEncoder(seen.clone())),
        &cfg(),
        1200,
        &[],
        Box::new(crate::upstream::NoSink),
    )
    .expect("a session opens before the display's first frame");
    session.first_frame_timeout_ns = first_frame_timeout_ns;
    let ready = UnixStream::pair().expect("socket pair");
    (&ready.0).write_all(&[1]).expect("make the carrier readable");
    let mut viewer = Viewer {
        seen: seen.clone(),
        display_wake,
        sent_input: false,
        frame_comes,
        encoded_before_input: None,
        ready,
    };
    let principal = Principal {
        user: "owner".into(),
        install: "test".into(),
        class: PrincipalClass::User,
        interactive: true,
    };
    let mut table = SessionTable::new(HostPolicy {
        enabled: true,
        owner_user: principal.user.clone(),
        grants: Vec::new(),
        consent: ConsentRule::AskOthers,
        unattended_allowed: true,
    });
    let id = table
        .start(StartRequest {
            key: "k",
            caller: Some(&principal),
            for_client: None,
            mode: Mode::Control,
            console_user: None,
            now_ms: 0,
        })
        .expect("session starts");
    let reason = session.run(&mut viewer, &mut table, id, &principal);
    (reason, viewer, seen)
}

#[test]
fn input_goes_through_before_the_first_frame_and_the_start_keyframe_follows_it() {
    let (reason, viewer, seen) = run(true, FIRST_FRAME_TIMEOUT_NS);
    assert_eq!(reason, "stopped by viewer");
    assert!(seen.injected.load(SeqCst), "the key press was never injected");
    assert_eq!(viewer.encoded_before_input, Some(false), "input waited for a frame");
    assert!(!seen.captured_without_frame.load(SeqCst), "a capture ran before the first frame");
    let encodes = seen.encodes.lock().expect("lock");
    assert_eq!(encodes.first(), Some(&true), "the first frame is the start keyframe: {encodes:?}");
}

#[test]
fn a_display_that_never_sends_a_frame_ends_the_session_later() {
    let (reason, viewer, seen) = run(false, 200_000_000);
    assert_eq!(reason, NO_FIRST_FRAME);
    assert!(seen.injected.load(SeqCst), "input went through while the display was silent");
    assert_eq!(viewer.encoded_before_input, Some(false));
    assert!(!seen.captured_without_frame.load(SeqCst), "a capture ran before the first frame");
    assert!(seen.encodes.lock().expect("lock").is_empty());
}
