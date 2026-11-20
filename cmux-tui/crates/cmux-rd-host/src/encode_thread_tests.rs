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
    };
    Job { req, halve_first }
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
