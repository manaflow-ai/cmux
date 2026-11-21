//! Recording as you go: a canned H.264 clip (64x40 High, 8 frames, IDR
//! every 4; testdata/clip_64x40_high.h264, made with ffmpeg's libx264)
//! goes through the recorder and the session C ABI, and the fragmented MP4
//! is parsed back into boxes. With ffprobe on PATH the file is also probed,
//! whole and cut off after five fragments (a crash).

use super::*;
use crate::h264::{NAL_AUD, nal_type, nal_units, parse_sps};
use crate::record::Recorder;
use cmux_rd_core::packetize::Packetizer;
use cmux_rd_proto::{FrameBody, MAX_DATAGRAM_VPC, REF_NONE, flags};

const CLIP: &[u8] = include_bytes!("testdata/clip_64x40_high.h264");

/// The clip's access units (each starts at an access unit delimiter).
fn access_units() -> Vec<Vec<u8>> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 4 < CLIP.len() {
        if CLIP[i..i + 3] == [0, 0, 1] && CLIP[i + 3] & 0x1f == NAL_AUD {
            let start = if i > 0 && CLIP[i - 1] == 0 { i - 1 } else { i };
            starts.push(start);
        }
        i += 1;
    }
    starts.push(CLIP.len());
    starts.windows(2).map(|w| CLIP[w[0]..w[1]].to_vec()).collect()
}

fn t(frame: usize) -> u64 {
    5_000_000 + frame as u64 * 33_333
}

/// Top-level or child boxes as (type, body).
fn boxes(mut data: &[u8]) -> Vec<(String, &[u8])> {
    let mut out = Vec::new();
    while data.len() >= 8 {
        let size = u32::from_be_bytes(data[..4].try_into().unwrap()) as usize;
        assert!(size >= 8 && size <= data.len(), "box size {size} of {}", data.len());
        out.push((String::from_utf8_lossy(&data[4..8]).into_owned(), &data[8..size]));
        data = &data[size..];
    }
    assert!(data.is_empty(), "trailing bytes");
    out
}

fn child<'a>(parent: &'a [u8], kind: &str) -> &'a [u8] {
    boxes(parent).into_iter().find(|(k, _)| k == kind).unwrap_or_else(|| panic!("no {kind}")).1
}

fn be32(b: &[u8], at: usize) -> u32 {
    u32::from_be_bytes(b[at..at + 4].try_into().unwrap())
}

/// Every fragment as (sequence, decode time, duration, sync, sample).
fn fragments(file: &[u8]) -> Vec<(u32, u64, u32, bool, Vec<u8>)> {
    let top = boxes(file);
    let kinds: Vec<&str> = top.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(&kinds[..2], ["ftyp", "moov"]);
    let mut out = Vec::new();
    for pair in top[2..].chunks(2) {
        let [(moof_kind, moof), (mdat_kind, mdat)] = pair else { panic!("unpaired fragment") };
        assert_eq!((moof_kind.as_str(), mdat_kind.as_str()), ("moof", "mdat"));
        let seq = be32(child(moof, "mfhd"), 4);
        let traf = child(moof, "traf");
        let tfdt = child(traf, "tfdt");
        assert_eq!(tfdt[0], 1, "tfdt version 1");
        let dts = u64::from_be_bytes(tfdt[4..12].try_into().unwrap());
        let trun = child(traf, "trun");
        assert_eq!(be32(trun, 0) & 0xff_ffff, 0x701);
        assert_eq!(be32(trun, 4), 1, "one sample per fragment");
        // data_offset counts from the moof's first byte to the sample.
        assert_eq!(be32(trun, 8) as usize, moof.len() + 8 + 8);
        let (duration, size, sample_flags) = (be32(trun, 12), be32(trun, 16), be32(trun, 20));
        assert_eq!(size as usize, mdat.len());
        out.push((seq, dts, duration, sample_flags & 0x0001_0000 == 0, mdat.to_vec()));
    }
    out
}

fn record(units: &[Vec<u8>], first: usize) -> (u64, Vec<u8>) {
    let mut r = Recorder::new(Vec::new());
    for (i, au) in units.iter().enumerate().skip(first) {
        r.push(t(i), au);
    }
    r.finish().expect("finish")
}

#[test]
fn the_clip_parses_into_nal_units_and_its_sps() {
    let units = access_units();
    assert_eq!(units.len(), 8);
    let first = nal_units(&units[0]);
    let sps = first.iter().find(|n| nal_type(n) == 7).expect("sps");
    let info = parse_sps(sps).expect("parse");
    assert_eq!((info.profile_idc, info.width, info.height), (100, 64, 40));
    assert_eq!((info.chroma_format_idc, info.bit_depth_luma, info.bit_depth_chroma), (1, 8, 8));
    assert!(nal_units(&units[1]).iter().all(|n| nal_type(n) != 5), "frame 2 is a P frame");
}

#[test]
fn a_recording_is_an_init_segment_and_one_fragment_per_frame() {
    let units = access_units();
    let (frames, file) = record(&units, 0);
    assert_eq!(frames, 8);
    let moov = boxes(&file)[1].1;
    let trak = child(moov, "trak");
    let tkhd = child(trak, "tkhd");
    assert_eq!((be32(tkhd, 76) >> 16, be32(tkhd, 80) >> 16), (64, 40));
    let mdhd = child(child(trak, "mdia"), "mdhd");
    assert_eq!(be32(mdhd, 12), mp4::TIMESCALE);
    let sps = nal_units(&units[0]).into_iter().find(|n| nal_type(n) == 7).unwrap();
    let at = file.windows(4).position(|w| w == b"avcC").expect("avcC");
    assert_eq!(&file[at + 4..at + 8], &[1, 100, sps[2], sps[3]]);
    assert_eq!(&file[at + 12..at + 12 + sps.len()], sps);
    child(moov, "mvex");

    let frags = fragments(&file);
    assert_eq!(frags.len(), 8);
    for (i, (seq, dts, duration, sync, sample)) in frags.iter().enumerate() {
        assert_eq!(*seq as usize, i + 1);
        assert_eq!(*dts, i as u64 * 33_333);
        assert_eq!(*duration, 33_333);
        assert_eq!(*sync, i % 4 == 0, "frame {i}");
        // Length-prefixed NAL units without the delimiter.
        let mut rest = &sample[..];
        let mut nals = 0;
        while !rest.is_empty() {
            let len = be32(rest, 0) as usize;
            assert_ne!(rest[4] & 0x1f, NAL_AUD);
            rest = &rest[4 + len..];
            nals += 1;
        }
        assert_eq!(nals, nal_units(&units[i]).len() - 1);
    }
}

#[test]
fn frames_before_the_first_keyframe_are_skipped() {
    let units = access_units();
    let (frames, file) = record(&units, 1);
    assert_eq!(frames, 4, "frames 4..8: the file starts at the second IDR");
    let frags = fragments(&file);
    assert!(frags[0].3, "the first sample is a sync sample");
    assert_eq!(frags[0].1, 0, "media time starts at the first written frame");

    let mut r = Recorder::new(Vec::new());
    r.push(1, &units[1]);
    assert!(r.waiting_for_keyframe());
    assert_eq!(r.finish().expect("finish"), (0, Vec::new()));
}

#[test]
fn a_clock_step_back_still_gives_positive_durations() {
    let units = access_units();
    let mut r = Recorder::new(Vec::new());
    r.push(10_000, &units[0]);
    r.push(5_000, &units[1]);
    r.push(40_000, &units[2]);
    let (_, file) = r.finish().expect("finish");
    let durations: Vec<u32> = fragments(&file).iter().map(|f| f.2).collect();
    assert_eq!(durations, [1, 35_000, 35_000]);
}

struct Owned(*mut CmuxRdSession);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: created by cmux_rd_session_new and freed once here.
        unsafe { cmux_rd_session_free(self.0) };
    }
}

fn temp_path(name: &str) -> std::path::PathBuf {
    let dir = std::env::var_os("FAST_CHECKS_OUT")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join(format!("cmux-rd-record-{}", std::process::id()));
    dir.join(name)
}

fn start(s: &Owned, path: &std::path::Path) -> i32 {
    let c = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
    // SAFETY: live session, NUL-terminated path.
    unsafe { cmux_rd_session_record_start(s.0, c.as_ptr()) }
}

/// Sends the clip through a session and pops every frame (which records it).
fn play(s: &Owned) {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    for (i, au) in access_units().into_iter().enumerate() {
        let f = i as u32 + 1;
        let body = FrameBody {
            t_capture_us: t(i),
            ref_frame: if i % 4 == 0 { REF_NONE } else { f - 1 },
            access_unit: au,
        };
        let fl = if i % 4 == 0 { flags::KEYFRAME } else { 0 };
        for d in p.packetize(f, fl, &body, 0).expect("packetize").datagrams {
            // SAFETY: live session, readable slice.
            assert!(unsafe { cmux_rd_session_push_datagram(s.0, d.as_ptr(), d.len(), t(i)) } >= 0);
        }
        let mut out = CmuxRdFrame {
            t_capture_us: 0,
            data: std::ptr::null(),
            len: 0,
            frame: 0,
            ref_frame: 0,
            flags: 0,
        };
        let mut stream = u16::MAX;
        // SAFETY: live session, writable outs.
        while unsafe { cmux_rd_session_pop_frame(s.0, &mut out, &mut stream) } == 1 {}
    }
}

#[test]
fn the_session_records_the_frames_it_hands_out() {
    let s = Owned(cmux_rd_session_new(CMUX_RD_CARRIER_DATAGRAM, 200_000, 5_000));
    assert!(!s.0.is_null());
    // SAFETY: live session.
    assert_eq!(unsafe { cmux_rd_session_record_stop(s.0) }, 0, "nothing running");
    // SAFETY: live session; NULL path refused.
    assert_eq!(unsafe { cmux_rd_session_record_start(s.0, std::ptr::null()) }, CMUX_RD_ERR_NULL);
    assert_eq!(start(&s, std::path::Path::new("")), CMUX_RD_ERR_INVALID);

    let path = temp_path("nested/session.mp4");
    assert_eq!(start(&s, &path), CMUX_RD_OK, "creates missing folders");
    play(&s);
    // SAFETY: live session.
    assert_eq!(unsafe { cmux_rd_session_record_stop(s.0) }, 8);
    let file = std::fs::read(&path).expect("read");
    assert_eq!(fragments(&file).len(), 8);
    let (_, direct) = record(&access_units(), 0);
    assert_eq!(file, direct, "the session writes what the recorder writes");
    probe(&path, 8);

    // A crash: the file cut off after five fragments still plays them.
    let top = boxes(&file);
    let cut: usize = top[..2 + 5 * 2].iter().map(|(_, b)| b.len() + 8).sum();
    let crashed = temp_path("crashed.mp4");
    std::fs::write(&crashed, &file[..cut]).expect("write");
    probe(&crashed, 5);

    // A folder where the file should go cannot be created.
    assert_eq!(start(&s, path.parent().unwrap()), CMUX_RD_ERR_IO);
    // A CI run keeps the files in its artifact (to probe them elsewhere).
    if std::env::var_os("FAST_CHECKS_OUT").is_none() {
        std::fs::remove_dir_all(path.parent().unwrap().parent().unwrap()).expect("clean up");
    }
}

/// With ffprobe installed: the file is H.264 64x40 with `frames` frames.
fn probe(path: &std::path::Path, frames: usize) {
    let args = [
        "-v",
        "error",
        "-count_frames",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,width,height,nb_read_frames",
        "-of",
        "csv=p=0",
    ];
    let Ok(out) = std::process::Command::new("ffprobe").args(args).arg(path).output() else {
        eprintln!("ffprobe not installed: skipped probing {}", path.display());
        return;
    };
    let text = String::from_utf8_lossy(&out.stdout);
    eprintln!(
        "ffprobe {}: {} {}",
        path.display(),
        text.trim(),
        String::from_utf8_lossy(&out.stderr).trim()
    );
    assert!(out.status.success());
    assert_eq!(text.trim(), format!("h264,64,40,{frames}"));
}
