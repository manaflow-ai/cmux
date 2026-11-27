use super::super::Scene;
use super::super::value::Track;
use super::*;

fn run(v: &Value) -> Translation {
    translate(v.to_string().as_bytes()).unwrap()
}

/// The scene's `shapes[i][key]` as a point track.
fn point(t: &Translation, i: usize, key: &str) -> Track<[f32; 2]> {
    let loop_s = t.scene["loop"].as_f64().unwrap() as f32;
    Track::point(&t.scene["shapes"][i][key], "", loop_s, -2.0, 4.0).unwrap()
}

fn number(t: &Translation, v: &Value) -> Track<f32> {
    let loop_s = t.scene["loop"].as_f64().unwrap() as f32;
    Track::number(v, "", loop_s, -3600.0, 3600.0).unwrap()
}

fn near2(a: [f32; 2], b: [f32; 2]) -> bool {
    (a[0] - b[0]).abs() < 2e-3 && (a[1] - b[1]).abs() < 2e-3
}

fn loads(t: &Translation) {
    assert!(t.loadable(), "{:#?}", t.lint);
    Scene::from_value(&t.scene).unwrap_or_else(|e| panic!("{e:?}\n{:#}", t.scene));
}

fn file(layers: Value) -> Value {
    json!({ "v": "5.7.4", "fr": 30, "ip": 0, "op": 60, "w": 400, "h": 400, "ddd": 0, "assets": [], "layers": layers })
}

fn shape_layer(ks: Value, shapes: Value) -> Value {
    json!({ "ddd": 0, "ind": 1, "ty": 4, "nm": "L", "sr": 1, "ks": ks, "ao": 0, "shapes": shapes,
            "ip": 0, "op": 60, "st": 0, "bm": 0 })
}

fn red_fill() -> Value {
    json!({ "ty": "fl", "c": { "a": 0, "k": [1, 0, 0, 1] }, "o": { "a": 0, "k": 100 }, "r": 1 })
}

#[test]
fn a_moving_scaling_ellipse_keeps_its_bezier_easing() {
    let ease = json!({ "o": { "x": [0.4], "y": [0] }, "i": { "x": [0.2], "y": [1] } });
    let mut k0 = json!({ "t": 0, "s": [100, 100, 0] });
    let mut s0 = json!({ "t": 0, "s": [100, 100, 100] });
    for k in [&mut k0, &mut s0] {
        k["o"] = ease["o"].clone();
        k["i"] = ease["i"].clone();
    }
    let ks = json!({
        "p": { "a": 1, "k": [k0, { "t": 30, "s": [300, 200, 0] }] },
        "s": { "a": 1, "k": [s0, { "t": 30, "s": [200, 200, 100] }] },
        "a": { "a": 0, "k": [0, 0, 0] }, "r": { "a": 0, "k": 0 }, "o": { "a": 0, "k": 100 }
    });
    let shapes = json!([{ "ty": "gr", "it": [
        { "ty": "el", "p": { "a": 0, "k": [0, 0] }, "s": { "a": 0, "k": [100, 100] } },
        red_fill(),
        { "ty": "tr", "p": { "a": 0, "k": [0, 0] }, "a": { "a": 0, "k": [0, 0] }, "s": { "a": 0, "k": [100, 100] },
          "r": { "a": 0, "k": 0 }, "o": { "a": 0, "k": 100 } }
    ]}]);
    let t = run(&file(json!([shape_layer(ks, shapes)])));
    loads(&t);
    let s = &t.scene["shapes"][0];
    assert_eq!(t.scene["loop"], json!(2.0));
    assert_eq!(s["kind"], "circle");
    assert_eq!(s["fill"]["from"], "#FF0000");
    assert_eq!(
        s["at"],
        json!({ "keys": [[0.0, [0.25, 0.25]], [1.0, [0.75, 0.5], [0.4, 0.0, 0.2, 1.0]]] })
    );
    assert_eq!(
        s["size"],
        json!({ "keys": [[0.0, [0.25, 0.25]], [1.0, [0.5, 0.5], [0.4, 0.0, 0.2, 1.0]]] })
    );
    // Halfway in time is well past halfway in value with this ease.
    let at = point(&t, 0, "at").at(0.5);
    assert!(at[0] > 0.6, "{at:?}");
}

#[test]
fn a_rect_in_a_group_in_a_parented_layer_composes_every_transform() {
    let parent = json!({ "ind": 1, "ty": 3, "ks": {
        "p": { "a": 0, "k": [200, 200, 0] }, "r": { "a": 0, "k": 90 }, "o": { "a": 0, "k": 50 } },
        "ip": 0, "op": 60, "st": 0 });
    let child = json!({ "ind": 2, "ty": 4, "parent": 1, "ks": { "p": { "a": 0, "k": [50, 0, 0] } },
    "ip": 0, "op": 60, "st": 0,
    "shapes": [{ "ty": "gr", "it": [
        { "ty": "rc", "p": { "a": 0, "k": [0, 0] }, "s": { "a": 0, "k": [40, 20] }, "r": { "a": 0, "k": 5 } },
        red_fill(),
        { "ty": "tr", "p": { "a": 0, "k": [10, 0] }, "o": { "a": 0, "k": 80 } }
    ]}]});
    let t = run(&file(json!([parent, child])));
    loads(&t);
    let s = &t.scene["shapes"][0];
    assert_eq!(s["kind"], "roundRect");
    // (50 + 10, 0) turned 90 degrees about the parent, at (200, 200): (200, 260).
    assert_eq!(s["at"], json!([0.5, 0.65]));
    assert_eq!(s["size"], json!([0.1, 0.05]));
    assert_eq!(s["rotate"], json!(90.0));
    assert_eq!(s["shape"], json!(0.25));
    // The group's 80% reaches it; the parent's 50% does not.
    assert_eq!(s["opacity"], json!(0.8));
}

#[test]
fn a_gradient_fill_maps_to_a_linear_fill() {
    let shapes = json!([
        { "ty": "el", "p": { "a": 0, "k": [200, 200] }, "s": { "a": 0, "k": [200, 200] } },
        { "ty": "gf", "t": 1, "o": { "a": 0, "k": 100 },
          "s": { "a": 0, "k": [-100, 0] }, "e": { "a": 0, "k": [0, 100] },
          "g": { "p": 2, "k": { "a": 0, "k": [0, 1, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0.5] } } }
    ]);
    let t = run(&file(json!([shape_layer(json!({}), shapes.clone())])));
    loads(&t);
    let fill = &t.scene["shapes"][0]["fill"];
    assert_eq!(fill["type"], "linear");
    assert_eq!(fill["from"], "#FF0000");
    assert_eq!(fill["to"], "#0000FF80");
    assert_eq!(fill["angle"], json!(45.0));
    assert!(t.lint.is_empty(), "{:?}", t.lint);

    // The angle is in the shape's own frame: turning the layer turns the
    // shape, not the angle.
    let turned = run(&file(json!([shape_layer(json!({ "r": { "a": 0, "k": 90 } }), shapes)])));
    loads(&turned);
    assert_eq!(turned.scene["shapes"][0]["rotate"], json!(90.0));
    assert_eq!(turned.scene["shapes"][0]["fill"]["angle"], json!(45.0));
}

#[test]
fn three_stops_warn_but_load() {
    let shapes = json!([
        { "ty": "el", "p": { "a": 0, "k": [200, 200] }, "s": { "a": 0, "k": [200, 200] } },
        { "ty": "gf", "t": 2, "s": { "a": 0, "k": [0, 0] }, "e": { "a": 0, "k": [100, 0] },
          "g": { "p": 3, "k": { "a": 0, "k": [0, 1, 0, 0, 0.5, 0, 1, 0, 1, 0, 0, 1] } } }
    ]);
    let v = file(json!([shape_layer(json!({}), shapes)]));
    let t = run(&v);
    loads(&t);
    assert_eq!(t.lint.len(), 1);
    assert_eq!(t.lint[0].pointer, "/layers/0/shapes/1/g");
    assert!(!t.lint[0].refused);
    let fill = &t.scene["shapes"][0]["fill"];
    assert_eq!(
        (fill["type"].as_str(), fill["from"].as_str(), fill["to"].as_str()),
        (Some("radial"), Some("#FF0000"), Some("#0000FF"))
    );
    assert!(Scene::from_lottie(v.to_string().as_bytes()).is_ok());
}

#[test]
fn hold_keyframes_jump() {
    let ks = json!({ "p": { "a": 1, "k": [
        { "t": 0, "s": [100, 100], "h": 1 },
        { "t": 30, "s": [300, 100], "h": 1 },
        { "t": 45, "s": [200, 100] } ] } });
    let shapes = json!([{ "ty": "el", "s": { "a": 0, "k": [40, 40] } }, red_fill()]);
    let t = run(&file(json!([shape_layer(ks, shapes)])));
    loads(&t);
    let keys = t.scene["shapes"][0]["at"]["keys"].as_array().unwrap().clone();
    assert!(keys.iter().any(|k| k[2] == "hold"), "{keys:?}");
    let at = point(&t, 0, "at");
    assert!(near2(at.at(0.99), [0.25, 0.25]));
    assert!(near2(at.at(1.0), [0.75, 0.25]));
    assert!(near2(at.at(1.49), [0.75, 0.25]));
    assert!(near2(at.at(1.5), [0.5, 0.25]));
}

#[test]
fn a_split_position_reads_x_and_y() {
    let ks = json!({ "p": { "s": true,
        "x": { "a": 1, "k": [{ "t": 0, "s": [0], "o": { "x": [0.5], "y": [0.5] }, "i": { "x": [0.5], "y": [0.5] } },
                             { "t": 60, "s": [400] }] },
        "y": { "a": 0, "k": 100 } } });
    let shapes = json!([{ "ty": "el", "s": { "a": 0, "k": [40, 40] } }, red_fill()]);
    let t = run(&file(json!([shape_layer(ks, shapes)])));
    loads(&t);
    assert_eq!(
        t.scene["shapes"][0]["at"],
        json!({ "keys": [[0.0, [0.0, 0.25]], [2.0, [1.0, 0.25]]] })
    );
}

#[test]
fn old_keyframes_with_e_play() {
    let ks = json!({ "p": { "k": [
        { "t": 0, "s": [0, 200], "e": [400, 200], "i": { "x": 0.833, "y": 0.833 }, "o": { "x": 0.167, "y": 0.167 } },
        { "t": 30 } ] } });
    let shapes = json!([{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()]);
    let t = run(&file(json!([shape_layer(ks, shapes)])));
    loads(&t);
    let at = point(&t, 0, "at");
    assert!(near2(at.at(0.0), [0.0, 0.5]));
    assert!(near2(at.at(1.0), [1.0, 0.5]));
    assert!(near2(at.at(1.8), [1.0, 0.5]));
    assert!(near2(at.at(0.5), [0.5, 0.5]));
}

#[test]
fn a_precomp_shifts_time_by_its_start() {
    let inner = json!({ "ind": 1, "ty": 4, "ip": 0, "op": 200, "st": 0,
        "ks": { "p": { "a": 1, "k": [{ "t": 0, "s": [0, 0] }, { "t": 30, "s": [400, 0] }] } },
        "shapes": [{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()] });
    let mut v = file(
        json!([{ "ind": 1, "ty": 0, "refId": "comp_0", "ip": 0, "op": 90, "st": 15, "w": 400, "h": 400,
        "ks": { "p": { "k": [0, 200] } } }]),
    );
    v["op"] = json!(90);
    v["assets"] = json!([{ "id": "comp_0", "layers": [inner] }]);
    let t = run(&v);
    loads(&t);
    let at = point(&t, 0, "at");
    assert!(near2(at.at(0.25), [0.0, 0.5]));
    assert!(near2(at.at(0.5), [0.0, 0.5]));
    assert!(near2(at.at(1.0), [0.5, 0.5]));
    assert!(near2(at.at(1.5), [1.0, 0.5]));
}

#[test]
fn in_and_out_points_hold_the_opacity() {
    let mut l = shape_layer(json!({}), json!([{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()]));
    l["ip"] = json!(15);
    l["op"] = json!(45);
    let t = run(&file(json!([l])));
    loads(&t);
    let o = number(&t, &t.scene["shapes"][0]["opacity"]);
    assert_eq!(o.at(0.0), 0.0);
    assert_eq!(o.at(0.49), 0.0);
    assert_eq!(o.at(0.5), 1.0);
    assert_eq!(o.at(1.49), 1.0);
    assert_eq!(o.at(1.5), 0.0);
    assert!(o.keys().iter().any(|k| k.2 == Ease::Hold));
}

#[test]
fn a_bottom_solid_becomes_the_field() {
    let solid = json!({ "ind": 2, "ty": 1, "sc": "#203040", "sw": 400, "sh": 400, "ip": 0, "op": 60, "st": 0,
        "ks": { "a": { "k": [200, 200, 0] }, "p": { "k": [200, 200, 0] } } });
    let top = shape_layer(json!({}), json!([{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()]));
    let t = run(&file(json!([top, solid])));
    loads(&t);
    assert_eq!(t.scene["field"]["points"][2]["color"], "#203040");
    assert_eq!(t.scene["shapes"].as_array().unwrap().len(), 1);
    // Without the solid, no field.
    let t = run(&file(json!([shape_layer(
        json!({}),
        json!([{ "ty": "el", "s": { "k": [40, 40] } }, red_fill()])
    )])));
    assert!(t.scene.get("field").is_none());
}

#[test]
fn shapes_draw_bottom_first() {
    let blue = json!({ "ty": "fl", "c": { "k": [0, 0, 1, 1] } });
    let shapes = json!([
        { "ty": "gr", "it": [{ "ty": "el", "s": { "k": [40, 40] } }, red_fill(), { "ty": "tr" }] },
        { "ty": "gr", "it": [{ "ty": "rc", "s": { "k": [40, 40] } }, blue, { "ty": "tr" }] }
    ]);
    let t = run(&file(json!([shape_layer(json!({}), shapes)])));
    loads(&t);
    assert_eq!(t.scene["shapes"][0]["kind"], "roundRect");
    assert_eq!(t.scene["shapes"][1]["kind"], "circle");
}

#[test]
fn a_stroke_on_an_ellipse_is_an_outline() {
    let shapes = json!([
        { "ty": "el", "p": { "k": [200, 200] }, "s": { "k": [100, 100] } },
        { "ty": "st", "c": { "k": [1, 1, 1, 1] }, "o": { "k": 100 }, "w": { "k": 8 } },
        red_fill()
    ]);
    let t = run(&file(json!([shape_layer(json!({}), shapes)])));
    loads(&t);
    let s = t.scene["shapes"].as_array().unwrap();
    assert_eq!(s.len(), 2);
    assert!(s[0].get("stroke").is_none());
    assert_eq!(s[1]["stroke"], json!(0.02));
    assert_eq!(s[1]["fill"]["from"], "#FFFFFF");
}

#[test]
fn a_path_layer_is_refused_where_it_is() {
    let shapes = json!([{ "ty": "gr", "it": [
        { "ty": "sh", "ks": { "a": 0, "k": { "c": true, "v": [[0, 0], [10, 0], [10, 10]], "i": [], "o": [] } } },
        red_fill(), { "ty": "tr" } ] }]);
    let v = file(json!([shape_layer(json!({}), shapes)]));
    let t = run(&v);
    assert!(!t.loadable());
    let l = t.lint.iter().find(|l| l.refused).unwrap();
    assert_eq!(l.pointer, "/layers/0/shapes/0/it/0");
    assert_eq!(l.feature, "sh path");
    let e = Scene::from_lottie(v.to_string().as_bytes()).unwrap_err();
    assert_eq!(e.pointer, "/layers/0/shapes/0/it/0");
}

#[test]
fn refused_features_each_get_a_line() {
    let mut l = shape_layer(
        json!({ "o": { "a": 0, "k": 100, "x": "wiggle(2, 10)" } }),
        json!([{ "ty": "el", "s": { "k": [40, 40] } }, { "ty": "tm" }, red_fill()]),
    );
    l["masksProperties"] = json!([{ "mode": "a" }]);
    l["tt"] = json!(1);
    l["ef"] = json!([{ "ty": 5 }]);
    let text = json!({ "ind": 3, "ty": 5, "ip": 0, "op": 60, "st": 0, "ks": {} });
    let t = run(&file(json!([l, text])));
    let found: Vec<(&str, &str)> = t
        .lint
        .iter()
        .filter(|l| l.refused)
        .map(|l| (l.pointer.as_str(), l.feature.as_str()))
        .collect();
    for want in [
        ("/layers/0/ks/o/x", "expression"),
        ("/layers/0/masksProperties", "mask"),
        ("/layers/0/tt", "matte"),
        ("/layers/0/ef", "effects"),
        ("/layers/0/shapes/1", "tm trim"),
        ("/layers/1", "text layer"),
    ] {
        assert!(found.contains(&want), "{want:?} not in {found:?}");
    }
}

#[test]
fn more_than_16_shapes_is_refused_but_the_scene_still_parses() {
    let shapes: Vec<Value> = (0..17)
        .map(|i| json!({ "ty": "gr", "it": [{ "ty": "el", "p": { "k": [i * 20, 100] }, "s": { "k": [10, 10] } }, red_fill(), { "ty": "tr" }] }))
        .collect();
    let t = run(&file(json!([shape_layer(json!({}), Value::Array(shapes))])));
    assert!(!t.loadable());
    assert!(t.lint.iter().any(|l| l.refused && l.feature == "shapes"));
    assert!(Scene::from_value(&t.scene).is_ok());
}

#[test]
fn not_lottie_is_an_error() {
    assert!(translate(b"{\"v\": \"5.7\"}").is_err());
    assert!(translate(b"[1, 2]").is_err());
    assert!(translate(b"nope").is_err());
    // Only refused content still translates, with lint.
    let t = run(&file(json!([{ "ty": 2, "ind": 1, "ks": {}, "ip": 0, "op": 60, "st": 0 }])));
    assert!(!t.loadable());
}

#[test]
fn the_orbs_fixture_loads() {
    let bytes = include_bytes!("../../tests/fixtures/lottie/orbs.json");
    assert!(bytes.len() <= 300 * 1024);
    let t = translate(bytes).unwrap();
    loads(&t);
    assert!(t.lint.is_empty(), "{:#?}", t.lint);
    assert!(t.scene.get("field").is_some());
    let shapes = t.scene["shapes"].as_array().unwrap();
    assert!((3..=5).contains(&shapes.len()));
    assert_eq!(t.scene["loop"], json!(6.0));
    let scene = Scene::from_lottie(bytes).unwrap();
    assert!(scene.animated());
    // Every orb moves and stays within its keys' limit.
    for s in shapes {
        assert!(s["at"].get("keys").is_some(), "{s}");
        assert!(s["at"]["keys"].as_array().unwrap().len() <= MAX_KEYS);
    }
}
