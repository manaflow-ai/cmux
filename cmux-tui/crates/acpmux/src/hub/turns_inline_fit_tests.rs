//! A picture the composer pastes goes at its own size, and what is written to the agent
//! (`turns::agent_blocks`) is scaled to the model in linear light (`model_copies::fit_inline`):
//! Leo, "What every coder should know about gamma"; claude-sr2-coord, 2026-11-17: "Composer
//! image fit: do it in Rust, not JS". Before, the page's canvas scaled it in sRGB, and a 1 px
//! black and white checkerboard reached the agent as 127 grey where its light is 188.

use super::*;
use base64::Engine as _;

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let argv = ["/usr/bin/env", "python3", fake];
    let cfg = json!({"harnesses": {"fake": {"argv": argv}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// An `n`x`n` grey PNG of a 1 px black and white checkerboard, as the composer now sends it.
fn checkerboard(n: u32) -> String {
    let data: Vec<u8> =
        (0..n * n).map(|i| if (i % n + i / n) % 2 == 0 { 255 } else { 0 }).collect();
    let mut out = Vec::new();
    let mut e = png::Encoder::new(&mut out, n, n);
    e.set_color(png::ColorType::Grayscale);
    e.set_depth(png::BitDepth::Eight);
    e.write_header().unwrap().write_image_data(&data).unwrap();
    base64::engine::general_purpose::STANDARD.encode(out)
}

fn decode(data: &str) -> (u32, u32, Vec<u8>) {
    let bytes = base64::engine::general_purpose::STANDARD.decode(data).unwrap();
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_transformations(png::Transformations::EXPAND);
    let mut reader = decoder.read_info().unwrap();
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).unwrap();
    buf.truncate(info.buffer_size());
    (info.width, info.height, buf)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pasted_checkerboard_reaches_the_agent_at_half_its_light() {
    let (hub, session) = chat().await;
    let blocks = vec![
        json!({"type": "text", "text": "what grey is this?"}),
        json!({"type": "image", "mimeType": "image/png", "name": "checker.png",
               "data": checkerboard(3136)}),
    ];
    let written = super::turns::agent_blocks(&hub, &session, &blocks).await.unwrap();
    let image = written.iter().find(|b| b["type"] == "image").expect("the image reaches the agent");
    let (w, h, px) = decode(image["data"].as_str().unwrap());
    assert_eq!((w, h), (1568, 1568), "the agent gets it at the model's edge");
    let mean = px.iter().map(|v| f64::from(*v)).sum::<f64>() / px.len() as f64;
    println!("checkerboard 3136 -> {w}x{h}: mean code {mean:.1} (sRGB average 127.5, light 188)");
    let off: Vec<u8> = px.iter().copied().filter(|v| !(187..=188).contains(v)).take(4).collect();
    assert!(off.is_empty(), "not half the light (188): {off:?}, mean {mean:.1}");
}
