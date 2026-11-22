/* Minimal low-latency x264 wrapper for rdhost (optional `x264` cargo feature).
 * zerolatency tune: no B-frames, no lookahead, sliced threads; infinite GOP, no scenecut,
 * IDR only on the first frame and on request, SPS/PPS repeated before every IDR, Annex-B. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <x264.h>

typedef struct {
    x264_t *enc;
    x264_picture_t in;
    x264_picture_t out;
} rd_x264;

const char *rd_x264_build(void) {
    static char buf[32];
    snprintf(buf, sizeof buf, "x264 core %d", X264_BUILD);
    return buf;
}

/* rc: qp >= 0 selects constant QP; otherwise ABR at bitrate_kbps with a one-frame VBV. */
rd_x264 *rd_x264_open(int w, int h, int fps, int qp, int bitrate_kbps, int threads, const char *preset, const char *profile) {
    x264_param_t p;
    if (x264_param_default_preset(&p, preset, "zerolatency") < 0) return NULL;
    p.i_log_level = X264_LOG_NONE;
    p.i_width = w;
    p.i_height = h;
    p.i_csp = X264_CSP_I420;
    p.i_fps_num = fps > 0 ? fps : 60;
    p.i_fps_den = 1;
    p.b_vfr_input = 0;
    p.i_keyint_max = X264_KEYINT_MAX_INFINITE;
    p.i_keyint_min = X264_KEYINT_MAX_INFINITE;
    p.i_scenecut_threshold = 0;
    p.b_intra_refresh = 0;
    p.i_bframe = 0;
    p.rc.i_lookahead = 0;
    p.rc.b_mb_tree = 0;
    p.i_sync_lookahead = 0;
    p.i_threads = threads > 0 ? threads : 1;
    p.b_sliced_threads = 1;
    p.b_repeat_headers = 1;
    p.b_annexb = 1;
    p.b_aud = 0;
    p.vui.b_fullrange = 0;
    if (qp >= 0) {
        p.rc.i_rc_method = X264_RC_CQP;
        p.rc.i_qp_constant = qp;
    } else {
        p.rc.i_rc_method = X264_RC_ABR;
        p.rc.i_bitrate = bitrate_kbps;
        p.rc.i_vbv_max_bitrate = bitrate_kbps;
        p.rc.i_vbv_buffer_size = bitrate_kbps / (fps > 0 ? fps : 60) + 1;
    }
    if (x264_param_apply_profile(&p, profile) < 0) return NULL;
    rd_x264 *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->enc = x264_encoder_open(&p);
    if (!r->enc) {
        free(r);
        return NULL;
    }
    x264_picture_init(&r->in);
    r->in.img.i_csp = X264_CSP_I420;
    r->in.img.i_plane = 3;
    return r;
}

/* Encodes one picture. Returns the access unit size (0 if none, < 0 on error); *out points
 * into encoder-owned memory valid until the next call. */
int rd_x264_encode(rd_x264 *r, uint8_t *y, uint8_t *u, uint8_t *v, int ystride, int cstride, int force_idr,
                   int64_t pts, const uint8_t **out, int *is_idr) {
    x264_nal_t *nals = NULL;
    int n = 0;
    r->in.img.plane[0] = y;
    r->in.img.plane[1] = u;
    r->in.img.plane[2] = v;
    r->in.img.i_stride[0] = ystride;
    r->in.img.i_stride[1] = cstride;
    r->in.img.i_stride[2] = cstride;
    r->in.i_type = force_idr ? X264_TYPE_IDR : X264_TYPE_AUTO;
    r->in.i_pts = pts;
    int size = x264_encoder_encode(r->enc, &nals, &n, &r->in, &r->out);
    if (size <= 0 || n <= 0) {
        *out = NULL;
        *is_idr = 0;
        return size < 0 ? -1 : 0;
    }
    /* NAL payloads are contiguous in x264's output buffer. */
    *out = nals[0].p_payload;
    *is_idr = r->out.b_keyframe;
    return size;
}

void rd_x264_close(rd_x264 *r) {
    if (!r) return;
    x264_encoder_close(r->enc);
    free(r);
}
