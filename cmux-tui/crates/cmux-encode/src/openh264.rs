//! OpenH264 behind [`H264Encoder`] (plans/cmux-next/remote-desktop-c7.md
//! section 4). Two ways to get the library, never a third:
//! - `openh264-source`: compiled from source, for tests and the bench
//!   decoder only, never in a shipped binary (the license gate refuses it in
//!   app-linked crates);
//! - `openh264-runtime`: Cisco's prebuilt library, downloaded from Cisco on
//!   the user's machine at first use (Cisco's patent license covers only that
//!   binary, so it is never bundled in an app or an image) and loaded by
//!   [`load_verified`] after its SHA-256 matches [`CiscoBinary`] for the
//!   platform. Mac hosts encode with VideoToolbox instead.
//!
//! The encoder settings: baseline, bitrate rate control with frame skip,
//! infinite GOP, one reference, screen or camera usage.

use std::os::raw::{c_int, c_void};
#[cfg(feature = "openh264-runtime")]
use std::path::Path;

use openh264_sys2::*;

use crate::{EncCfg, H264Encoder, I420, Res};

/// The OpenH264 entry points in use.
pub struct OpenH264Api(DynamicAPI);

impl OpenH264Api {
    /// The library compiled from source (tests and the bench only).
    #[cfg(feature = "openh264-source")]
    pub fn from_source() -> Self {
        Self(DynamicAPI::from_source())
    }
}

/// A platform Cisco publishes OpenH264 for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Platform {
    LinuxX64,
    LinuxArm64,
    MacArm64,
    MacX64,
    WindowsX64,
    WindowsArm64,
}

impl Platform {
    pub const ALL: [Platform; 6] = [
        Platform::LinuxX64,
        Platform::LinuxArm64,
        Platform::MacArm64,
        Platform::MacX64,
        Platform::WindowsX64,
        Platform::WindowsArm64,
    ];

    /// The platform this binary runs on, if Cisco publishes one for it.
    pub fn current() -> Option<Self> {
        match (std::env::consts::OS, std::env::consts::ARCH) {
            ("linux", "x86_64") => Some(Self::LinuxX64),
            ("linux", "aarch64") => Some(Self::LinuxArm64),
            ("macos", "aarch64") => Some(Self::MacArm64),
            ("macos", "x86_64") => Some(Self::MacX64),
            ("windows", "x86_64") => Some(Self::WindowsX64),
            ("windows", "aarch64") => Some(Self::WindowsArm64),
            _ => None,
        }
    }
}

/// Where Cisco publishes OpenH264 2.6.0 for one platform and the SHA-256 of
/// the decompressed library. Cisco serves bzip2 files over plain HTTP; the
/// hash of the decompressed library is the integrity check. The hashes are
/// the openh264-sys2 0.9.8 list of Cisco 2.6.0 releases (the API version
/// this crate's headers match).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CiscoBinary {
    pub url: &'static str,
    /// The library's file name after decompression.
    pub file_name: &'static str,
    pub sha256: &'static str,
}

impl CiscoBinary {
    pub fn for_platform(platform: Platform) -> Self {
        let (file_name, sha256) = match platform {
            Platform::LinuxX64 => (
                "libopenh264-2.6.0-linux64.8.so",
                "2f0cde7c6a6abcf5cae76942894ea42897fa677bce4ed6c91a24dd1b041d5f04",
            ),
            Platform::LinuxArm64 => (
                "libopenh264-2.6.0-linux-arm64.8.so",
                "12e7b33623667cdab0e575170c147b1b36eadb77d0d2aa7ceb5afd3e58902140",
            ),
            Platform::MacArm64 => (
                "libopenh264-2.6.0-mac-arm64.dylib",
                "052e98bfcf7a9167d22f3bbb3f5988ef79065591f36af8b52924b22b13624551",
            ),
            Platform::MacX64 => (
                "libopenh264-2.6.0-mac-x64.dylib",
                "e3dc8bc01fe69363f61fd3c02fd27798537a585eadd38cd808f303d1ee505a19",
            ),
            Platform::WindowsX64 => (
                "openh264-2.6.0-win64.dll",
                "2076cb5675ec6c1a4c70e7a2a322552f547b6eeed649d6dfcd9e02a543b24691",
            ),
            Platform::WindowsArm64 => (
                "openh264-2.6.0-win-arm64.dll",
                "fb75103938f4f47d119b983e06334df41a803bc72fb5c46e3623f6fea5782732",
            ),
        };
        let url = match platform {
            Platform::LinuxX64 => {
                "http://ciscobinary.openh264.org/libopenh264-2.6.0-linux64.8.so.bz2"
            }
            Platform::LinuxArm64 => {
                "http://ciscobinary.openh264.org/libopenh264-2.6.0-linux-arm64.8.so.bz2"
            }
            Platform::MacArm64 => {
                "http://ciscobinary.openh264.org/libopenh264-2.6.0-mac-arm64.dylib.bz2"
            }
            Platform::MacX64 => {
                "http://ciscobinary.openh264.org/libopenh264-2.6.0-mac-x64.dylib.bz2"
            }
            Platform::WindowsX64 => "http://ciscobinary.openh264.org/openh264-2.6.0-win64.dll.bz2",
            Platform::WindowsArm64 => {
                "http://ciscobinary.openh264.org/openh264-2.6.0-win-arm64.dll.bz2"
            }
        };
        Self { url, file_name, sha256 }
    }
}

/// Why Cisco's library was not loaded.
#[derive(Debug)]
pub enum LoadError {
    /// The file could not be read.
    Io(std::io::Error),
    /// The file is not the pinned Cisco library for this platform.
    HashMismatch { expected: &'static str, actual: String },
    /// The library failed to load.
    Load(String),
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "cannot read the OpenH264 library: {e}"),
            Self::HashMismatch { expected, actual } => {
                write!(
                    f,
                    "the OpenH264 library is not Cisco's pinned build (sha256 {actual}, expected {expected})"
                )
            }
            Self::Load(e) => write!(f, "cannot load the OpenH264 library: {e}"),
        }
    }
}

impl std::error::Error for LoadError {}

/// Loads Cisco's library from `path` after checking that its SHA-256 is the
/// pinned one for `platform`. Nothing is loaded when the hash differs.
#[cfg(feature = "openh264-runtime")]
pub fn load_verified(path: impl AsRef<Path>, platform: Platform) -> Result<OpenH264Api, LoadError> {
    use sha2::Digest;
    let path = path.as_ref();
    let bytes = std::fs::read(path).map_err(LoadError::Io)?;
    let actual: String = sha2::Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
    let expected = CiscoBinary::for_platform(platform).sha256;
    if actual != expected {
        return Err(LoadError::HashMismatch { expected, actual });
    }
    DynamicAPI::from_blob_path(path).map(OpenH264Api).map_err(|e| LoadError::Load(e.to_string()))
}

pub struct OpenH264 {
    api: OpenH264Api,
    enc: *mut ISVCEncoder,
    info: Box<SFrameBSInfo>,
    kbps: u32,
    name: String,
}

// SAFETY: the encoder instance is used from one thread at a time (owned by the media loop).
unsafe impl Send for OpenH264 {}

fn ok(rc: c_int, what: &str) -> Res<()> {
    if rc == 0 { Ok(()) } else { Err(format!("openh264 {what} failed: {rc}").into()) }
}

impl OpenH264 {
    /// An encoder on `api` (from source in tests and the bench, Cisco's
    /// library loaded by [`load_verified`] otherwise).
    pub fn new(cfg: &EncCfg, api: OpenH264Api) -> Res<Self> {
        let mut enc: *mut ISVCEncoder = std::ptr::null_mut();
        // SAFETY: the API fills `enc` with a new encoder instance or fails.
        ok(unsafe { api.0.WelsCreateSVCEncoder(&mut enc) }, "create")?;
        if enc.is_null() {
            return Err("openh264 create returned null".into());
        }
        // SAFETY: plain version query.
        let v = unsafe { api.0.WelsGetCodecVersion() };
        let name = format!(
            "openh264 {}.{}.{} {} baseline rc=bitrate frameskip=on gop=inf",
            v.uMajor,
            v.uMinor,
            v.uRevision,
            if cfg.screen_content { "screen-realtime" } else { "camera-realtime" }
        );
        let this = Self { api, enc, info: Box::default(), kbps: cfg.kbps.max(100), name };
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
            uiTimeStamp: pts.max(0) / 1000,
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
            self.api.0.WelsDestroySVCEncoder(self.enc);
        }
    }
}
