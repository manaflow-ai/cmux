//! In-process H.264 encoder (openh264 built from source), configured for low latency:
//! screen-content (or camera) usage, constrained baseline (no B-frames), no lookahead, infinite GOP,
//! IDR only on the first frame and on request, constant QP (or bitrate mode, no frame skip).

use crate::convert::I420;
use crate::Res;
use openh264_sys2::source::APILoader;
use openh264_sys2::*;
use std::os::raw::{c_int, c_void};

#[derive(Clone, Debug)]
pub struct EncCfg {
    pub width: u32,
    pub height: u32,
    pub max_fps: u32,
    /// Constant QP when Some; otherwise bitrate mode at `bitrate_kbps`.
    pub qp: Option<u8>,
    pub bitrate_kbps: u32,
    /// Encoder threads; > 1 uses one slice per thread.
    pub threads: u16,
    /// Screen-content mode. openh264 forces scene-change detection on in this mode, so a large
    /// change (full-screen motion) becomes an IDR; camera mode honors scene-change detection off.
    pub screen: bool,
    /// "openh264" or "x264" (x264 needs the `x264` feature).
    pub codec: String,
    /// x264 preset and profile (ignored by openh264).
    pub x264_preset: String,
    pub x264_profile: String,
}

/// One in-process H.264 encoder producing Annex-B access units.
pub trait VideoEncoder: Send {
    /// Encodes one picture into `out`. Returns true for an IDR access unit.
    fn encode(&mut self, pic: &I420, force_idr: bool, ts_ms: i64, out: &mut Vec<u8>) -> Res<bool>;
    fn name(&self) -> &str;
}

pub fn open(cfg: &EncCfg) -> Res<Box<dyn VideoEncoder>> {
    match cfg.codec.as_str() {
        "openh264" => Ok(Box::new(Encoder::new(cfg)?)),
        #[cfg(feature = "x264")]
        "x264" => Ok(Box::new(crate::x264::X264::new(cfg)?)),
        other => Err(format!("codec {other} not available in this build").into()),
    }
}

impl EncCfg {
    pub fn describe(&self) -> String {
        let rc = match self.qp {
            Some(q) => format!("rc=off qp={q}"),
            None => format!("rc=bitrate {}kbps skip=off", self.bitrate_kbps),
        };
        format!(
            "usage={} profile=baseline cavlc {rc} gop=inf idr=first+request scenecut={} \
             ref=1 slices={} threads={} complexity=low denoise=off deblock=on",
            if self.screen { "screen-realtime" } else { "camera-realtime" },
            if self.screen { "forced-on" } else { "off" },
            self.threads.max(1),
            self.threads.max(1)
        )
    }
}

pub struct Encoder {
    enc: *mut ISVCEncoder,
    info: Box<SFrameBSInfo>,
    pub name: String,
}

// SAFETY: the encoder instance is used from one thread at a time (owned by the capture loop).
unsafe impl Send for Encoder {}

fn ok(rc: c_int, what: &str) -> Res<()> {
    if rc == 0 { Ok(()) } else { Err(format!("openh264 {what} failed: {rc}").into()) }
}

pub fn version() -> String {
    // SAFETY: plain version query.
    let v = unsafe { APILoader::WelsGetCodecVersion() };
    format!("openh264 {}.{}.{}", v.uMajor, v.uMinor, v.uRevision)
}

impl Encoder {
    pub fn new(cfg: &EncCfg) -> Res<Self> {
        let mut enc: *mut ISVCEncoder = std::ptr::null_mut();
        // SAFETY: the API fills `enc` with a new encoder instance or fails.
        ok(unsafe { APILoader::WelsCreateSVCEncoder(&mut enc) }, "create")?;
        if enc.is_null() {
            return Err("openh264 create returned null".into());
        }
        let this = Self { enc, info: Box::default(), name: format!("{} ({})", version(), cfg.describe()) };
        let vt = this.vtbl();
        let mut p = SEncParamExt::default();
        // SAFETY: vtable functions of a live encoder, called with valid pointers.
        unsafe {
            ok(vt.GetDefaultParams.ok_or("no GetDefaultParams")?(enc, &mut p), "defaults")?;
        }
        let threads = cfg.threads.max(1);
        p.iUsageType = if cfg.screen { SCREEN_CONTENT_REAL_TIME } else { CAMERA_VIDEO_REAL_TIME };
        p.iPicWidth = cfg.width as c_int;
        p.iPicHeight = cfg.height as c_int;
        p.fMaxFrameRate = cfg.max_fps as f32;
        p.iTemporalLayerNum = 1;
        p.iSpatialLayerNum = 1;
        p.iComplexityMode = LOW_COMPLEXITY;
        p.uiIntraPeriod = 0;
        p.iNumRefFrame = 1;
        p.eSpsPpsIdStrategy = CONSTANT_ID;
        p.bPrefixNalAddingCtrl = false;
        p.bEnableSSEI = false;
        p.iEntropyCodingModeFlag = 0;
        p.bEnableFrameSkip = false;
        p.bEnableLongTermReference = false;
        p.iMultipleThreadIdc = threads;
        p.bUseLoadBalancing = false;
        p.iLoopFilterDisableIdc = 0;
        p.bEnableDenoise = false;
        p.bEnableBackgroundDetection = false;
        p.bEnableAdaptiveQuant = false;
        p.bEnableSceneChangeDetect = false;
        let bitrate = (cfg.bitrate_kbps.max(100) * 1000) as c_int;
        match cfg.qp {
            Some(q) => {
                p.iRCMode = RC_OFF_MODE;
                p.iMinQp = c_int::from(q);
                p.iMaxQp = c_int::from(q);
                p.sSpatialLayers[0].iDLayerQp = c_int::from(q);
            }
            None => {
                p.iRCMode = RC_BITRATE_MODE;
                p.iTargetBitrate = bitrate;
                p.iMaxBitrate = bitrate;
            }
        }
        let l = &mut p.sSpatialLayers[0];
        l.iVideoWidth = cfg.width as c_int;
        l.iVideoHeight = cfg.height as c_int;
        l.fFrameRate = cfg.max_fps as f32;
        l.iSpatialBitrate = bitrate;
        l.iMaxSpatialBitrate = bitrate;
        l.uiProfileIdc = PRO_BASELINE;
        l.uiLevelIdc = LEVEL_UNKNOWN;
        if threads > 1 {
            l.sSliceArgument.uiSliceMode = SM_FIXEDSLCNUM_SLICE;
            l.sSliceArgument.uiSliceNum = u32::from(threads);
        } else {
            l.sSliceArgument.uiSliceMode = SM_SINGLE_SLICE;
            l.sSliceArgument.uiSliceNum = 1;
        }
        let mut trace: c_int = WELS_LOG_QUIET as c_int;
        let mut fmt: c_int = videoFormatI420 as c_int;
        // SAFETY: as above; option payloads are valid c_int pointers.
        unsafe {
            ok(vt.InitializeExt.ok_or("no InitializeExt")?(enc, &p), "initialize")?;
            let set = vt.SetOption.ok_or("no SetOption")?;
            ok(set(enc, ENCODER_OPTION_TRACE_LEVEL, (&mut trace as *mut c_int).cast::<c_void>()), "trace level")?;
            ok(set(enc, ENCODER_OPTION_DATAFORMAT, (&mut fmt as *mut c_int).cast::<c_void>()), "data format")?;
        }
        Ok(this)
    }

    fn vtbl(&self) -> &ISVCEncoderVtbl {
        // SAFETY: `enc` points at a live encoder whose first field is its vtable pointer.
        unsafe { &**self.enc }
    }

    fn encode_au(&mut self, pic: &I420, force_idr: bool, ts_ms: i64, out: &mut Vec<u8>) -> Res<bool> {
        out.clear();
        let vt = self.vtbl();
        let force = vt.ForceIntraFrame.ok_or("no ForceIntraFrame")?;
        let encode = vt.EncodeFrame.ok_or("no EncodeFrame")?;
        let src = SSourcePicture {
            iColorFormat: videoFormatI420 as c_int,
            iStride: [pic.width as c_int, (pic.width / 2) as c_int, (pic.width / 2) as c_int, 0],
            pData: [pic.y.as_ptr().cast_mut(), pic.u.as_ptr().cast_mut(), pic.v.as_ptr().cast_mut(), std::ptr::null_mut()],
            iPicWidth: pic.width as c_int,
            iPicHeight: pic.height as c_int,
            uiTimeStamp: ts_ms,
            bPsnrY: false,
            bPsnrU: false,
            bPsnrV: false,
        };
        // SAFETY: the encoder reads the planes (kept alive by `pic`) and writes into self.info.
        unsafe {
            if force_idr {
                ok(force(self.enc, true), "force idr")?;
            }
            ok(encode(self.enc, &src, &mut *self.info), "encode")?;
        }
        let info = &*self.info;
        if info.eFrameType == videoFrameTypeSkip {
            return Ok(false);
        }
        for layer in &info.sLayerInfo[..info.iLayerNum.max(0) as usize] {
            let mut offset = 0usize;
            for n in 0..layer.iNalCount.max(0) as usize {
                // SAFETY: openh264 guarantees iNalCount lengths and a buffer covering their sum.
                let len = unsafe { *layer.pNalLengthInByte.add(n) } as usize;
                let nal = unsafe { std::slice::from_raw_parts(layer.pBsBuf.add(offset), len) };
                out.extend_from_slice(nal);
                offset += len;
            }
        }
        Ok(info.eFrameType == videoFrameTypeIDR)
    }
}

impl VideoEncoder for Encoder {
    fn encode(&mut self, pic: &I420, force_idr: bool, ts_ms: i64, out: &mut Vec<u8>) -> Res<bool> {
        self.encode_au(pic, force_idr, ts_ms, out)
    }

    fn name(&self) -> &str {
        &self.name
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        // SAFETY: uninitialize and destroy a live encoder exactly once.
        unsafe {
            if let Some(uninit) = self.vtbl().Uninitialize {
                uninit(self.enc);
            }
            APILoader::WelsDestroySVCEncoder(self.enc);
        }
    }
}
