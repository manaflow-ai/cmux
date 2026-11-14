//! Media Foundation H.264 encoder for Windows hosts, behind the same [`H264Encoder`] trait
//! as OpenH264 and VideoToolbox. Windows licenses the codec with the OS, so this links no
//! codec library: the GPU vendor's hardware MFT ([`MftKind::Hardware`]) or Windows' own
//! software H.264 MFT ([`MftKind::Software`], what a GPU-less machine has). Settings match
//! the other H.264 encoders: constrained baseline, CBR, low-latency mode (one picture in,
//! one access unit out), no B-frames, a GOP of an hour, IDR on request; Annex-B out, with
//! SPS/PPS before every IDR. [`hardware_or`] is a host's choice: a hardware MFT when one is
//! registered, else the caller's fallback (OpenH264).

use std::mem::ManuallyDrop;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{VARIANT_FALSE, VARIANT_TRUE};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoTaskMemFree};
use windows::Win32::System::Variant::{VARIANT, VT_BOOL, VT_UI4};
use windows::core::{GUID, Interface, PWSTR};

use crate::{Codec, EncCfg, H264Encoder, I420, Res};

/// Which MFTs [`MediaFoundation::new`] may pick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MftKind {
    /// A hardware encoder (NVENC, Quick Sync, AMF), usually asynchronous.
    Hardware,
    /// Windows' software H.264 encoder MFT (synchronous).
    Software,
}

/// An async hardware MFT that has not produced the access unit for a picture by this long
/// after it was given counts the frame as held; its output comes out on a later call.
const ASYNC_OUTPUT_WAIT: Duration = Duration::from_millis(100);

pub struct MediaFoundation {
    activate: IMFActivate,
    mft: IMFTransform,
    /// Set for an asynchronous MFT, which signals input and output readiness as events.
    events: Option<IMFMediaEventGenerator>,
    codec_api: Option<ICodecAPI>,
    /// METransformNeedInput events not yet answered with a picture (async MFTs).
    input_credit: u32,
    /// METransformHaveOutput events not yet answered with ProcessOutput (async MFTs).
    output_ready: u32,
    width: usize,
    height: usize,
    frame_hns: i64,
    kbps: u32,
    /// SPS and PPS in Annex-B, from the output type, put before an IDR that lacks them.
    sequence_header: Vec<u8>,
    nv12: Vec<u8>,
    out_pts: Option<i64>,
    name: String,
}

// SAFETY: Media Foundation transforms are free-threaded COM objects created in the
// multithreaded apartment; the encoder is used from one thread at a time (the media loop),
// and every thread that calls it joins the MTA first (`com_init`).
unsafe impl Send for MediaFoundation {}

/// Joins this thread to COM's multithreaded apartment once. A thread already in a
/// single-threaded apartment keeps it; MF transforms work from either.
fn com_init() {
    thread_local! {
        static JOINED: () = {
            // SAFETY: plain COM initialization for this thread; its result only says whether
            // the thread was already initialized, which is fine either way.
            let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        };
    }
    JOINED.with(|_| ());
}

/// Starts Media Foundation once per process (never shut down: encoders may outlive any owner).
fn mf_startup() -> Res<()> {
    static STARTED: OnceLock<Result<(), String>> = OnceLock::new();
    com_init();
    STARTED
        .get_or_init(|| {
            // SAFETY: MFStartup with the SDK version this crate's bindings declare.
            unsafe { MFStartup(MF_VERSION, MFSTARTUP_LITE) }.map_err(|e| format!("MFStartup: {e}"))
        })
        .clone()
        .map_err(Into::into)
}

fn variant_u32(v: u32) -> VARIANT {
    let mut var = VARIANT::default();
    // SAFETY: writing the tag and the matching union member of a fresh VARIANT.
    unsafe {
        var.Anonymous.Anonymous.vt = VT_UI4;
        var.Anonymous.Anonymous.Anonymous.ulVal = v;
    }
    var
}

fn variant_bool(v: bool) -> VARIANT {
    let mut var = VARIANT::default();
    // SAFETY: as above, for VT_BOOL.
    unsafe {
        var.Anonymous.Anonymous.vt = VT_BOOL;
        var.Anonymous.Anonymous.Anonymous.boolVal = if v { VARIANT_TRUE } else { VARIANT_FALSE };
    }
    var
}

/// The H.264 encoder MFTs of `kind`, best first (Media Foundation's sort, which puts the
/// adapter's own hardware encoder first).
fn enum_mfts(kind: MftKind) -> Res<Vec<IMFActivate>> {
    let output = MFT_REGISTER_TYPE_INFO {
        guidMajorType: MFMediaType_Video,
        guidSubtype: MFVideoFormat_H264,
    };
    let flags = match kind {
        MftKind::Hardware => MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
        MftKind::Software => MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
    };
    let mut list: *mut Option<IMFActivate> = std::ptr::null_mut();
    let mut n = 0u32;
    // SAFETY: MFTEnumEx fills `list` with `n` activation objects in a CoTaskMemAlloc'd array.
    unsafe {
        MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, None, Some(&output), &mut list, &mut n)
    }?;
    let mut out = Vec::new();
    if !list.is_null() {
        for i in 0..n as usize {
            // SAFETY: each of the `n` entries is an owned reference, moved out exactly once.
            if let Some(a) = unsafe { std::ptr::read(list.add(i)) } {
                out.push(a);
            }
        }
        // SAFETY: the array itself was allocated by MFTEnumEx with CoTaskMemAlloc.
        unsafe { CoTaskMemFree(Some(list.cast_const().cast())) };
    }
    Ok(out)
}

fn friendly_name(a: &IMFActivate) -> String {
    let mut s = PWSTR::null();
    let mut len = 0u32;
    // SAFETY: GetAllocatedString hands back a CoTaskMemAlloc'd string we free below.
    if unsafe { a.GetAllocatedString(&MFT_FRIENDLY_NAME_Attribute, &mut s, &mut len) }.is_err()
        || s.is_null()
    {
        return "unnamed MFT".into();
    }
    // SAFETY: a NUL-terminated wide string from Media Foundation.
    let name = unsafe { s.to_string() }.unwrap_or_else(|_| "unnamed MFT".into());
    // SAFETY: freeing the string GetAllocatedString allocated.
    unsafe { CoTaskMemFree(Some(s.0.cast_const().cast())) };
    name
}

fn video_type(subtype: &GUID, cfg: &EncCfg) -> Res<IMFMediaType> {
    // SAFETY: attribute setters on a fresh media type, with valid GUID pointers.
    unsafe {
        let t = MFCreateMediaType()?;
        t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        t.SetGUID(&MF_MT_SUBTYPE, subtype)?;
        t.SetUINT64(&MF_MT_FRAME_SIZE, (u64::from(cfg.width) << 32) | u64::from(cfg.height))?;
        t.SetUINT64(&MF_MT_FRAME_RATE, (u64::from(cfg.fps.max(1)) << 32) | 1)?;
        t.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
        t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
        Ok(t)
    }
}

/// The output type's SPS/PPS (MF_MT_MPEG_SEQUENCE_HEADER), when it is Annex-B.
fn sequence_header(mft: &IMFTransform) -> Vec<u8> {
    // SAFETY: reading a blob attribute of the current output type into a buffer of its size.
    unsafe {
        let Ok(t) = mft.GetOutputCurrentType(0) else { return Vec::new() };
        let Ok(n) = t.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER) else { return Vec::new() };
        let mut blob = vec![0u8; n as usize];
        if t.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut blob, None).is_err() {
            return Vec::new();
        }
        if blob.starts_with(&[0, 0, 1]) || blob.starts_with(&[0, 0, 0, 1]) {
            blob
        } else {
            Vec::new()
        }
    }
}

impl MediaFoundation {
    /// An encoder on the best MFT of `kind` that accepts the settings.
    pub fn new(cfg: &EncCfg, kind: MftKind) -> Res<Self> {
        if cfg.width % 2 != 0 || cfg.height % 2 != 0 {
            return Err(format!(
                "media foundation: NV12 needs an even size, not {}x{}",
                cfg.width, cfg.height
            )
            .into());
        }
        mf_startup()?;
        let candidates = enum_mfts(kind)?;
        if candidates.is_empty() {
            return Err(format!("media foundation: no {kind:?} H.264 encoder MFT").into());
        }
        let mut errors = Vec::new();
        for activate in candidates {
            let name = friendly_name(&activate);
            match Self::open(activate, cfg, kind, &name) {
                Ok(enc) => return Ok(enc),
                Err(e) => errors.push(format!("{name}: {e}")),
            }
        }
        Err(format!("media foundation: no {kind:?} MFT took the settings ({})", errors.join("; "))
            .into())
    }

    fn open(activate: IMFActivate, cfg: &EncCfg, kind: MftKind, mft_name: &str) -> Res<Self> {
        let kbps = cfg.kbps.max(100);
        // SAFETY: COM calls on objects this function owns, with valid arguments.
        unsafe {
            let mft: IMFTransform = activate.ActivateObject()?;
            let attrs = mft.GetAttributes().ok();
            let is_async =
                attrs.as_ref().and_then(|a| a.GetUINT32(&MF_TRANSFORM_ASYNC).ok()).unwrap_or(0)
                    != 0;
            if let Some(a) = &attrs {
                if is_async {
                    a.SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1)?;
                }
                let _ = a.SetUINT32(&MF_LOW_LATENCY, 1);
            }
            let events = if is_async { Some(mft.cast::<IMFMediaEventGenerator>()?) } else { None };
            let codec_api = mft.cast::<ICodecAPI>().ok();
            // Rate control first: some encoders read it when the output type is set.
            let mut settings = Vec::new();
            if let Some(api) = &codec_api {
                for (what, key, value) in [
                    (
                        "cbr",
                        CODECAPI_AVEncCommonRateControlMode,
                        variant_u32(eAVEncCommonRateControlMode_CBR.0 as u32),
                    ),
                    ("bitrate", CODECAPI_AVEncCommonMeanBitRate, variant_u32(kbps * 1000)),
                    ("low-latency", CODECAPI_AVLowLatencyMode, variant_bool(true)),
                    ("b=0", CODECAPI_AVEncMPVDefaultBPictureCount, variant_u32(0)),
                    ("gop=1h", CODECAPI_AVEncMPVGOPSize, variant_u32(cfg.fps.max(1) * 3600)),
                ] {
                    if api.SetValue(&key, &value).is_ok() {
                        settings.push(what);
                    }
                }
            }
            let out = video_type(&MFVideoFormat_H264, cfg)?;
            out.SetUINT32(&MF_MT_AVG_BITRATE, kbps * 1000)?;
            out.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base.0 as u32)?;
            mft.SetOutputType(0, &out, 0)?;
            mft.SetInputType(0, &video_type(&MFVideoFormat_NV12, cfg)?, 0)?;
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            let name = format!(
                "media foundation {} ({}{}) baseline {}",
                mft_name,
                if kind == MftKind::Hardware { "hardware" } else { "software" },
                if is_async { ", async" } else { "" },
                settings.join(" ")
            );
            let (w, h) = (cfg.width as usize, cfg.height as usize);
            Ok(Self {
                sequence_header: sequence_header(&mft),
                activate,
                mft,
                events,
                codec_api,
                input_credit: 0,
                output_ready: 0,
                width: w,
                height: h,
                frame_hns: 10_000_000 / i64::from(cfg.fps.max(1)),
                kbps,
                nv12: vec![0; w * h * 3 / 2],
                out_pts: None,
                name,
            })
        }
    }

    fn input_sample(&mut self, pic: &I420, pts: i64) -> Res<IMFSample> {
        let (w, h) = (self.width, self.height);
        if pic.width != w || pic.y.len() < w * h {
            return Err(format!("media foundation: picture is not {w}x{h}").into());
        }
        let (y, uv) = self.nv12.split_at_mut(w * h);
        y.copy_from_slice(&pic.y[..w * h]);
        for ((pair, &u), &v) in uv.chunks_exact_mut(2).zip(&pic.u).zip(&pic.v) {
            pair[0] = u;
            pair[1] = v;
        }
        // SAFETY: a new buffer of the NV12 size, locked while it is filled; then a new sample.
        unsafe {
            let buf = MFCreateMemoryBuffer(self.nv12.len() as u32)?;
            let mut dst = std::ptr::null_mut();
            buf.Lock(&mut dst, None, None)?;
            std::ptr::copy_nonoverlapping(self.nv12.as_ptr(), dst, self.nv12.len());
            buf.Unlock()?;
            buf.SetCurrentLength(self.nv12.len() as u32)?;
            let sample = MFCreateSample()?;
            sample.AddBuffer(&buf)?;
            sample.SetSampleTime(pts.max(0) * 10)?;
            sample.SetSampleDuration(self.frame_hns)?;
            Ok(sample)
        }
    }

    /// One ProcessOutput call: appends an access unit to `out` and returns true, or
    /// returns false when the MFT needs more input first.
    fn take_output(&mut self, out: &mut Vec<u8>) -> Res<bool> {
        loop {
            // SAFETY: ProcessOutput with one output buffer whose sample we own (or the MFT
            // provides); both ManuallyDrop fields are taken back exactly once after the call.
            let (result, sample) = unsafe {
                let info = self.mft.GetOutputStreamInfo(0)?;
                let provides = info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 != 0;
                let sample = if provides {
                    None
                } else {
                    let s = MFCreateSample()?;
                    let size = info.cbSize.max((self.width * self.height) as u32);
                    s.AddBuffer(&MFCreateMemoryBuffer(size)?)?;
                    Some(s)
                };
                let mut db = MFT_OUTPUT_DATA_BUFFER {
                    dwStreamID: 0,
                    pSample: ManuallyDrop::new(sample),
                    dwStatus: 0,
                    pEvents: ManuallyDrop::new(None),
                };
                let mut status = 0u32;
                let r = self.mft.ProcessOutput(0, 1, &mut db, &mut status);
                drop(ManuallyDrop::into_inner(db.pEvents));
                (r, ManuallyDrop::into_inner(db.pSample))
            };
            match result {
                Ok(()) => {}
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(false),
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    // SAFETY: renegotiating the output type the MFT now offers.
                    unsafe {
                        let t = self.mft.GetOutputAvailableType(0, 0)?;
                        self.mft.SetOutputType(0, &t, 0)?;
                    }
                    self.sequence_header = sequence_header(&self.mft);
                    continue;
                }
                Err(e) => return Err(format!("media foundation ProcessOutput: {e}").into()),
            }
            let sample = sample.ok_or("media foundation: ProcessOutput returned no sample")?;
            let start = out.len();
            // SAFETY: reading the sample's bytes while its contiguous buffer is locked.
            unsafe {
                let buf = sample.ConvertToContiguousBuffer()?;
                let mut src = std::ptr::null_mut();
                let mut len = 0u32;
                buf.Lock(&mut src, None, Some(&mut len))?;
                out.extend_from_slice(std::slice::from_raw_parts(src, len as usize));
                buf.Unlock()?;
                self.out_pts = sample.GetSampleTime().ok().map(|t| t / 10);
            }
            let au = &out[start..];
            if Codec::H264.is_keyframe(au)
                && !crate::annexb_nals(au).any(|n| n.first().is_some_and(|b| b & 0x1f == 7))
                && !self.sequence_header.is_empty()
            {
                out.splice(start..start, self.sequence_header.iter().copied());
            }
            return Ok(true);
        }
    }

    /// Takes the next event of an async MFT, waiting until `deadline` (None: don't wait).
    fn next_event(&mut self, deadline: Option<Instant>) -> Res<bool> {
        let Some(events) = &self.events else { return Ok(false) };
        loop {
            // SAFETY: a non-blocking event read on the MFT's own event generator.
            match unsafe { events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                Ok(ev) => {
                    // SAFETY: reading the type of an event we own.
                    let t = unsafe { ev.GetType() }?;
                    if t == METransformNeedInput.0 as u32 {
                        self.input_credit += 1;
                    } else if t == METransformHaveOutput.0 as u32 {
                        self.output_ready += 1;
                    }
                    return Ok(true);
                }
                Err(e) if e.code() == MF_E_NO_EVENTS_AVAILABLE => {
                    if deadline.is_none_or(|d| Instant::now() >= d) {
                        return Ok(false);
                    }
                    // The generator's blocking read has no timeout, and a held frame must not
                    // hang the media loop; hardware encoders answer in a few milliseconds.
                    std::thread::sleep(Duration::from_micros(250));
                }
                Err(e) => return Err(format!("media foundation event: {e}").into()),
            }
        }
    }

    fn encode_async(&mut self, sample: &IMFSample, out: &mut Vec<u8>) -> Res<()> {
        let deadline = Instant::now() + ASYNC_OUTPUT_WAIT;
        // Output still owed from earlier pictures goes first.
        while self.next_event(None)? {}
        while self.output_ready > 0 {
            self.output_ready -= 1;
            self.take_output(out)?;
        }
        while self.input_credit == 0 {
            if !self.next_event(Some(deadline))? {
                return Err("media foundation: hardware MFT asked for no input".into());
            }
        }
        self.input_credit -= 1;
        // SAFETY: handing the MFT a sample it asked for (METransformNeedInput).
        unsafe { self.mft.ProcessInput(0, sample, 0) }?;
        let start = out.len();
        while out.len() == start {
            if self.output_ready > 0 {
                self.output_ready -= 1;
                self.take_output(out)?;
            } else if !self.next_event(Some(deadline))? {
                break;
            }
        }
        Ok(())
    }

    fn encode_sync(&mut self, sample: &IMFSample, out: &mut Vec<u8>) -> Res<()> {
        // SAFETY: ProcessInput on a synchronous MFT; MF_E_NOTACCEPTING means drain first.
        match unsafe { self.mft.ProcessInput(0, sample, 0) } {
            Ok(()) => {}
            Err(e) if e.code() == MF_E_NOTACCEPTING => {
                while self.take_output(out)? {}
                // SAFETY: as above, after the MFT's pending output was taken.
                unsafe { self.mft.ProcessInput(0, sample, 0) }?;
            }
            Err(e) => return Err(format!("media foundation ProcessInput: {e}").into()),
        }
        while self.take_output(out)? {}
        Ok(())
    }
}

impl H264Encoder for MediaFoundation {
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool> {
        com_init();
        out.clear();
        self.out_pts = None;
        if force_idr && let Some(api) = &self.codec_api {
            // SAFETY: a documented codec property set before the picture it applies to.
            unsafe { api.SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &variant_u32(1)) }?;
        }
        let sample = self.input_sample(pic, pts)?;
        if self.events.is_some() {
            self.encode_async(&sample, out)?;
        } else {
            self.encode_sync(&sample, out)?;
        }
        Ok(Codec::H264.is_keyframe(out))
    }

    fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.clamp(100, 288_000);
        if u64::from(kbps.abs_diff(self.kbps)) * 20 < u64::from(self.kbps) {
            return;
        }
        if let Some(api) = &self.codec_api
            // SAFETY: the mean bitrate is a dynamic property on encoders that take CBR.
            && unsafe { api.SetValue(&CODECAPI_AVEncCommonMeanBitRate, &variant_u32(kbps * 1000)) }.is_ok()
        {
            self.kbps = kbps;
        }
    }

    fn kbps(&self) -> u32 {
        self.kbps
    }

    fn name(&self) -> String {
        self.name.clone()
    }

    fn output_pts(&self) -> Option<i64> {
        self.out_pts
    }
}

impl Drop for MediaFoundation {
    fn drop(&mut self) {
        // SAFETY: ending the stream and releasing the activated MFT exactly once.
        unsafe {
            let _ = self.mft.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.activate.ShutdownObject();
        }
    }
}

/// A hardware Media Foundation encoder when this machine has one, else `fallback`
/// (a host passes OpenH264). The fallback's error names the hardware failure too.
pub fn hardware_or(
    cfg: &EncCfg,
    fallback: impl FnOnce() -> Res<Box<dyn H264Encoder>>,
) -> Res<Box<dyn H264Encoder>> {
    match MediaFoundation::new(cfg, MftKind::Hardware) {
        Ok(enc) => Ok(Box::new(enc)),
        Err(hw) => fallback().map_err(|e| format!("{e} (after {hw})").into()),
    }
}
