//! A small MP4 writer and reader for one H.264 video track, in plain Rust.
//!
//! The writer takes what every encoder cmux has gives out (one Annex-B access
//! unit per frame, parameter sets before each keyframe) and writes a file any
//! player opens: `ftyp`, one `mdat` holding the samples back to back
//! (length-prefixed NAL units), then `moov` with the sample table. The frame
//! times are the capture times, so a recording made at an uneven rate plays
//! at the speed it happened.
//!
//! The reader ([`probe`], [`read_samples`]) reads a finished file back: the
//! recording's result is what the file says, not what the writer meant.

use std::fs::File;
use std::io::{self, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::time::Duration;

/// The media timescale (ticks per second), as video files usually have it.
const TIMESCALE: u64 = 90_000;
/// The movie header's timescale (milliseconds).
const MOVIE_TIMESCALE: u64 = 1000;
/// `mdat`'s header: size 1 (a 64-bit size follows), the type, the size.
const MDAT_HEADER: u64 = 16;

const NAL_IDR: u8 = 5;
const NAL_SPS: u8 = 7;
const NAL_PPS: u8 = 8;
const NAL_AUD: u8 = 9;

fn ticks(at: Duration) -> u64 {
    (at.as_micros() as u64).saturating_mul(TIMESCALE) / 1_000_000
}

/// The NAL units of an Annex-B buffer (the bytes between start codes).
pub fn nal_units(annexb: &[u8]) -> Vec<&[u8]> {
    let mut starts: Vec<(usize, usize)> = Vec::new();
    let mut i = 0;
    while i + 3 <= annexb.len() {
        if annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1 {
            starts.push((i, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::with_capacity(starts.len());
    for (n, &(_, begin)) in starts.iter().enumerate() {
        let mut end = starts.get(n + 1).map_or(annexb.len(), |next| next.0);
        // The zero before a four-byte start code, and any trailing zeros,
        // are not part of the unit (a unit never ends in a zero byte).
        while end > begin && annexb[end - 1] == 0 {
            end -= 1;
        }
        if end > begin {
            out.push(&annexb[begin..end]);
        }
    }
    out
}

struct Sample {
    size: u32,
    at: u64,
    key: bool,
}

/// Writes one H.264 track to an MP4 file.
pub struct Mp4Writer {
    file: BufWriter<File>,
    width: u32,
    height: u32,
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
    samples: Vec<Sample>,
    /// Where `mdat`'s header starts.
    mdat_at: u64,
    /// The bytes of samples written so far.
    payload: u64,
}

impl Mp4Writer {
    /// Creates `path` (replacing it) for pictures of `width` x `height`.
    pub fn create(path: &Path, width: u32, height: u32) -> io::Result<Self> {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = BufWriter::new(options.open(path)?);
        let mut ftyp = Vec::new();
        ftyp.extend_from_slice(b"isom");
        ftyp.extend_from_slice(&0x200u32.to_be_bytes());
        for brand in [b"isom", b"iso2", b"avc1", b"mp41"] {
            ftyp.extend_from_slice(brand);
        }
        let ftyp = boxed(b"ftyp", ftyp);
        file.write_all(&ftyp)?;
        // The size is written when the file is finished.
        file.write_all(&1u32.to_be_bytes())?;
        file.write_all(b"mdat")?;
        file.write_all(&MDAT_HEADER.to_be_bytes())?;
        Ok(Self {
            file,
            width,
            height,
            sps: None,
            pps: None,
            samples: Vec::new(),
            mdat_at: ftyp.len() as u64,
            payload: 0,
        })
    }

    /// The frames written so far.
    pub fn frames(&self) -> usize {
        self.samples.len()
    }

    /// The file's size so far, without the index written at the end.
    pub fn bytes(&self) -> u64 {
        self.mdat_at + MDAT_HEADER + self.payload
    }

    /// Adds one frame: an Annex-B access unit shown `at` after the start.
    /// Returns false when nothing was written: the unit held no picture, or
    /// no keyframe with its parameter sets has come yet (a player could not
    /// decode what came before one).
    pub fn write_sample(&mut self, annexb: &[u8], at: Duration) -> io::Result<bool> {
        let mut body: Vec<u8> = Vec::with_capacity(annexb.len() + 16);
        let mut key = false;
        for nal in nal_units(annexb) {
            match nal[0] & 0x1f {
                NAL_SPS => {
                    if self.sps.is_none() {
                        self.sps = Some(nal.to_vec());
                    }
                }
                NAL_PPS => {
                    if self.pps.is_none() {
                        self.pps = Some(nal.to_vec());
                    }
                }
                NAL_AUD => {}
                kind => {
                    key |= kind == NAL_IDR;
                    let len = u32::try_from(nal.len())
                        .map_err(|_| io::Error::other("a NAL unit over 4 GiB"))?;
                    body.extend_from_slice(&len.to_be_bytes());
                    body.extend_from_slice(nal);
                }
            }
        }
        if body.is_empty() {
            return Ok(false);
        }
        if self.samples.is_empty() && !(key && self.sps.is_some() && self.pps.is_some()) {
            return Ok(false);
        }
        let size = u32::try_from(body.len()).map_err(|_| io::Error::other("a frame over 4 GiB"))?;
        // Times never go back, and two frames never share one.
        let mut at = ticks(at);
        if let Some(last) = self.samples.last() {
            at = at.max(last.at + 1);
        }
        self.file.write_all(&body)?;
        self.payload += u64::from(size);
        self.samples.push(Sample { size, at, key });
        Ok(true)
    }

    /// Writes the index and closes the file. `end`: when the recording
    /// stopped, after the start (the last frame shows until then).
    pub fn finish(mut self, end: Duration) -> io::Result<()> {
        let (Some(sps), Some(pps)) = (self.sps.take(), self.pps.take()) else {
            return Err(io::Error::other("the encoder gave no H.264 parameter sets"));
        };
        if self.samples.is_empty() || sps.len() < 4 {
            return Err(io::Error::other("no frame was recorded"));
        }
        let last = self.samples[self.samples.len() - 1].at;
        // The last frame shows until the end, at least one tick.
        let tail = ticks(end).saturating_sub(last).max(1);
        let mut deltas: Vec<u64> = self.samples.windows(2).map(|w| w[1].at - w[0].at).collect();
        deltas.push(tail);
        let duration: u64 = deltas.iter().sum();
        let movie_duration = duration * MOVIE_TIMESCALE / TIMESCALE;

        let moov = self.moov(&sps, &pps, &deltas, duration, movie_duration);
        self.file.write_all(&moov)?;
        self.file.flush()?;
        let mut file = self.file.into_inner().map_err(|e| e.into_error())?;
        file.seek(SeekFrom::Start(self.mdat_at + 8))?;
        file.write_all(&(MDAT_HEADER + self.payload).to_be_bytes())?;
        file.sync_all()
    }

    fn moov(
        &self,
        sps: &[u8],
        pps: &[u8],
        deltas: &[u64],
        duration: u64,
        movie_duration: u64,
    ) -> Vec<u8> {
        let matrix: [u32; 9] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000];
        let mut mvhd = Vec::new();
        put32(&mut mvhd, 0); // creation
        put32(&mut mvhd, 0); // modification
        put32(&mut mvhd, MOVIE_TIMESCALE as u32);
        put32(&mut mvhd, movie_duration.min(u64::from(u32::MAX)) as u32);
        put32(&mut mvhd, 0x0001_0000); // rate 1.0
        put16(&mut mvhd, 0x0100); // volume 1.0
        mvhd.extend_from_slice(&[0; 10]);
        for m in matrix {
            put32(&mut mvhd, m);
        }
        mvhd.extend_from_slice(&[0; 24]);
        put32(&mut mvhd, 2); // next track id

        let mut tkhd = Vec::new();
        put32(&mut tkhd, 0);
        put32(&mut tkhd, 0);
        put32(&mut tkhd, 1); // track id
        put32(&mut tkhd, 0);
        put32(&mut tkhd, movie_duration.min(u64::from(u32::MAX)) as u32);
        tkhd.extend_from_slice(&[0; 8]);
        put16(&mut tkhd, 0); // layer
        put16(&mut tkhd, 0); // alternate group
        put16(&mut tkhd, 0); // volume (video)
        put16(&mut tkhd, 0);
        for m in matrix {
            put32(&mut tkhd, m);
        }
        put32(&mut tkhd, self.width << 16);
        put32(&mut tkhd, self.height << 16);

        let mut mdhd = Vec::new();
        put32(&mut mdhd, 0);
        put32(&mut mdhd, 0);
        put32(&mut mdhd, TIMESCALE as u32);
        put32(&mut mdhd, duration.min(u64::from(u32::MAX)) as u32);
        put16(&mut mdhd, 0x55c4); // language: und
        put16(&mut mdhd, 0);

        let mut hdlr = Vec::new();
        put32(&mut hdlr, 0);
        hdlr.extend_from_slice(b"vide");
        hdlr.extend_from_slice(&[0; 12]);
        hdlr.extend_from_slice(b"cmux Computer Use\0");

        let mut vmhd = Vec::new();
        put16(&mut vmhd, 0);
        vmhd.extend_from_slice(&[0; 6]);

        let mut dref = Vec::new();
        put32(&mut dref, 1);
        dref.extend_from_slice(&full(b"url ", 0, 1, Vec::new()));
        let dinf = boxed(b"dinf", full(b"dref", 0, 0, dref));

        let mut avcc = vec![1, sps[1], sps[2], sps[3], 0xfc | 3, 0xe0 | 1];
        put16(&mut avcc, sps.len() as u16);
        avcc.extend_from_slice(sps);
        avcc.push(1);
        put16(&mut avcc, pps.len() as u16);
        avcc.extend_from_slice(pps);
        if matches!(sps[1], 100 | 110 | 122 | 144) {
            // High profiles name the chroma format and bit depths: 4:2:0,
            // 8 bits, which is all cmux's encoders make.
            avcc.extend_from_slice(&[0xfc | 1, 0xf8, 0xf8, 0]);
        }
        let mut avc1 = Vec::new();
        avc1.extend_from_slice(&[0; 6]);
        put16(&mut avc1, 1); // data reference index
        avc1.extend_from_slice(&[0; 16]);
        put16(&mut avc1, self.width as u16);
        put16(&mut avc1, self.height as u16);
        put32(&mut avc1, 0x0048_0000); // 72 dpi
        put32(&mut avc1, 0x0048_0000);
        put32(&mut avc1, 0);
        put16(&mut avc1, 1); // frames per sample
        avc1.extend_from_slice(&[0; 32]); // compressor name
        put16(&mut avc1, 0x0018); // depth
        put16(&mut avc1, 0xffff);
        avc1.extend_from_slice(&boxed(b"avcC", avcc));
        let mut stsd = Vec::new();
        put32(&mut stsd, 1);
        stsd.extend_from_slice(&boxed(b"avc1", avc1));

        // Runs of equal frame times.
        let mut runs: Vec<(u32, u32)> = Vec::new();
        for &delta in deltas {
            let delta = delta.min(u64::from(u32::MAX)) as u32;
            match runs.last_mut() {
                Some((count, d)) if *d == delta => *count += 1,
                _ => runs.push((1, delta)),
            }
        }
        let mut stts = Vec::new();
        put32(&mut stts, runs.len() as u32);
        for (count, delta) in runs {
            put32(&mut stts, count);
            put32(&mut stts, delta);
        }

        let keys: Vec<u32> = self
            .samples
            .iter()
            .enumerate()
            .filter(|(_, s)| s.key)
            .map(|(i, _)| i as u32 + 1)
            .collect();
        let mut stss = Vec::new();
        put32(&mut stss, keys.len() as u32);
        for k in keys {
            put32(&mut stss, k);
        }

        // One chunk: the samples lie back to back in mdat.
        let mut stsc = Vec::new();
        put32(&mut stsc, 1);
        put32(&mut stsc, 1);
        put32(&mut stsc, self.samples.len() as u32);
        put32(&mut stsc, 1);

        let mut stsz = Vec::new();
        put32(&mut stsz, 0);
        put32(&mut stsz, self.samples.len() as u32);
        for s in &self.samples {
            put32(&mut stsz, s.size);
        }

        let mut co64 = Vec::new();
        put32(&mut co64, 1);
        co64.extend_from_slice(&(self.mdat_at + MDAT_HEADER).to_be_bytes());

        let mut stbl = Vec::new();
        stbl.extend_from_slice(&full(b"stsd", 0, 0, stsd));
        stbl.extend_from_slice(&full(b"stts", 0, 0, stts));
        stbl.extend_from_slice(&full(b"stss", 0, 0, stss));
        stbl.extend_from_slice(&full(b"stsc", 0, 0, stsc));
        stbl.extend_from_slice(&full(b"stsz", 0, 0, stsz));
        stbl.extend_from_slice(&full(b"co64", 0, 0, co64));

        let mut minf = Vec::new();
        minf.extend_from_slice(&full(b"vmhd", 0, 1, vmhd));
        minf.extend_from_slice(&dinf);
        minf.extend_from_slice(&boxed(b"stbl", stbl));

        let mut mdia = Vec::new();
        mdia.extend_from_slice(&full(b"mdhd", 0, 0, mdhd));
        mdia.extend_from_slice(&full(b"hdlr", 0, 0, hdlr));
        mdia.extend_from_slice(&boxed(b"minf", minf));

        let mut trak = Vec::new();
        trak.extend_from_slice(&full(b"tkhd", 0, 3, tkhd));
        trak.extend_from_slice(&boxed(b"mdia", mdia));

        let mut moov = Vec::new();
        moov.extend_from_slice(&full(b"mvhd", 0, 0, mvhd));
        moov.extend_from_slice(&boxed(b"trak", trak));
        boxed(b"moov", moov)
    }
}

fn put16(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_be_bytes());
}

fn put32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_be_bytes());
}

fn boxed(kind: &[u8; 4], body: Vec<u8>) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len() + 8);
    put32(&mut out, body.len() as u32 + 8);
    out.extend_from_slice(kind);
    out.extend_from_slice(&body);
    out
}

fn full(kind: &[u8; 4], version: u8, flags: u32, body: Vec<u8>) -> Vec<u8> {
    let mut inner = Vec::with_capacity(body.len() + 4);
    put32(&mut inner, (u32::from(version) << 24) | (flags & 0x00ff_ffff));
    inner.extend_from_slice(&body);
    boxed(kind, inner)
}

/// What a finished file says about itself ([`probe`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Info {
    /// The sample entry's type (`avc1` for H.264).
    pub codec: String,
    pub width: u32,
    pub height: u32,
    pub frames: u64,
    pub keyframes: u64,
    pub duration_ms: u64,
    /// The whole file.
    pub bytes: u64,
}

/// One frame read back: its NAL units, each after a four-byte length.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadSample {
    pub data: Vec<u8>,
    pub key: bool,
    /// When it shows, after the start.
    pub at: Duration,
}

/// A finished file read back whole ([`read_samples`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Track {
    pub info: Info,
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
    pub samples: Vec<ReadSample>,
}

fn be32(b: &[u8], at: usize) -> Result<u32, String> {
    b.get(at..at + 4)
        .map(|s| u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
        .ok_or_else(|| "the file ends inside a box".to_string())
}

fn be16(b: &[u8], at: usize) -> Result<u16, String> {
    b.get(at..at + 2)
        .map(|s| u16::from_be_bytes([s[0], s[1]]))
        .ok_or_else(|| "the file ends inside a box".to_string())
}

fn be64(b: &[u8], at: usize) -> Result<u64, String> {
    Ok((u64::from(be32(b, at)?) << 32) | u64::from(be32(b, at + 4)?))
}

/// One box: (type, payload).
type BoxRef<'a> = ([u8; 4], &'a [u8]);

/// The child boxes of `body`.
fn children(body: &[u8]) -> Result<Vec<BoxRef<'_>>, String> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while at + 8 <= body.len() {
        let size = be32(body, at)? as usize;
        let kind = [body[at + 4], body[at + 5], body[at + 6], body[at + 7]];
        if size < 8 || at + size > body.len() {
            return Err(format!("box {} has a bad size", String::from_utf8_lossy(&kind)));
        }
        out.push((kind, &body[at + 8..at + size]));
        at += size;
    }
    Ok(out)
}

fn child<'a>(body: &'a [u8], kind: &[u8; 4]) -> Result<&'a [u8], String> {
    children(body)?
        .into_iter()
        .find(|(k, _)| k == kind)
        .map(|(_, b)| b)
        .ok_or_else(|| format!("no {} box", String::from_utf8_lossy(kind)))
}

/// The largest index (`moov`) this reader loads: an hour at 30 frames a
/// second needs under 1 MiB.
const MAX_MOOV: u64 = 64 << 20;

/// Reads the file's index and checks it against the file: every frame lies
/// inside `mdat` and is a whole number of NAL units.
pub fn probe(path: &Path) -> Result<Info, String> {
    read(path, false).map(|t| t.info)
}

/// [`probe`], with every frame's bytes.
pub fn read_samples(path: &Path) -> Result<Track, String> {
    read(path, true)
}

fn read(path: &Path, keep: bool) -> Result<Track, String> {
    let mut file = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let bytes = file.metadata().map_err(|e| e.to_string())?.len();
    // The top-level boxes: where mdat's payload is, and moov's bytes.
    let mut at = 0u64;
    let mut mdat: Option<(u64, u64)> = None;
    let mut moov: Option<Vec<u8>> = None;
    while at + 8 <= bytes {
        let mut head = [0u8; 16];
        file.seek(SeekFrom::Start(at)).map_err(|e| e.to_string())?;
        file.read_exact(&mut head[..8]).map_err(|e| e.to_string())?;
        let mut size = u64::from(be32(&head, 0)?);
        let mut header = 8u64;
        if size == 1 {
            file.read_exact(&mut head[8..]).map_err(|e| e.to_string())?;
            size = be64(&head, 8)?;
            header = 16;
        } else if size == 0 {
            size = bytes - at;
        }
        if size < header || at + size > bytes {
            return Err(format!(
                "box {} at {at} has a bad size (the recording was not finished?)",
                String::from_utf8_lossy(&head[4..8])
            ));
        }
        match &head[4..8] {
            b"mdat" => mdat = Some((at + header, at + size)),
            b"moov" => {
                if size - header > MAX_MOOV {
                    return Err("the index is too large".into());
                }
                let mut body = vec![0u8; (size - header) as usize];
                file.read_exact(&mut body).map_err(|e| e.to_string())?;
                moov = Some(body);
            }
            _ => {}
        }
        at += size;
    }
    let moov = moov.ok_or("no moov box (the recording was not finished)")?;
    let (mdat_from, mdat_to) = mdat.ok_or("no mdat box")?;

    let trak = child(&moov, b"trak")?;
    let tkhd = child(trak, b"tkhd")?;
    // Version 0: the size is the last two 16.16 numbers.
    let width = be32(tkhd, tkhd.len().saturating_sub(8))? >> 16;
    let height = be32(tkhd, tkhd.len().saturating_sub(4))? >> 16;
    let mdia = child(trak, b"mdia")?;
    let mdhd = child(mdia, b"mdhd")?;
    let timescale = u64::from(be32(mdhd, 12)?).max(1);
    let duration = u64::from(be32(mdhd, 16)?);
    let stbl = child(child(mdia, b"minf")?, b"stbl")?;

    let stsd = child(stbl, b"stsd")?;
    let entry = children(stsd.get(8..).ok_or("a short stsd box")?)?
        .into_iter()
        .next()
        .ok_or("no sample entry")?;
    let codec = String::from_utf8_lossy(&entry.0).into_owned();
    // The visual sample entry's fixed part is 78 bytes; its boxes follow.
    let avcc = child(entry.1.get(78..).ok_or("a short sample entry")?, b"avcC")?;
    let sps_len = usize::from(be16(avcc, 6)?);
    let sps = avcc.get(8..8 + sps_len).ok_or("a short avcC box")?.to_vec();
    let pps_at = 8 + sps_len + 1;
    let pps_len = usize::from(be16(avcc, pps_at)?);
    let pps = avcc.get(pps_at + 2..pps_at + 2 + pps_len).ok_or("a short avcC box")?.to_vec();

    let stsz = child(stbl, b"stsz")?;
    let count = be32(stsz, 8)? as usize;
    let mut sizes = Vec::with_capacity(count.min(1 << 20));
    for i in 0..count {
        sizes.push(u64::from(be32(stsz, 12 + i * 4)?));
    }
    let stss = child(stbl, b"stss")?;
    let key_count = be32(stss, 4)? as usize;
    let mut keys = std::collections::HashSet::new();
    for i in 0..key_count {
        keys.insert(be32(stss, 8 + i * 4)? as usize);
    }
    let stts = child(stbl, b"stts")?;
    let mut times = Vec::with_capacity(count.min(1 << 20));
    let mut tick = 0u64;
    for run in 0..be32(stts, 4)? as usize {
        let n = be32(stts, 8 + run * 8)?;
        let delta = u64::from(be32(stts, 12 + run * 8)?);
        for _ in 0..n {
            times.push(tick);
            tick += delta;
        }
    }
    if times.len() != count {
        return Err(format!("{count} frames but {} frame times", times.len()));
    }
    // One chunk holds every sample (this writer's layout).
    let first = be64(child(stbl, b"co64")?, 8)?;
    let total: u64 = sizes.iter().sum();
    if first < mdat_from || first + total > mdat_to {
        return Err("the frames do not lie inside mdat".into());
    }

    let mut samples = Vec::new();
    file.seek(SeekFrom::Start(first)).map_err(|e| e.to_string())?;
    let mut reader = io::BufReader::new(file);
    for (i, size) in sizes.iter().enumerate() {
        let mut data = vec![0u8; *size as usize];
        reader.read_exact(&mut data).map_err(|e| e.to_string())?;
        // The NAL lengths cover the frame exactly.
        let mut at = 0usize;
        while at < data.len() {
            let len =
                be32(&data, at).map_err(|_| format!("frame {} is cut short", i + 1))? as usize;
            at += 4 + len;
        }
        if at != data.len() {
            return Err(format!("frame {} is not a whole number of NAL units", i + 1));
        }
        if keep {
            samples.push(ReadSample {
                data,
                key: keys.contains(&(i + 1)),
                at: Duration::from_micros(times[i] * 1_000_000 / timescale),
            });
        }
    }
    Ok(Track {
        info: Info {
            codec,
            width,
            height,
            frames: count as u64,
            keyframes: key_count as u64,
            duration_ms: duration * 1000 / timescale,
            bytes,
        },
        sps,
        pps,
        samples,
    })
}

#[cfg(test)]
#[path = "mp4_tests.rs"]
mod tests;
