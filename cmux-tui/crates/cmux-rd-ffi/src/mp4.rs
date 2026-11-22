//! Hand-written fragmented MP4 (ISO/IEC 14496-12) boxes for one H.264 video
//! track: an init segment (`ftyp` + `moov` with `avcC` and `mvex`) and one
//! `moof` + `mdat` fragment per frame. Every fragment is self-contained, so
//! a file cut off after any fragment still plays up to it.

use crate::h264::SpsInfo;

/// Media time units per second: the host's capture clock is in microseconds.
pub const TIMESCALE: u32 = 1_000_000;
const TRACK_ID: u32 = 1;
/// Sample flags (14496-12 8.8.3.1): a sync sample depends on nothing; any
/// other sample depends on others and is not a sync sample.
const SYNC_FLAGS: u32 = 0x0200_0000;
const NON_SYNC_FLAGS: u32 = 0x0101_0000;
const MATRIX: [u32; 9] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000];

/// Writes a box of `kind` whose body `body` appends, patching its size.
fn bx(out: &mut Vec<u8>, kind: &[u8; 4], body: impl FnOnce(&mut Vec<u8>)) {
    let start = out.len();
    out.extend_from_slice(&[0; 4]);
    out.extend_from_slice(kind);
    body(out);
    let size = u32::try_from(out.len() - start).unwrap_or(u32::MAX);
    out[start..start + 4].copy_from_slice(&size.to_be_bytes());
}

/// A full box: version and flags before the body.
fn full(
    out: &mut Vec<u8>,
    kind: &[u8; 4],
    version: u8,
    flags: u32,
    body: impl FnOnce(&mut Vec<u8>),
) {
    bx(out, kind, |o| {
        o.extend_from_slice(&((u32::from(version) << 24) | (flags & 0x00ff_ffff)).to_be_bytes());
        body(o);
    });
}

fn u16be(o: &mut Vec<u8>, v: u16) {
    o.extend_from_slice(&v.to_be_bytes());
}

fn u32be(o: &mut Vec<u8>, v: u32) {
    o.extend_from_slice(&v.to_be_bytes());
}

fn matrix(o: &mut Vec<u8>) {
    for v in MATRIX {
        u32be(o, v);
    }
}

/// `ftyp` and `moov` for a track whose first keyframe carried `sps` and
/// `pps` (NAL units, header bytes included).
pub fn init_segment(info: &SpsInfo, sps: &[u8], pps: &[u8]) -> Vec<u8> {
    let (w, h) = (clamp16(info.width), clamp16(info.height));
    let mut out = Vec::with_capacity(768 + sps.len() + pps.len());
    bx(&mut out, b"ftyp", |o| {
        o.extend_from_slice(b"isom");
        u32be(o, 0x200);
        o.extend_from_slice(b"isomiso6avc1mp41");
    });
    bx(&mut out, b"moov", |o| {
        full(o, b"mvhd", 0, 0, |o| {
            o.extend_from_slice(&[0; 8]); // creation, modification
            u32be(o, 1000);
            u32be(o, 0); // duration: fragments carry it
            u32be(o, 0x0001_0000); // rate 1.0
            u16be(o, 0x0100); // volume 1.0
            o.extend_from_slice(&[0; 10]);
            matrix(o);
            o.extend_from_slice(&[0; 24]); // pre_defined
            u32be(o, TRACK_ID + 1);
        });
        bx(o, b"trak", |o| {
            full(o, b"tkhd", 0, 0x3, |o| {
                o.extend_from_slice(&[0; 8]);
                u32be(o, TRACK_ID);
                o.extend_from_slice(&[0; 4 + 4 + 8]); // reserved, duration, reserved
                o.extend_from_slice(&[0; 8]); // layer, group, volume, reserved
                matrix(o);
                u32be(o, u32::from(w) << 16);
                u32be(o, u32::from(h) << 16);
            });
            bx(o, b"mdia", |o| {
                full(o, b"mdhd", 0, 0, |o| {
                    o.extend_from_slice(&[0; 8]);
                    u32be(o, TIMESCALE);
                    u32be(o, 0);
                    u16be(o, 0x55c4); // "und"
                    u16be(o, 0);
                });
                full(o, b"hdlr", 0, 0, |o| {
                    u32be(o, 0);
                    o.extend_from_slice(b"vide");
                    o.extend_from_slice(&[0; 12]);
                    o.extend_from_slice(b"cmux screen\0");
                });
                bx(o, b"minf", |o| {
                    full(o, b"vmhd", 0, 1, |o| o.extend_from_slice(&[0; 8]));
                    bx(o, b"dinf", |o| {
                        full(o, b"dref", 0, 0, |o| {
                            u32be(o, 1);
                            full(o, b"url ", 0, 1, |_| {});
                        });
                    });
                    bx(o, b"stbl", |o| {
                        full(o, b"stsd", 0, 0, |o| {
                            u32be(o, 1);
                            avc1(o, info, w, h, sps, pps);
                        });
                        full(o, b"stts", 0, 0, |o| u32be(o, 0));
                        full(o, b"stsc", 0, 0, |o| u32be(o, 0));
                        full(o, b"stsz", 0, 0, |o| o.extend_from_slice(&[0; 8]));
                        full(o, b"stco", 0, 0, |o| u32be(o, 0));
                    });
                });
            });
        });
        bx(o, b"mvex", |o| {
            full(o, b"trex", 0, 0, |o| {
                u32be(o, TRACK_ID);
                u32be(o, 1); // sample description index
                o.extend_from_slice(&[0; 12]); // default duration, size, flags
            });
        });
    });
    out
}

fn clamp16(v: u32) -> u16 {
    u16::try_from(v).unwrap_or(u16::MAX)
}

/// The `avc1` sample entry and its `avcC` (14496-15 5.3.3.1).
fn avc1(o: &mut Vec<u8>, info: &SpsInfo, w: u16, h: u16, sps: &[u8], pps: &[u8]) {
    bx(o, b"avc1", |o| {
        o.extend_from_slice(&[0; 6]);
        u16be(o, 1); // data reference index
        o.extend_from_slice(&[0; 16]); // pre_defined, reserved
        u16be(o, w);
        u16be(o, h);
        u32be(o, 0x0048_0000); // 72 dpi
        u32be(o, 0x0048_0000);
        u32be(o, 0);
        u16be(o, 1); // frame count
        o.extend_from_slice(&[0; 32]); // compressor name
        u16be(o, 0x0018);
        u16be(o, 0xffff);
        bx(o, b"avcC", |o| {
            o.extend_from_slice(&[
                1,
                info.profile_idc,
                info.constraint_flags,
                info.level_idc,
                0xff,
                0xe1,
            ]);
            u16be(o, clamp16(sps.len() as u32));
            o.extend_from_slice(sps);
            o.push(1);
            u16be(o, clamp16(pps.len() as u32));
            o.extend_from_slice(pps);
            if SpsInfo::high_profile(info.profile_idc) {
                let depth = |d: u32| 0xf8 | (d.saturating_sub(8) & 0x7) as u8;
                o.push(0xfc | (info.chroma_format_idc & 0x3) as u8);
                o.push(depth(info.bit_depth_luma));
                o.push(depth(info.bit_depth_chroma));
                o.push(0); // no SPS extensions
            }
        });
    });
}

/// One fragment holding one sample: `moof` (sequence `seq`, decode time
/// `dts`) and the `mdat` with `sample` (length-prefixed NAL units).
pub fn fragment(seq: u32, dts: u64, duration: u32, sample: &[u8], sync: bool) -> Vec<u8> {
    let mut out = Vec::with_capacity(112 + sample.len());
    let mut offset_at = 0;
    bx(&mut out, b"moof", |o| {
        full(o, b"mfhd", 0, 0, |o| u32be(o, seq));
        bx(o, b"traf", |o| {
            // default-base-is-moof: data offsets count from this moof.
            full(o, b"tfhd", 0, 0x02_0000, |o| u32be(o, TRACK_ID));
            full(o, b"tfdt", 1, 0, |o| o.extend_from_slice(&dts.to_be_bytes()));
            // data offset, sample duration, size and flags present.
            full(o, b"trun", 0, 0x0701, |o| {
                u32be(o, 1);
                offset_at = o.len();
                u32be(o, 0);
                u32be(o, duration);
                u32be(o, u32::try_from(sample.len()).unwrap_or(u32::MAX));
                u32be(o, if sync { SYNC_FLAGS } else { NON_SYNC_FLAGS });
            });
        });
    });
    // The sample starts after the moof and the mdat header.
    let data_offset = u32::try_from(out.len() + 8).unwrap_or(u32::MAX);
    out[offset_at..offset_at + 4].copy_from_slice(&data_offset.to_be_bytes());
    bx(&mut out, b"mdat", |o| o.extend_from_slice(sample));
    out
}
