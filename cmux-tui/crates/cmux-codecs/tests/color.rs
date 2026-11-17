//! Colour end to end (the HN thread "What every coder should know about gamma"): a known sRGB
//! test card goes through the host's real path on Linux (BGRX -> I420 with
//! `bgrx_rect_to_i420`, OpenH264's encoder), its SPS VUI is read back, it is decoded, and each
//! viewer's conversion turns it back into RGB:
//!
//! - the Rust viewers (`cmux-rd view`, `cmux-rd bench --present`): the shared
//!   `cmux_encode::color::i420_to_bgrx` with the matrix and range the stream's SPS tags;
//! - the Mac app's remote desktop pane (`MetalYUVRenderer.swift`): BT.709 always, video or
//!   full range from the decoded buffer's pixel format, modelled here in f32 as its shader.
//!
//! Every patch must come back within a few codes of the source on every channel. A matrix
//! mismatch (BT.601 in, BT.709 out) moves saturated red by tens of codes; a range mismatch
//! lifts or crushes black and white. `COLOR_DIFF_DIR=DIR` also writes `color-diff.png`
//! (rows: source, Rust viewer, Mac Metal viewer, a reader that ignores the tag and assumes
//! BT.601) and `color-diff.txt` there.

use cmux_codecs::{H264Decoder, open_encoder};
use cmux_encode::color::{self, Yuv};
use cmux_encode::{Codec, EncCfg, I420, VideoDecoder, bgrx_rect_to_i420};

const W: usize = 512;
const H: usize = 96;
const RAMP_ROWS: usize = 32;
const BT601: Yuv = Yuv { matrix: color::Matrix::Bt601, full_range: false };

const PATCHES: [(&str, [u8; 3]); 8] = [
    ("black 0", [0, 0, 0]),
    ("black 16", [16, 16, 16]),
    ("grey 128", [128, 128, 128]),
    ("white", [255, 255, 255]),
    ("red", [255, 0, 0]),
    ("green", [0, 255, 0]),
    ("blue", [0, 0, 255]),
    ("teal", [0, 128, 128]),
];

/// The card as RGB: a 0..255 grey ramp (2 px per level) over eight 64 x 64 patches.
fn card() -> Vec<[u8; 3]> {
    let mut px = vec![[0u8; 3]; W * H];
    for y in 0..H {
        for x in 0..W {
            px[y * W + x] = if y < RAMP_ROWS { [(x / 2) as u8; 3] } else { PATCHES[x / 64].1 };
        }
    }
    px
}

/// The Mac pane's shader (MetalYUVRenderer.swift `rv_fragment`), nearest chroma.
fn metal_bt709(pic: &I420, full_range: bool) -> Vec<[u8; 3]> {
    let cw = pic.width / 2;
    let mut out = Vec::with_capacity(W * H);
    for y in 0..H {
        for x in 0..W {
            let mut l = f32::from(pic.y[y * W + x]) / 255.0;
            let mut cb = f32::from(pic.u[(y / 2) * cw + x / 2]) / 255.0;
            let mut cr = f32::from(pic.v[(y / 2) * cw + x / 2]) / 255.0;
            if full_range {
                cb -= 0.5;
                cr -= 0.5;
            } else {
                l = (l - 16.0 / 255.0) * (255.0 / 219.0);
                cb = (cb - 128.0 / 255.0) * (255.0 / 224.0);
                cr = (cr - 128.0 / 255.0) * (255.0 / 224.0);
            }
            let rgb = [l + 1.5748 * cr, l - 0.1873 * cb - 0.4681 * cr, l + 1.8556 * cb];
            out.push(rgb.map(|c| (c.clamp(0.0, 1.0) * 255.0).round() as u8));
        }
    }
    out
}

fn rust_viewer(pic: &I420, yuv: Yuv) -> Vec<[u8; 3]> {
    let mut bgrx = vec![0u8; W * H * 4];
    color::i420_to_bgrx(&pic.y, &pic.u, &pic.v, (W, W / 2, W / 2), W, H, yuv, &mut bgrx);
    bgrx.chunks_exact(4).map(|p| [p[2], p[1], p[0]]).collect()
}

/// Per channel (max, mean) absolute error over `points`.
fn error(src: &[[u8; 3]], got: &[[u8; 3]], points: &[usize]) -> [(u8, f64); 3] {
    std::array::from_fn(|c| {
        let diffs = points.iter().map(|&i| src[i][c].abs_diff(got[i][c]));
        let max = diffs.clone().max().unwrap_or(0);
        let mean = diffs.map(f64::from).sum::<f64>() / points.len().max(1) as f64;
        (max, mean)
    })
}

/// Interior points of each region (8 px in from patch edges, away from chroma bleed and
/// block edges), the ramp first.
fn regions() -> Vec<(String, Vec<usize>)> {
    let mut out = Vec::new();
    let ramp: Vec<usize> = (0..256).map(|level| (RAMP_ROWS / 2) * W + level * 2).collect();
    out.push(("grey ramp 0..255".to_owned(), ramp));
    for (i, (name, _)) in PATCHES.iter().enumerate() {
        let pts = (RAMP_ROWS + 8..H - 8)
            .flat_map(|y| (i * 64 + 8..i * 64 + 56).map(move |x| y * W + x))
            .collect();
        out.push(((*name).to_owned(), pts));
    }
    out
}

fn encode_and_decode(src_bgrx: &[u8]) -> (Vec<u8>, I420, Yuv, I420) {
    let mut pic = I420::new(W, H);
    bgrx_rect_to_i420(src_bgrx, &mut pic, 0, 0, W, H, 1);
    let cfg = EncCfg {
        width: W as u32,
        height: H as u32,
        fps: 30,
        kbps: 20_000,
        threads: 1,
        screen_content: true,
    };
    let mut enc = open_encoder(Codec::H264, &cfg).expect("encoder").expect("h264 in build");
    let mut dec = H264Decoder::new().expect("decoder");
    let (mut au, mut out, mut first_au) = (Vec::new(), I420::new(W, H), Vec::new());
    let mut decoded = 0;
    // A still screen: rate control refines it over a few frames, as a host does.
    for i in 0..12 {
        enc.encode(&pic, i == 0, i * 33_333, &mut au).expect("encode");
        if au.is_empty() {
            continue;
        }
        if first_au.is_empty() {
            first_au = au.clone();
        }
        decoded += usize::from(dec.decode(&au, &mut out).expect("decode"));
    }
    assert!(decoded > 0, "no picture decoded");
    (first_au, pic, dec.color(), out)
}

#[test]
fn every_viewer_shows_the_hosts_colours() {
    let src = card();
    let src_bgrx: Vec<u8> = src.iter().flat_map(|p| [p[2], p[1], p[0], 0]).collect();
    let (first_au, host_pic, tagged, decoded) = encode_and_decode(&src_bgrx);
    let vui = color::sps_vui(&first_au).expect("the first access unit carries an SPS");

    let rows = [
        ("converter only, Rust viewer", rust_viewer(&host_pic, tagged)),
        ("converter only, Mac Metal", metal_bt709(&host_pic, vui.full_range)),
        ("H.264, Rust viewer", rust_viewer(&decoded, tagged)),
        ("H.264, Mac Metal", metal_bt709(&decoded, vui.full_range)),
        // Report only: a reader that ignores the tag and assumes BT.601 (what `cmux-rd view`
        // and `bench --present` did before they read the VUI), here and on a Mac host's stream.
        ("H.264, tag ignored, read as BT.601 (report only)", rust_viewer(&decoded, BT601)),
    ];
    let mut report = format!(
        "SPS VUI: colour_primaries={} transfer_characteristics={} matrix_coefficients={} video_full_range_flag={}\n\
         Rust viewer converts with {tagged:?}; Mac Metal pane with BT.709 always\n\
         per channel max / mean absolute error (R G B) against the sRGB source\n",
        vui.primaries,
        vui.transfer,
        vui.matrix,
        u8::from(vui.full_range)
    );
    let mut worst = Vec::new();
    for (path, got) in &rows {
        report.push_str(&format!("\n{path}\n"));
        for (name, pts) in regions() {
            let e = error(&src, got, &pts);
            report.push_str(&format!(
                "  {name:<18} R {:>3} / {:>5.2}   G {:>3} / {:>5.2}   B {:>3} / {:>5.2}\n",
                e[0].0, e[0].1, e[1].0, e[1].1, e[2].0, e[2].1
            ));
            if !path.ends_with("(report only)") {
                worst.push((path.to_string(), name, e.iter().map(|c| c.0).max().unwrap_or(0)));
            }
        }
    }
    println!("{report}");
    if let Some(dir) = std::env::var_os("COLOR_DIFF_DIR") {
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).expect("artifact dir");
        std::fs::write(dir.join("color-diff.txt"), &report).expect("report");
        let mut img = src.clone();
        img.extend(&rows[2].1);
        img.extend(&rows[3].1);
        img.extend(&rows[4].1);
        std::fs::write(dir.join("color-diff.png"), png(W, H * 4, &img)).expect("png");
    }

    assert_eq!(vui, color::SCREEN, "the SPS tags what the host converted");
    for (path, region, max) in worst {
        let bound = if path.starts_with("converter") { 2 } else { 6 };
        assert!(max <= bound, "{path}, {region}: {max} codes off (bound {bound})\n{report}");
    }
}

/// An RGB PNG (stored deflate blocks: no compression crate).
fn png(w: usize, h: usize, px: &[[u8; 3]]) -> Vec<u8> {
    fn crc(data: &[u8]) -> u32 {
        let mut c = !0u32;
        for &b in data {
            c ^= u32::from(b);
            for _ in 0..8 {
                c = if c & 1 == 1 { 0xedb8_8320 ^ (c >> 1) } else { c >> 1 };
            }
        }
        !c
    }
    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend((data.len() as u32).to_be_bytes());
        let mut body = kind.to_vec();
        body.extend(data);
        out.extend(&body);
        out.extend(crc(&body).to_be_bytes());
    }
    let mut raw = Vec::with_capacity(h * (1 + w * 3));
    for row in px.chunks(w) {
        raw.push(0);
        row.iter().for_each(|p| raw.extend(p));
    }
    let mut z = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = raw.chunks(65_535).collect();
    for (i, b) in blocks.iter().enumerate() {
        z.push(u8::from(i + 1 == blocks.len()));
        let n = b.len() as u16;
        z.extend(n.to_le_bytes());
        z.extend((!n).to_le_bytes());
        z.extend(*b);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for &x in &raw {
        a = (a + u32::from(x)) % 65_521;
        b = (b + a) % 65_521;
    }
    z.extend(((b << 16) | a).to_be_bytes());
    let mut out = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
    let mut ihdr = Vec::new();
    ihdr.extend((w as u32).to_be_bytes());
    ihdr.extend((h as u32).to_be_bytes());
    ihdr.extend([8, 2, 0, 0, 0]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    out
}
