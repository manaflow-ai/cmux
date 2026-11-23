use std::time::Duration;

use super::*;

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-mp4-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

const SPS: &[u8] = &[0x67, 0x42, 0xc0, 0x1f, 0x95];
const PPS: &[u8] = &[0x68, 0xce, 0x3c, 0x80];

fn unit(key: bool, body: &[u8], long_start: bool) -> Vec<u8> {
    let start: &[u8] = if long_start { &[0, 0, 0, 1] } else { &[0, 0, 1] };
    let mut out = Vec::new();
    if key {
        for set in [SPS, PPS] {
            out.extend_from_slice(start);
            out.extend_from_slice(set);
        }
    }
    out.extend_from_slice(start);
    out.push(if key { 0x65 } else { 0x41 });
    out.extend_from_slice(body);
    out
}

#[test]
fn nal_units_split_on_both_start_codes_and_drop_the_padding() {
    let au = [&[0, 0, 0, 1, 0x67, 1, 2][..], &[0, 0, 1, 0x68, 3], &[0, 0, 0, 1, 0x65, 4, 5, 0, 0]]
        .concat();
    let nals = nal_units(&au);
    assert_eq!(nals, vec![&[0x67, 1, 2][..], &[0x68, 3], &[0x65, 4, 5]]);
    assert!(nal_units(&[1, 2, 3]).is_empty());
}

#[test]
fn a_written_file_reads_back_frame_for_frame() {
    let path = scratch("roundtrip.mp4");
    let mut w = Mp4Writer::create(&path, 640, 360).unwrap();
    // Frames before the first keyframe are not written: nothing could decode them.
    assert!(!w.write_sample(&unit(false, &[9, 9], true), Duration::ZERO).unwrap());
    let mut bodies = Vec::new();
    for i in 0..25u32 {
        let key = i % 10 == 0;
        let body: Vec<u8> = (0..(50 + i as usize)).map(|b| (b as u8) | 1).collect();
        // Uneven frame times, as a capture has them.
        let at = Duration::from_millis(u64::from(i) * 100 + u64::from(i % 3) * 7);
        assert!(w.write_sample(&unit(key, &body, i % 2 == 0), at).unwrap());
        bodies.push((key, body, at));
    }
    assert_eq!(w.frames(), 25);
    w.finish(Duration::from_millis(2600)).unwrap();

    let info = probe(&path).unwrap();
    assert_eq!(info.codec, "avc1");
    assert_eq!((info.width, info.height), (640, 360));
    assert_eq!(info.frames, 25);
    assert_eq!(info.keyframes, 3);
    assert_eq!(info.duration_ms, 2600);
    assert_eq!(info.bytes, std::fs::metadata(&path).unwrap().len());

    let track = read_samples(&path).unwrap();
    assert_eq!(track.sps, SPS);
    assert_eq!(track.pps, PPS);
    assert_eq!(track.samples.len(), 25);
    for (sample, (key, body, at)) in track.samples.iter().zip(&bodies) {
        assert_eq!(sample.key, *key);
        // One NAL unit: its length, its header byte, the body.
        let len = u32::from_be_bytes(sample.data[..4].try_into().unwrap()) as usize;
        assert_eq!(len, body.len() + 1);
        assert_eq!(sample.data[4], if *key { 0x65 } else { 0x41 });
        assert_eq!(&sample.data[5..], &body[..]);
        let off = sample.at.as_micros().abs_diff(at.as_micros());
        assert!(off < 50, "frame time {:?} for {:?}", sample.at, at);
    }
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn the_box_layout_is_what_players_expect() {
    let path = scratch("layout.mp4");
    let mut w = Mp4Writer::create(&path, 320, 200).unwrap();
    w.write_sample(&unit(true, &[1, 2, 3], true), Duration::ZERO).unwrap();
    w.finish(Duration::from_millis(500)).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    // ftyp first, then mdat with a 64-bit size, then moov to the end.
    assert_eq!(&bytes[4..8], b"ftyp");
    let ftyp = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
    assert_eq!(&bytes[ftyp..ftyp + 8], &[0, 0, 0, 1, b'm', b'd', b'a', b't']);
    let mdat = u64::from_be_bytes(bytes[ftyp + 8..ftyp + 16].try_into().unwrap()) as usize;
    let moov = ftyp + mdat;
    assert_eq!(&bytes[moov + 4..moov + 8], b"moov");
    let moov_size = u32::from_be_bytes(bytes[moov..moov + 4].try_into().unwrap()) as usize;
    assert_eq!(moov + moov_size, bytes.len());
    for kind in
        [&b"mvhd"[..], b"tkhd", b"mdhd", b"hdlr", b"avc1", b"avcC", b"stts", b"stss", b"co64"]
    {
        assert!(bytes[moov..].windows(4).any(|w| w == kind), "{}", String::from_utf8_lossy(kind));
    }
    std::fs::remove_file(&path).unwrap();
}

#[test]
fn an_unfinished_or_empty_recording_is_an_error_not_a_file_that_looks_fine() {
    // No frame at all: finish refuses.
    let path = scratch("empty.mp4");
    let w = Mp4Writer::create(&path, 320, 200).unwrap();
    assert!(w.finish(Duration::from_secs(1)).is_err());
    // Written but never finished (the process died): no index, probe says so.
    let path2 = scratch("cut.mp4");
    let mut w = Mp4Writer::create(&path2, 320, 200).unwrap();
    w.write_sample(&unit(true, &[1, 2, 3], true), Duration::ZERO).unwrap();
    drop(w);
    let err = probe(&path2).unwrap_err();
    assert!(err.contains("not finished"), "{err}");
    // A finished file cut short reads as an error too.
    let path3 = scratch("short.mp4");
    let mut w = Mp4Writer::create(&path3, 320, 200).unwrap();
    w.write_sample(&unit(true, &[1, 2, 3], true), Duration::ZERO).unwrap();
    w.finish(Duration::from_secs(1)).unwrap();
    let bytes = std::fs::read(&path3).unwrap();
    std::fs::write(&path3, &bytes[..bytes.len() - 40]).unwrap();
    assert!(probe(&path3).is_err());
    for p in [path, path2, path3] {
        std::fs::remove_file(p).unwrap();
    }
}
