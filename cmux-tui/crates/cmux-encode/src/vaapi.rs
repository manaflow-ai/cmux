//! H.264 on the GPU through VAAPI (Intel and AMD on Linux), behind [`H264Encoder`].
//!
//! libva is opened at run time with `dlopen` (module `dynlib`), like Cisco's OpenH264: a
//! binary links nothing of it, and a machine without a GPU, without libva or without an H.264
//! encode entry point fails [`Vaapi::new`] with the reason, so the host falls back to software.
//! The patent license for the bitstream comes with the GPU's encoder, as with VideoToolbox and
//! Media Foundation.
//!
//! Settings, for latency first (plans: cmuxterm-hq docs/design/screen-share-under-100ms.md):
//! - I and P frames only (`ip_period` 1, no B-frames), one reference: each picture leaves the
//!   encoder in the call that gave it, and the stream's VUI says no frame waits for reordering
//!   (`max_num_reorder_frames` 0, `max_dec_frame_buffering` 1), so a decoder shows it at once;
//! - an infinite GOP: an IDR only for the first frame and when the caller forces one;
//! - VBR capped at the target (CBR when the driver has no VBR) with a 250 ms HRD buffer, so a
//!   still screen costs almost nothing and no frame is larger than a quarter second at the rate;
//! - the low-power entry point (the fixed-function encoder) when the driver has it;
//! - High profile, or Constrained Baseline when the caller asks for baseline (software decoders
//!   such as OpenH264's take only that).
//!
//! The SPS and PPS are written here and handed to the driver as packed headers, so every driver
//! emits the same VUI; a driver without packed headers writes its own, and when its IDR carries
//! none the encoder puts these in front.

use std::ffi::{CStr, c_int, c_uint, c_void};
use std::fs::File;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

use crate::{EncCfg, H264Encoder, I420, Res};

mod ffi;
mod headers;

pub use ffi::*;
#[cfg(test)]
use headers::{BitWriter, nal};

/// H.264 slice_type as VAAPI takes it.
const SLICE_P: u8 = 0;
const SLICE_I: u8 = 2;
/// frame_num is 16 bits (log2_max_frame_num_minus4 = 12).
const LOG2_MAX_FRAME_NUM_MINUS4: u32 = 12;

/// The DRM render nodes to try, in order.
pub fn render_nodes() -> Vec<PathBuf> {
    let mut nodes: Vec<PathBuf> = std::fs::read_dir("/dev/dri")
        .map(|dir| {
            dir.filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| {
                    p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("renderD"))
                })
                .collect()
        })
        .unwrap_or_default();
    nodes.sort();
    nodes
}

/// What the probe picked on one device, for the host's log and the encoder's name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Probe {
    pub device: PathBuf,
    pub vendor: String,
    pub profile: i32,
    pub entrypoint: i32,
    pub rate_control: u32,
    /// The driver takes our SPS and PPS (else it writes its own).
    pub packed_headers: bool,
}

impl Probe {
    fn profile_name(&self) -> &'static str {
        match self.profile {
            VA_PROFILE_H264_HIGH => "high",
            VA_PROFILE_H264_MAIN => "main",
            _ => "constrained-baseline",
        }
    }
}

impl std::fmt::Display for Probe {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} {} {} {} packed-headers={} ({})",
            self.device.display(),
            self.profile_name(),
            if self.entrypoint == VA_ENTRYPOINT_ENC_SLICE_LP { "low-power" } else { "full" },
            if self.rate_control == VA_RC_VBR { "vbr" } else { "cbr" },
            self.packed_headers,
            self.vendor,
        )
    }
}

/// An initialized VADisplay on one render node; terminated on drop.
struct Display {
    api: &'static LibVa,
    dpy: VADisplay,
    _node: File,
}

impl Display {
    fn open(api: &'static LibVa, node: &Path) -> Result<Self, String> {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(node)
            .map_err(|e| format!("{}: {e}", node.display()))?;
        // SAFETY: a live descriptor, kept open as long as the display (`_node`).
        let dpy = unsafe { (api.get_display_drm)(file.as_raw_fd()) };
        if dpy.is_null() {
            return Err(format!("{}: vaGetDisplayDRM returned no display", node.display()));
        }
        if let Some(set) = api.set_info_callback {
            // SAFETY: a valid display; a NULL callback turns the info messages off.
            unsafe { set(dpy, None, std::ptr::null_mut()) };
        }
        let (mut major, mut minor) = (0, 0);
        // SAFETY: a valid display and two writable ints.
        let status = unsafe { (api.initialize)(dpy, &mut major, &mut minor) };
        if let Err(e) = api.check(status, "vaInitialize") {
            // SAFETY: the display came from vaGetDisplayDRM; terminate releases it.
            unsafe { (api.terminate)(dpy) };
            return Err(format!("{}: {e}", node.display()));
        }
        Ok(Self { api, dpy, _node: file })
    }

    fn vendor(&self) -> String {
        // SAFETY: an initialized display; the string is owned by libva.
        let text = unsafe { (self.api.query_vendor_string)(self.dpy) };
        if text.is_null() {
            return String::new();
        }
        // SAFETY: non-NULL, NUL-terminated.
        unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned()
    }

    /// The best H.264 encode profile, entry point and settings this device has.
    fn choose(&self, node: &Path, baseline: bool) -> Result<Probe, String> {
        let api = self.api;
        // SAFETY: an initialized display.
        let max = unsafe { (api.max_num_profiles)(self.dpy) }.max(0) as usize;
        let mut profiles = vec![0i32; max.max(1)];
        let mut n = 0;
        // SAFETY: room for vaMaxNumProfiles entries.
        api.check(
            unsafe { (api.query_config_profiles)(self.dpy, profiles.as_mut_ptr(), &mut n) },
            "vaQueryConfigProfiles",
        )?;
        profiles.truncate(n.max(0) as usize);
        let wanted: &[i32] = if baseline {
            &[VA_PROFILE_H264_CONSTRAINED_BASELINE]
        } else {
            &[VA_PROFILE_H264_HIGH, VA_PROFILE_H264_MAIN, VA_PROFILE_H264_CONSTRAINED_BASELINE]
        };
        // SAFETY: an initialized display.
        let max_ep = unsafe { (api.max_num_entrypoints)(self.dpy) }.max(0) as usize;
        for &profile in wanted.iter().filter(|p| profiles.contains(p)) {
            let mut eps = vec![0i32; max_ep.max(1)];
            let mut n = 0;
            // SAFETY: room for vaMaxNumEntrypoints entries.
            let status = unsafe {
                (api.query_config_entrypoints)(self.dpy, profile, eps.as_mut_ptr(), &mut n)
            };
            if status != VA_STATUS_SUCCESS {
                continue;
            }
            eps.truncate(n.max(0) as usize);
            let Some(&entrypoint) = [VA_ENTRYPOINT_ENC_SLICE_LP, VA_ENTRYPOINT_ENC_SLICE]
                .iter()
                .find(|e| eps.contains(e))
            else {
                continue;
            };
            let mut attribs = [
                VAConfigAttrib { kind: VA_CONFIG_ATTRIB_RT_FORMAT, value: 0 },
                VAConfigAttrib { kind: VA_CONFIG_ATTRIB_RATE_CONTROL, value: 0 },
                VAConfigAttrib { kind: VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS, value: 0 },
            ];
            // SAFETY: three attributes to fill.
            api.check(
                unsafe {
                    (api.get_config_attributes)(
                        self.dpy,
                        profile,
                        entrypoint,
                        attribs.as_mut_ptr(),
                        attribs.len() as c_int,
                    )
                },
                "vaGetConfigAttributes",
            )?;
            let supported = |a: &VAConfigAttrib| a.value & VA_ATTRIB_NOT_SUPPORTED == 0;
            if !supported(&attribs[0]) || attribs[0].value & VA_RT_FORMAT_YUV420 == 0 {
                continue;
            }
            let rc = attribs[1].value;
            let rate_control = if !supported(&attribs[1]) {
                continue;
            } else if rc & VA_RC_VBR != 0 {
                VA_RC_VBR
            } else if rc & VA_RC_CBR != 0 {
                VA_RC_CBR
            } else {
                continue;
            };
            let packed = VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE;
            let packed_headers = supported(&attribs[2]) && attribs[2].value & packed == packed;
            return Ok(Probe {
                device: node.to_path_buf(),
                vendor: self.vendor(),
                profile,
                entrypoint,
                rate_control,
                packed_headers,
            });
        }
        Err(format!(
            "{}: no H.264 {}encode entry point with VBR or CBR ({})",
            node.display(),
            if baseline { "constrained-baseline " } else { "" },
            self.vendor()
        ))
    }
}

impl Drop for Display {
    fn drop(&mut self) {
        // SAFETY: an initialized display, used by nothing after this.
        unsafe { (self.api.terminate)(self.dpy) };
    }
}

/// How a picture gets onto the input surface.
enum Upload {
    /// The surface maps directly (vaDeriveImage).
    Derive,
    /// A separate NV12 image, copied in with vaPutImage.
    Put(VAImage),
}

/// The VAAPI H.264 encoder (module docs).
pub struct Vaapi {
    api: &'static LibVa,
    config: VAId,
    context: VAId,
    input: VAId,
    recon: [VAId; 2],
    coded: VAId,
    upload: Upload,
    probe: Probe,
    width: u32,
    height: u32,
    fps: u32,
    kbps: u32,
    /// The bitrate the driver's rate control has (sent with the next frame when it differs).
    applied_kbps: Option<u32>,
    sps: Vec<u8>,
    pps: Vec<u8>,
    /// Frames since the last IDR; `None` until the first frame (which is an IDR).
    since_idr: Option<u32>,
    idr_pic_id: u16,
    /// Which of `recon` the next frame reconstructs into (false: the first; the other holds
    /// its reference).
    cur: bool,
    // Declared last: dropped after `Drop for Vaapi` destroyed everything made on it.
    display: Display,
}

// SAFETY: a VADisplay and the ids made on it are used by one thread at a time (the encoder is
// moved, never shared); libva allows a display to be used from any thread.
unsafe impl Send for Vaapi {}

impl Vaapi {
    /// Opens the first render node whose driver encodes H.264 (module docs). `baseline` asks
    /// for Constrained Baseline. Errors name each device tried and why it was refused.
    pub fn new(cfg: &EncCfg, baseline: bool) -> Res<Self> {
        let api = LibVa::system()?;
        let nodes = render_nodes();
        if nodes.is_empty() {
            return Err("no GPU render node in /dev/dri".into());
        }
        Self::open_on(api, &nodes, cfg, baseline)
    }

    /// [`Vaapi::new`] with a given libva and device list (tests pass stand-ins).
    pub fn open_on(
        api: &'static LibVa,
        nodes: &[PathBuf],
        cfg: &EncCfg,
        baseline: bool,
    ) -> Res<Self> {
        let mut why = Vec::new();
        for node in nodes {
            let opened = Display::open(api, node)
                .and_then(|d| Self::with_display(d, node, cfg, baseline))
                .and_then(|mut enc| enc.self_test().map(|()| enc));
            match opened {
                Ok(enc) => return Ok(enc),
                Err(e) => why.push(e),
            }
        }
        Err(why.join("; ").into())
    }

    fn with_display(
        display: Display,
        node: &Path,
        cfg: &EncCfg,
        baseline: bool,
    ) -> Result<Self, String> {
        if cfg.width % 2 == 1 || cfg.height % 2 == 1 || cfg.width < 16 || cfg.height < 16 {
            return Err(format!(
                "{}x{}: VAAPI needs an even size of at least 16x16",
                cfg.width, cfg.height
            ));
        }
        let probe = display.choose(node, baseline)?;
        let api = display.api;
        let dpy = display.dpy;
        let mut enc = Vaapi {
            api,
            config: VA_INVALID_ID,
            context: VA_INVALID_ID,
            input: VA_INVALID_ID,
            recon: [VA_INVALID_ID; 2],
            coded: VA_INVALID_ID,
            upload: Upload::Derive,
            sps: Vec::new(),
            pps: Vec::new(),
            width: cfg.width,
            height: cfg.height,
            fps: cfg.fps.clamp(1, 240),
            kbps: cfg.kbps.clamp(100, 288_000),
            applied_kbps: None,
            since_idr: None,
            idr_pic_id: 0,
            cur: false,
            probe,
            display,
        };
        let mut attribs = vec![
            VAConfigAttrib { kind: VA_CONFIG_ATTRIB_RT_FORMAT, value: VA_RT_FORMAT_YUV420 },
            VAConfigAttrib { kind: VA_CONFIG_ATTRIB_RATE_CONTROL, value: enc.probe.rate_control },
        ];
        if enc.probe.packed_headers {
            attribs.push(VAConfigAttrib {
                kind: VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS,
                value: VA_ENC_PACKED_HEADER_SEQUENCE | VA_ENC_PACKED_HEADER_PICTURE,
            });
        }
        // SAFETY: an initialized display, a filled attribute list, one id to write.
        api.check(
            unsafe {
                (api.create_config)(
                    dpy,
                    enc.probe.profile,
                    enc.probe.entrypoint,
                    attribs.as_mut_ptr(),
                    attribs.len() as c_int,
                    &mut enc.config,
                )
            },
            "vaCreateConfig",
        )?;
        let mut surfaces = [VA_INVALID_ID; 3];
        // SAFETY: room for three ids; no surface attributes.
        api.check(
            unsafe {
                (api.create_surfaces)(
                    dpy,
                    VA_RT_FORMAT_YUV420,
                    cfg.width,
                    cfg.height,
                    surfaces.as_mut_ptr(),
                    3,
                    std::ptr::null_mut(),
                    0,
                )
            },
            "vaCreateSurfaces",
        )?;
        enc.input = surfaces[0];
        enc.recon = [surfaces[1], surfaces[2]];
        // SAFETY: the config and the three surfaces above, one id to write.
        api.check(
            unsafe {
                (api.create_context)(
                    dpy,
                    enc.config,
                    cfg.width as c_int,
                    cfg.height as c_int,
                    VA_PROGRESSIVE,
                    surfaces.as_mut_ptr(),
                    3,
                    &mut enc.context,
                )
            },
            "vaCreateContext",
        )?;
        // A coded frame is never larger than the raw picture (384 bytes per macroblock) plus headers.
        let coded_size = enc.mbs_wide() * enc.mbs_high() * 384 + 64 * 1024;
        // SAFETY: a coded buffer with no initial data, one id to write.
        api.check(
            unsafe {
                (api.create_buffer)(
                    dpy,
                    enc.context,
                    VA_ENC_CODED_BUFFER_TYPE,
                    coded_size,
                    1,
                    std::ptr::null_mut(),
                    &mut enc.coded,
                )
            },
            "vaCreateBuffer(coded)",
        )?;
        enc.upload = enc.choose_upload()?;
        enc.sps = enc.write_sps();
        enc.pps = enc.write_pps();
        Ok(enc)
    }

    /// The probe's last step: two gray frames must come back as an IDR with SPS and PPS, then a
    /// P slice. A driver that takes the settings but cannot encode with them fails here, at
    /// open, so the host falls back to software instead of sending a broken stream. The next
    /// frame is an IDR again and gets the rate control anew.
    fn self_test(&mut self) -> Result<(), String> {
        let pic = I420::new(self.width as usize, self.height as usize);
        let mut au = Vec::new();
        let nal_types = |au: &[u8]| {
            crate::annexb_nals(au).filter_map(|n| n.first().map(|b| b & 0x1f)).collect::<Vec<_>>()
        };
        let idr = self.encode_frame(&pic, true, &mut au)?;
        let types = nal_types(&au);
        if !idr || ![7, 8, 5].iter().all(|t| types.contains(t)) {
            return Err(format!(
                "self-test: the first frame's NAL types are {types:?}, not SPS, PPS, IDR"
            ));
        }
        let idr = self.encode_frame(&pic, false, &mut au)?;
        let types = nal_types(&au);
        if idr || !types.contains(&1) {
            return Err(format!(
                "self-test: the second frame's NAL types are {types:?}, not a P slice"
            ));
        }
        self.since_idr = None;
        self.applied_kbps = None;
        Ok(())
    }

    /// What the probe picked (device, profile, entry point, rate control, driver).
    pub fn probe(&self) -> &Probe {
        &self.probe
    }

    fn dpy(&self) -> VADisplay {
        self.display.dpy
    }

    fn mbs_wide(&self) -> u32 {
        self.width.div_ceil(16)
    }

    fn mbs_high(&self) -> u32 {
        self.height.div_ceil(16)
    }

    /// The surface the next frame reconstructs into, or (`reference`) the one holding the
    /// frame before it.
    fn recon(&self, reference: bool) -> VAId {
        let [first, second] = self.recon;
        if self.cur == reference { first } else { second }
    }

    fn high(&self) -> bool {
        self.probe.profile == VA_PROFILE_H264_HIGH
    }

    fn cabac(&self) -> bool {
        self.probe.profile != VA_PROFILE_H264_CONSTRAINED_BASELINE
    }

    /// vaDeriveImage when the input surface maps directly, else an NV12 image and vaPutImage.
    fn choose_upload(&self) -> Result<Upload, String> {
        let mut image = VAImage::default();
        // SAFETY: a live surface and an image struct to fill.
        if unsafe { (self.api.derive_image)(self.dpy(), self.input, &mut image) }
            == VA_STATUS_SUCCESS
        {
            // SAFETY: the image vaDeriveImage just made.
            unsafe { (self.api.destroy_image)(self.dpy(), image.image_id) };
            if image.format.fourcc == VA_FOURCC_NV12 {
                return Ok(Upload::Derive);
            }
        }
        let mut format =
            VAImageFormat { fourcc: VA_FOURCC_NV12, bits_per_pixel: 12, ..Default::default() };
        let mut image = VAImage::default();
        // SAFETY: a format and an image struct to fill.
        self.api.check(
            unsafe {
                (self.api.create_image)(
                    self.dpy(),
                    &mut format,
                    self.width as c_int,
                    self.height as c_int,
                    &mut image,
                )
            },
            "vaCreateImage(NV12)",
        )?;
        Ok(Upload::Put(image))
    }

    /// Copies `pic` (I420) into the input surface as NV12.
    fn upload(&mut self, pic: &I420) -> Result<(), String> {
        let api = self.api;
        let dpy = self.dpy();
        let image = match &self.upload {
            Upload::Put(image) => *image,
            Upload::Derive => {
                let mut image = VAImage::default();
                // SAFETY: a live surface and an image struct to fill.
                api.check(
                    unsafe { (api.derive_image)(dpy, self.input, &mut image) },
                    "vaDeriveImage",
                )?;
                image
            }
        };
        let result = self.write_nv12(pic, &image);
        match self.upload {
            Upload::Derive => {
                // SAFETY: the image derived above.
                unsafe { (api.destroy_image)(dpy, image.image_id) };
            }
            Upload::Put(_) => {
                result.as_ref().map_err(Clone::clone)?;
                let (w, h) = (self.width, self.height);
                // SAFETY: a live surface and image of this size.
                api.check(
                    unsafe {
                        (api.put_image)(dpy, self.input, image.image_id, 0, 0, w, h, 0, 0, w, h)
                    },
                    "vaPutImage",
                )?;
            }
        }
        result
    }

    // perf-hot: 1ms vaapi-upload
    fn write_nv12(&self, pic: &I420, image: &VAImage) -> Result<(), String> {
        let api = self.api;
        let mut base: *mut c_void = std::ptr::null_mut();
        // SAFETY: the image's buffer and a pointer to fill.
        api.check(
            unsafe { (api.map_buffer)(self.dpy(), image.buf, &mut base) },
            "vaMapBuffer(image)",
        )?;
        if base.is_null() {
            return Err("vaMapBuffer(image) returned NULL".into());
        }
        let (w, h) = (self.width as usize, self.height as usize);
        let (y_pitch, uv_pitch) = (image.pitches[0] as usize, image.pitches[1] as usize);
        let (y_off, uv_off) = (image.offsets[0] as usize, image.offsets[1] as usize);
        let size = image.data_size as usize;
        let fits = y_pitch >= w
            && uv_pitch >= w
            && y_off + y_pitch * (h - 1) + w <= size
            && uv_off + uv_pitch * (h / 2 - 1) + w <= size;
        if fits {
            // SAFETY: the mapping covers data_size bytes (checked against every row written).
            let data = unsafe { std::slice::from_raw_parts_mut(base.cast::<u8>(), size) };
            // Rows at `offset + row * pitch`, `w` bytes each; `fits` proved each is inside.
            fn row_at(data: &mut [u8], start: usize, w: usize) -> Option<&mut [u8]> {
                data.get_mut(start..).and_then(|d| d.get_mut(..w))
            }
            for (row, src) in pic.y.chunks_exact(w).take(h).enumerate() {
                if let Some(dst) = row_at(data, y_off + row * y_pitch, w) {
                    dst.copy_from_slice(src);
                }
            }
            let cw = w / 2;
            for (row, (u, v)) in
                pic.u.chunks_exact(cw).zip(pic.v.chunks_exact(cw)).take(h / 2).enumerate()
            {
                let Some(dst) = row_at(data, uv_off + row * uv_pitch, w) else { continue };
                for ((pair, &u), &v) in dst.chunks_exact_mut(2).zip(u).zip(v) {
                    if let [cb, cr] = pair {
                        *cb = u;
                        *cr = v;
                    }
                }
            }
        }
        // SAFETY: mapped above.
        unsafe { (api.unmap_buffer)(self.dpy(), image.buf) };
        if fits { Ok(()) } else { Err(format!("NV12 image layout too small for {w}x{h}")) }
    }

    fn sequence_params(&self) -> VAEncSequenceParameterBufferH264 {
        let (crop_right, crop_bottom) = self.crop();
        VAEncSequenceParameterBufferH264 {
            seq_parameter_set_id: 0,
            level_idc: self.level_idc(),
            // The encoder, not the driver, picks each frame's type (an IDR only when asked);
            // the periods only bound the driver's rate-control horizon.
            intra_period: u32::from(u16::MAX),
            intra_idr_period: u32::from(u16::MAX),
            ip_period: 1,
            bits_per_second: self.kbps * 1000,
            max_num_ref_frames: 1,
            picture_width_in_mbs: self.mbs_wide() as u16,
            picture_height_in_mbs: self.mbs_high() as u16,
            seq_fields: 1 | (1 << 2) | (1 << 5) | (LOG2_MAX_FRAME_NUM_MINUS4 << 6) | (2 << 10),
            bit_depth_luma_minus8: 0,
            bit_depth_chroma_minus8: 0,
            num_ref_frames_in_pic_order_cnt_cycle: 0,
            offset_for_non_ref_pic: 0,
            offset_for_top_to_bottom_field: 0,
            offset_for_ref_frame: [0; 256],
            frame_cropping_flag: u8::from(crop_right > 0 || crop_bottom > 0),
            frame_crop_left_offset: 0,
            frame_crop_right_offset: crop_right,
            frame_crop_top_offset: 0,
            frame_crop_bottom_offset: crop_bottom,
            vui_parameters_present_flag: 1,
            vui_fields: (1 << 2) | (15 << 3) | (15 << 8) | (1 << 15),
            aspect_ratio_idc: 0,
            sar_width: 0,
            sar_height: 0,
            num_units_in_tick: 0,
            time_scale: 0,
            va_reserved: [0; 4],
        }
    }

    fn rate_control_params(&self) -> (VAEncMiscParameterRateControl, VAEncMiscParameterHRD) {
        let bps = self.kbps * 1000;
        // A quarter second of buffer: no frame takes longer than that to send at the rate.
        let buffer = bps / 4;
        let rc = VAEncMiscParameterRateControl {
            bits_per_second: bps,
            target_percentage: 100,
            window_size: 250,
            ..Default::default()
        };
        (
            rc,
            VAEncMiscParameterHRD {
                initial_buffer_fullness: buffer / 2,
                buffer_size: buffer,
                va_reserved: [0; 4],
            },
        )
    }

    fn buffer(&self, kind: c_int, data: &[u8]) -> Result<VAId, String> {
        let mut id = VA_INVALID_ID;
        // SAFETY: libva copies `data.len()` bytes from `data` into the new buffer.
        self.api.check(
            unsafe {
                (self.api.create_buffer)(
                    self.dpy(),
                    self.context,
                    kind,
                    data.len() as c_uint,
                    1,
                    data.as_ptr().cast_mut().cast(),
                    &mut id,
                )
            },
            "vaCreateBuffer",
        )?;
        Ok(id)
    }

    fn misc<T: Copy>(&self, kind: u32, value: &T) -> Result<VAId, String> {
        let mut data = kind.to_ne_bytes().to_vec();
        data.extend_from_slice(bytes_of(value));
        self.buffer(VA_ENC_MISC_PARAMETER_BUFFER_TYPE, &data)
    }

    fn packed(&self, kind: u32, header: &[u8], bufs: &mut Vec<VAId>) -> Result<(), String> {
        let param = VAEncPackedHeaderParameterBuffer {
            kind,
            bit_length: (header.len() * 8) as u32,
            has_emulation_bytes: 1,
            va_reserved: [0; 4],
        };
        bufs.push(self.buffer(VA_ENC_PACKED_HEADER_PARAMETER_BUFFER_TYPE, bytes_of(&param))?);
        bufs.push(self.buffer(VA_ENC_PACKED_HEADER_DATA_BUFFER_TYPE, header)?);
        Ok(())
    }

    /// The parameter buffers for one frame, in the order the driver reads them.
    fn frame_buffers(&self, idr: bool, frame: u32, bufs: &mut Vec<VAId>) -> Result<(), String> {
        if idr {
            bufs.push(self.buffer(
                VA_ENC_SEQUENCE_PARAMETER_BUFFER_TYPE,
                bytes_of(&self.sequence_params()),
            )?);
        }
        if self.applied_kbps.is_none() {
            let rate = VAEncMiscParameterFrameRate { framerate: self.fps, ..Default::default() };
            bufs.push(self.misc(VA_ENC_MISC_PARAMETER_TYPE_FRAME_RATE, &rate)?);
        }
        if self.applied_kbps != Some(self.kbps) {
            let (mut rc, hrd) = self.rate_control_params();
            // rc_flags.reset: a new rate mid-stream restarts the driver's rate control at once.
            rc.rc_flags = u32::from(self.applied_kbps.is_some());
            bufs.push(self.misc(VA_ENC_MISC_PARAMETER_TYPE_RATE_CONTROL, &rc)?);
            bufs.push(self.misc(VA_ENC_MISC_PARAMETER_TYPE_HRD, &hrd)?);
        }
        if idr && self.probe.packed_headers {
            self.packed(VA_ENC_PACKED_HEADER_TYPE_SEQUENCE, &self.sps, bufs)?;
            self.packed(VA_ENC_PACKED_HEADER_TYPE_PICTURE, &self.pps, bufs)?;
        }
        let poc = (frame as i32).wrapping_mul(2);
        let current = VAPictureH264 {
            picture_id: self.recon(false),
            frame_idx: frame % (1 << (LOG2_MAX_FRAME_NUM_MINUS4 + 4)),
            flags: 0,
            top_field_order_cnt: poc,
            bottom_field_order_cnt: poc,
            va_reserved: [0; 4],
        };
        let reference = (!idr).then(|| {
            let poc = (frame.wrapping_sub(1) as i32).wrapping_mul(2);
            VAPictureH264 {
                picture_id: self.recon(true),
                frame_idx: frame.wrapping_sub(1) % (1 << (LOG2_MAX_FRAME_NUM_MINUS4 + 4)),
                flags: VA_PICTURE_H264_SHORT_TERM_REFERENCE,
                top_field_order_cnt: poc,
                bottom_field_order_cnt: poc,
                va_reserved: [0; 4],
            }
        });
        let mut reference_frames = [VAPictureH264::INVALID; 16];
        if let Some(r) = reference {
            reference_frames[0] = r;
        }
        let pic = VAEncPictureParameterBufferH264 {
            curr_pic: current,
            reference_frames,
            coded_buf: self.coded,
            pic_parameter_set_id: 0,
            seq_parameter_set_id: 0,
            last_picture: 0,
            frame_num: current.frame_idx as u16,
            pic_init_qp: 26,
            num_ref_idx_l0_active_minus1: 0,
            num_ref_idx_l1_active_minus1: 0,
            chroma_qp_index_offset: 0,
            second_chroma_qp_index_offset: 0,
            pic_fields: u32::from(idr)
                | (1 << 1)
                | (u32::from(self.cabac()) << 3)
                | (u32::from(self.high()) << 8)
                | (1 << 9),
            va_reserved: [0; 4],
        };
        bufs.push(self.buffer(VA_ENC_PICTURE_PARAMETER_BUFFER_TYPE, bytes_of(&pic))?);
        // SAFETY: an all-zero slice parameter struct is valid (plain integers).
        let mut slice: VAEncSliceParameterBufferH264 = unsafe { std::mem::zeroed() };
        slice.num_macroblocks = self.mbs_wide() * self.mbs_high();
        slice.macroblock_info = VA_INVALID_ID;
        slice.slice_type = if idr { SLICE_I } else { SLICE_P };
        slice.idr_pic_id = self.idr_pic_id;
        slice.ref_pic_list0 = [VAPictureH264::INVALID; 32];
        slice.ref_pic_list1 = [VAPictureH264::INVALID; 32];
        if let Some(r) = reference {
            slice.ref_pic_list0[0] = r;
        }
        bufs.push(self.buffer(VA_ENC_SLICE_PARAMETER_BUFFER_TYPE, bytes_of(&slice))?);
        Ok(())
    }

    fn read_coded(&self, out: &mut Vec<u8>) -> Result<(), String> {
        let api = self.api;
        let mut segment: *mut c_void = std::ptr::null_mut();
        // SAFETY: the coded buffer and a pointer to fill.
        api.check(
            unsafe { (api.map_buffer)(self.dpy(), self.coded, &mut segment) },
            "vaMapBuffer(coded)",
        )?;
        let mut next = segment.cast::<VACodedBufferSegment>();
        while !next.is_null() {
            // SAFETY: libva's list of segments, valid while the buffer is mapped.
            let seg = unsafe { &*next };
            if !seg.buf.is_null() && seg.size > 0 {
                // SAFETY: `size` bytes at `buf`, valid while mapped.
                out.extend_from_slice(unsafe {
                    std::slice::from_raw_parts(seg.buf.cast::<u8>(), seg.size as usize)
                });
            }
            next = seg.next.cast();
        }
        // SAFETY: mapped above.
        unsafe { (api.unmap_buffer)(self.dpy(), self.coded) };
        Ok(())
    }

    fn encode_frame(
        &mut self,
        pic: &I420,
        force_idr: bool,
        out: &mut Vec<u8>,
    ) -> Result<bool, String> {
        out.clear();
        if pic.width != self.width as usize || pic.y.len() != pic.width * self.height as usize {
            return Err(format!("picture is not {}x{}", self.width, self.height));
        }
        let idr = force_idr || self.since_idr.is_none();
        let frame = if idr { 0 } else { self.since_idr.unwrap_or(0) };
        self.upload(pic)?;
        let api = self.api;
        let dpy = self.dpy();
        let mut bufs = Vec::with_capacity(12);
        let result = self.frame_buffers(idr, frame, &mut bufs).and_then(|()| {
            // SAFETY: the context, its input surface and the buffers made for this frame.
            api.check(
                unsafe { (api.begin_picture)(dpy, self.context, self.input) },
                "vaBeginPicture",
            )?;
            // SAFETY: as above.
            let rendered = api.check(
                unsafe {
                    (api.render_picture)(dpy, self.context, bufs.as_mut_ptr(), bufs.len() as c_int)
                },
                "vaRenderPicture",
            );
            // SAFETY: as above; a picture that began always ends.
            let ended = api.check(unsafe { (api.end_picture)(dpy, self.context) }, "vaEndPicture");
            rendered.and(ended)
        });
        for id in bufs {
            // SAFETY: buffers made for this frame; the driver is done with them after vaEndPicture.
            unsafe { (api.destroy_buffer)(dpy, id) };
        }
        result?;
        // SAFETY: the input surface of the picture just ended.
        api.check(unsafe { (api.sync_surface)(dpy, self.input) }, "vaSyncSurface")?;
        self.read_coded(out)?;
        if out.is_empty() {
            return Err("the driver returned an empty frame".into());
        }
        if idr {
            if !crate::annexb_nals(out).any(|n| n.first().is_some_and(|b| b & 0x1f == 7)) {
                let mut with_headers =
                    Vec::with_capacity(self.sps.len() + self.pps.len() + out.len());
                with_headers.extend_from_slice(&self.sps);
                with_headers.extend_from_slice(&self.pps);
                with_headers.append(out);
                *out = with_headers;
            }
            self.idr_pic_id = self.idr_pic_id.wrapping_add(1);
        }
        self.applied_kbps = Some(self.kbps);
        self.since_idr = Some(frame.wrapping_add(1));
        self.cur = !self.cur;
        Ok(idr)
    }
}

impl H264Encoder for Vaapi {
    // perf-hot: 8ms vaapi-encode
    fn encode(&mut self, pic: &I420, force_idr: bool, _pts: i64, out: &mut Vec<u8>) -> Res<bool> {
        Ok(self.encode_frame(pic, force_idr, out)?)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        let kbps = kbps.clamp(100, 288_000);
        // Changes under 5% are noise from the controller; each applied one resets the driver's rate control.
        if u64::from(kbps.abs_diff(self.kbps)) * 20 >= u64::from(self.kbps) {
            self.kbps = kbps;
        }
    }

    fn kbps(&self) -> u32 {
        self.kbps
    }

    fn name(&self) -> String {
        format!("vaapi {}", self.probe)
    }
}

impl Drop for Vaapi {
    fn drop(&mut self) {
        let (api, dpy) = (self.api, self.dpy());
        // SAFETY: ids made on this display (VA_INVALID_ID ones were never made); each is
        // destroyed once, before the display terminates (field order).
        unsafe {
            if let Upload::Put(image) = &self.upload {
                (api.destroy_image)(dpy, image.image_id);
            }
            if self.coded != VA_INVALID_ID {
                (api.destroy_buffer)(dpy, self.coded);
            }
            if self.context != VA_INVALID_ID {
                (api.destroy_context)(dpy, self.context);
            }
            let mut surfaces = {
                let [a, b] = self.recon;
                [self.input, a, b]
            };
            if self.input != VA_INVALID_ID {
                (api.destroy_surfaces)(dpy, surfaces.as_mut_ptr(), 3);
            }
            if self.config != VA_INVALID_ID {
                (api.destroy_config)(dpy, self.config);
            }
        }
    }
}

fn bytes_of<T: Copy>(value: &T) -> &[u8] {
    // SAFETY: a plain-old-data #[repr(C)] struct read as its bytes (padding included; libva
    // ignores it).
    unsafe { std::slice::from_raw_parts((value as *const T).cast::<u8>(), size_of::<T>()) }
}

#[cfg(test)]
mod tests;
