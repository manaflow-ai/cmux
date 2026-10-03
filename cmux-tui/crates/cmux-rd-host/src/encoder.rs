//! The H.264 encoder behind one trait, so the codec is a build feature, not a code fork.
//! Default: openh264 (BSD) built from source. Optional: x264 (GPL) with the `x264` feature.

use crate::convert::I420;
use crate::Res;
use openh264_sys2::source::APILoader;
use openh264_sys2::*;
use std::os::raw::{c_int, c_void};

/// One in-process low-latency H.264 encoder producing Annex-B access units.
pub trait H264Encoder: Send {
    /// Encodes one picture into `out` (empty when the encoder skipped the frame).
    /// Returns true for an IDR.
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool>;
    /// Retargets the bitrate (congestion control); small changes may be ignored.
    fn set_bitrate(&mut self, kbps: u32);
    fn kbps(&self) -> u32;
    fn name(&self) -> String;
}

/// Encoder settings.
pub struct EncCfg<'a> {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub kbps: u32,
    pub threads: u16,
    /// `openh264` (default) or `x264` (needs the `x264` feature).
    pub codec: &'a str,
    /// openh264 usage: screen content (default; codes scrolling text with motion search
    /// at a small fraction of the camera mode's bitrate, but turns large changes into
    /// IDRs) or camera.
    pub screen_content: bool,
    /// x264 only.
    #[cfg_attr(not(feature = "x264"), allow(dead_code))]
    pub preset: &'a str,
    /// x264 only (`high` for hardware decoders, `baseline` for the Linux bench).
    #[cfg_attr(not(feature = "x264"), allow(dead_code))]
    pub profile: &'a str,
}

pub fn open(cfg: &EncCfg<'_>) -> Res<Box<dyn H264Encoder>> {
    match cfg.codec {
        "openh264" => Ok(Box::new(OpenH264::new(cfg)?)),
        #[cfg(feature = "x264")]
        "x264" => Ok(Box::new(crate::x264::X264::new(
            cfg.width,
            cfg.height,
            cfg.fps,
            cfg.kbps,
            cfg.threads,
            cfg.preset,
            cfg.profile,
        )?)),
        other => Err(format!("codec {other} not available in this build").into()),
    }
}

pub struct OpenH264 {
    enc: *mut ISVCEncoder,
    info: Box<SFrameBSInfo>,
    kbps: u32,
    name: String,
}

// SAFETY: the encoder instance is used from one thread at a time (owned by the media loop).
unsafe impl Send for OpenH264 {}

fn ok(rc: c_int, what: &str) -> Res<()> {
    if rc == 0 {
        Ok(())
    } else {
        Err(format!("openh264 {what} failed: {rc}").into())
    }
}

impl OpenH264 {
    pub fn new(cfg: &EncCfg<'_>) -> Res<Self> {
        let mut enc: *mut ISVCEncoder = std::ptr::null_mut();
        // SAFETY: the API fills `enc` with a new encoder instance or fails.
        ok(unsafe { APILoader::WelsCreateSVCEncoder(&mut enc) }, "create")?;
        if enc.is_null() {
            return Err("openh264 create returned null".into());
        }
        // SAFETY: plain version query.
        let v = unsafe { APILoader::WelsGetCodecVersion() };
        let name = format!(
            "openh264 {}.{}.{} {} baseline rc=bitrate frameskip=on gop=inf",
            v.uMajor,
            v.uMinor,
            v.uRevision,
            if cfg.screen_content { "screen-realtime" } else { "camera-realtime" }
        );
        let this = Self { enc, info: Box::default(), kbps: cfg.kbps.max(100), name };
        let vt = this.vtbl();
        let mut p = SEncParamExt::default();
        // SAFETY: vtable functions of a live encoder, called with valid pointers.
        unsafe { ok(vt.GetDefaultParams.ok_or("no GetDefaultParams")?(enc, &mut p), "defaults")? };
        let threads = cfg.threads.max(1);
        let bitrate = (this.kbps * 1000) as c_int;
        // Camera usage honors "no scene-change IDR"; screen usage forces one on large changes
        // but is the only mode that codes a text scroll cheaply (prototype: 73x less).
        p.iUsageType =
            if cfg.screen_content { SCREEN_CONTENT_REAL_TIME } else { CAMERA_VIDEO_REAL_TIME };
        p.iPicWidth = cfg.width as c_int;
        p.iPicHeight = cfg.height as c_int;
        p.fMaxFrameRate = cfg.fps as f32;
        p.iTemporalLayerNum = 1;
        p.iSpatialLayerNum = 1;
        p.iComplexityMode = LOW_COMPLEXITY;
        p.uiIntraPeriod = 0;
        p.iNumRefFrame = 1;
        p.eSpsPpsIdStrategy = CONSTANT_ID;
        p.bPrefixNalAddingCtrl = false;
        p.bEnableSSEI = false;
        p.iEntropyCodingModeFlag = 0;
        // Frame skipping lets the rate controller hold the target (measured: without it the
        // target overshot 6x); a skipped frame sends nothing and the next damage retries.
        p.bEnableFrameSkip = true;
        p.bEnableLongTermReference = false;
        p.iMultipleThreadIdc = threads;
        p.bUseLoadBalancing = false;
        p.iLoopFilterDisableIdc = 0;
        p.bEnableDenoise = false;
        p.bEnableBackgroundDetection = false;
        p.bEnableAdaptiveQuant = false;
        p.bEnableSceneChangeDetect = false;
        p.iRCMode = RC_BITRATE_MODE;
        p.iTargetBitrate = bitrate;
        p.iMaxBitrate = bitrate;
        let l = &mut p.sSpatialLayers[0];
        l.iVideoWidth = cfg.width as c_int;
        l.iVideoHeight = cfg.height as c_int;
        l.fFrameRate = cfg.fps as f32;
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
        // SAFETY: as above; option payloads are valid pointers for the call.
        unsafe {
            ok(vt.InitializeExt.ok_or("no InitializeExt")?(enc, &p), "initialize")?;
            let set = vt.SetOption.ok_or("no SetOption")?;
            ok(
                set(enc, ENCODER_OPTION_TRACE_LEVEL, (&mut trace as *mut c_int).cast::<c_void>()),
                "trace level",
            )?;
            ok(
                set(enc, ENCODER_OPTION_DATAFORMAT, (&mut fmt as *mut c_int).cast::<c_void>()),
                "data format",
            )?;
        }
        Ok(this)
    }

    fn vtbl(&self) -> &ISVCEncoderVtbl {
        // SAFETY: `enc` points at a live encoder whose first field is its vtable pointer.
        unsafe { &**self.enc }
    }
}

impl H264Encoder for OpenH264 {
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool> {
        out.clear();
        let vt = self.vtbl();
        let force = vt.ForceIntraFrame.ok_or("no ForceIntraFrame")?;
        let encode = vt.EncodeFrame.ok_or("no EncodeFrame")?;
        let src = SSourcePicture {
            iColorFormat: videoFormatI420 as c_int,
            iStride: [pic.width as c_int, (pic.width / 2) as c_int, (pic.width / 2) as c_int, 0],
            pData: [
                pic.y.as_ptr().cast_mut(),
                pic.u.as_ptr().cast_mut(),
                pic.v.as_ptr().cast_mut(),
                std::ptr::null_mut(),
            ],
            iPicWidth: pic.width as c_int,
            iPicHeight: (pic.y.len() / pic.width.max(1)) as c_int,
            uiTimeStamp: pts.saturating_mul(16),
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
        for layer in &info.sLayerInfo[..info.iLayerNum.clamp(0, 128) as usize] {
            let mut offset = 0usize;
            for n in 0..layer.iNalCount.max(0) as usize {
                // SAFETY: openh264 guarantees iNalCount lengths and a buffer covering their sum.
                let len = unsafe { *layer.pNalLengthInByte.add(n) }.max(0) as usize;
                // SAFETY: as above.
                let nal = unsafe { std::slice::from_raw_parts(layer.pBsBuf.add(offset), len) };
                out.extend_from_slice(nal);
                offset += len;
            }
        }
        Ok(info.eFrameType == videoFrameTypeIDR)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.max(100);
        if kbps.abs_diff(self.kbps) * 20 < self.kbps {
            return;
        }
        let set = match self.vtbl().SetOption {
            Some(f) => f,
            None => return,
        };
        let mut info = SBitrateInfo { iLayer: SPATIAL_LAYER_ALL, iBitrate: (kbps * 1000) as c_int };
        // SAFETY: a valid SBitrateInfo for the duration of each call on a live encoder.
        let rc = unsafe {
            set(
                self.enc,
                ENCODER_OPTION_MAX_BITRATE,
                (&mut info as *mut SBitrateInfo).cast::<c_void>(),
            );
            set(self.enc, ENCODER_OPTION_BITRATE, (&mut info as *mut SBitrateInfo).cast::<c_void>())
        };
        if rc == 0 {
            self.kbps = kbps;
        }
    }

    fn kbps(&self) -> u32 {
        self.kbps
    }

    fn name(&self) -> String {
        self.name.clone()
    }
}

impl Drop for OpenH264 {
    /// Uninitialize is safe on an encoder whose InitializeExt failed (openh264 checks its state).
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
