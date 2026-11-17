//! OpenH264 behind [`H264Encoder`] (plans/cmux-next/remote-desktop-c7.md
//! section 4). Two ways to get the library, never a third:
//! - `openh264-source`: compiled from source, for tests and the bench
//!   decoder only, never in a shipped binary (the license gate refuses it in
//!   app-linked crates);
//! - `openh264-runtime`: Cisco's prebuilt library, downloaded from Cisco on
//!   the user's machine when the host is enabled (`cmux-rd openh264-install`,
//!   module `cisco`; Cisco's patent license covers only that
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
/// the decompressed library. Cisco serves the bzip2 files over HTTPS too
/// (certificate for openh264.org, checked by rustls with the webpki roots);
/// the hash of the decompressed library stays the integrity check. The hashes are
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
                "https://ciscobinary.openh264.org/libopenh264-2.6.0-linux64.8.so.bz2"
            }
            Platform::LinuxArm64 => {
                "https://ciscobinary.openh264.org/libopenh264-2.6.0-linux-arm64.8.so.bz2"
            }
            Platform::MacArm64 => {
                "https://ciscobinary.openh264.org/libopenh264-2.6.0-mac-arm64.dylib.bz2"
            }
            Platform::MacX64 => {
                "https://ciscobinary.openh264.org/libopenh264-2.6.0-mac-x64.dylib.bz2"
            }
            Platform::WindowsX64 => "https://ciscobinary.openh264.org/openh264-2.6.0-win64.dll.bz2",
            Platform::WindowsArm64 => {
                "https://ciscobinary.openh264.org/openh264-2.6.0-win-arm64.dll.bz2"
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
    cfg: EncCfg,
    opts: OpenH264Options,
    /// The instance codes with screen usage now (else camera usage).
    screen: bool,
    motion: MotionGuard,
}

/// Screen usage turns OpenH264's scene-change detection on whatever the settings say
/// (v2.6.0 ParamValidation), and with no long-term references every frame that moves 80 %
/// of its blocks is an IDR (DecideFrameType): full-screen motion was all IDRs, about
/// 4.7 fps on a Linux host. Camera usage honors "no scene-change IDR" but codes a text
/// scroll far worse. So screen content starts in screen usage; after an IDR the encoder
/// made on its own, a next picture that changed more than [`MOTION_CHANGE`] of its samples
/// moves it to camera usage before that picture is coded (the IDR the move costs replaces
/// the one screen usage would have made), and [`CALM_FRAMES_TO_SCREEN`] pictures in a row
/// that changed less than [`CALM_CHANGE`] move it back. A move rebuilds the encoder, so its
/// next frame is an IDR. One page flip or a scroll stays in screen usage.
pub const MOTION_CHANGE: f32 = 0.5;
/// The QP range screen usage codes in when the options name none. OpenH264's own screen range is
/// 26-35, and its screen rate control pins a P frame's base QP at the minimum
/// (WelRcPictureInitScc, v2.6.0: `WELS_CLIP3 (iBaseQp, iMinQp, iMinQp)`), so frame skipping was
/// its only way to hold the bitrate: after a share's first keyframe it dropped ~260 ms of frames
/// (the first key presses of every share waited 55-290 ms for a frame), and on full-screen
/// motion it settled near half the frame rate. A higher floor makes each frame cheaper, so the
/// buffer drains in a few frames and drops stay rare; the ceiling leaves the keyframe and scene
/// changes room to shrink further.
pub const SCREEN_MIN_QP: u8 = 30;
pub const SCREEN_MAX_QP: u8 = 42;
pub const CALM_CHANGE: f32 = 0.25;
pub const CALM_FRAMES_TO_SCREEN: u32 = 30;
/// Luma rows and columns between samples of the change check.
const SAMPLE_STEP: usize = 16;

/// The state behind the usage moves (see [`MOTION_CHANGE`]).
#[derive(Default)]
struct MotionGuard {
    /// The last coded frame was an IDR the encoder made on its own (screen usage).
    self_idr: bool,
    /// The instance has coded no frame yet (its first is an IDR).
    fresh: bool,
    /// Pictures in a row that changed little (camera usage).
    calm: u32,
    /// Every [`SAMPLE_STEP`]th luma sample of the previous picture.
    samples: Vec<u8>,
}

impl MotionGuard {
    /// The share of sampled luma that changed since the previous picture (1 for the first).
    fn changed(&mut self, pic: &I420) -> f32 {
        let rows = pic.y.chunks_exact(pic.width.max(1)).step_by(SAMPLE_STEP);
        let now: Vec<u8> = rows.flat_map(|row| row.iter().step_by(SAMPLE_STEP).copied()).collect();
        let changed = if now.len() == self.samples.len() && !now.is_empty() {
            let n = now.iter().zip(&self.samples).filter(|(a, b)| a.abs_diff(**b) > 2).count();
            n as f32 / now.len() as f32
        } else {
            1.0
        };
        self.samples = now;
        changed
    }
}

// SAFETY: the encoder instance is used from one thread at a time (owned by the media loop).
unsafe impl Send for OpenH264 {}

fn ok(rc: c_int, what: &str) -> Res<()> {
    if rc == 0 { Ok(()) } else { Err(format!("openh264 {what} failed: {rc}").into()) }
}

/// Settings past [`OpenH264::new`]'s, for measuring speed against sharpness. The default
/// is the shipped encoder. [`OpenH264Options::parse`] reads the bench's comma list
/// (`frameskip=0,threads=8,complexity=1,minqp=18,maxqp=40,aq=1,bgd=1`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenH264Options {
    pub frame_skip: bool,
    /// Worker threads and slices; `None` is the config's.
    pub threads: Option<u16>,
    /// Slices of each picture; `None` is one per thread.
    pub slices: Option<u16>,
    /// OpenH264 moves slice boundaries toward equal coding time per thread.
    pub load_balancing: bool,
    /// 0 low (the default), 1 medium, 2 high.
    pub complexity: u8,
    pub min_qp: Option<u8>,
    pub max_qp: Option<u8>,
    pub adaptive_quant: bool,
    pub background_detection: bool,
    /// How screen content is coded (camera content always codes in camera usage).
    pub usage: Usage,
    /// Long-term references (0 off, at most 4). In screen usage a scene change then
    /// codes a P-frame marked long-term instead of an IDR until all are taken.
    pub ltr: u8,
}

/// The usage OpenH264 codes screen content in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Usage {
    /// Screen usage throughout.
    Screen,
    /// Camera usage throughout.
    Camera,
    /// Screen usage, camera usage while most of the picture moves (see [`MOTION_CHANGE`]).
    Switch,
}

/// The shipped usage and long-term references for screen content.
pub const SHIPPED_USAGE: Usage = Usage::Switch;
pub const SHIPPED_LTR: u8 = 0;

impl Default for OpenH264Options {
    fn default() -> Self {
        Self {
            frame_skip: true,
            threads: None,
            slices: None,
            load_balancing: false,
            complexity: 0,
            min_qp: None,
            max_qp: None,
            adaptive_quant: false,
            background_detection: false,
            usage: SHIPPED_USAGE,
            ltr: SHIPPED_LTR,
        }
    }
}

impl OpenH264Options {
    /// Reads `key=value` pairs, comma separated, over the default.
    pub fn parse(s: &str) -> Res<Self> {
        let mut o = Self::default();
        for pair in s.split(',').map(str::trim).filter(|p| !p.is_empty()) {
            let (k, v) =
                pair.split_once('=').ok_or(format!("openh264 options: {pair} is not key=value"))?;
            let num = || v.parse::<u32>().map_err(|e| format!("openh264 options {k}: {e}"));
            match k {
                "frameskip" => o.frame_skip = num()? != 0,
                "threads" => o.threads = Some(num()?.clamp(1, 16) as u16),
                "slices" => o.slices = Some(num()?.clamp(1, 35) as u16),
                "lb" => o.load_balancing = num()? != 0,
                "complexity" => o.complexity = num()?.min(2) as u8,
                "minqp" => o.min_qp = Some(num()?.min(51) as u8),
                "maxqp" => o.max_qp = Some(num()?.min(51) as u8),
                "aq" => o.adaptive_quant = num()? != 0,
                "bgd" => o.background_detection = num()? != 0,
                "usage" => {
                    o.usage = match v {
                        "screen" => Usage::Screen,
                        "camera" => Usage::Camera,
                        "switch" => Usage::Switch,
                        _ => return Err(format!("openh264 options usage: {v}").into()),
                    }
                }
                "ltr" => o.ltr = num()?.min(4) as u8,
                _ => return Err(format!("openh264 options: unknown key {k}").into()),
            }
        }
        Ok(o)
    }

    /// The settings that differ from the default, for the encoder's name.
    fn describe(&self) -> String {
        let d = Self::default();
        let mut s = Vec::new();
        if self.threads.is_some() {
            s.push(format!("threads={}", self.threads.unwrap_or(1)));
        }
        if let Some(n) = self.slices {
            s.push(format!("slices={n}"));
        }
        if self.load_balancing {
            s.push("lb=on".into());
        }
        if self.complexity != d.complexity {
            s.push(format!("complexity={}", self.complexity));
        }
        if let Some(q) = self.min_qp {
            s.push(format!("minqp={q}"));
        }
        if let Some(q) = self.max_qp {
            s.push(format!("maxqp={q}"));
        }
        if self.adaptive_quant {
            s.push("aq=on".into());
        }
        if self.background_detection {
            s.push("bgd=on".into());
        }
        if self.usage != d.usage {
            s.push(format!("usage={:?}", self.usage).to_lowercase());
        }
        if self.ltr != d.ltr {
            s.push(format!("ltr={}", self.ltr));
        }
        s.join(" ")
    }
}

impl OpenH264 {
    /// An encoder on `api` (from source in tests and the bench, Cisco's
    /// library loaded by [`load_verified`] otherwise).
    pub fn new(cfg: &EncCfg, api: OpenH264Api) -> Res<Self> {
        Self::with_options(cfg, api, &OpenH264Options::default())
    }

    /// [`OpenH264::new`] with `opts` in place of the shipped settings.
    pub fn with_options(cfg: &EncCfg, api: OpenH264Api, opts: &OpenH264Options) -> Res<Self> {
        let mut this = Self {
            api,
            enc: std::ptr::null_mut(),
            info: Box::default(),
            kbps: cfg.kbps.max(100),
            name: String::new(),
            cfg: *cfg,
            opts: opts.clone(),
            screen: cfg.screen_content && opts.usage != Usage::Camera,
            motion: MotionGuard::default(),
        };
        this.rebuild(this.screen)?;
        Ok(this)
    }

    /// Replaces the encoder instance with a new one in screen or camera usage, at the
    /// current bitrate; its next frame is an IDR. On failure the old instance stays.
    fn rebuild(&mut self, screen: bool) -> Res<()> {
        let mut enc: *mut ISVCEncoder = std::ptr::null_mut();
        // SAFETY: the API fills `enc` with a new encoder instance or fails.
        ok(unsafe { self.api.0.WelsCreateSVCEncoder(&mut enc) }, "create")?;
        if enc.is_null() {
            return Err("openh264 create returned null".into());
        }
        // SAFETY: `enc` is the live instance created above.
        if let Err(e) = unsafe { init(enc, &self.cfg, &self.opts, self.kbps, screen) } {
            // SAFETY: uninitialize and destroy the new instance exactly once (openh264
            // checks its state, so a failed InitializeExt is safe to uninitialize).
            unsafe {
                if let Some(uninit) = (**enc).Uninitialize {
                    uninit(enc);
                }
                self.api.0.WelsDestroySVCEncoder(enc);
            }
            return Err(e);
        }
        self.release();
        self.enc = enc;
        self.screen = screen;
        self.motion.self_idr = false;
        self.motion.fresh = true;
        self.motion.calm = 0;
        // SAFETY: plain version query.
        let v = unsafe { self.api.0.WelsGetCodecVersion() };
        self.name = format!(
            "openh264 {}.{}.{} {} baseline rc=bitrate frameskip={} gop=inf {}",
            v.uMajor,
            v.uMinor,
            v.uRevision,
            match (self.cfg.screen_content, screen, self.opts.usage) {
                (true, true, _) => "screen-realtime",
                (true, false, Usage::Switch) => "screen-realtime(camera-for-motion)",
                _ => "camera-realtime",
            },
            if self.opts.frame_skip { "on" } else { "off" },
            self.opts.describe()
        )
        .trim_end()
        .to_owned();
        Ok(())
    }

    /// Uninitializes and destroys the current instance, if there is one.
    fn release(&mut self) {
        if self.enc.is_null() {
            return;
        }
        // SAFETY: uninitialize and destroy a live encoder exactly once; `enc` is cleared.
        unsafe {
            if let Some(uninit) = self.vtbl().Uninitialize {
                uninit(self.enc);
            }
            self.api.0.WelsDestroySVCEncoder(self.enc);
        }
        self.enc = std::ptr::null_mut();
    }

    /// Moves between screen and camera usage before `pic` is coded (see [`MOTION_CHANGE`]).
    fn pick_usage(&mut self, pic: &I420) {
        if !self.cfg.screen_content || self.opts.usage != Usage::Switch {
            return;
        }
        let changed = self.motion.changed(pic);
        if self.screen {
            if self.motion.self_idr && changed > MOTION_CHANGE {
                // A failed rebuild keeps screen usage; the next IDR tries again.
                let _ = self.rebuild(false);
            }
            return;
        }
        self.motion.calm = if changed < CALM_CHANGE { self.motion.calm + 1 } else { 0 };
        if self.motion.calm >= CALM_FRAMES_TO_SCREEN {
            let _ = self.rebuild(true);
        }
    }

    fn vtbl(&self) -> &ISVCEncoderVtbl {
        // SAFETY: `enc` points at a live encoder whose first field is its vtable pointer.
        unsafe { &**self.enc }
    }
}

/// Initializes the new instance `enc` with the shipped settings over `opts`.
///
/// # Safety
/// `enc` is a live, uninitialized encoder instance.
unsafe fn init(
    enc: *mut ISVCEncoder,
    cfg: &EncCfg,
    opts: &OpenH264Options,
    kbps: u32,
    screen: bool,
) -> Res<()> {
    // SAFETY: the caller's live instance; its first field is its vtable pointer.
    let vt = unsafe { &**enc };
    let mut p = SEncParamExt::default();
    // SAFETY: vtable functions of a live encoder, called with valid pointers.
    unsafe { ok(vt.GetDefaultParams.ok_or("no GetDefaultParams")?(enc, &mut p), "defaults")? };
    let threads = opts.threads.unwrap_or(cfg.threads).max(1);
    let bitrate = (kbps * 1000) as c_int;
    // Camera usage honors "no scene-change IDR"; screen usage forces one on large changes
    // but is the only mode that codes a text scroll cheaply (prototype: 73x less).
    p.iUsageType = if screen { SCREEN_CONTENT_REAL_TIME } else { CAMERA_VIDEO_REAL_TIME };
    p.iPicWidth = cfg.width as c_int;
    p.iPicHeight = cfg.height as c_int;
    p.fMaxFrameRate = cfg.fps as f32;
    p.iTemporalLayerNum = 1;
    p.iSpatialLayerNum = 1;
    p.iComplexityMode = match opts.complexity {
        0 => LOW_COMPLEXITY,
        1 => MEDIUM_COMPLEXITY,
        _ => HIGH_COMPLEXITY,
    };
    p.uiIntraPeriod = 0;
    // Screen usage keeps long-term references only on a link it calls lossless; ours
    // recovers a lost reference with a keyframe the viewer asks for.
    p.iNumRefFrame = 1 + c_int::from(opts.ltr);
    p.bIsLosslessLink = opts.ltr > 0;
    p.iLTRRefNum = c_int::from(opts.ltr);
    p.eSpsPpsIdStrategy = CONSTANT_ID;
    p.bPrefixNalAddingCtrl = false;
    p.bEnableSSEI = false;
    p.iEntropyCodingModeFlag = 0;
    // Frame skipping lets the rate controller hold the target (measured: without it the
    // target overshot 6x); a skipped frame sends nothing and the next damage retries.
    p.bEnableFrameSkip = opts.frame_skip;
    p.bEnableLongTermReference = opts.ltr > 0;
    p.iMultipleThreadIdc = threads;
    p.bUseLoadBalancing = opts.load_balancing;
    p.iLoopFilterDisableIdc = 0;
    p.bEnableDenoise = false;
    p.bEnableBackgroundDetection = opts.background_detection;
    p.bEnableAdaptiveQuant = opts.adaptive_quant;
    let (min_qp, max_qp) = if screen {
        (Some(opts.min_qp.unwrap_or(SCREEN_MIN_QP)), Some(opts.max_qp.unwrap_or(SCREEN_MAX_QP)))
    } else {
        (opts.min_qp, opts.max_qp)
    };
    if let Some(q) = min_qp {
        p.iMinQp = c_int::from(q);
    }
    if let Some(q) = max_qp {
        p.iMaxQp = c_int::from(q);
    }
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
    let slices = opts.slices.unwrap_or(threads).max(1);
    if slices > 1 {
        l.sSliceArgument.uiSliceMode = SM_FIXEDSLCNUM_SLICE;
        l.sSliceArgument.uiSliceNum = u32::from(slices);
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
    Ok(())
}

impl OpenH264 {
    /// One picture through the instance as it is (see [`H264Encoder::encode`]).
    fn encode_now(
        &mut self,
        pic: &I420,
        force_idr: bool,
        pts: i64,
        out: &mut Vec<u8>,
    ) -> Res<bool> {
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
        let idr = info.eFrameType == videoFrameTypeIDR;
        // A new instance's first IDR is the move's, not a scene change's.
        self.motion.self_idr = self.screen && idr && !force_idr && !self.motion.fresh;
        self.motion.fresh = false;
        Ok(idr)
    }
}

impl H264Encoder for OpenH264 {
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool> {
        self.pick_usage(pic);
        self.encode_now(pic, force_idr, pts, out)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        // The codec's level 5.2 maximum is 288 Mbit/s. Above it the max
        // setter silently lowers its cap before the target setter validates.
        let kbps = kbps.clamp(100, 288_000);
        let set = match self.vtbl().SetOption {
            Some(f) => f,
            None => return,
        };
        let get = match self.vtbl().GetOption {
            Some(f) => f,
            None => return,
        };
        let mut current = SBitrateInfo { iLayer: SPATIAL_LAYER_0, iBitrate: 0 };
        // SAFETY: a live encoder and a writable SBitrateInfo for this option.
        if unsafe {
            get(self.enc, ENCODER_OPTION_BITRATE, (&mut current as *mut SBitrateInfo).cast())
        } != 0
        {
            return;
        }
        if current.iBitrate == (self.kbps as f32 * 1000.0) as c_int
            && u64::from(kbps.abs_diff(self.kbps)) * 20 < u64::from(self.kbps)
        {
            return;
        }
        // ALL distributes the target through f32 even with one spatial layer.
        // Quantize both target and caps alike so rounding cannot exceed the cap.
        let requested = (kbps * 1000) as f32 as c_int;
        // ALL updates the aggregate maximum only. The active layer's maximum
        // otherwise stays at startup bitrate and rejects every upward retarget.
        // Setters mutate before validating: read the actual target, first make
        // both ceilings safe, then move the target and finally lower the caps.
        // This also repairs a partially applied prior update without trusting
        // the wrapper's cached bitrate.
        let ceiling = current.iBitrate.max(requested);
        for (option, layer, bitrate) in [
            (ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_0, ceiling),
            (ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_ALL, ceiling),
            (ENCODER_OPTION_BITRATE, SPATIAL_LAYER_ALL, requested),
            (ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_0, requested),
            (ENCODER_OPTION_MAX_BITRATE, SPATIAL_LAYER_ALL, requested),
        ] {
            let mut info = SBitrateInfo { iLayer: layer, iBitrate: bitrate };
            // SAFETY: each option accepts SBitrateInfo and the encoder is live.
            if unsafe { set(self.enc, option, (&mut info as *mut SBitrateInfo).cast()) } != 0 {
                return;
            }
        }
        self.kbps = kbps;
    }

    fn kbps(&self) -> u32 {
        self.kbps
    }

    fn name(&self) -> String {
        self.name.clone()
    }
}

impl Drop for OpenH264 {
    fn drop(&mut self) {
        self.release();
    }
}

#[cfg(all(test, feature = "openh264-source"))]
mod bitrate_tests {
    use super::*;

    fn read_rate(enc: &OpenH264, option: ENCODER_OPTION, layer: LAYER_NUM) -> i32 {
        let mut rate = SBitrateInfo { iLayer: layer, iBitrate: 0 };
        let get = enc.vtbl().GetOption.expect("GetOption");
        // SAFETY: a live encoder and a writable payload of the option's documented type.
        let status =
            unsafe { get(enc.enc, option, (&mut rate as *mut SBitrateInfo).cast::<c_void>()) };
        assert_eq!(status, 0);
        rate.iBitrate
    }

    #[test]
    fn bitrate_retarget_updates_the_active_layer_ceiling_in_both_directions() {
        let cfg = EncCfg {
            width: 640,
            height: 480,
            fps: 60,
            kbps: 8000,
            threads: 1,
            screen_content: true,
        };
        let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
        for kbps in [16_000, 4_000, 12_000, 200_003, 2_000] {
            enc.set_bitrate(kbps);
            for layer in [SPATIAL_LAYER_ALL, SPATIAL_LAYER_0] {
                assert_eq!(
                    read_rate(&enc, ENCODER_OPTION_BITRATE, layer),
                    (kbps * 1000) as f32 as i32
                );
                assert_eq!(
                    read_rate(&enc, ENCODER_OPTION_MAX_BITRATE, layer),
                    (kbps * 1000) as f32 as i32
                );
            }
            assert_eq!(enc.kbps(), kbps);
        }
    }
    #[test]
    fn bitrate_retarget_clamps_oversized_requests_without_corrupting_codec_state() {
        let cfg = EncCfg {
            width: 640,
            height: 480,
            fps: 60,
            kbps: 8000,
            threads: 1,
            screen_content: true,
        };
        let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
        for (requested, expected) in [(u32::MAX, 288_000), (8_000, 8_000), (0, 100)] {
            enc.set_bitrate(requested);
            assert_eq!(enc.kbps(), expected);
            for layer in [SPATIAL_LAYER_ALL, SPATIAL_LAYER_0] {
                assert_eq!(
                    read_rate(&enc, ENCODER_OPTION_BITRATE, layer),
                    (expected * 1000) as i32
                );
                assert_eq!(
                    read_rate(&enc, ENCODER_OPTION_MAX_BITRATE, layer),
                    (expected * 1000) as i32
                );
            }
        }
    }

    #[test]
    fn bitrate_retarget_repairs_a_partial_update_even_at_the_cached_target() {
        let cfg = EncCfg {
            width: 640,
            height: 480,
            fps: 60,
            kbps: 8000,
            threads: 1,
            screen_content: true,
        };
        let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
        let mut rate = SBitrateInfo { iLayer: SPATIAL_LAYER_ALL, iBitrate: 16_000_000 };
        let set = enc.vtbl().SetOption.expect("SetOption");
        // SAFETY: live codec and the documented bitrate payload. The old setter
        // mutates the target before failing validation against the layer cap.
        assert_ne!(
            unsafe {
                set(enc.enc, ENCODER_OPTION_BITRATE, (&mut rate as *mut SBitrateInfo).cast())
            },
            0
        );
        assert_eq!(enc.kbps(), 8000);
        assert_eq!(read_rate(&enc, ENCODER_OPTION_BITRATE, SPATIAL_LAYER_0), 16_000_000);
        enc.set_bitrate(8000);
        for layer in [SPATIAL_LAYER_ALL, SPATIAL_LAYER_0] {
            assert_eq!(read_rate(&enc, ENCODER_OPTION_BITRATE, layer), 8_000_000);
            assert_eq!(read_rate(&enc, ENCODER_OPTION_MAX_BITRATE, layer), 8_000_000);
        }
    }
}

/// OpenH264's decoder behind [`crate::VideoDecoder`], on the same entry points as the encoder:
/// Cisco's binary loaded at run time (`cmux-rd view`, the Linux viewer) or the source build
/// (tests). It decodes Constrained Baseline, the profile a host sends a viewer that offers
/// the `h264.baseline` cap.
pub struct OpenH264Decoder {
    api: OpenH264Api,
    dec: *mut ISVCDecoder,
}

// SAFETY: the decoder instance is used from one thread at a time (owned by the viewer's loop).
unsafe impl Send for OpenH264Decoder {}

impl OpenH264Decoder {
    pub fn new(api: OpenH264Api) -> Res<Self> {
        let mut dec: *mut ISVCDecoder = std::ptr::null_mut();
        // SAFETY: WelsCreateDecoder writes one decoder pointer to `dec`.
        ok(unsafe { api.0.WelsCreateDecoder(&mut dec) } as c_int, "WelsCreateDecoder")?;
        if dec.is_null() {
            return Err("openh264 WelsCreateDecoder returned no decoder".into());
        }
        let this = Self { api, dec };
        // SAFETY: a zeroed SDecodingParam is the library's "defaults" (its own tests do the same).
        let mut param: SDecodingParam = unsafe { std::mem::zeroed() };
        param.sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
        let vtbl = this.vtbl()?;
        let initialize = vtbl.Initialize.ok_or("openh264 decoder has no Initialize")?;
        // SAFETY: a live decoder and an initialized parameter block.
        ok(unsafe { initialize(this.dec, &param) } as c_int, "decoder Initialize")?;
        if let Some(set_option) = vtbl.SetOption {
            let mut quiet: c_int = WELS_LOG_QUIET as c_int;
            // Error concealment off: a frame with a hole is not shown; the viewer asks for
            // recovery instead of drawing a smeared picture.
            let mut conceal: c_int = ERROR_CON_DISABLE as c_int;
            // SAFETY: each option takes a pointer to an int.
            unsafe {
                set_option(this.dec, DECODER_OPTION_TRACE_LEVEL, (&mut quiet as *mut c_int).cast());
                set_option(
                    this.dec,
                    DECODER_OPTION_ERROR_CON_IDC,
                    (&mut conceal as *mut c_int).cast(),
                );
            }
        }
        Ok(this)
    }

    fn vtbl(&self) -> Res<&ISVCDecoderVtbl> {
        // SAFETY: a live decoder points at its vtable pointer, which points at the vtable.
        unsafe { (*self.dec).as_ref() }.ok_or_else(|| "openh264 decoder has no vtable".into())
    }
}

impl Drop for OpenH264Decoder {
    fn drop(&mut self) {
        // SAFETY: the decoder was created by this API and is destroyed once.
        unsafe {
            if let Ok(Some(uninitialize)) = self.vtbl().map(|v| v.Uninitialize) {
                uninitialize(self.dec);
            }
            self.api.0.WelsDestroyDecoder(self.dec);
        }
    }
}

impl crate::VideoDecoder for OpenH264Decoder {
    fn decode(&mut self, au: &[u8], out: &mut I420) -> Res<bool> {
        let decode =
            self.vtbl()?.DecodeFrameNoDelay.ok_or("openh264 decoder has no DecodeFrameNoDelay")?;
        let mut planes = [std::ptr::null_mut::<u8>(); 3];
        // SAFETY: zeroed SBufferInfo is the empty answer the decoder fills.
        let mut info: SBufferInfo = unsafe { std::mem::zeroed() };
        // SAFETY: `au` stays alive for the call; `planes` and `info` are ours to fill.
        let state = unsafe {
            decode(self.dec, au.as_ptr(), au.len() as c_int, planes.as_mut_ptr(), &mut info)
        };
        if state != 0 {
            return Err(format!("openh264 decode failed: state {state:#x}").into());
        }
        if info.iBufferStatus != 1 {
            return Ok(false);
        }
        // SAFETY: with iBufferStatus 1 the system buffer describes the three planes.
        let sys = unsafe { info.UsrData.sSystemBuffer };
        let (w, h) = (sys.iWidth.max(0) as usize, sys.iHeight.max(0) as usize);
        let (ys, cs) = (sys.iStride[0].max(0) as usize, sys.iStride[1].max(0) as usize);
        if w == 0 || h == 0 || planes.iter().any(|p| p.is_null()) {
            return Ok(false);
        }
        if out.width != w || out.y.len() != w * h {
            *out = I420::new(w, h);
        }
        let (cw, ch) = (w / 2, h / 2);
        for (i, (dst, pw, ph, stride)) in
            [(&mut out.y, w, h, ys), (&mut out.u, cw, ch, cs), (&mut out.v, cw, ch, cs)]
                .into_iter()
                .enumerate()
        {
            for row in 0..ph {
                // SAFETY: OpenH264's plane `i` covers `stride * ph` bytes until the next call.
                let src = unsafe { std::slice::from_raw_parts(planes[i].add(row * stride), pw) };
                dst[row * pw..(row + 1) * pw].copy_from_slice(src);
            }
        }
        Ok(true)
    }

    fn codec(&self) -> crate::Codec {
        crate::Codec::H264
    }

    fn name(&self) -> String {
        "openh264 decoder".into()
    }
}

#[cfg(all(test, feature = "openh264-source"))]
mod keyframe_skip_tests {
    use super::*;

    /// A detailed 1280x720 picture (blocks of flat luma with fine stripes): a keyframe of it
    /// costs far more than a frame interval of the start rate, as a real desktop does.
    fn desktop(w: usize, h: usize) -> I420 {
        let mut pic = I420::new(w, h);
        let mut seed = 0x9e37_79b9u32;
        for by in (0..h).step_by(8) {
            for bx in (0..w).step_by(8) {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let base = 32 + (seed >> 24) as u8 % 192;
                for y in by..(by + 8).min(h) {
                    for x in bx..(bx + 8).min(w) {
                        pic.y[y * w + x] = base.wrapping_add(((x ^ y) & 3) as u8 * 6);
                    }
                }
            }
        }
        pic
    }

    /// The share's first keyframe must not starve the frames after it: a key press after it
    /// has to code within a few frames, not wait for OpenH264's buffer to drain (it used to
    /// drop ~260 ms of frames after a start keyframe at 8 Mbit/s). Rate control may still drop
    /// a frame now and then; no run of dropped frames may exceed LONGEST_GAP (~83 ms).
    #[test]
    fn frames_after_a_screen_keyframe_are_not_skipped() {
        let (w, h) = (1280usize, 720usize);
        let cfg = EncCfg {
            width: w as u32,
            height: h as u32,
            fps: 60,
            kbps: 8000,
            threads: 1,
            screen_content: true,
        };
        let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
        let mut pic = desktop(w, h);
        let mut au = Vec::new();
        let mut sizes = Vec::new();
        for frame in 0..61i64 {
            // A typed character: a small marker that changes every frame.
            for y in 0..32 {
                for x in 0..64 {
                    pic.y[y * w + x] = if (frame as usize + x / 8) % 2 == 0 { 30 } else { 220 };
                }
            }
            // `encode` answers whether the frame is an IDR; a dropped frame is an empty access unit.
            enc.encode(&pic, frame == 0, frame * 16_667, &mut au).expect("encode");
            sizes.push(au.len());
        }
        const LONGEST_GAP: usize = 5;
        let longest = sizes[1..].split(|&n| n > 0).map(<[usize]>::len).max().unwrap_or(0);
        assert!(sizes[0] > 0, "no keyframe: {sizes:?}");
        assert!(
            longest <= LONGEST_GAP,
            "{longest} frames in a row dropped after the keyframe ({} KB): {sizes:?}",
            sizes[0] / 1024
        );
        assert_eq!(enc.kbps(), 8000, "the rate goes back after the keyframe");
    }
}

#[cfg(all(test, feature = "openh264-source"))]
mod decoder_tests {
    use super::*;
    use crate::{VideoDecoder, VideoEncoder};

    /// The encoder's own stream decodes back to its size, and the picture is close to the source.
    #[test]
    fn decodes_what_the_encoder_makes() {
        let (w, h) = (64usize, 48usize);
        let cfg = EncCfg {
            width: w as u32,
            height: h as u32,
            fps: 30,
            kbps: 2000,
            threads: 1,
            screen_content: true,
        };
        let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
        let mut dec = OpenH264Decoder::new(OpenH264Api::from_source()).expect("decoder");
        let mut src = I420::new(w, h);
        src.y.iter_mut().enumerate().for_each(|(i, p)| *p = 16 + (i % 200) as u8);
        let mut out = I420::new(2, 2);
        let mut decoded = 0;
        let mut au = Vec::new();
        for frame in 0..5 {
            au.clear();
            if !enc.encode(&src, frame == 0, frame, &mut au).expect("encode") || au.is_empty() {
                continue;
            }
            if dec.decode(&au, &mut out).expect("decode") {
                decoded += 1;
            }
        }
        assert!(decoded > 0, "no picture came out");
        assert_eq!((out.width, out.y.len()), (w, w * h));
        let err: u64 = out.y.iter().zip(&src.y).map(|(a, b)| u64::from(a.abs_diff(*b))).sum();
        assert!(err / (w * h) as u64 <= 8, "mean luma error {}", err / (w * h) as u64);
    }
}
