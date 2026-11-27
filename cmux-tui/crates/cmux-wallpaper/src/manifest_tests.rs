use super::*;

fn base() -> Value {
    json!({
        "id": "grain-silk",
        "name": "Grain and Silk",
        "description": "Film grain.",
        "shader": "wallpaper.wgsl",
        "fps": 30,
        "scale": 0.5,
        "interactive": true,
        "params": [{ "name": "speed", "title": "Speed", "default": 0.4, "min": 0, "max": 2 }],
        "still": { "time": 14.0, "pointer": [0.62, 0.42] },
        "variants": [{ "name": "Cobalt", "accent": "#3D7BFF", "params": { "speed": 1 }, "themes": ["dark"] }]
    })
}

fn refuse(edit: impl FnOnce(&mut Value)) -> ManifestError {
    let mut v = base();
    edit(&mut v);
    match Manifest::from_value(&v) {
        Ok(m) => panic!("accepted {m:?}"),
        Err(e) => e,
    }
}

#[test]
fn the_spec_example_parses() {
    let m = Manifest::from_value(&base()).unwrap();
    assert_eq!(m.id, "grain-silk");
    assert_eq!(m.fps, 30);
    assert_eq!(m.params.len(), 1);
    assert_eq!(m.still.pointer, [0.62, 0.42]);
    assert_eq!(m.variants[0].params["speed"], 1.0);
    let back = Manifest::from_value(&m.to_json()).unwrap();
    assert_eq!(back.id, m.id);
    assert_eq!(back.params[0].title.as_deref(), Some("Speed"));
    // `agents` is optional and off unless the program asks for it.
    assert!(!m.agents);
    let mut v = base();
    v["agents"] = json!(true);
    let m = Manifest::from_value(&v).unwrap();
    assert!(m.agents);
    assert!(Manifest::from_value(&m.to_json()).unwrap().agents);
}

#[test]
fn decimal_endpoints_are_in_range() {
    // 0.1 and 0.3 are not exact in f32: a default or variant value at a decimal limit is valid.
    let mut v = base();
    v["params"][0] = json!({ "name": "speed", "default": 0.1, "min": 0.1, "max": 0.3 });
    v["variants"][0]["params"] = json!({ "speed": 0.3 });
    let m = Manifest::from_value(&v).unwrap();
    assert_eq!((m.params[0].min, m.params[0].max, m.params[0].default), (0.1, 0.3, 0.1));
    v["variants"][0]["params"] = json!({ "speed": 0.1 });
    Manifest::from_value(&v).unwrap();
    v["variants"][0]["params"] = json!({ "speed": 0.31 });
    assert_eq!(Manifest::from_value(&v).unwrap_err().kind, ManifestErrorKind::OutOfRange);
}

#[test]
fn idle_after_is_optional_and_round_trips() {
    let m = Manifest::from_value(&base()).unwrap();
    assert_eq!(m.idle_after, DEFAULT_IDLE_AFTER_S);
    assert_eq!(m.to_json()["idle_after"], json!(20.0));
    let mut v = base();
    v["idle_after"] = json!(2);
    let m = Manifest::from_value(&v).unwrap();
    assert_eq!(m.idle_after, 2.0);
    assert_eq!(Manifest::from_value(&m.to_json()).unwrap(), m);
}

#[test]
fn a_variant_may_carry_its_own_still() {
    let mut v = base();
    v["variants"][0]["still"] = json!({ "time": 3.0, "pointer": [0.2, 0.8] });
    let m = Manifest::from_value(&v).unwrap();
    assert_eq!(m.variants[0].still, Some(Still { time: 3.0, pointer: [0.2, 0.8] }));
    let back = Manifest::from_value(&m.to_json()).unwrap();
    assert_eq!(back.variants[0].still, m.variants[0].still);
    let plain = Manifest::from_value(&base()).unwrap();
    assert_eq!(plain.variants[0].still, None);
    assert_eq!(Manifest::from_value(&plain.to_json()).unwrap(), plain);
    let mut bare = base();
    bare["variants"][0].as_object_mut().unwrap().remove("accent");
    let bare = Manifest::from_value(&bare).unwrap();
    assert_eq!(Manifest::from_value(&bare.to_json()).unwrap(), bare);
    let e = refuse(|v| v["variants"][0]["still"] = json!({ "time": 3.0, "pointer": [0.2, 2] }));
    assert_eq!(e.pointer, "/variants/0/still/pointer/1");
}

#[test]
fn params_and_variants_are_optional() {
    let e = Manifest::from_value(&{
        let mut v = base();
        let o = v.as_object_mut().unwrap();
        o.remove("params");
        o.remove("variants");
        v
    })
    .unwrap();
    assert!(e.params.is_empty());
    assert_eq!(e.param_values(&BTreeMap::new()), [0.0; 8]);
}

#[test]
fn param_values_take_overrides_clamped() {
    let m = Manifest::from_value(&base()).unwrap();
    let mut o = BTreeMap::new();
    assert_eq!(m.param_values(&o)[0], 0.4);
    o.insert("speed".to_string(), 9.0);
    assert_eq!(m.param_values(&o)[0], 2.0);
}

#[test]
fn each_rule_refuses_with_a_pointer() {
    type Edit = Box<dyn FnOnce(&mut Value)>;
    let cases: Vec<(Edit, ManifestErrorKind, &str)> = vec![
        (Box::new(|v| v["id"] = json!("Grain")), ManifestErrorKind::BadFormat, "/id"),
        (Box::new(|v| v["id"] = json!("a--b")), ManifestErrorKind::BadFormat, "/id"),
        (Box::new(|v| v["id"] = json!("-a")), ManifestErrorKind::BadFormat, "/id"),
        (Box::new(|v| v["id"] = json!(3)), ManifestErrorKind::WrongType, "/id"),
        (
            Box::new(|v| {
                v.as_object_mut().unwrap().remove("name");
            }),
            ManifestErrorKind::Missing,
            "",
        ),
        (Box::new(|v| v["name"] = json!("")), ManifestErrorKind::OutOfRange, "/name"),
        (Box::new(|v| v["extra"] = json!(1)), ManifestErrorKind::UnknownKey, "/extra"),
        (Box::new(|v| v["shader"] = json!("../x.wgsl")), ManifestErrorKind::BadFormat, "/shader"),
        (Box::new(|v| v["shader"] = json!("/x.wgsl")), ManifestErrorKind::BadFormat, "/shader"),
        (Box::new(|v| v["shader"] = json!("x.metal")), ManifestErrorKind::BadFormat, "/shader"),
        (Box::new(|v| v["fps"] = json!(0)), ManifestErrorKind::OutOfRange, "/fps"),
        (Box::new(|v| v["fps"] = json!(61)), ManifestErrorKind::OutOfRange, "/fps"),
        (Box::new(|v| v["fps"] = json!(29.5)), ManifestErrorKind::WrongType, "/fps"),
        (Box::new(|v| v["scale"] = json!(0.2)), ManifestErrorKind::OutOfRange, "/scale"),
        (Box::new(|v| v["scale"] = json!(1.5)), ManifestErrorKind::OutOfRange, "/scale"),
        (Box::new(|v| v["interactive"] = json!(1)), ManifestErrorKind::WrongType, "/interactive"),
        (Box::new(|v| v["agents"] = json!("yes")), ManifestErrorKind::WrongType, "/agents"),
        (Box::new(|v| v["idle_after"] = json!(0.5)), ManifestErrorKind::OutOfRange, "/idle_after"),
        (Box::new(|v| v["idle_after"] = json!(21)), ManifestErrorKind::OutOfRange, "/idle_after"),
        (Box::new(|v| v["idle_after"] = json!("2")), ManifestErrorKind::WrongType, "/idle_after"),
        (
            Box::new(|v| {
                v["params"] = json!(
                    (0..9)
                        .map(|i| json!({"name": format!("p{i}"), "default": 0, "min": 0, "max": 1}))
                        .collect::<Vec<_>>()
                );
            }),
            ManifestErrorKind::OutOfRange,
            "/params",
        ),
        (
            Box::new(|v| v["params"][0]["default"] = json!(3)),
            ManifestErrorKind::OutOfRange,
            "/params/0/default",
        ),
        (
            Box::new(|v| v["params"][0]["max"] = json!(-1)),
            ManifestErrorKind::OutOfRange,
            "/params/0/max",
        ),
        (
            Box::new(|v| v["params"][0]["name"] = json!("Speed")),
            ManifestErrorKind::BadFormat,
            "/params/0/name",
        ),
        (
            Box::new(
                |v| v["params"] = json!([{"name": "a", "default": 0, "min": 0, "max": 1}, {"name": "a", "default": 0, "min": 0, "max": 1}]),
            ),
            ManifestErrorKind::Duplicate,
            "/params/1/name",
        ),
        (
            Box::new(|v| v["still"]["pointer"] = json!([0.5])),
            ManifestErrorKind::OutOfRange,
            "/still/pointer",
        ),
        (
            Box::new(|v| v["still"]["pointer"] = json!([0.5, 2])),
            ManifestErrorKind::OutOfRange,
            "/still/pointer/1",
        ),
        (
            Box::new(|v| v["still"]["time"] = json!(-1)),
            ManifestErrorKind::OutOfRange,
            "/still/time",
        ),
        (
            Box::new(|v| v["variants"][0]["accent"] = json!("blue")),
            ManifestErrorKind::BadFormat,
            "/variants/0/accent",
        ),
        (
            Box::new(|v| v["variants"][0]["params"] = json!({"x": 1})),
            ManifestErrorKind::UnknownKey,
            "/variants/0/params/x",
        ),
        (
            Box::new(|v| v["variants"][0]["params"] = json!({"speed": 5})),
            ManifestErrorKind::OutOfRange,
            "/variants/0/params/speed",
        ),
        (
            Box::new(|v| v["variants"][0]["themes"] = json!(["sepia"])),
            ManifestErrorKind::BadFormat,
            "/variants/0/themes/0",
        ),
        (
            Box::new(|v| v["variants"][0]["themes"] = json!([])),
            ManifestErrorKind::OutOfRange,
            "/variants/0/themes",
        ),
    ];
    for (i, (edit, kind, pointer)) in cases.into_iter().enumerate() {
        let e = refuse(edit);
        assert_eq!((e.kind, e.pointer.as_str()), (kind, pointer), "case {i}: {e}");
    }
}

#[test]
fn not_json_and_too_large_are_refused() {
    assert_eq!(Manifest::parse(b"{").unwrap_err().kind, ManifestErrorKind::NotJson);
    let big = vec![b' '; MAX_MANIFEST_BYTES + 1];
    assert_eq!(Manifest::parse(&big).unwrap_err().kind, ManifestErrorKind::NotJson);
    assert_eq!(Manifest::parse(b"[]").unwrap_err().kind, ManifestErrorKind::WrongType);
}
