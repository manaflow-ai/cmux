//! The SPS and PPS the encoder writes itself (so every driver emits the same VUI), and the
//! bit writer for them.

use super::{LOG2_MAX_FRAME_NUM_MINUS4, Vaapi, ffi::*};

impl Vaapi {
    pub(super) fn level_idc(&self) -> u8 {
        // (level_idc, MaxFS in macroblocks, MaxMBPS) from H.264 table A-1.
        const LEVELS: [(u8, u64, u64); 11] = [
            (31, 3_600, 108_000),
            (32, 5_120, 216_000),
            (40, 8_192, 245_760),
            (42, 8_704, 522_240),
            (50, 22_080, 589_824),
            (51, 36_864, 983_040),
            (52, 36_864, 2_073_600),
            (60, 139_264, 4_177_920),
            (61, 139_264, 8_355_840),
            (62, 139_264, 16_711_680),
            (62, u64::MAX, u64::MAX),
        ];
        let fs = u64::from(self.mbs_wide() * self.mbs_high());
        let mbps = fs * u64::from(self.fps);
        LEVELS
            .iter()
            .find(|&&(_, max_fs, max_mbps)| fs <= max_fs && mbps <= max_mbps)
            .map_or(62, |l| l.0)
    }

    pub(super) fn profile_idc(&self) -> (u8, u8) {
        // (profile_idc, constraint flags byte: set0..set5 in the high bits).
        match self.probe.profile {
            VA_PROFILE_H264_HIGH => (100, 0),
            VA_PROFILE_H264_MAIN => (77, 0x40),
            _ => (66, 0xc0),
        }
    }

    pub(super) fn crop(&self) -> (u32, u32) {
        // In 4:2:0 the crop unit is 2 pixels.
        ((self.mbs_wide() * 16 - self.width) / 2, (self.mbs_high() * 16 - self.height) / 2)
    }

    /// The SPS as an Annex-B NAL unit (start code included).
    pub(super) fn write_sps(&self) -> Vec<u8> {
        let mut b = BitWriter::default();
        let (profile_idc, constraints) = self.profile_idc();
        b.put(u32::from(profile_idc), 8);
        b.put(u32::from(constraints), 8);
        b.put(u32::from(self.level_idc()), 8);
        b.ue(0); // seq_parameter_set_id
        if self.high() {
            b.ue(1); // chroma_format_idc 4:2:0
            b.ue(0); // bit_depth_luma_minus8
            b.ue(0); // bit_depth_chroma_minus8
            b.put(0, 1); // qpprime_y_zero_transform_bypass_flag
            b.put(0, 1); // seq_scaling_matrix_present_flag
        }
        b.ue(LOG2_MAX_FRAME_NUM_MINUS4);
        b.ue(2); // pic_order_cnt_type: picture order follows frame_num (no B-frames)
        b.ue(1); // max_num_ref_frames
        b.put(0, 1); // gaps_in_frame_num_value_allowed_flag
        b.ue(self.mbs_wide() - 1);
        b.ue(self.mbs_high() - 1);
        b.put(1, 1); // frame_mbs_only_flag
        b.put(1, 1); // direct_8x8_inference_flag
        let (crop_right, crop_bottom) = self.crop();
        if crop_right > 0 || crop_bottom > 0 {
            b.put(1, 1);
            b.ue(0);
            b.ue(crop_right);
            b.ue(0);
            b.ue(crop_bottom);
        } else {
            b.put(0, 1);
        }
        b.put(1, 1); // vui_parameters_present_flag
        b.put(0, 1); // aspect_ratio_info_present_flag
        b.put(0, 1); // overscan_info_present_flag
        // What the pictures are (crate::color::SCREEN), so a viewer converts them back with
        // the same matrix and range instead of guessing.
        let color = crate::color::SCREEN;
        b.put(1, 1); // video_signal_type_present_flag
        b.put(5, 3); // video_format: unspecified
        b.put(u32::from(color.full_range), 1); // video_full_range_flag
        b.put(1, 1); // colour_description_present_flag
        b.put(u32::from(color.primaries), 8);
        b.put(u32::from(color.transfer), 8);
        b.put(u32::from(color.matrix), 8);
        b.put(0, 1); // chroma_loc_info_present_flag
        b.put(0, 1); // timing_info_present_flag
        b.put(0, 1); // nal_hrd_parameters_present_flag
        b.put(0, 1); // vcl_hrd_parameters_present_flag
        b.put(0, 1); // pic_struct_present_flag
        b.put(1, 1); // bitstream_restriction_flag
        b.put(1, 1); // motion_vectors_over_pic_boundaries_flag
        b.ue(0); // max_bytes_per_pic_denom
        b.ue(0); // max_bits_per_mb_denom
        b.ue(15); // log2_max_mv_length_horizontal
        b.ue(15); // log2_max_mv_length_vertical
        b.ue(0); // max_num_reorder_frames: shown as soon as decoded
        b.ue(1); // max_dec_frame_buffering
        nal(0x67, b.finish())
    }

    /// The PPS as an Annex-B NAL unit (start code included).
    pub(super) fn write_pps(&self) -> Vec<u8> {
        let mut b = BitWriter::default();
        b.ue(0); // pic_parameter_set_id
        b.ue(0); // seq_parameter_set_id
        b.put(u32::from(self.cabac()), 1); // entropy_coding_mode_flag
        b.put(0, 1); // bottom_field_pic_order_in_frame_present_flag
        b.ue(0); // num_slice_groups_minus1
        b.ue(0); // num_ref_idx_l0_default_active_minus1
        b.ue(0); // num_ref_idx_l1_default_active_minus1
        b.put(0, 1); // weighted_pred_flag
        b.put(0, 2); // weighted_bipred_idc
        b.se(0); // pic_init_qp_minus26
        b.se(0); // pic_init_qs_minus26
        b.se(0); // chroma_qp_index_offset
        b.put(1, 1); // deblocking_filter_control_present_flag
        b.put(0, 1); // constrained_intra_pred_flag
        b.put(0, 1); // redundant_pic_cnt_present_flag
        if self.high() {
            b.put(1, 1); // transform_8x8_mode_flag
            b.put(0, 1); // pic_scaling_matrix_present_flag
            b.se(0); // second_chroma_qp_index_offset
        }
        nal(0x68, b.finish())
    }
}

/// An RBSP written MSB first, with H.264's Exp-Golomb codes.
#[derive(Default)]
pub(super) struct BitWriter {
    bytes: Vec<u8>,
    cur: u8,
    bits: u8,
}

impl BitWriter {
    pub(super) fn put(&mut self, value: u32, n: u8) {
        for i in (0..n).rev() {
            self.cur = (self.cur << 1) | ((value >> i) & 1) as u8;
            self.bits += 1;
            if self.bits == 8 {
                self.bytes.push(self.cur);
                self.cur = 0;
                self.bits = 0;
            }
        }
    }

    pub(super) fn ue(&mut self, value: u32) {
        let v = u64::from(value) + 1;
        let len = 64 - v.leading_zeros() as u8;
        self.put(0, len - 1);
        for i in (0..len).rev() {
            self.put(((v >> i) & 1) as u32, 1);
        }
    }

    pub(super) fn se(&mut self, value: i32) {
        let mapped = if value > 0 { 2 * value as u32 - 1 } else { 2 * value.unsigned_abs() };
        self.ue(mapped);
    }

    /// rbsp_trailing_bits, then the bytes.
    pub(super) fn finish(mut self) -> Vec<u8> {
        self.put(1, 1);
        while self.bits != 0 {
            self.put(0, 1);
        }
        self.bytes
    }
}

/// An Annex-B NAL unit: start code, header byte, RBSP with emulation prevention bytes.
pub(super) fn nal(header: u8, rbsp: Vec<u8>) -> Vec<u8> {
    let mut out = vec![0, 0, 0, 1, header];
    let mut zeros = 0;
    for byte in rbsp {
        if zeros >= 2 && byte <= 3 {
            out.push(3);
            zeros = 0;
        }
        zeros = if byte == 0 { zeros + 1 } else { 0 };
        out.push(byte);
    }
    out
}
