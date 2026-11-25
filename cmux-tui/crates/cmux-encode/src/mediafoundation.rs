//! Media Foundation H.264 encoder for Windows hosts, behind the same [`H264Encoder`] trait
//! as OpenH264 and VideoToolbox. Windows licenses the codec with the OS, so this links no
//! codec library: the GPU vendor's hardware MFT ([`MftKind::Hardware`]) or Windows' own
//! software H.264 MFT ([`MftKind::Software`], what a GPU-less machine has). Settings match
//! the other H.264 encoders: constrained baseline, CBR, low-latency mode (one picture in,
//! one access unit out), no B-frames, a GOP of an hour, IDR on request; Annex-B out, with
//! SPS/PPS before every IDR. [`hardware_or`] is a host's choice: a hardware MFT when one is
//! registered, else the caller's fallback (OpenH264).
//!
//! mfplat.dll is bound at run time, as the Windows host's probe does: Windows N editions and
//! Server without the Media Foundation feature have none, and a binary that imported it at
//! load time would not start there, fallback or not.

use std::collections::VecDeque;
use std::ffi::c_void;
use std::mem::ManuallyDrop;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{VARIANT_FALSE, VARIANT_TRUE};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoTaskMemFree};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryW};
use windows::Win32::System::Variant::{VARIANT, VT_BOOL, VT_UI4};
use windows::core::{GUID, HRESULT, Interface, PWSTR, s, w};

use crate::{Codec, EncCfg, H264Encoder, I420, Res};

/// Which MFTs [`MediaFoundation::new`] may pick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MftKind {
    /// A hardware encoder (NVENC, Quick Sync, AMF), usually asynchronous.
    Hardware,
    /// Windows' software H.264 encoder MFT (synchronous).
    Software,
}

/// Rate control an MFT runs ([`MfTuning::rc`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RateControl {
    /// Constant bitrate at the target (the default).
    #[default]
    Cbr,
    /// Low-delay VBR: the target as a mean, frames may vary.
    LowDelayVbr,
    /// Peak-constrained VBR: the target as a mean, capped at `peak_pct` of it.
    PeakVbr,
    /// Constant quality ([`MfTuning::quality`], 0-100), the target ignored.
    Quality,
}

/// The H.264 profile an MFT sends ([`MfTuning::profile`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Profile {
    /// Constrained baseline, as OpenH264 and VideoToolbox send (the default).
    #[default]
    Baseline,
    Main,
    /// High: 8x8 transforms; with CABAC, the most bits saved on text.
    High,
}

impl Profile {
    fn mf_profile(self) -> u32 {
        match self {
            Profile::Baseline => eAVEncH264VProfile_Base.0 as u32,
            Profile::Main => eAVEncH264VProfile_Main.0 as u32,
            Profile::High => eAVEncH264VProfile_High.0 as u32,
        }
    }
}

/// Settings past the defaults, for measuring what makes screen content sharper. The
/// default is what [`MediaFoundation::new`] uses. [`MfTuning::parse`] reads the bench's
/// comma list (`rc=quality,quality=70,profile=high,cabac=1,minqp=20,maxqp=40,stillqp=22`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MfTuning {
    pub rc: RateControl,
    /// Constant-quality level, 0-100 ([`RateControl::Quality`]).
    pub quality: u32,
    /// The peak as a percent of the target ([`RateControl::PeakVbr`]).
    pub peak_pct: u32,
    pub profile: Profile,
    /// CABAC entropy coding (main and high profiles only).
    pub cabac: bool,
    pub min_qp: Option<u32>,
    pub max_qp: Option<u32>,
    /// The QP ceiling on a picture identical to the one before (sharpen-on-still).
    pub still_max_qp: Option<u32>,
    /// The rate-control buffer, in milliseconds of the target.
    pub buffer_ms: Option<u32>,
    /// Quality against speed, 0 (fastest) to 100 (best).
    pub quality_vs_speed: Option<u32>,
    pub threads: Option<u32>,
    pub low_latency: bool,
}

impl Default for MfTuning {
    fn default() -> Self {
        Self {
            rc: RateControl::Cbr,
            quality: 70,
            peak_pct: 200,
            profile: Profile::Baseline,
            cabac: false,
            min_qp: None,
            max_qp: None,
            still_max_qp: None,
            buffer_ms: None,
            quality_vs_speed: None,
            threads: None,
            low_latency: true,
        }
    }
}

impl MfTuning {
    /// Reads `key=value` pairs, comma separated, over the default.
    pub fn parse(s: &str) -> Res<Self> {
        let mut t = Self::default();
        for pair in s.split(',').map(str::trim).filter(|p| !p.is_empty()) {
            let (k, v) =
                pair.split_once('=').ok_or(format!("mf tuning: {pair} is not key=value"))?;
            let num = || v.parse::<u32>().map_err(|e| format!("mf tuning {k}: {e}"));
            match k {
                "rc" => {
                    t.rc = match v {
                        "cbr" => RateControl::Cbr,
                        "ldvbr" => RateControl::LowDelayVbr,
                        "pvbr" => RateControl::PeakVbr,
                        "quality" => RateControl::Quality,
                        _ => return Err(format!("mf tuning: unknown rc {v}").into()),
                    }
                }
                "quality" => t.quality = num()?.min(100),
                "peak" => t.peak_pct = num()?.max(100),
                "profile" => {
                    t.profile = match v {
                        "base" => Profile::Baseline,
                        "main" => Profile::Main,
                        "high" => Profile::High,
                        _ => return Err(format!("mf tuning: unknown profile {v}").into()),
                    }
                }
                "cabac" => t.cabac = num()? != 0,
                "minqp" => t.min_qp = Some(num()?),
                "maxqp" => t.max_qp = Some(num()?),
                "stillqp" => t.still_max_qp = Some(num()?),
                "buffer_ms" => t.buffer_ms = Some(num()?),
                "qvs" => t.quality_vs_speed = Some(num()?.min(100)),
                "threads" => t.threads = Some(num()?),
                "lowlat" => t.low_latency = num()? != 0,
                _ => return Err(format!("mf tuning: unknown key {k}").into()),
            }
        }
        Ok(t)
    }

    /// The codec properties these settings set, each with the name the encoder's name lists.
    fn properties(&self, kbps: u32, fps: u32) -> Vec<(String, GUID, VARIANT)> {
        let bps = kbps * 1000;
        let rc = match self.rc {
            RateControl::Cbr => eAVEncCommonRateControlMode_CBR,
            RateControl::LowDelayVbr => eAVEncCommonRateControlMode_LowDelayVBR,
            RateControl::PeakVbr => eAVEncCommonRateControlMode_PeakConstrainedVBR,
            RateControl::Quality => eAVEncCommonRateControlMode_Quality,
        };
        let mut p = vec![(
            format!("rc={:?}", self.rc).to_lowercase(),
            CODECAPI_AVEncCommonRateControlMode,
            variant_u32(rc.0 as u32),
        )];
        if self.rc == RateControl::Quality {
            p.push((
                format!("quality={}", self.quality),
                CODECAPI_AVEncCommonQuality,
                variant_u32(self.quality),
            ));
        } else {
            p.push(("bitrate".into(), CODECAPI_AVEncCommonMeanBitRate, variant_u32(bps)));
        }
        if self.rc == RateControl::PeakVbr {
            let peak =
                (u64::from(bps) * u64::from(self.peak_pct) / 100).min(u64::from(u32::MAX)) as u32;
            p.push((
                format!("peak={}%", self.peak_pct),
                CODECAPI_AVEncCommonMaxBitRate,
                variant_u32(peak),
            ));
        }
        p.push((
            format!("low-latency={}", self.low_latency),
            CODECAPI_AVLowLatencyMode,
            variant_bool(self.low_latency),
        ));
        p.push(("b=0".into(), CODECAPI_AVEncMPVDefaultBPictureCount, variant_u32(0)));
        p.push(("gop=1h".into(), CODECAPI_AVEncMPVGOPSize, variant_u32(fps.max(1) * 3600)));
        if self.profile != Profile::Baseline {
            p.push((
                format!("profile={:?} cabac={}", self.profile, self.cabac).to_lowercase(),
                CODECAPI_AVEncH264CABACEnable,
                variant_bool(self.cabac),
            ));
        }
        for (name, key, v) in [
            ("minqp", CODECAPI_AVEncVideoMinQP, self.min_qp),
            ("maxqp", CODECAPI_AVEncVideoMaxQP, self.max_qp),
            ("qvs", CODECAPI_AVEncCommonQualityVsSpeed, self.quality_vs_speed),
            ("threads", CODECAPI_AVEncNumWorkerThreads, self.threads),
        ] {
            if let Some(v) = v {
                p.push((format!("{name}={v}"), key, variant_u32(v)));
            }
        }
        if let Some(ms) = self.buffer_ms {
            let bits = (u64::from(bps) * u64::from(ms) / 1000).min(u64::from(u32::MAX)) as u32;
            p.push((format!("buffer={ms}ms"), CODECAPI_AVEncCommonBufferSize, variant_u32(bits)));
        }
        p
    }
}

/// How long an async hardware MFT may take to ask for a picture or to return its access
/// unit. Past it the picture is dropped or its output comes on a later call, as a skipped
/// frame would; the media loop never waits longer.
const ASYNC_WAIT: Duration = Duration::from_millis(100);

/// Pictures in a row an async MFT may refuse before the encoder counts it dead.
const MAX_REFUSED: u32 = 30;

/// The mfplat.dll entry points in use, bound once per process.
struct MfPlat {
    startup: unsafe extern "system" fn(u32, u32) -> HRESULT,
    enum_ex: unsafe extern "system" fn(
        GUID,
        u32,
        *const MFT_REGISTER_TYPE_INFO,
        *const MFT_REGISTER_TYPE_INFO,
        *mut *mut *mut c_void,
        *mut u32,
    ) -> HRESULT,
    create_media_type: unsafe extern "system" fn(*mut *mut c_void) -> HRESULT,
    create_sample: unsafe extern "system" fn(*mut *mut c_void) -> HRESULT,
    create_memory_buffer: unsafe extern "system" fn(u32, *mut *mut c_void) -> HRESULT,
}

/// mfplat.dll's entry points, with Media Foundation started (never shut down: encoders may
/// outlive any owner).
fn mfplat() -> Res<&'static MfPlat> {
    static PLAT: OnceLock<Result<MfPlat, String>> = OnceLock::new();
    com_init();
    PLAT.get_or_init(|| {
        // SAFETY: loading a system DLL by name and reading exports whose documented
        // signatures the fn types above declare; the module stays loaded for the process.
        unsafe {
            let module = LoadLibraryW(w!("mfplat.dll"))
                .map_err(|e| format!("mfplat.dll (no Media Foundation on this Windows): {e}"))?;
            macro_rules! bind {
                ($name:literal) => {
                    std::mem::transmute(
                        GetProcAddress(module, s!($name))
                            .ok_or(concat!("mfplat.dll has no ", $name))?,
                    )
                };
            }
            let plat = MfPlat {
                startup: bind!("MFStartup"),
                enum_ex: bind!("MFTEnumEx"),
                create_media_type: bind!("MFCreateMediaType"),
                create_sample: bind!("MFCreateSample"),
                create_memory_buffer: bind!("MFCreateMemoryBuffer"),
            };
            (plat.startup)(MF_VERSION, MFSTARTUP_LITE)
                .ok()
                .map_err(|e| format!("MFStartup: {e}"))?;
            Ok(plat)
        }
    })
    .as_ref()
    .map_err(|e| e.clone().into())
}

/// An interface from a creator that returns one through an out pointer.
///
/// # Safety
/// `f` must write an owned `T` (or null on failure) through its argument.
unsafe fn created<T: Interface>(f: impl FnOnce(*mut *mut c_void) -> HRESULT) -> Res<T> {
    let mut raw = std::ptr::null_mut();
    f(&mut raw).ok()?;
    if raw.is_null() {
        return Err("media foundation: a creator returned null".into());
    }
    // SAFETY: per the contract, `raw` is an owned reference to a `T`.
    Ok(unsafe { T::from_raw(raw) })
}

impl MfPlat {
    fn media_type(&self) -> Res<IMFMediaType> {
        // SAFETY: MFCreateMediaType writes an owned IMFMediaType.
        unsafe { created(|p| (self.create_media_type)(p)) }
    }

    fn sample(&self) -> Res<IMFSample> {
        // SAFETY: MFCreateSample writes an owned IMFSample.
        unsafe { created(|p| (self.create_sample)(p)) }
    }

    fn buffer(&self, len: u32) -> Res<IMFMediaBuffer> {
        // SAFETY: MFCreateMemoryBuffer writes an owned IMFMediaBuffer.
        unsafe { created(|p| (self.create_memory_buffer)(len, p)) }
    }

    /// The H.264 encoder MFTs of `kind`, best first (Media Foundation's sort, which puts the
    /// adapter's own hardware encoder first).
    fn encoders(&self, kind: MftKind) -> Res<Vec<IMFActivate>> {
        let output = MFT_REGISTER_TYPE_INFO {
            guidMajorType: MFMediaType_Video,
            guidSubtype: MFVideoFormat_H264,
        };
        let flags = match kind {
            MftKind::Hardware => MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
            MftKind::Software => MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
        };
        let mut list: *mut *mut c_void = std::ptr::null_mut();
        let mut n = 0u32;
        // SAFETY: MFTEnumEx fills `list` with `n` owned IMFActivate pointers in a
        // CoTaskMemAlloc'd array; each is taken exactly once, then the array is freed.
        unsafe {
            (self.enum_ex)(
                MFT_CATEGORY_VIDEO_ENCODER,
                flags.0 as u32,
                std::ptr::null(),
                &output,
                &mut list,
                &mut n,
            )
            .ok()?;
            let mut out = Vec::new();
            if !list.is_null() {
                for i in 0..n as usize {
                    let raw = *list.add(i);
                    if !raw.is_null() {
                        out.push(IMFActivate::from_raw(raw));
                    }
                }
                CoTaskMemFree(Some(list.cast_const().cast()));
            }
            Ok(out)
        }
    }

    fn video_type(&self, subtype: &GUID, cfg: &EncCfg) -> Res<IMFMediaType> {
        let t = self.media_type()?;
        // SAFETY: attribute setters on a fresh media type, with valid GUID pointers.
        unsafe {
            t.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            t.SetGUID(&MF_MT_SUBTYPE, subtype)?;
            t.SetUINT64(&MF_MT_FRAME_SIZE, (u64::from(cfg.width) << 32) | u64::from(cfg.height))?;
            t.SetUINT64(&MF_MT_FRAME_RATE, (u64::from(cfg.fps.max(1)) << 32) | 1)?;
            t.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
            t.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            // The pictures' colour (crate::color::SCREEN: BT.709 video range from sRGB), which
            // the encoder writes into the SPS VUI so a viewer converts them back the same way.
            t.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32)?;
            t.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32)?;
            t.SetUINT32(&MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709.0 as u32)?;
            t.SetUINT32(&MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_sRGB.0 as u32)?;
        }
        Ok(t)
    }
}

/// An access unit and the capture time of the picture it carries.
type Unit = (Vec<u8>, Option<i64>);

pub struct MediaFoundation {
    plat: &'static MfPlat,
    activate: IMFActivate,
    mft: IMFTransform,
    /// Set for an asynchronous MFT, which signals input and output readiness as events.
    events: Option<IMFMediaEventGenerator>,
    codec_api: Option<ICodecAPI>,
    /// METransformNeedInput events not yet answered with a picture (async MFTs).
    input_credit: u32,
    /// METransformHaveOutput events not yet answered with ProcessOutput (async MFTs).
    output_ready: u32,
    /// Pictures in a row the async MFT gave no input credit for.
    refused: u32,
    /// Access units taken from the MFT but not yet returned: [`H264Encoder::encode`]
    /// returns one per call.
    pending: VecDeque<Unit>,
    width: usize,
    height: usize,
    frame_hns: i64,
    kbps: u32,
    /// SPS and PPS in Annex-B, from the output type, put before an IDR that lacks them.
    sequence_header: Vec<u8>,
    nv12: Vec<u8>,
    out_pts: Option<i64>,
    name: String,
    /// [`MfTuning::still_max_qp`]; `moving_max_qp` is the ceiling it restores.
    still_max_qp: Option<u32>,
    moving_max_qp: u32,
    prev_y: Vec<u8>,
    sharpening: bool,
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

fn variant_u32(v: u32) -> VARIANT {
    let mut var = VARIANT::default();
    // SAFETY: writing the tag and the matching member of a fresh VARIANT; the
    // ManuallyDrop wraps plain data.
    unsafe {
        (*var.Anonymous.Anonymous).vt = VT_UI4;
        (*var.Anonymous.Anonymous).Anonymous.ulVal = v;
    }
    var
}

fn variant_bool(v: bool) -> VARIANT {
    let mut var = VARIANT::default();
    // SAFETY: as above, for VT_BOOL.
    unsafe {
        (*var.Anonymous.Anonymous).vt = VT_BOOL;
        (*var.Anonymous.Anonymous).Anonymous.boolVal = if v { VARIANT_TRUE } else { VARIANT_FALSE };
    }
    var
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

/// Shuts an activated MFT down unless defused: a candidate that refused the settings must
/// not keep its hardware encoder session until the process exits.
struct ShutdownGuard<'a>(Option<&'a IMFActivate>);

impl Drop for ShutdownGuard<'_> {
    fn drop(&mut self) {
        if let Some(a) = self.0 {
            // SAFETY: shutting down an object this function activated.
            let _ = unsafe { a.ShutdownObject() };
        }
    }
}

impl MediaFoundation {
    /// An encoder on the best MFT of `kind` that accepts the settings.
    pub fn new(cfg: &EncCfg, kind: MftKind) -> Res<Self> {
        Self::with_tuning(cfg, kind, &MfTuning::default())
    }

    /// [`MediaFoundation::new`] with `tuning` in place of the default settings.
    pub fn with_tuning(cfg: &EncCfg, kind: MftKind, tuning: &MfTuning) -> Res<Self> {
        if cfg.width % 2 != 0 || cfg.height % 2 != 0 {
            return Err(format!(
                "media foundation: NV12 needs an even size, not {}x{}",
                cfg.width, cfg.height
            )
            .into());
        }
        let plat = mfplat()?;
        let candidates = plat.encoders(kind)?;
        if candidates.is_empty() {
            return Err(format!("media foundation: no {kind:?} H.264 encoder MFT").into());
        }
        let mut errors = Vec::new();
        for activate in candidates {
            let name = friendly_name(&activate);
            match Self::open(plat, activate, cfg, kind, tuning, &name) {
                Ok(enc) => return Ok(enc),
                Err(e) => errors.push(format!("{name}: {e}")),
            }
        }
        Err(format!("media foundation: no {kind:?} MFT took the settings ({})", errors.join("; "))
            .into())
    }

    fn open(
        plat: &'static MfPlat,
        activate: IMFActivate,
        cfg: &EncCfg,
        kind: MftKind,
        tuning: &MfTuning,
        mft_name: &str,
    ) -> Res<Self> {
        let kbps = cfg.kbps.max(100);
        // SAFETY: COM calls on objects this function owns, with valid arguments.
        let mft: IMFTransform = unsafe { activate.ActivateObject() }?;
        let mut guard = ShutdownGuard(Some(&activate));
        // SAFETY: as above.
        let (events, codec_api, settings, is_async) = unsafe {
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
                for (what, key, value) in tuning.properties(kbps, cfg.fps) {
                    if api.SetValue(&key, &value).is_ok() {
                        settings.push(what);
                    } else {
                        settings.push(format!("{what}(refused)"));
                    }
                }
            }
            if let Some(qp) = tuning.still_max_qp {
                settings.push(format!("stillqp={qp}"));
            }
            let out = plat.video_type(&MFVideoFormat_H264, cfg)?;
            out.SetUINT32(&MF_MT_AVG_BITRATE, kbps * 1000)?;
            out.SetUINT32(&MF_MT_MPEG2_PROFILE, tuning.profile.mf_profile())?;
            mft.SetOutputType(0, &out, 0)?;
            mft.SetInputType(0, &plat.video_type(&MFVideoFormat_NV12, cfg)?, 0)?;
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            (events, codec_api, settings, is_async)
        };
        guard.0 = None;
        drop(guard);
        let name = format!(
            "media foundation {} ({}{}) {}",
            mft_name,
            if kind == MftKind::Hardware { "hardware" } else { "software" },
            if is_async { ", async" } else { "" },
            settings.join(" ")
        );
        let (w, h) = (cfg.width as usize, cfg.height as usize);
        Ok(Self {
            plat,
            sequence_header: sequence_header(&mft),
            activate,
            mft,
            events,
            codec_api,
            input_credit: 0,
            output_ready: 0,
            refused: 0,
            pending: VecDeque::new(),
            width: w,
            height: h,
            frame_hns: 10_000_000 / i64::from(cfg.fps.max(1)),
            kbps,
            nv12: vec![0; w * h * 3 / 2],
            out_pts: None,
            name,
            still_max_qp: tuning.still_max_qp,
            moving_max_qp: tuning.max_qp.unwrap_or(51),
            prev_y: Vec::new(),
            sharpening: false,
        })
    }

    /// Sharpen-on-still: a picture identical to the one before gets `still_max_qp` as its
    /// QP ceiling, so the encoder spends the idle frames refining what is on screen; the
    /// first changed picture puts the ceiling back.
    fn sharpen_on_still(&mut self, pic: &I420) {
        let Some(still_qp) = self.still_max_qp else { return };
        let still = !self.prev_y.is_empty() && self.prev_y == pic.y;
        if still != self.sharpening
            && let Some(api) = &self.codec_api
        {
            let qp = if still { still_qp } else { self.moving_max_qp };
            // SAFETY: a documented codec property, set between pictures.
            if unsafe { api.SetValue(&CODECAPI_AVEncVideoMaxQP, &variant_u32(qp)) }.is_ok() {
                self.sharpening = still;
            }
        }
        self.prev_y.clear();
        self.prev_y.extend_from_slice(&pic.y);
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
        let buf = self.plat.buffer(self.nv12.len() as u32)?;
        let sample = self.plat.sample()?;
        // SAFETY: the new buffer holds the NV12 size and is locked while it is filled.
        unsafe {
            let mut dst = std::ptr::null_mut();
            buf.Lock(&mut dst, None, None)?;
            std::ptr::copy_nonoverlapping(self.nv12.as_ptr(), dst, self.nv12.len());
            buf.Unlock()?;
            buf.SetCurrentLength(self.nv12.len() as u32)?;
            sample.AddBuffer(&buf)?;
            sample.SetSampleTime(pts.max(0) * 10)?;
            sample.SetSampleDuration(self.frame_hns)?;
        }
        Ok(sample)
    }

    /// One ProcessOutput call: an access unit, or `None` when the MFT has none ready (it
    /// needs more input, or, async, it changed its output type and will signal again).
    fn take_output(&mut self) -> Res<Option<Unit>> {
        loop {
            // SAFETY: ProcessOutput with one output buffer whose sample we own (or the MFT
            // provides); both ManuallyDrop fields are taken back exactly once after the call.
            let (result, sample) = unsafe {
                let info = self.mft.GetOutputStreamInfo(0)?;
                let provides = info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 != 0;
                let sample = if provides {
                    None
                } else {
                    let s = self.plat.sample()?;
                    // An IDR with SPS/PPS fits in a raw picture's size with room to spare.
                    let size = info.cbSize.max((self.width * self.height * 3 / 2 + 1024) as u32);
                    s.AddBuffer(&self.plat.buffer(size)?)?;
                    Some(s)
                };
                let mut db = MFT_OUTPUT_DATA_BUFFER {
                    dwStreamID: 0,
                    pSample: ManuallyDrop::new(sample),
                    dwStatus: 0,
                    pEvents: ManuallyDrop::new(None),
                };
                let mut status = 0u32;
                let r = self.mft.ProcessOutput(0, std::slice::from_mut(&mut db), &mut status);
                drop(ManuallyDrop::into_inner(db.pEvents));
                (r, ManuallyDrop::into_inner(db.pSample))
            };
            match result {
                Ok(()) => {}
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(None),
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    // SAFETY: renegotiating the output type the MFT now offers.
                    unsafe {
                        let t = self.mft.GetOutputAvailableType(0, 0)?;
                        self.mft.SetOutputType(0, &t, 0)?;
                    }
                    self.sequence_header = sequence_header(&self.mft);
                    // An async MFT signals METransformHaveOutput again for the unit.
                    if self.events.is_some() {
                        return Ok(None);
                    }
                    continue;
                }
                Err(e) => return Err(format!("media foundation ProcessOutput: {e}").into()),
            }
            let sample = sample.ok_or("media foundation: ProcessOutput returned no sample")?;
            let mut au = Vec::new();
            // SAFETY: reading the sample's bytes while its contiguous buffer is locked.
            let pts = unsafe {
                let buf = sample.ConvertToContiguousBuffer()?;
                let mut src = std::ptr::null_mut();
                let mut len = 0u32;
                buf.Lock(&mut src, None, Some(&mut len))?;
                au.extend_from_slice(std::slice::from_raw_parts(src, len as usize));
                buf.Unlock()?;
                sample.GetSampleTime().ok().map(|t| t / 10)
            };
            if Codec::H264.is_keyframe(&au)
                && !crate::annexb_nals(&au).any(|n| n.first().is_some_and(|b| b & 0x1f == 7))
                && !self.sequence_header.is_empty()
            {
                au.splice(0..0, self.sequence_header.iter().copied());
            }
            return Ok(Some((au, pts)));
        }
    }

    /// Reads the next event of an async MFT, waiting until `deadline` (None: don't wait).
    /// Returns false when none came.
    fn next_event(&mut self, deadline: Option<Instant>) -> Res<bool> {
        let Some(events) = &self.events else { return Ok(false) };
        loop {
            // SAFETY: a non-blocking event read on the MFT's own event generator.
            match unsafe { events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                Ok(ev) => {
                    // SAFETY: reading the type and status of an event we own.
                    let (t, status) = unsafe { (ev.GetType()?, ev.GetStatus()?) };
                    if t == MEError.0 as u32 || status.is_err() {
                        return Err(
                            format!("media foundation: hardware MFT failed: {status:?}").into()
                        );
                    }
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

    /// Takes every access unit the async MFT has signalled into `pending`.
    fn drain_async(&mut self) -> Res<()> {
        while self.output_ready > 0 {
            self.output_ready -= 1;
            if let Some(unit) = self.take_output()? {
                self.pending.push_back(unit);
            }
        }
        Ok(())
    }

    fn encode_async(&mut self, sample: &IMFSample) -> Res<()> {
        let deadline = Instant::now() + ASYNC_WAIT;
        while self.next_event(None)? {}
        self.drain_async()?;
        while self.input_credit == 0 {
            if !self.next_event(Some(deadline))? {
                // Busy encoder: drop this picture as a skipped frame; a dead one fails.
                self.refused += 1;
                if self.refused >= MAX_REFUSED {
                    return Err(format!(
                        "media foundation: hardware MFT asked for no input in {MAX_REFUSED} frames"
                    )
                    .into());
                }
                return Ok(());
            }
            self.drain_async()?;
        }
        self.refused = 0;
        self.input_credit -= 1;
        // SAFETY: handing the MFT a sample it asked for (METransformNeedInput).
        unsafe { self.mft.ProcessInput(0, sample, 0) }?;
        while self.pending.is_empty() {
            if self.output_ready == 0 && !self.next_event(Some(deadline))? {
                break;
            }
            self.drain_async()?;
        }
        Ok(())
    }

    fn encode_sync(&mut self, sample: &IMFSample) -> Res<()> {
        // SAFETY: ProcessInput on a synchronous MFT; MF_E_NOTACCEPTING means drain first.
        match unsafe { self.mft.ProcessInput(0, sample, 0) } {
            Ok(()) => {}
            Err(e) if e.code() == MF_E_NOTACCEPTING => {
                while let Some(unit) = self.take_output()? {
                    self.pending.push_back(unit);
                }
                // SAFETY: as above, after the MFT's pending output was taken.
                unsafe { self.mft.ProcessInput(0, sample, 0) }?;
            }
            Err(e) => return Err(format!("media foundation ProcessInput: {e}").into()),
        }
        while let Some(unit) = self.take_output()? {
            self.pending.push_back(unit);
        }
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
        self.sharpen_on_still(pic);
        let sample = self.input_sample(pic, pts)?;
        if self.events.is_some() {
            self.encode_async(&sample)?;
        } else {
            self.encode_sync(&sample)?;
        }
        // One access unit per call; a backlog (an async MFT's late output) drains one by one.
        if let Some((au, au_pts)) = self.pending.pop_front() {
            *out = au;
            self.out_pts = au_pts;
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
            && unsafe { api.SetValue(&CODECAPI_AVEncCommonMeanBitRate, &variant_u32(kbps * 1000)) }
                .is_ok()
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
