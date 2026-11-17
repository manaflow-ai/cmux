//! The libva types, constants and entry points the VAAPI encoder uses (va.h, va_drm.h and
//! va_enc_h264.h of libva 2.x), loaded at run time.

use std::ffi::{CStr, c_char, c_int, c_uint, c_void};

pub type VADisplay = *mut c_void;
pub type VAStatus = c_int;
/// Surface, config, context, buffer and image ids are all `unsigned int`.
pub type VAId = c_uint;
pub type VAMessageCallback = unsafe extern "C" fn(*mut c_void, *const c_char);

pub const VA_STATUS_SUCCESS: VAStatus = 0;
pub const VA_INVALID_ID: VAId = 0xffff_ffff;
pub const VA_ATTRIB_NOT_SUPPORTED: u32 = 0x8000_0000;

pub const VA_PROFILE_H264_MAIN: i32 = 6;
pub const VA_PROFILE_H264_HIGH: i32 = 7;
pub const VA_PROFILE_H264_CONSTRAINED_BASELINE: i32 = 13;
pub const VA_ENTRYPOINT_ENC_SLICE: i32 = 6;
pub const VA_ENTRYPOINT_ENC_SLICE_LP: i32 = 8;

pub const VA_CONFIG_ATTRIB_RT_FORMAT: i32 = 0;
pub const VA_CONFIG_ATTRIB_RATE_CONTROL: i32 = 5;
pub const VA_CONFIG_ATTRIB_ENC_PACKED_HEADERS: i32 = 10;
pub const VA_RT_FORMAT_YUV420: u32 = 0x1;
pub const VA_RC_CBR: u32 = 0x2;
pub const VA_RC_VBR: u32 = 0x4;
pub const VA_ENC_PACKED_HEADER_SEQUENCE: u32 = 0x1;
pub const VA_ENC_PACKED_HEADER_PICTURE: u32 = 0x2;

pub const VA_ENC_CODED_BUFFER_TYPE: c_int = 21;
pub const VA_ENC_SEQUENCE_PARAMETER_BUFFER_TYPE: c_int = 22;
pub const VA_ENC_PICTURE_PARAMETER_BUFFER_TYPE: c_int = 23;
pub const VA_ENC_SLICE_PARAMETER_BUFFER_TYPE: c_int = 24;
pub const VA_ENC_PACKED_HEADER_PARAMETER_BUFFER_TYPE: c_int = 25;
pub const VA_ENC_PACKED_HEADER_DATA_BUFFER_TYPE: c_int = 26;
pub const VA_ENC_MISC_PARAMETER_BUFFER_TYPE: c_int = 27;
pub const VA_ENC_MISC_PARAMETER_TYPE_FRAME_RATE: u32 = 0;
pub const VA_ENC_MISC_PARAMETER_TYPE_RATE_CONTROL: u32 = 1;
pub const VA_ENC_MISC_PARAMETER_TYPE_HRD: u32 = 5;
pub const VA_ENC_PACKED_HEADER_TYPE_SEQUENCE: u32 = 1;
pub const VA_ENC_PACKED_HEADER_TYPE_PICTURE: u32 = 2;
pub const VA_PROGRESSIVE: c_int = 0x1;
pub const VA_FOURCC_NV12: u32 = 0x3231_564e;
pub const VA_PICTURE_H264_INVALID: u32 = 0x1;
pub const VA_PICTURE_H264_SHORT_TERM_REFERENCE: u32 = 0x8;

// The structs below are va.h and va_enc_h264.h of libva 2.x; the size checks at the end of
// the module match gcc's layout of libva 2.20's headers (x86-64 and arm64 alike).

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct VAConfigAttrib {
    pub kind: i32,
    pub value: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct VAImageFormat {
    pub fourcc: u32,
    pub byte_order: u32,
    pub bits_per_pixel: u32,
    pub depth: u32,
    pub red_mask: u32,
    pub green_mask: u32,
    pub blue_mask: u32,
    pub alpha_mask: u32,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct VAImage {
    pub image_id: VAId,
    pub format: VAImageFormat,
    pub buf: VAId,
    pub width: u16,
    pub height: u16,
    pub data_size: u32,
    pub num_planes: u32,
    pub pitches: [u32; 3],
    pub offsets: [u32; 3],
    pub num_palette_entries: i32,
    pub entry_bytes: i32,
    pub component_order: [i8; 4],
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct VACodedBufferSegment {
    pub size: u32,
    pub bit_offset: u32,
    pub status: u32,
    pub reserved: u32,
    pub buf: *mut c_void,
    pub next: *mut c_void,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct VAPictureH264 {
    pub picture_id: VAId,
    pub frame_idx: u32,
    pub flags: u32,
    pub top_field_order_cnt: i32,
    pub bottom_field_order_cnt: i32,
    pub va_reserved: [u32; 4],
}

impl VAPictureH264 {
    pub const INVALID: Self = Self {
        picture_id: VA_INVALID_ID,
        frame_idx: 0,
        flags: VA_PICTURE_H264_INVALID,
        top_field_order_cnt: 0,
        bottom_field_order_cnt: 0,
        va_reserved: [0; 4],
    };
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct VAEncSequenceParameterBufferH264 {
    pub seq_parameter_set_id: u8,
    pub level_idc: u8,
    pub intra_period: u32,
    pub intra_idr_period: u32,
    pub ip_period: u32,
    pub bits_per_second: u32,
    pub max_num_ref_frames: u32,
    pub picture_width_in_mbs: u16,
    pub picture_height_in_mbs: u16,
    /// Bits: chroma_format_idc 0-1, frame_mbs_only_flag 2, direct_8x8_inference_flag 5,
    /// log2_max_frame_num_minus4 6-9, pic_order_cnt_type 10-11.
    pub seq_fields: u32,
    pub bit_depth_luma_minus8: u8,
    pub bit_depth_chroma_minus8: u8,
    pub num_ref_frames_in_pic_order_cnt_cycle: u8,
    pub offset_for_non_ref_pic: i32,
    pub offset_for_top_to_bottom_field: i32,
    pub offset_for_ref_frame: [i32; 256],
    pub frame_cropping_flag: u8,
    pub frame_crop_left_offset: u32,
    pub frame_crop_right_offset: u32,
    pub frame_crop_top_offset: u32,
    pub frame_crop_bottom_offset: u32,
    pub vui_parameters_present_flag: u8,
    /// Bits: bitstream_restriction_flag 2, log2_max_mv_length_horizontal 3-7,
    /// log2_max_mv_length_vertical 8-12, motion_vectors_over_pic_boundaries_flag 15.
    pub vui_fields: u32,
    pub aspect_ratio_idc: u8,
    pub sar_width: u32,
    pub sar_height: u32,
    pub num_units_in_tick: u32,
    pub time_scale: u32,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct VAEncPictureParameterBufferH264 {
    pub curr_pic: VAPictureH264,
    pub reference_frames: [VAPictureH264; 16],
    pub coded_buf: VAId,
    pub pic_parameter_set_id: u8,
    pub seq_parameter_set_id: u8,
    pub last_picture: u8,
    pub frame_num: u16,
    pub pic_init_qp: u8,
    pub num_ref_idx_l0_active_minus1: u8,
    pub num_ref_idx_l1_active_minus1: u8,
    pub chroma_qp_index_offset: i8,
    pub second_chroma_qp_index_offset: i8,
    /// Bits: idr_pic_flag 0, reference_pic_flag 1-2, entropy_coding_mode_flag 3,
    /// transform_8x8_mode_flag 8, deblocking_filter_control_present_flag 9.
    pub pic_fields: u32,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct VAEncSliceParameterBufferH264 {
    pub macroblock_address: u32,
    pub num_macroblocks: u32,
    pub macroblock_info: VAId,
    pub slice_type: u8,
    pub pic_parameter_set_id: u8,
    pub idr_pic_id: u16,
    pub pic_order_cnt_lsb: u16,
    pub delta_pic_order_cnt_bottom: i32,
    pub delta_pic_order_cnt: [i32; 2],
    pub direct_spatial_mv_pred_flag: u8,
    pub num_ref_idx_active_override_flag: u8,
    pub num_ref_idx_l0_active_minus1: u8,
    pub num_ref_idx_l1_active_minus1: u8,
    pub ref_pic_list0: [VAPictureH264; 32],
    pub ref_pic_list1: [VAPictureH264; 32],
    pub luma_log2_weight_denom: u8,
    pub chroma_log2_weight_denom: u8,
    pub luma_weight_l0_flag: u8,
    pub luma_weight_l0: [i16; 32],
    pub luma_offset_l0: [i16; 32],
    pub chroma_weight_l0_flag: u8,
    pub chroma_weight_l0: [[i16; 2]; 32],
    pub chroma_offset_l0: [[i16; 2]; 32],
    pub luma_weight_l1_flag: u8,
    pub luma_weight_l1: [i16; 32],
    pub luma_offset_l1: [i16; 32],
    pub chroma_weight_l1_flag: u8,
    pub chroma_weight_l1: [[i16; 2]; 32],
    pub chroma_offset_l1: [[i16; 2]; 32],
    pub cabac_init_idc: u8,
    pub slice_qp_delta: i8,
    pub disable_deblocking_filter_idc: u8,
    pub slice_alpha_c0_offset_div2: i8,
    pub slice_beta_offset_div2: i8,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct VAEncMiscParameterRateControl {
    pub bits_per_second: u32,
    pub target_percentage: u32,
    pub window_size: u32,
    pub initial_qp: u32,
    pub min_qp: u32,
    pub basic_unit_size: u32,
    pub rc_flags: u32,
    pub icq_quality_factor: u32,
    pub max_qp: u32,
    pub quality_factor: u32,
    pub target_frame_size: u32,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct VAEncMiscParameterFrameRate {
    pub framerate: u32,
    pub framerate_flags: u32,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct VAEncMiscParameterHRD {
    pub initial_buffer_fullness: u32,
    pub buffer_size: u32,
    pub va_reserved: [u32; 4],
}

#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct VAEncPackedHeaderParameterBuffer {
    pub kind: u32,
    pub bit_length: u32,
    pub has_emulation_bytes: u8,
    pub va_reserved: [u32; 4],
}

/// The libva entry points in use (libva.so.2 and libva-drm.so.2). Tests fill one with stand-ins.
#[allow(clippy::type_complexity)]
pub struct LibVa {
    pub get_display_drm: unsafe extern "C" fn(c_int) -> VADisplay,
    pub initialize: unsafe extern "C" fn(VADisplay, *mut c_int, *mut c_int) -> VAStatus,
    pub terminate: unsafe extern "C" fn(VADisplay) -> VAStatus,
    /// Optional: silences libva's "libva info:" lines on stderr.
    pub set_info_callback: Option<
        unsafe extern "C" fn(
            VADisplay,
            Option<VAMessageCallback>,
            *mut c_void,
        ) -> Option<VAMessageCallback>,
    >,
    pub query_vendor_string: unsafe extern "C" fn(VADisplay) -> *const c_char,
    pub error_str: unsafe extern "C" fn(VAStatus) -> *const c_char,
    pub max_num_profiles: unsafe extern "C" fn(VADisplay) -> c_int,
    pub query_config_profiles: unsafe extern "C" fn(VADisplay, *mut i32, *mut c_int) -> VAStatus,
    pub max_num_entrypoints: unsafe extern "C" fn(VADisplay) -> c_int,
    pub query_config_entrypoints:
        unsafe extern "C" fn(VADisplay, i32, *mut i32, *mut c_int) -> VAStatus,
    pub get_config_attributes:
        unsafe extern "C" fn(VADisplay, i32, i32, *mut VAConfigAttrib, c_int) -> VAStatus,
    pub create_config: unsafe extern "C" fn(
        VADisplay,
        i32,
        i32,
        *mut VAConfigAttrib,
        c_int,
        *mut VAId,
    ) -> VAStatus,
    pub destroy_config: unsafe extern "C" fn(VADisplay, VAId) -> VAStatus,
    pub create_surfaces: unsafe extern "C" fn(
        VADisplay,
        c_uint,
        c_uint,
        c_uint,
        *mut VAId,
        c_uint,
        *mut c_void,
        c_uint,
    ) -> VAStatus,
    pub destroy_surfaces: unsafe extern "C" fn(VADisplay, *mut VAId, c_int) -> VAStatus,
    pub create_context: unsafe extern "C" fn(
        VADisplay,
        VAId,
        c_int,
        c_int,
        c_int,
        *mut VAId,
        c_int,
        *mut VAId,
    ) -> VAStatus,
    pub destroy_context: unsafe extern "C" fn(VADisplay, VAId) -> VAStatus,
    pub create_buffer: unsafe extern "C" fn(
        VADisplay,
        VAId,
        c_int,
        c_uint,
        c_uint,
        *mut c_void,
        *mut VAId,
    ) -> VAStatus,
    pub destroy_buffer: unsafe extern "C" fn(VADisplay, VAId) -> VAStatus,
    pub map_buffer: unsafe extern "C" fn(VADisplay, VAId, *mut *mut c_void) -> VAStatus,
    pub unmap_buffer: unsafe extern "C" fn(VADisplay, VAId) -> VAStatus,
    pub begin_picture: unsafe extern "C" fn(VADisplay, VAId, VAId) -> VAStatus,
    pub render_picture: unsafe extern "C" fn(VADisplay, VAId, *mut VAId, c_int) -> VAStatus,
    pub end_picture: unsafe extern "C" fn(VADisplay, VAId) -> VAStatus,
    pub sync_surface: unsafe extern "C" fn(VADisplay, VAId) -> VAStatus,
    pub derive_image: unsafe extern "C" fn(VADisplay, VAId, *mut VAImage) -> VAStatus,
    pub create_image:
        unsafe extern "C" fn(VADisplay, *mut VAImageFormat, c_int, c_int, *mut VAImage) -> VAStatus,
    pub put_image: unsafe extern "C" fn(
        VADisplay,
        VAId,
        VAId,
        c_int,
        c_int,
        c_uint,
        c_uint,
        c_int,
        c_int,
        c_uint,
        c_uint,
    ) -> VAStatus,
    pub destroy_image: unsafe extern "C" fn(VADisplay, VAId) -> VAStatus,
}

impl LibVa {
    /// The system's libva, loaded once per process; the error says which library or symbol is
    /// missing.
    pub fn system() -> Result<&'static LibVa, String> {
        static LIBVA: std::sync::OnceLock<Result<LibVa, String>> = std::sync::OnceLock::new();
        LIBVA.get_or_init(Self::load).as_ref().map_err(Clone::clone)
    }

    fn load() -> Result<LibVa, String> {
        use crate::dynlib::Library;
        // The libraries stay loaded for the process (`Library` never closes; the table points
        // into them).
        let va = Library::open(c"libva.so.2")?;
        let drm = Library::open(c"libva-drm.so.2")?;
        /// `name`'s address as the function pointer type `F` of the table's field.
        fn function<F: Copy>(address: *mut c_void) -> F {
            const { assert!(size_of::<F>() == size_of::<*mut c_void>()) };
            // SAFETY: `address` is the libva function the table declares as `F` (va.h), and
            // a function pointer has the size of a data pointer (checked above).
            unsafe { std::mem::transmute_copy::<*mut c_void, F>(&address) }
        }
        macro_rules! sym {
            ($lib:expr, $name:literal) => {
                function($lib.symbol($name)?)
            };
        }
        Ok(LibVa {
            get_display_drm: sym!(drm, c"vaGetDisplayDRM"),
            initialize: sym!(va, c"vaInitialize"),
            terminate: sym!(va, c"vaTerminate"),
            set_info_callback: va.symbol(c"vaSetInfoCallback").ok().map(function),
            query_vendor_string: sym!(va, c"vaQueryVendorString"),
            error_str: sym!(va, c"vaErrorStr"),
            max_num_profiles: sym!(va, c"vaMaxNumProfiles"),
            query_config_profiles: sym!(va, c"vaQueryConfigProfiles"),
            max_num_entrypoints: sym!(va, c"vaMaxNumEntrypoints"),
            query_config_entrypoints: sym!(va, c"vaQueryConfigEntrypoints"),
            get_config_attributes: sym!(va, c"vaGetConfigAttributes"),
            create_config: sym!(va, c"vaCreateConfig"),
            destroy_config: sym!(va, c"vaDestroyConfig"),
            create_surfaces: sym!(va, c"vaCreateSurfaces"),
            destroy_surfaces: sym!(va, c"vaDestroySurfaces"),
            create_context: sym!(va, c"vaCreateContext"),
            destroy_context: sym!(va, c"vaDestroyContext"),
            create_buffer: sym!(va, c"vaCreateBuffer"),
            destroy_buffer: sym!(va, c"vaDestroyBuffer"),
            map_buffer: sym!(va, c"vaMapBuffer"),
            unmap_buffer: sym!(va, c"vaUnmapBuffer"),
            begin_picture: sym!(va, c"vaBeginPicture"),
            render_picture: sym!(va, c"vaRenderPicture"),
            end_picture: sym!(va, c"vaEndPicture"),
            sync_surface: sym!(va, c"vaSyncSurface"),
            derive_image: sym!(va, c"vaDeriveImage"),
            create_image: sym!(va, c"vaCreateImage"),
            put_image: sym!(va, c"vaPutImage"),
            destroy_image: sym!(va, c"vaDestroyImage"),
        })
    }

    pub(super) fn check(&self, status: VAStatus, what: &str) -> Result<(), String> {
        if status == VA_STATUS_SUCCESS {
            return Ok(());
        }
        // SAFETY: vaErrorStr returns a static NUL-terminated string for any status.
        let text = unsafe { (self.error_str)(status) };
        let text = if text.is_null() {
            "unknown error".into()
        } else {
            // SAFETY: non-NULL, NUL-terminated, static.
            unsafe { CStr::from_ptr(text) }.to_string_lossy()
        };
        Err(format!("{what}: {text} ({status})"))
    }
}

const _: () = {
    assert!(size_of::<VAConfigAttrib>() == 8);
    assert!(size_of::<VAImageFormat>() == 48);
    assert!(size_of::<VAImage>() == 120);
    assert!(size_of::<VACodedBufferSegment>() == 48);
    assert!(size_of::<VAPictureH264>() == 36);
    assert!(size_of::<VAEncSequenceParameterBufferH264>() == 1132);
    assert!(size_of::<VAEncPictureParameterBufferH264>() == 648);
    assert!(size_of::<VAEncSliceParameterBufferH264>() == 3140);
    assert!(size_of::<VAEncMiscParameterRateControl>() == 60);
    assert!(size_of::<VAEncMiscParameterFrameRate>() == 24);
    assert!(size_of::<VAEncMiscParameterHRD>() == 24);
    assert!(size_of::<VAEncPackedHeaderParameterBuffer>() == 28);
};
