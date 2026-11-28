//! The scene's own cost per frame across a full 3,000-row fling (no GPU): the CPU half of THE number. A 120 Hz
//! frame is 8.33 ms; the scene's share must be a small part of it.
//!
//! `cargo bench -p cmux-native-transcript --bench scene_frame` prints one NATIVE_TRANSCRIPT_SCENE_JSON line.

use cmux_native_transcript::{Metrics, Quad, Scene};
use std::time::Instant;

fn main() {
    let rows = std::env::var("ROWS").ok().and_then(|v| v.parse().ok()).unwrap_or(3000u32);
    let t0 = Instant::now();
    let mut s = Scene::fixture(rows, 800.0, 900.0, Metrics::uniform()).expect("fixture");
    let layout_ms = t0.elapsed().as_secs_f64() * 1e3;
    let mut buf = vec![Quad::default(); 1 << 16];
    let mut build = Vec::new();
    let mut t = 0.0;
    let mut max_quads = 0;
    // Fling down the whole document and back up, the textures always ready (scene cost only).
    for dir in [1.0, -1.0] {
        let mut v = 30_000.0 * dir;
        loop {
            s.fling(v, t);
            let mut moved = 0;
            loop {
                t += 1.0 / 120.0;
                let fi = s.frame(t, &mut buf);
                for (id, _, _, _) in s.take_texture_requests(60, 64) {
                    s.texture_ready(id, true);
                }
                s.atlas().take(4096);
                s.atlas().ready();
                build.push(fi.build_us);
                max_quads = max_quads.max(fi.quads_needed);
                moved += 1;
                if !fi.flinging {
                    break;
                }
            }
            let at_end = if dir > 0.0 {
                s.offset() >= s.content_height() - 901.0
            } else {
                s.offset() <= 0.0
            };
            if at_end || moved == 0 {
                break;
            }
            v = 30_000.0 * dir;
        }
    }
    build.sort_by(f64::total_cmp);
    let p = |q: f64| build[((q * build.len() as f64) as usize).min(build.len() - 1)];
    println!(
        "NATIVE_TRANSCRIPT_SCENE_JSON {{\"rows\":{rows},\"layoutMs\":{layout_ms:.2},\"frames\":{},\"buildP50Us\":{:.1},\"buildP95Us\":{:.1},\"buildMaxUs\":{:.1},\"maxQuads\":{max_quads},\"glyphs\":{},\"lateTextures\":{}}}",
        build.len(),
        p(0.5),
        p(0.95),
        build[build.len() - 1],
        s.glyph_count(),
        s.record.late_textures,
    );
}
