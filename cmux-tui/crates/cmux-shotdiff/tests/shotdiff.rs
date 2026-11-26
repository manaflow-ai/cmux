use cmux_shotdiff::store::{Status, collect_pngs};
use cmux_shotdiff::{
    BatchOptions, Mask, Region, Rgba, Spec, Store, batch, compare, decode_png, encode_png,
};
use std::path::PathBuf;

fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-shotdiff-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A UI-ish picture: a sidebar, a title bar, text-like stripes.
fn screen(w: u32, h: u32) -> Rgba {
    let mut img = Rgba::new(w, h, [246, 246, 248, 255]);
    for y in 0..h {
        for x in 0..w.min(60) {
            img.set(x, y, [228, 230, 236, 255]);
        }
    }
    for y in 0..20.min(h) {
        for x in 0..w {
            img.set(x, y, [210, 212, 220, 255]);
        }
    }
    for row in 0..((h.saturating_sub(30)) / 12) {
        let y0 = 30 + row * 12;
        for y in y0..(y0 + 6).min(h) {
            for x in 70..w.saturating_sub(10) {
                if (x / 3 + row) % 5 != 0 {
                    img.set(x, y, [40, 40, 48, 255]);
                }
            }
        }
    }
    img
}

fn paint(img: &mut Rgba, x0: u32, y0: u32, w: u32, h: u32, p: [u8; 4]) {
    for y in y0..y0 + h {
        for x in x0..x0 + w {
            img.set(x, y, p);
        }
    }
}

#[test]
fn identical_images_pass_with_ssim_one() {
    let a = screen(200, 150);
    let v = compare(&a, &a.clone(), &Spec::default()).verdict;
    assert!(v.pass && v.identical);
    assert_eq!(v.changed_pixels, 0);
    assert_eq!(v.ssim, 1.0);
    assert!(v.boxes.is_empty());
}

#[test]
fn small_channel_noise_under_tolerance_passes() {
    let a = screen(200, 150);
    let mut b = a.clone();
    for i in (0..b.data.len()).step_by(4) {
        b.data[i] = b.data[i].saturating_add(((i / 4) % 7) as u8);
    }
    let v = compare(&a, &b, &Spec::default()).verdict;
    assert!(!v.identical);
    assert_eq!(v.changed_pixels, 0);
    assert!(v.pass, "{:?}", v.reasons);
}

#[test]
fn moved_block_fails_and_is_boxed() {
    let a = screen(200, 150);
    let mut b = a.clone();
    paint(&mut b, 100, 60, 40, 30, [0, 120, 255, 255]);
    let v = compare(&a, &b, &Spec::default()).verdict;
    assert!(!v.pass);
    assert_eq!(v.changed_pixels, 1200);
    assert!(v.reasons.iter().any(|r| r.starts_with("changed_ratio")));
    assert_eq!(v.boxes.len(), 1);
    let bx = v.boxes[0];
    assert!(bx.x <= 100 && bx.y <= 60 && bx.x + bx.w >= 140 && bx.y + bx.h >= 90);
}

#[test]
fn ignore_mask_hides_the_clock() {
    let a = screen(200, 150);
    let mut b = a.clone();
    paint(&mut b, 150, 2, 40, 14, [0, 0, 0, 255]);
    let spec = Spec {
        ignore: vec![Mask { x: 148, y: 0, w: 52, h: 20, why: "clock".into() }],
        ..Spec::default()
    };
    let v = compare(&a, &b, &spec).verdict;
    assert!(v.pass, "{:?}", v.reasons);
    assert_eq!(v.changed_pixels, 0);
    assert_eq!(v.ignored_pixels, 52 * 20);
    assert!(!compare(&a, &b, &Spec { max_changed_ratio: 0.001, ..Spec::default() }).verdict.pass);
}

#[test]
fn scale_maps_points_to_pixels() {
    let a = screen(200, 150);
    let mut b = a.clone();
    paint(&mut b, 150, 2, 40, 14, [0, 0, 0, 255]);
    let spec = Spec {
        scale: 2,
        ignore: vec![Mask { x: 74, y: 0, w: 26, h: 10, why: "clock, in points".into() }],
        ..Spec::default()
    };
    assert!(compare(&a, &b, &spec).verdict.pass);
}

#[test]
fn strict_region_fails_where_global_passes() {
    let a = screen(400, 300);
    let mut b = a.clone();
    paint(&mut b, 10, 100, 12, 12, [255, 0, 0, 255]);
    let loose = Spec { max_changed_ratio: 0.05, min_ssim: 0.9, ..Spec::default() };
    assert!(compare(&a, &b, &loose).verdict.pass);
    let spec = Spec {
        regions: vec![Region {
            name: "sidebar".into(),
            x: 0,
            y: 0,
            w: 60,
            h: 300,
            channel_tolerance: None,
            max_changed_ratio: Some(0.0),
            min_ssim: Some(0.999),
        }],
        ..loose
    };
    let v = compare(&a, &b, &spec).verdict;
    assert!(!v.pass);
    assert_eq!(v.regions.len(), 1);
    assert!(!v.regions[0].pass);
    assert_eq!(v.regions[0].changed_pixels, 144);
    assert!(v.reasons.iter().all(|r| r.starts_with("region sidebar")));
}

#[test]
fn region_tolerance_overrides_global() {
    let a = screen(200, 150);
    let mut b = a.clone();
    for y in 30..150 {
        for x in 0..60 {
            let p = b.pixel(x, y);
            b.set(x, y, [p[0] - 24, p[1] - 24, p[2] - 24, 255]);
        }
    }
    let base = Spec { min_ssim: 0.0, max_changed_ratio: 0.0, ..Spec::default() };
    assert!(!compare(&a, &b, &base).verdict.pass);
    let spec = Spec {
        regions: vec![Region {
            name: "glass".into(),
            x: 0,
            y: 0,
            w: 60,
            h: 150,
            channel_tolerance: Some(32),
            max_changed_ratio: None,
            min_ssim: None,
        }],
        ..base
    };
    assert!(compare(&a, &b, &spec).verdict.pass);
}

#[test]
fn ssim_catches_structure_the_pixel_ratio_misses() {
    // Text shifted by one pixel: few pixels pass tolerance changes at a loose ratio, SSIM drops.
    let a = screen(300, 200);
    let mut b = Rgba::new(300, 200, [246, 246, 248, 255]);
    for y in 0..200 {
        for x in 0..300 {
            b.set(x, y, a.pixel(if x >= 70 { x - 1 } else { x }, y));
        }
    }
    let v = compare(&a, &b, &Spec { max_changed_ratio: 1.0, ..Spec::default() }).verdict;
    assert!(v.ssim < 0.98, "ssim {}", v.ssim);
    assert!(!v.pass);
}

#[test]
fn size_mismatch_fails_without_diff() {
    let c = compare(&screen(200, 150), &screen(200, 151), &Spec::default());
    assert!(!c.verdict.pass);
    assert!(c.verdict.reasons[0].starts_with("size:"));
    assert!(c.diff_image.is_none());
}

#[test]
fn deterministic_verdict_and_diff_bytes() {
    let a = screen(257, 129);
    let mut b = a.clone();
    paint(&mut b, 33, 40, 70, 9, [10, 200, 30, 255]);
    let one = compare(&a, &b, &Spec::default());
    let two = compare(&a, &b, &Spec::default());
    assert_eq!(
        serde_json::to_string(&one.verdict).unwrap(),
        serde_json::to_string(&two.verdict).unwrap()
    );
    let d1 = encode_png(one.diff_image.as_ref().unwrap()).unwrap();
    let d2 = encode_png(two.diff_image.as_ref().unwrap()).unwrap();
    assert_eq!(d1, d2);
    assert_eq!(decode_png(&d1).unwrap(), *one.diff_image.as_ref().unwrap());
}

#[test]
fn content_hash_ignores_encoding() {
    let a = screen(64, 48);
    let rgba_png = encode_png(&a).unwrap();
    let mut rgb = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut rgb, 64, 48);
        enc.set_color(png::ColorType::Rgb);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Best);
        let mut w = enc.write_header().unwrap();
        let data: Vec<u8> = a.data.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
        w.write_image_data(&data).unwrap();
    }
    assert_ne!(rgba_png, rgb);
    assert_eq!(
        decode_png(&rgba_png).unwrap().content_hash(),
        decode_png(&rgb).unwrap().content_hash()
    );
    assert_eq!(a.content_hash().len(), 64);
}

#[test]
fn spec_json_round_trip_and_validation() {
    let spec: Spec = serde_json::from_str(
        r#"{"min_ssim":0.95,"ignore":[{"x":1,"y":2,"w":3,"h":4,"why":"caret"}],
            "regions":[{"name":"tabs","x":0,"y":0,"w":10,"h":10,"max_changed_ratio":0}]}"#,
    )
    .unwrap();
    assert_eq!(spec.channel_tolerance, 16);
    assert_eq!(spec.min_ssim, 0.95);
    assert!(spec.validate().is_ok());
    assert!(serde_json::from_str::<Spec>(r#"{"min_sim":0.9}"#).is_err(), "typos are refused");
    let no_why: Spec =
        serde_json::from_str(r#"{"ignore":[{"x":0,"y":0,"w":1,"h":1,"why":" "}]}"#).unwrap();
    assert!(no_why.validate().is_err());
}

#[test]
fn store_bless_check_and_batch() {
    let root = scratch("store");
    let st = Store::open(root.join("goldens"));
    let home = screen(120, 90);
    let mut sheet = screen(120, 90);
    paint(&mut sheet, 20, 20, 30, 30, [90, 90, 200, 255]);
    st.bless("ios/home/light", &home, None).unwrap();
    let g = st.bless("ios/sheet", &sheet, None).unwrap();
    st.bless("ios/gone", &home, None).unwrap();
    // Same pixels: one object.
    let objects = collect_pngs(&root.join("goldens/objects")).unwrap();
    assert_eq!(objects.len(), 2);
    assert_eq!(st.get(&g.hash).unwrap(), sheet);

    let heads = root.join("heads");
    std::fs::create_dir_all(heads.join("ios/home")).unwrap();
    std::fs::write(heads.join("ios/home/light.png"), encode_png(&home).unwrap()).unwrap();
    let mut changed = sheet.clone();
    paint(&mut changed, 60, 40, 40, 40, [255, 0, 0, 255]);
    std::fs::write(heads.join("ios/sheet.png"), encode_png(&changed).unwrap()).unwrap();
    std::fs::write(heads.join("ios/new.png"), encode_png(&home).unwrap()).unwrap();

    let out = root.join("out");
    let report = batch(&st, &heads, Some(&out), BatchOptions::default()).unwrap();
    let status: Vec<(&str, Status)> =
        report.entries.iter().map(|e| (e.name.as_str(), e.status)).collect();
    assert_eq!(
        status,
        vec![
            ("ios/gone", Status::Missing),
            ("ios/home/light", Status::Identical),
            ("ios/new", Status::New),
            ("ios/sheet", Status::Fail),
        ]
    );
    assert!(!report.pass);
    assert!(out.join("report.json").exists());
    assert!(out.join("diff/ios/sheet.png").exists());
    assert!(!out.join("diff/ios/home/light.png").exists());
    let md = cmux_shotdiff::store::markdown(&report, "t");
    assert!(md.contains("`ios/sheet` | fail"));

    // Re-bless the sheet; a per-golden spec survives a later bless without one.
    let loose = Spec { max_changed_ratio: 1.0, min_ssim: 0.0, ..Spec::default() };
    st.bless("ios/sheet", &sheet, Some(loose.clone())).unwrap();
    st.bless("ios/sheet", &sheet, None).unwrap();
    assert_eq!(st.manifest().unwrap().goldens["ios/sheet"].spec, Some(loose));
    let report =
        batch(&st, &heads, None, BatchOptions { allow_new: true, require_all: false }).unwrap();
    assert!(report.pass, "{:?}", report.counts);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn bad_names_are_refused() {
    let root = scratch("names");
    let st = Store::open(&root);
    let img = screen(8, 8);
    for bad in ["", "../x", "a//b", "a/./b", "a b"] {
        assert!(st.bless(bad, &img, None).is_err(), "{bad:?}");
    }
    let _ = std::fs::remove_dir_all(&root);
}
