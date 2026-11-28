use super::*;
use std::mem::{offset_of, size_of};

fn scene() -> Scene {
    Scene::fixture(3000, 800.0, 900.0, Metrics::uniform()).expect("fixture")
}

#[test]
fn quad_is_48_bytes_for_the_instance_buffer() {
    assert_eq!(size_of::<Quad>(), 48);
    assert_eq!(offset_of!(Quad, color), 32);
    assert_eq!(offset_of!(Quad, texture_id), 40);
}

#[test]
fn metrics_match_the_header_layout() {
    // 95 advances + 8 floats + 1 u32.
    assert_eq!(size_of::<Metrics>(), (95 + 8 + 1) * 4);
    assert_eq!(offset_of!(Metrics, atlas_px), (95 + 8) * 4);
}

#[test]
fn fixture_mix_is_stable() {
    let rows = fixture::fixture(3000);
    assert_eq!(rows.len(), 3000);
    let rich = rows.iter().filter(|r| matches!(r, RowSource::Rich { .. })).count();
    assert_eq!(rich, 300);
    assert!(rows.iter().any(|r| matches!(r, RowSource::Code(_))));
    assert_eq!(rows, fixture::fixture(3000), "same seed, same document");
}

#[test]
fn bad_metrics_or_size_make_no_scene() {
    let mut m = Metrics::uniform();
    m.line_height = 0.0;
    assert!(Scene::fixture(10, 800.0, 600.0, m).is_none());
    assert!(Scene::fixture(10, f32::NAN, 600.0, Metrics::uniform()).is_none());
}

#[test]
fn frame_draws_only_the_viewport() {
    let mut s = scene();
    let mut buf = vec![Quad::default(); 1 << 16];
    let top = s.frame(0.0, &mut buf);
    assert_eq!(top.first_row, 0);
    assert!(top.last_row < 100, "a 900 pt viewport shows a few dozen rows, got {}", top.last_row);
    assert!(top.quads > 0 && top.quads == top.quads_needed);
    for q in &buf[..top.quads as usize] {
        assert!(q.y < 900.0 && q.y + q.h > 0.0, "quad off screen: {q:?}");
    }
    s.scroll_to(f64::MAX);
    let end = s.frame(0.0, &mut buf);
    assert_eq!(end.last_row, 2999);
    assert!((end.offset - (s.content_height() - 900.0)).abs() < 1e-6);
}

#[test]
fn short_buffer_reports_what_it_needed() {
    let mut s = scene();
    let mut buf = vec![Quad::default(); 10];
    let fi = s.frame(0.0, &mut buf);
    assert_eq!(fi.quads, 10);
    assert!(fi.quads_needed > 10);
}

#[test]
fn rich_rows_are_late_until_their_texture_is_ready_and_prefetch_covers_a_fling() {
    let mut s = scene();
    let mut buf = vec![Quad::default(); 1 << 16];
    let fi = s.frame(0.0, &mut buf);
    assert!(fi.late_textures > 0, "rich rows on the first screen have no texture yet");
    let reqs = s.take_texture_requests(60, 1000);
    assert!(reqs.iter().all(|r| r.1 % 10 == 9));
    for r in &reqs {
        s.texture_ready(r.0, true);
    }
    assert!(s.take_texture_requests(60, 1000).is_empty(), "asked once");
    let fi = s.frame(0.0, &mut buf);
    assert_eq!(fi.late_textures, 0);
    let tex = buf[..fi.quads as usize]
        .iter()
        .find(|q| q.kind == QUAD_TEXTURE)
        .expect("a rich row on screen");
    assert!(tex.v0 >= 0.0 && tex.v1 <= 1.0 && tex.v0 < tex.v1);
    // Released: asked again.
    s.texture_ready(reqs[0].0, false);
    assert_eq!(s.take_texture_requests(60, 1000).len(), 1);
}

#[test]
fn glyphs_are_queued_once_and_ready_after_the_app_fills_them() {
    let mut s = scene();
    let mut buf = vec![Quad::default(); 1 << 16];
    s.frame(0.0, &mut buf);
    let first = s.atlas().take(10_000);
    assert!(!first.is_empty() && first.len() < 200, "ASCII prose and code: {} glyphs", first.len());
    s.frame(0.0, &mut buf);
    assert!(s.atlas().take(10_000).is_empty(), "no glyph queued twice");
    s.atlas().ready();
    assert_eq!(s.atlas().placed(), first.len());
    let glyph = buf.iter().find(|q| q.kind == QUAD_GLYPH).expect("a glyph");
    assert!(glyph.u1 > glyph.u0 && glyph.u1 <= 1.0);
}

#[test]
fn fling_moves_decays_and_records_intervals() {
    let mut s = scene();
    let mut buf = vec![Quad::default(); 1 << 16];
    s.fling(8000.0, 0.0);
    let mut t = 0.0;
    let mut last = 0.0;
    let mut frames = 0;
    loop {
        t += 1.0 / 120.0;
        let fi = s.frame(t, &mut buf);
        assert!(fi.offset >= last, "a downward fling never moves up");
        last = fi.offset;
        frames += 1;
        if !fi.flinging || frames > 2000 {
            break;
        }
    }
    assert!(last > 2000.0 && last < 8000.0 * fling::TAU + 1.0, "travel {last}");
    let iv = s.record.intervals();
    assert!((iv.p95 - 1000.0 / 120.0).abs() < 0.01, "{iv:?}");
    assert_eq!(s.record.intervals_missed, 0);
    s.scroll_to(0.0);
    s.fling(-5000.0, t);
    let fi = s.frame(t + 0.5, &mut buf);
    assert_eq!(fi.offset, 0.0);
    assert!(!fi.flinging, "a fling into the top edge stops");
}

#[test]
fn missed_frames_are_counted() {
    let mut s = scene();
    let mut buf = vec![Quad::default(); 4096];
    s.fling(8000.0, 0.0);
    for t in [0.008, 0.016, 0.050, 0.058] {
        s.frame(t, &mut buf);
    }
    assert_eq!(s.record.intervals_missed, 1);
}

#[test]
fn width_change_relayouts_and_keeps_the_top_row() {
    let mut s = scene();
    let mut buf = vec![Quad::default(); 1 << 16];
    s.scroll_to(50_000.0);
    let before = s.frame(0.0, &mut buf).first_row;
    let h = s.content_height();
    s.set_viewport(400.0, 900.0);
    assert!(s.content_height() > h, "narrower wraps taller");
    let after = s.frame(0.0, &mut buf).first_row;
    assert_eq!(before, after);
}

#[test]
fn ffi_round_trip() {
    let m = Metrics::uniform();
    // SAFETY: the pointers below are live for each call.
    unsafe {
        let s = ffi::cmux_nt_scene_new_fixture(3000, 800.0, 900.0, &m);
        assert!(!s.is_null());
        let mut quads = vec![Quad::default(); 8192];
        let mut info = ffi::CmuxNtFrameInfo::default();
        ffi::cmux_nt_fling(s, 6000.0, 0.0);
        let n = ffi::cmux_nt_frame(s, 0.008, quads.as_mut_ptr(), quads.len() as u32, &mut info);
        assert_eq!(n, info.quads);
        let mut rr = vec![ffi::CmuxNtRasterRequest::default(); 512];
        assert!(ffi::cmux_nt_take_raster_requests(s, rr.as_mut_ptr(), 512) > 0);
        ffi::cmux_nt_glyphs_ready(s);
        let mut tr = vec![ffi::CmuxNtTextureRequest::default(); 64];
        let k = ffi::cmux_nt_take_texture_requests(s, 30, tr.as_mut_ptr(), 64);
        assert!(k > 0);
        ffi::cmux_nt_texture_ready(s, tr[0].texture_id, true);
        let mut st = ffi::CmuxNtStats::default();
        ffi::cmux_nt_stats(s, &mut st);
        assert_eq!(st.frames, 1);
        ffi::cmux_nt_stats_reset(s);
        ffi::cmux_nt_stats(s, &mut st);
        assert_eq!(st.frames, 0);
        assert_eq!(
            ffi::cmux_nt_frame(std::ptr::null_mut(), 0.0, quads.as_mut_ptr(), 1, &mut info),
            0
        );
        ffi::cmux_nt_scene_free(s);
        assert!(ffi::cmux_nt_scene_new_fixture(10, 800.0, 900.0, std::ptr::null()).is_null());
    }
}
