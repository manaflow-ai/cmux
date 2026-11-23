//! Writes codec-bench's synthetic scenes as raw I420 (yuv420p), so another encoder (x264,
//! a hardware encoder) codes the very frames the OpenH264 rows code.
//!
//!     scene-dump SCENE FRAMES OUT.yuv [--size 1920x1080] [--seed 1]
use cmux_codecs::bench::scene::{Scene, SceneKind};
use std::io::Write;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let opt = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1));
    let kind = SceneKind::parse(args.get(1).ok_or("scene")?).ok_or("unknown scene")?;
    let frames: usize = args.get(2).ok_or("frames")?.parse()?;
    let out = args.get(3).ok_or("out")?;
    let (w, h) = opt("--size")
        .and_then(|s| s.split_once('x'))
        .map(|(w, h)| (w.parse().unwrap_or(1920), h.parse().unwrap_or(1080)))
        .unwrap_or((1920, 1080));
    let seed = opt("--seed").and_then(|s| s.parse().ok()).unwrap_or(1);
    let mut scene = Scene::new(kind, w, h, seed);
    let mut f = std::io::BufWriter::new(std::fs::File::create(out)?);
    for _ in 0..frames {
        let p = scene.picture();
        f.write_all(&p.y)?;
        f.write_all(&p.u)?;
        f.write_all(&p.v)?;
        scene.advance();
    }
    Ok(())
}
