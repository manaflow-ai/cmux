use super::*;
use cmux_rd_core::flow::Rect;

/// Records every bitrate it is given.
struct Recorder {
    kbps: u32,
    set: Vec<u32>,
}

impl FrameSource for Recorder {
    fn capture(&mut self, _damage: Rect) -> Res<()> {
        Ok(())
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
        profile: Default::default(),
        refine: false,
    };
    Job { req, released_us: 0, halve_first }
}

#[test]
fn the_frame_after_a_drop_encodes_at_half_the_rate() {
    let mut source = Recorder { kbps: 8_000, set: Vec::new() };
    let frame = encode_one(&mut source, &job(8_000, true)).expect("encode");
    assert_eq!(frame.kbps, 4_000, "the halve holds for this frame: {:?}", source.set);
    assert_eq!(source.set.last(), Some(&4_000));
    // A target already under half wins.
    let mut source = Recorder { kbps: 8_000, set: Vec::new() };
    encode_one(&mut source, &job(3_000, true)).expect("encode");
    assert_eq!(source.kbps, 3_000);
    // Without a drop the engine's target applies.
    let mut source = Recorder { kbps: 8_000, set: Vec::new() };
    encode_one(&mut source, &job(9_000, false)).expect("encode");
    assert_eq!(source.kbps, 9_000);
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
    let mut plain = Recorder { kbps: 8_000, set: Vec::new() };
    assert_eq!(encode_one(&mut plain, &ultra_job).expect("encode").profile, None);
    let mut able = Ultra(Recorder { kbps: 8_000, set: Vec::new() });
    assert_eq!(
        encode_one(&mut able, &ultra_job).expect("encode").profile,
        Some(EncodeProfile::Ultra)
    );
}
