//! `appearance.backgroundPlacement` (Leo, 2026-11-22: "we also want people to be able to
//! reposition the images easily"): each picture's mode, anchor and zoom. Unset keeps today's
//! centered fill. The app draws with mirrors of `cmux_config::backdrop_placement` (Swift
//! `BackdropPlacement`, web `backgroundPlacement.ts`); `fixtures/backdrop-placement-cases.json`
//! is the table all three check, written from the Rust math here.

use cmux_config::Domains;
use cmux_config::backdrop_placement::{
    Placement, Size, dragged, placement_key, placement_rect, visible,
};
use cmux_config::schema::{Kind, Schema, accepts};
use cmux_config::theme_file::is_look;
use serde_json::{Value, json};

const KEY: &str = "appearance.backgroundPlacement";
const FIXTURE: &str = "tests/fixtures/backdrop-placement-cases.json";

fn accepted(value: Value) -> bool {
    let schema = Schema::embedded();
    let row = schema.row(KEY).expect("appearance.backgroundPlacement is a row");
    accepts(row, &value, &Domains::default()).is_ok()
}

#[test]
fn the_placement_is_a_stored_map_with_no_default() {
    let schema = Schema::embedded();
    let row = schema.row(KEY).expect("appearance.backgroundPlacement is a row");
    assert_eq!(row.kind, Kind::StringMap);
    assert_eq!(row.default, None, "unset is today's centered fill");
    assert!(row.agent_settable, "settable like the other background keys");
    assert!(!is_look(row), "a theme file never carries where a person placed their own picture");
}

#[test]
fn the_setting_accepts_placements_and_refuses_the_rest() {
    assert!(accepted(json!({})));
    assert!(accepted(
        json!({ "munch-scream": "fit", "file:/Users/me/Harbor.png": "fill 0.2 0.8 1.5" })
    ));
    for bad in [
        json!("fit"),
        json!({ "munch-scream": "cover" }),
        json!({ "munch-scream": "fill 2 0" }),
        json!({ "a": 1 }),
    ] {
        assert!(!accepted(bad.clone()), "{bad} is refused");
    }
}

/// The shared cases: picture size, view size, placement text.
fn cases() -> Vec<(Size, Size, &'static str)> {
    let size = |width, height| Size { width, height };
    let mut out = Vec::new();
    for image in [size(2000.0, 1000.0), size(800.0, 1200.0), size(300.0, 200.0)] {
        for view in [size(400.0, 400.0), size(1440.0, 900.0), size(320.0, 700.0)] {
            for text in [
                "fill",
                "fit",
                "center",
                "stretch",
                "fill 0 0",
                "fill 1 1",
                "fill 0.25 0.75 2",
                "fit 0 1",
                "fit 0.5 0.5 3",
                "center 1 0",
                "stretch 0.5 0.5 1.5",
            ] {
                out.push((image, view, text));
            }
        }
    }
    // No area on either side: nothing is drawn and nothing shows.
    for (image, view) in
        [(size(0.0, 100.0), size(400.0, 400.0)), (size(300.0, 200.0), size(400.0, 0.0))]
    {
        out.push((image, view, "fill"));
        out.push((image, view, "fit 0 1"));
    }
    out
}

/// The shared drags: picture size, view size, placement text, pointer delta (right and down).
fn drags() -> Vec<(Size, Size, &'static str, f64, f64)> {
    let size = |width, height| Size { width, height };
    let wide = size(2000.0, 1000.0);
    let tall = size(800.0, 1200.0);
    let square = size(400.0, 400.0);
    vec![
        (wide, square, "fill", 100.0, 0.0),
        (wide, square, "fill", -100.0, 30.0),
        (wide, square, "fill", 10_000.0, 0.0),
        (wide, square, "fill 0.25 0.75 2", 50.0, -50.0),
        (wide, square, "fit", 0.0, 50.0),
        (wide, square, "fit", 30.0, 0.0),
        (tall, size(1440.0, 900.0), "fit 0 0.5", 200.0, 0.0),
        (tall, size(1440.0, 900.0), "center", -300.0, -300.0),
        (wide, size(0.0, 400.0), "fill", 100.0, 0.0),
    ]
}

/// The shared keys: a shown picture's id and the entry it reads (`null`: none).
const KEYS: &[(&str, Option<&str>)] = &[
    ("munch-scream", Some("munch-scream")),
    ("  munch-scream ", Some("munch-scream")),
    ("file:/Users/me/Harbor.png", Some("file:/Users/me/Harbor.png")),
    (
        "system:/System/Library/Desktop Pictures/Sonoma.heic",
        Some("system:/System/Library/Desktop Pictures/Sonoma.heic"),
    ),
    (
        "system:/System/Library/Desktop Pictures/Sonoma.heic|frame:3|dark",
        Some("system:/System/Library/Desktop Pictures/Sonoma.heic"),
    ),
    (
        "system:/System/Library/Desktop Pictures/Sonoma.heic|frame:12|light",
        Some("system:/System/Library/Desktop Pictures/Sonoma.heic"),
    ),
    ("system:/odd|frame:x|dark", Some("system:/odd|frame:x|dark")),
    ("desktop", Some("desktop")),
    ("appearance:munch-scream|file:/Users/me/Harbor.png", None),
    ("appearance", None),
    ("schedule", None),
    ("daily", None),
    ("folder:/Users/me/Pictures", None),
    ("none", None),
    ("", None),
    ("\n", None),
];

fn round(v: f64) -> f64 {
    (v * 1e6).round() / 1e6
}

fn table() -> Value {
    let rows: Vec<Value> = cases()
        .into_iter()
        .map(|(image, view, text)| {
            let placement = Placement::parse(text).expect("case parses");
            let rect = placement_rect(image, view, &placement);
            let shown = visible(image, view, &placement);
            json!({
                "image": [image.width, image.height],
                "view": [view.width, view.height],
                "placement": text,
                "rect": rect.map(|r| json!([round(r.x), round(r.y), round(r.width), round(r.height)])),
                "frame": shown.map(|v| json!([round(v.frame.x), round(v.frame.y), round(v.frame.width), round(v.frame.height)])),
                "contents": shown.map(|v| json!([round(v.contents.x), round(v.contents.y), round(v.contents.width), round(v.contents.height)])),
            })
        })
        .collect();
    json!({
        "about": "Written by cmux-config tests/background_placement.rs (CMUX_UPDATE_FIXTURES=1); Swift BackdropPlacementTests and web backgroundPlacement.test.ts check their mirrors against it. Rects: top-left origin, points; contents: unit rect of the picture; null: nothing drawn or shown. drags: the placement after the pointer moves by delta (right and down). keys: the appearance.backgroundPlacement entry a shown picture id reads (null: none).",
        "cases": rows,
        "drags": drags().into_iter().map(|(image, view, text, dx, dy)| {
            let placement = Placement::parse(text).expect("drag parses");
            json!({
                "image": [image.width, image.height],
                "view": [view.width, view.height],
                "placement": text,
                "delta": [dx, dy],
                "after": dragged(image, view, &placement, dx, dy).to_text(),
            })
        }).collect::<Vec<_>>(),
        "keys": KEYS.iter().map(|(id, key)| json!({ "id": id, "key": key })).collect::<Vec<_>>(),
    })
}

#[test]
fn the_shared_table_is_the_rust_math() {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(FIXTURE);
    let want = serde_json::to_string_pretty(&table()).expect("table serializes") + "\n";
    if std::env::var_os("CMUX_UPDATE_FIXTURES").is_some() {
        std::fs::create_dir_all(path.parent().expect("fixture dir")).expect("fixture dir");
        std::fs::write(&path, &want).expect("fixture written");
    }
    let have = std::fs::read_to_string(&path).unwrap_or_default();
    assert_eq!(
        have, want,
        "run CMUX_UPDATE_FIXTURES=1 cargo test -p cmux-config --test background_placement"
    );
}

#[test]
fn a_moment_keys_its_file_and_a_pair_keys_nothing() {
    for (id, key) in KEYS {
        assert_eq!(placement_key(id), *key, "{id:?}");
    }
}
