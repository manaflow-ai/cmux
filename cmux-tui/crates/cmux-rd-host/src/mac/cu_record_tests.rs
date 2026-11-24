//! The macOS recording path past the capture: RGBA frames through the
//! VideoToolbox encoder, the engine's MP4 writer, the file read back and
//! decoded by VideoToolbox's decoder to the colours that went in.

use super::*;
use crate::vtdecode::VtDecoder;
use cmux_computer_use::desktop::Point;
use cmux_computer_use::record::mp4::{self, Mp4Writer};

const W: u32 = 640;
const H: u32 = 400;

/// A frame of one colour with a white block that moves with `i`.
fn frame(i: u32, rgb: [u8; 3]) -> RawFrame {
    let mut rgba = Vec::with_capacity((W * H * 4) as usize);
    for y in 0..H {
        for x in 0..W {
            let block = (40 + i * 16..120 + i * 16).contains(&x) && (100..180).contains(&y);
            let c = if block { [255, 255, 255] } else { rgb };
            rgba.extend_from_slice(&[c[0], c[1], c[2], 255]);
        }
    }
    RawFrame { width: W, height: H, rgba, scale: 1.0, origin: Point { x: 0.0, y: 0.0 } }
}

#[test]
fn frames_encode_into_an_mp4_that_reads_back_and_decodes_to_the_same_picture() {
    let dir = std::env::temp_dir().join(format!("cmux-cu-record-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("recording.mp4");
    // Red, then green, then blue: a swapped channel shows as the wrong colour.
    let colours = [[200u8, 30, 30], [30, 200, 30], [30, 30, 200]];
    let mut encoder = VideoToolboxFrames::new(W, H, 10).unwrap();
    assert!(!encoder.name().is_empty());
    let mut writer = Mp4Writer::create(&path, W, H).unwrap();
    const FRAMES: u32 = 30;
    for i in 0..FRAMES {
        let at = Duration::from_millis(u64::from(i) * 100);
        let unit = encoder.encode(&frame(i, colours[(i / 10) as usize]), i % 10 == 0, at).unwrap();
        assert!(!unit.is_empty(), "frame {i} produced nothing");
        assert!(writer.write_sample(&unit, at).unwrap(), "frame {i} was not written");
    }
    writer.finish(Duration::from_millis(u64::from(FRAMES) * 100)).unwrap();

    let track = mp4::read_samples(&path).unwrap();
    assert_eq!(track.info.codec, "avc1");
    assert_eq!((track.info.width, track.info.height), (W, H));
    assert_eq!(track.info.frames, u64::from(FRAMES));
    assert_eq!(track.info.duration_ms, 3000);
    assert!(track.info.keyframes >= 3, "{:?}", track.info);
    assert!(track.samples[0].key);
    // The parameter sets say the size (SPS type 7, PPS type 8).
    assert_eq!(track.sps[0] & 0x1f, 7);
    assert_eq!(track.pps[0] & 0x1f, 8);

    // Decode what the file holds: the parameter sets from its header, then
    // each sample's NAL units behind start codes.
    let mut decoder = VtDecoder::new();
    let mut decoded = 0;
    for (i, sample) in track.samples.iter().enumerate() {
        let mut au = Vec::new();
        if sample.key {
            for set in [&track.sps, &track.pps] {
                au.extend_from_slice(&[0, 0, 0, 1]);
                au.extend_from_slice(set);
            }
        }
        let mut rest = &sample.data[..];
        while rest.len() >= 4 {
            let len = u32::from_be_bytes(rest[..4].try_into().unwrap()) as usize;
            au.extend_from_slice(&[0, 0, 0, 1]);
            au.extend_from_slice(&rest[4..4 + len]);
            rest = &rest[4 + len..];
        }
        assert!(rest.is_empty(), "sample {i} has bytes past its last unit");
        let Some(picture) = decoder.decode(&au).unwrap() else { continue };
        decoded += 1;
        let (w, h, rgb) = picture.rgb();
        assert_eq!((w, h), (W as usize, H as usize));
        let pixel = |x: usize, y: usize| -> [i32; 3] {
            let at = (y * w + x) * 3;
            [i32::from(rgb[at]), i32::from(rgb[at + 1]), i32::from(rgb[at + 2])]
        };
        let want = colours[i / 10];
        let background = pixel(600, 300);
        for c in 0..3 {
            assert!(
                (background[c] - i32::from(want[c])).abs() < 40,
                "frame {i}: background {background:?}, wanted {want:?}"
            );
        }
        // The block is where this frame put it.
        let block = pixel(80 + i * 16, 140);
        assert!(block.iter().all(|c| *c > 200), "frame {i}: block {block:?}");
    }
    assert!(decoded >= FRAMES as usize - 1, "{decoded} of {FRAMES} frames decoded");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn the_bitrate_follows_the_picture_and_stays_in_bounds() {
    assert_eq!(kbps_for(1920, 1200, 10), 3456);
    assert_eq!(kbps_for(320, 200, 1), MIN_KBPS);
    assert_eq!(kbps_for(3840, 2160, 30), MAX_KBPS);
}

#[test]
fn odd_sizes_are_refused() {
    assert!(VideoToolboxFrames::new(641, 400, 10).is_err());
    assert!(VideoToolboxFrames::new(0, 0, 10).is_err());
}
