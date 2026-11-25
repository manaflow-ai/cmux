use super::*;
use serde_json::json;

fn frame(time: f32) -> FrameInput {
    FrameInput {
        time,
        width: 1000.0,
        height: 500.0,
        backing_scale: 1.0,
        ink: [0.0; 3],
        paper: [1.0; 3],
        accent: [1.0, 0.0, 0.0],
        presence: 1.0,
        ..FrameInput::default()
    }
}

fn row(out: &[f32; SCENE_FLOATS], r: usize) -> [f32; 4] {
    [out[r * 4], out[r * 4 + 1], out[r * 4 + 2], out[r * 4 + 3]]
}

fn sample() -> Value {
    json!({
        "loop": 4,
        "field": {
            "points": [
                { "at": [0, 0], "color": "#FF0000" },
                { "at": [1, 0], "color": "paper" },
                { "at": [1, 1], "color": "accent 50% paper" },
                { "at": [0, 1], "color": "ink", "radius": 0.5 }
            ],
            "warp": 0.2
        },
        "grain": { "amount": 0.1 },
        "light": { "at": [0.5, 0.5], "intensity": 0.6 },
        "shapes": [
            { "kind": "circle", "at": { "keys": [[0, [0.25, 0.5]], [2, [0.75, 0.5], "inOut"]] }, "size": [0.4, 0.4],
              "fill": { "type": "linear", "from": "#FFFFFF", "to": "accent", "angle": 90 } },
            { "kind": "cube", "size": [0.3, 0.3], "rotate": 30, "lit": 1, "shape": 0.6, "fill": "paper" }
        ],
        "guides": [ { "from": [0, 0.5], "to": [1, 0.5], "handles": true, "color": "accent" } ]
    })
}

#[test]
fn the_block_is_2048_bytes_and_the_prelude_says_so() {
    assert_eq!(SCENE_BYTES, 2048);
    let prelude = include_str!("../scene_prelude.wgsl");
    assert!(prelude.contains(&format!("array<vec4<f32>, {SCENE_ROWS}>")));
    // The layout's last block ends at the last row.
    assert_eq!(ROW_IMAGE + 2, SCENE_ROWS);
    assert_eq!(ROW_SHAPES + SHAPE_ROWS * MAX_SHAPES, ROW_GUIDES);
    assert_eq!(ROW_GUIDES + GUIDE_ROWS * MAX_GUIDES, ROW_ROPE_POINTS);
    assert_eq!(ROW_ROPE_POINTS + MAX_ROPE_POINTS / 2, ROW_ROPES);
}

#[test]
fn packs_the_sample_in_place() {
    let scene = Scene::from_value(&sample()).unwrap();
    assert!(scene.animated());
    let mut p = Player::new(scene);
    let mut out = [0.0; SCENE_FLOATS];
    p.evaluate(&frame(1.0), &mut out);
    assert_eq!(row(&out, ROW_HEADER), [2.0, 1.0, 0.0, 0.0]);
    // Grain: amount, size x backing scale, still seed, no image.
    assert_eq!(row(&out, ROW_GRAIN), [0.1, 1.0, 0.0, 0.0]);
    // Field point 0 at the top left, radius 0.9 of the shorter side, the warp in its spare lane.
    let p0 = row(&out, ROW_FIELD);
    assert_eq!(&p0[..3], &[0.0, 0.0, 450.0]);
    assert!((p0[3] - 0.2).abs() < 1e-6);
    // Point 1 carries the loop phase: 1 s of 4.
    assert_eq!(row(&out, ROW_FIELD + 2)[3], 0.25);
    // Point 2: accent with half paper.
    assert_eq!(row(&out, ROW_FIELD + 5), [1.0, 0.5, 0.5, 1.0]);
    // Shape 0, halfway through an inOut move from x 0.25 to 0.75 at t = 1.
    let s0 = row(&out, ROW_SHAPES);
    assert_eq!(s0[0], 1.0);
    assert!((s0[1] - 500.0).abs() < 1e-3, "{s0:?}");
    assert_eq!(row(&out, ROW_SHAPES + 1), [100.0, 100.0, 0.0, 1.0]);
    assert_eq!(row(&out, ROW_SHAPES + 3), [1.0, 0.0, 0.0, 1.0]);
    // Shape 1: a cube, turned 30°, at the default center.
    let s1 = row(&out, ROW_SHAPES + SHAPE_ROWS);
    assert_eq!(&s1[..3], &[7.0, 500.0, 250.0]);
    assert!((s1[3] - 30f32.to_radians()).abs() < 1e-6);
    // The guide across the middle, in the accent.
    assert_eq!(row(&out, ROW_GUIDES), [0.0, 250.0, 1000.0, 250.0]);
    assert_eq!(row(&out, ROW_GUIDES + 1)[2], 1.0);
    assert_eq!(row(&out, ROW_GUIDES + 2), [1.0, 0.0, 0.0, 0.0]);
    // The light at the center.
    assert_eq!(row(&out, ROW_LIGHT), [500.0, 250.0, 400.0, 0.6]);
    assert!(out.iter().all(|v| v.is_finite()));
}

#[test]
fn the_loop_wraps() {
    let mut p = Player::new(Scene::from_value(&sample()).unwrap());
    let (mut a, mut b) = ([0.0; SCENE_FLOATS], [0.0; SCENE_FLOATS]);
    p.evaluate(&frame(1.0), &mut a);
    p.evaluate(&frame(5.0), &mut b);
    assert_eq!(a, b);
}

#[test]
fn the_light_follows_the_pointer_by_its_share() {
    let mut v = sample();
    v["light"]["followPointer"] = json!(0.5);
    let mut p = Player::new(Scene::from_value(&v).unwrap());
    let mut out = [0.0; SCENE_FLOATS];
    let f = FrameInput { pointer_x: 1000.0, pointer_y: 0.0, ..frame(0.0) };
    p.evaluate(&f, &mut out);
    assert_eq!(&row(&out, ROW_LIGHT)[..2], &[750.0, 125.0]);
}

#[test]
fn a_still_scene_is_at_rest() {
    let v = json!({
        "field": { "points": [
            { "at": [0, 0], "color": "#C9B8F0" }, { "at": [1, 0], "color": "#F6C9A8" },
            { "at": [1, 1], "color": "#F08A4B" }, { "at": [0, 1], "color": "#A9C4F5" }
        ] },
        "grain": { "amount": 0.15 },
        "shapes": [ { "kind": "lens", "size": [0.5, 0.2] } ]
    });
    let p = Player::new(Scene::from_value(&v).unwrap());
    assert!(p.at_rest());
    let mut following = v.clone();
    following["light"] = json!({ "at": [0.5, 0.5], "followPointer": 0.3 });
    assert!(!Player::new(Scene::from_value(&following).unwrap()).at_rest());
    let mut moving = v;
    moving["grain"]["animated"] = json!(true);
    assert!(!Player::new(Scene::from_value(&moving).unwrap()).at_rest());
}

#[test]
fn every_pack_scene_parses_and_moves() {
    for id in
        ["gradient-lens", "gradient-cube", "gradient-arcs", "gradient-specimen", "badge-lanyard"]
    {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("wallpapers").join(id);
        let manifest = crate::Manifest::parse(&std::fs::read(dir.join("wallpaper.json")).unwrap())
            .unwrap_or_else(|e| panic!("{id}/wallpaper.json: {e}"));
        let bytes = std::fs::read(dir.join(manifest.scene.as_deref().unwrap())).unwrap();
        let scene = load(&manifest, &bytes).unwrap_or_else(|e| panic!("{id}/scene.json: {e}"));
        let mut p = Player::new(scene);
        let mut out = [0.0; SCENE_FLOATS];
        p.evaluate(&frame(manifest.still.time), &mut out);
        assert!(out.iter().all(|v| v.is_finite()), "{id}");
        assert!(row(&out, ROW_HEADER)[0] >= 1.0, "{id} draws no shape");
    }
}

#[test]
fn the_badge_rests_once_it_settles() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("wallpapers/badge-lanyard");
    let mut p = Player::new(Scene::parse(&std::fs::read(dir.join("scene.json")).unwrap()).unwrap());
    let mut out = [0.0; SCENE_FLOATS];
    let mut t = 0.0_f64;
    while t < 30.0 && !(t > 0.1 && p.at_rest()) {
        #[allow(clippy::cast_possible_truncation)]
        let f = frame(t as f32);
        p.evaluate_at(&f, t, &mut out);
        t += 1.0 / 60.0;
    }
    assert!(p.at_rest(), "the badge never rested");
    // Two rope strips' worth of points, the card and the image all drawn.
    let header = row(&out, ROW_HEADER);
    assert_eq!(header[2], 8.0);
    assert!(row(&out, ROW_IMAGE)[2] > 0.0);
}

#[test]
fn mistakes_are_refused_with_a_pointer() {
    let cases: Vec<(Value, &str)> = vec![
        (json!({ "shapes": [ { "kind": "star", "size": [1, 1] } ] }), "/shapes/0/kind"),
        (json!({ "shapes": [ { "kind": "circle" } ] }), "/shapes/0"),
        (
            json!({ "shapes": [ { "kind": "circle", "size": [1, 1], "colour": "#fff" } ] }),
            "/shapes/0/colour",
        ),
        (
            json!({ "shapes": [ { "kind": "circle", "size": [1, 1], "body": "card" } ] }),
            "/shapes/0/body",
        ),
        (json!({ "field": { "points": [] } }), "/field/points"),
        (json!({ "guides": [ { "from": [0, 0] } ] }), "/guides/0"),
        (json!({ "image": { "slot": "photo" } }), "/image/slot"),
        (json!({ "loop": 0 }), "/loop"),
        (json!({ "tempo": 1 }), "/tempo"),
    ];
    for (v, pointer) in cases {
        let e = Scene::from_value(&v).unwrap_err();
        assert_eq!(e.pointer, pointer, "{v}: {e}");
    }
    let too_many =
        json!({ "shapes": vec![json!({ "kind": "circle", "size": [0.1, 0.1] }); MAX_SHAPES + 1] });
    assert_eq!(Scene::from_value(&too_many).unwrap_err().pointer, "/shapes");
}

#[test]
fn bad_frame_numbers_never_reach_the_gpu() {
    let mut p = Player::new(Scene::from_value(&sample()).unwrap());
    let mut out = [0.0; SCENE_FLOATS];
    let f = FrameInput { time: f32::NAN, width: f32::INFINITY, pointer_x: f32::NAN, ..frame(0.0) };
    p.evaluate(&f, &mut out);
    assert!(out.iter().all(|v| v.is_finite()));
}
