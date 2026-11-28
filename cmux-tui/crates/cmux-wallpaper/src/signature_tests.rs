use super::*;

fn ids() -> impl Iterator<Item = String> {
    (0..5000).map(|i| format!("{i:08x}-session-{}", i * 7919))
}

#[test]
fn particles_manifest_is_read() {
    let s = Signer::particles();
    assert_ne!(s, Signer::fallback(), "the particles manifest did not parse");
    let names: Vec<&str> = s.looks.iter().map(|l| l.name.as_str()).collect();
    assert_eq!(names, ["Dust", "Star field", "Nebula"]);
}

#[test]
fn the_same_id_gives_the_same_glyph() {
    let s = Signer::particles();
    for id in ids().take(200) {
        assert_eq!(s.glyph(&id), s.glyph(&id));
        assert_eq!(s.glyph(&id), glyph(&id));
    }
    assert_ne!(s.glyph("a"), s.glyph("b"));
}

#[test]
fn every_glyph_has_5_to_9_dots_inside_the_circle_none_overlapping() {
    let s = Signer::particles();
    let mut counts = [0usize; MAX_DOTS + 1];
    for id in ids().chain(["".to_owned(), "a".to_owned()]) {
        let g = s.glyph(&id);
        let n = g.dots.len();
        assert!((MIN_DOTS..=MAX_DOTS).contains(&n), "{id}: {n} dots");
        counts[n] += 1;
        assert!((0.0..1.0).contains(&g.seed));
        for (i, a) in g.dots.iter().enumerate() {
            assert!(
                (f64::from(MIN_RADIUS)..=f64::from(MAX_RADIUS)).contains(&a.r),
                "{id}: r {}",
                a.r
            );
            assert!((0.0..=1.0).contains(&a.phase));
            let (cx, cy) = (a.x - 0.5, a.y - 0.5);
            assert!(
                (cx * cx + cy * cy).sqrt() + a.r <= f64::from(DISK_RADIUS) + 1e-3,
                "{id}: dot {i} leaves the circle"
            );
            for b in &g.dots[i + 1..] {
                let d = ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt();
                assert!(d >= a.r + b.r, "{id}: dots overlap ({d} < {} + {})", a.r, b.r);
            }
        }
    }
    // Every count is used.
    assert!(counts[MIN_DOTS..].iter().all(|&c| c > 0), "{counts:?}");
}

#[test]
fn every_variant_is_used_and_drift_is_its_speed() {
    let s = Signer::particles();
    let mut seen = std::collections::BTreeMap::new();
    for id in ids().take(300) {
        let g = s.glyph(&id);
        seen.insert(g.variant.clone(), (g.accent.clone(), g.drift));
    }
    assert_eq!(seen.get("Dust"), Some(&("#3D7BFF".to_owned(), 1.0)));
    assert_eq!(seen.get("Star field"), Some(&("#E8A23A".to_owned(), 0.5)));
    assert_eq!(seen.get("Nebula"), Some(&("#D9576E".to_owned(), 0.6)));
}

#[test]
fn fnv1a64_matches_the_reference() {
    assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
    assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
    assert_eq!(fnv1a64(b"foobar"), 0x8594_4171_f739_67e8);
}

#[test]
fn the_wire_shape_is_camel_case() {
    let v = serde_json::to_value(glyph("a")).unwrap_or_default();
    let keys: Vec<&str> =
        v.as_object().map(|o| o.keys().map(String::as_str).collect()).unwrap_or_default();
    assert_eq!(keys, ["accent", "dots", "drift", "seed", "variant"]);
    let dot = &v["dots"][0];
    assert!(dot["x"].is_number() && dot["y"].is_number());
    assert!(dot["r"].is_number() && dot["phase"].is_number());
}

/// Golden output: a change here changes every agent's glyph.
#[test]
fn golden_glyphs() {
    let json = |id: &str| serde_json::to_string(&glyph(id)).unwrap_or_default();
    assert_eq!(json("a"), GOLDEN_A);
    assert_eq!(json("01a1f1fd-638f-73f4-b295-534adfe6d7cc"), GOLDEN_UUID);
    assert_eq!(json(""), GOLDEN_EMPTY);
}

const GOLDEN_A: &str = r##"{"seed":0.6851174831390381,"variant":"Star field","accent":"#E8A23A","drift":0.5,"dots":[{"x":0.3511,"y":0.6258,"r":0.0769,"phase":0.528},{"x":0.7586,"y":0.2812,"r":0.0767,"phase":0.4514},{"x":0.3571,"y":0.2144,"r":0.0763,"phase":0.2944},{"x":0.6771,"y":0.6403,"r":0.066,"phase":0.5226},{"x":0.178,"y":0.3906,"r":0.0651,"phase":0.0509},{"x":0.5965,"y":0.4377,"r":0.0611,"phase":0.4506},{"x":0.5632,"y":0.8389,"r":0.06,"phase":0.7871},{"x":0.512,"y":0.3012,"r":0.06,"phase":0.7711}]}"##;
const GOLDEN_UUID: &str = r##"{"seed":0.7347151041030884,"variant":"Dust","accent":"#3D7BFF","drift":1.0,"dots":[{"x":0.4713,"y":0.2333,"r":0.0972,"phase":0.6566},{"x":0.5687,"y":0.8012,"r":0.0914,"phase":0.3661},{"x":0.8202,"y":0.4426,"r":0.0907,"phase":0.1697},{"x":0.2177,"y":0.5977,"r":0.073,"phase":0.4664},{"x":0.1861,"y":0.3676,"r":0.0718,"phase":0.5878}]}"##;
const GOLDEN_EMPTY: &str = r##"{"seed":0.79667067527771,"variant":"Nebula","accent":"#D9576E","drift":0.6,"dots":[{"x":0.382,"y":0.5823,"r":0.1117,"phase":0.7917},{"x":0.8013,"y":0.4328,"r":0.0847,"phase":0.1762},{"x":0.4354,"y":0.2316,"r":0.0823,"phase":0.3682},{"x":0.6471,"y":0.8003,"r":0.0822,"phase":0.9274},{"x":0.2317,"y":0.3317,"r":0.0789,"phase":0.3291},{"x":0.5946,"y":0.3516,"r":0.0708,"phase":0.9626},{"x":0.7733,"y":0.6576,"r":0.065,"phase":0.5856},{"x":0.5992,"y":0.5845,"r":0.06,"phase":0.6022}]}"##;
