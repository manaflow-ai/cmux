use super::*;
use cmux_rd_core::flow::Rect;
use cmux_rd_core::resolution::Picture;

/// Records every bitrate it is given, and the picture each capture was made for.
struct Recorder {
    kbps: u32,
    set: Vec<u32>,
    picture: Option<Picture>,
    captured_for: Vec<Option<Picture>>,
}

impl Recorder {
    fn new(kbps: u32) -> Self {
        Self { kbps, set: Vec::new(), picture: None, captured_for: Vec::new() }
    }
}

impl FrameSource for Recorder {
    fn capture(&mut self, _damage: Rect) -> Res<()> {
        self.captured_for.push(self.picture);
        Ok(())
    }
    fn set_picture(&mut self, picture: Option<Picture>) {
        self.picture = picture;
    }
    fn encode(&mut self, _force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        out.extend_from_slice(&[0, 0, 0, 1, 0x65]);
        Ok(true)
    }
    fn set_bitrate(&mut self, kbps: u32) {
        self.kbps = kbps;
        self.set.push(kbps);
    }
    fn kbps(&self) -> u32 {
        self.kbps
    }
    fn encoder_name(&self) -> String {
        "recorder".into()
    }
}

fn job(target_kbps: u32, halve_first: bool) -> Job {
    let damage = Rect { x: 0, y: 0, width: 16, height: 16 };
    let req = EncodeRequest {
        stream: 0,
        frame: 1,
        damage,
        force_idr: true,
        idr_reason: None,
        target_kbps,
        picture: None,
        profile: Default::default(),
        refine: false,
    };
    Job { req, released_us: 0, halve_first }
}

#[test]
fn the_frame_after_a_drop_encodes_at_half_the_rate() {
    let mut source = Recorder::new(8_000);
    let frame = encode_one(&mut source, &job(8_000, true)).expect("encode");
    assert_eq!(frame.kbps, 4_000, "the halve holds for this frame: {:?}", source.set);
    assert_eq!(source.set.last(), Some(&4_000));
    // A target already under half wins.
    let mut source = Recorder::new(8_000);
    encode_one(&mut source, &job(3_000, true)).expect("encode");
    assert_eq!(source.kbps, 3_000);
    // Without a drop the engine's target applies.
    let mut source = Recorder::new(8_000);
    encode_one(&mut source, &job(9_000, false)).expect("encode");
    assert_eq!(source.kbps, 9_000);
}

#[test]
fn the_ladders_picture_reaches_the_source_before_its_capture() {
    let picture = Picture { width: 960, height: 540, eighths: 4, fps: 60, max_qp: Some(40) };
    let mut source = Recorder::new(8_000);
    let mut scaled = job(2_000, false);
    scaled.req.picture = Some(picture);
    encode_one(&mut source, &scaled).expect("encode");
    // Without a ladder the next frame is the full stream again.
    encode_one(&mut source, &job(2_000, false)).expect("encode");
    assert_eq!(source.captured_for, vec![Some(picture), None]);
}

/// Takes `ms` to capture, as an XShm readback and conversion of a large rect does.
struct SlowCapture {
    ms: u64,
}

impl FrameSource for SlowCapture {
    fn capture(&mut self, _damage: Rect) -> Res<()> {
        std::thread::sleep(std::time::Duration::from_millis(self.ms));
        Ok(())
    }
    fn encode(&mut self, _force_idr: bool, _pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        out.extend_from_slice(&[0, 0, 0, 1, 0x65]);
        Ok(true)
    }
    fn set_bitrate(&mut self, _kbps: u32) {}
    fn kbps(&self) -> u32 {
        1_000
    }
    fn encoder_name(&self) -> String {
        "slow-capture".into()
    }
}

/// The capture's own time is on the frame, from its start to `t_capture_us`.
#[test]
fn a_frame_carries_when_its_capture_started() {
    let mut source = SlowCapture { ms: 5 };
    let frame = encode_one(&mut source, &job(1_000, false)).expect("encode");
    let capture_us = frame.t_capture_us - frame.capture_start_us;
    assert!(capture_us >= 5_000, "capture took 5 ms, the frame says {capture_us} us");
    assert!(frame.t_capture_us <= frame.encoded_us);
}

/// The stats line names only a profile the encoder applied: one without an ultra mode
/// (the Linux X11 source) reports none even for an ultra request.
#[test]
fn a_frame_names_only_the_profile_its_encoder_applied() {
    struct Ultra(Recorder);
    impl FrameSource for Ultra {
        fn capture(&mut self, damage: Rect) -> Res<()> {
            self.0.capture(damage)
        }
        fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
            self.0.encode(force_idr, pts_us, out)
        }
        fn set_bitrate(&mut self, kbps: u32) {
            self.0.set_bitrate(kbps);
        }
        fn applies_profile(&self) -> bool {
            true
        }
        fn kbps(&self) -> u32 {
            self.0.kbps()
        }
        fn encoder_name(&self) -> String {
            "ultra".into()
        }
    }
    let mut ultra_job = job(8_000, false);
    ultra_job.req.profile = EncodeProfile::Ultra;
    let mut plain = Recorder::new(8_000);
    assert_eq!(encode_one(&mut plain, &ultra_job).expect("encode").profile, None);
    let mut able = Ultra(Recorder::new(8_000));
    assert_eq!(
        encode_one(&mut able, &ultra_job).expect("encode").profile,
        Some(EncodeProfile::Ultra)
    );
}
