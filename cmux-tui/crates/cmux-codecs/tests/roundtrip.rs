//! Each codec in the build encodes a text screen, decodes it back legibly, marks
//! its first frame as a keyframe its own framing agrees with, and recovers from a
//! forced keyframe.

use cmux_codecs::bench::scene::{Scene, SceneKind};
use cmux_codecs::{open_decoder, open_encoder, psnr_y};
use cmux_encode::{Codec, EncCfg, I420};

/// Capture times as the native host sends them: microseconds of a real clock.
const WALL_CLOCK_US: i64 = 1_794_671_439_604_000;

fn roundtrip(codec: Codec, pts_base: i64) {
    let cfg =
        EncCfg { width: 640, height: 360, fps: 30, kbps: 4000, threads: 2, screen_content: true };
    let Some(mut enc) = open_encoder(codec, &cfg).expect("encoder") else { return };
    let mut dec = open_decoder(codec, 2).expect("decoder").expect("decoder in build");
    assert_eq!(enc.codec(), codec);
    let mut scene = Scene::new(SceneKind::Typing, 640, 360, 3);
    let mut au = Vec::new();
    let mut out = I420::new(640, 360);
    let mut shown = 0;
    let mut first = true;
    let mut pictures = Vec::new();
    let mut steady = Vec::new();
    for i in 0..20 {
        let force = i == 0 || i == 12;
        pictures.push(scene.picture().clone());
        let idr =
            enc.encode(scene.picture(), force, pts_base + i * 33_333, &mut au).expect("encode");
        if !au.is_empty() {
            assert_eq!(
                codec.is_keyframe(&au),
                idr,
                "{codec:?} frame {i}: framing agrees with the encoder"
            );
            if first {
                assert!(idr, "{codec:?}: the first frame out is a keyframe");
                first = false;
            }
            if dec.decode(&au, &mut out).expect("decode") {
                shown += 1;
                // The picture this unit carries (an encoder with lookahead returns an older one).
                let n = enc.output_pts().map_or(i, |pts| (pts - pts_base) / 33_333) as usize;
                let p = psnr_y(&pictures[n], &out);
                assert!(p > 20.0, "{codec:?} frame {n}: PSNR {p:.1} dB, not this picture");
                // A real-time CBR keyframe starts coarse; quality is judged once rate control settles.
                if n >= 5 {
                    steady.push(p);
                }
            }
        }
        scene.advance();
    }
    assert!(shown >= 15, "{codec:?}: {shown} of 20 frames shown");
    let mean = steady.iter().sum::<f64>() / steady.len().max(1) as f64;
    assert!(mean > 30.0, "{codec:?}: steady-state PSNR {mean:.1} dB ({steady:?})");
}

#[test]
fn h264() {
    roundtrip(Codec::H264, 0);
}

#[test]
fn vp9() {
    roundtrip(Codec::Vp9, 0);
}

#[test]
fn av1() {
    roundtrip(Codec::Av1, 0);
}

#[test]
fn h264_wall_clock_pts() {
    roundtrip(Codec::H264, WALL_CLOCK_US);
}

#[test]
fn vp9_wall_clock_pts() {
    roundtrip(Codec::Vp9, WALL_CLOCK_US);
}

#[test]
fn av1_wall_clock_pts() {
    roundtrip(Codec::Av1, WALL_CLOCK_US);
}

#[test]
fn bench_row_runs() {
    let row = cmux_codecs::bench::run_row(&cmux_codecs::bench::RowCfg {
        codec: Codec::H264,
        scene: SceneKind::Scroll,
        loss_pct: 2.0,
        burst_len: 0.0,
        max_kbps: None,
        rtt_ms: 50,
        link_mbps: 30.0,
        seconds: 2,
        width: 640,
        height: 360,
        fps: 30,
        threads: 2,
        on_time_ms: 100,
        deadline_ms: 200,
        seed: 1,
        h264: Default::default(),
    })
    .expect("row");
    assert!(row["shown_fps"].as_f64().unwrap() > 10.0, "{row}");
}

/// A clean link loses nothing, so a session sends one keyframe, its first. On Linux every
/// frame of `cmux-rd testapp --workload motion` came out an IDR (cmux#44425's harness):
/// OpenH264's screen usage makes one of every frame that moves most of the picture, which
/// only `noise` here does. Full-screen motion may cost two more, the scene change that
/// shows it and the encoder's move to camera usage (cmux-encode `openh264::MOTION_CHANGE`);
/// none after that.
#[test]
fn a_clean_link_sends_one_keyframe() {
    for (scene, most) in [(SceneKind::Drag, 1), (SceneKind::Scroll, 1), (SceneKind::Noise, 3)] {
        let row = cmux_codecs::bench::run_row(&cmux_codecs::bench::RowCfg {
            codec: Codec::H264,
            scene,
            loss_pct: 0.0,
            burst_len: 0.0,
            max_kbps: None,
            rtt_ms: 2,
            link_mbps: 1000.0,
            seconds: 3,
            width: 640,
            height: 360,
            fps: 30,
            threads: 2,
            on_time_ms: 100,
            deadline_ms: 200,
            seed: 1,
            h264: Default::default(),
        })
        .expect("row");
        // Enough frames that an IDR on each would break the bound.
        assert!(row["encoded"].as_u64().expect("encoded") > 2 * most, "{scene:?}: {row}");
        let keyframes = row["keyframes"].as_u64().expect("keyframes");
        assert!((1..=most).contains(&keyframes), "{scene:?}: {row}");
        assert_eq!(row["engine_keyframes"], keyframes, "{scene:?}: {row}");
    }
}
