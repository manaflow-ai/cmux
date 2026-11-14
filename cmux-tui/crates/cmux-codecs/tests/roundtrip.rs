//! Each codec in the build encodes a text screen, decodes it back legibly, marks
//! its first frame as a keyframe its own framing agrees with, and recovers from a
//! forced keyframe.

use cmux_codecs::bench::scene::{Scene, SceneKind};
use cmux_codecs::{open_decoder, open_encoder, psnr_y};
use cmux_encode::{Codec, EncCfg, I420};

fn roundtrip(codec: Codec) {
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
        let idr = enc.encode(scene.picture(), force, i * 33_333, &mut au).expect("encode");
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
                let n = enc.output_pts().map_or(i, |pts| pts / 33_333) as usize;
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
    roundtrip(Codec::H264);
}

#[test]
fn vp9() {
    roundtrip(Codec::Vp9);
}

#[test]
fn av1() {
    roundtrip(Codec::Av1);
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
    })
    .expect("row");
    assert!(row["shown_fps"].as_f64().unwrap() > 10.0, "{row}");
}
