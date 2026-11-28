use super::*;
use serde_json::json;

/// A small document of our own (not the measured glyph): a three-dot row that trades size
/// between its middle and its ends, a hand-off dot, and a generated two-site orbit.
fn sample() -> Value {
    json!({
        "$schema": "cmux.particles/1",
        "particle": {"shape": "circle", "size": 4, "color": "accent", "max": 4},
        "phases": {
            "lone": {"duration": 300, "ease": "easeInOut",
                     "frames": [{"at": 0, "dots": [[0, 0, 0.5]]}, {"at": 1, "dots": [[0, 0, 0.5]]}]},
            "breathe": {"duration": 1000, "ease": "easeInOut", "frames": [
                {"at": 0, "dots": [[-8, 0, 0.5], [0, 0, 1.5], [8, 0, 0.5]]},
                {"at": 0.5, "dots": [[-10, 0, 1.2], [0, 0, 0.6], [10, 0, 1.2]], "ease": {"bezier": [0.3, 0, 0.7, 1]}},
                {"at": 1, "formation": "row"}
            ]},
            "orbit": {"duration": 800, "sites": [[-6, 0], [6, 0]],
                      "spawn": {"every": 400, "order": [0, 1], "life": 800},
                      "lifeFrames": [{"at": 0, "pos": "centre", "s": 0.2},
                                     {"at": 0.5, "pos": "site", "s": 1, "ease": "easeOut"},
                                     {"at": 1, "pos": "centre", "s": 0, "ease": {"spring": {"response": 0.3, "dampingFraction": 1}}}]}
        },
        "formations": {"wide": [[-12, 0, 1], [12, 0, 1]]},
        "triggers": {"read": ["orbit"], "sendMessage": {"intro": ["lone"], "loop": ["breathe"]}, "cycle": ["breathe", "lone", "orbit", "lone"]}
    })
}

fn refused(doc: &Value) -> String {
    validate(doc).expect_err("refused").to_string()
}

#[test]
fn the_sample_document_is_valid() {
    validate(&sample()).expect("valid");
}

#[test]
fn unknown_keys_are_refused_at_every_level() {
    for (pointer, key) in [
        ("", "extra"),
        ("/particle", "glow"),
        ("/phases/breathe", "loop"),
        ("/phases/breathe/frames/0", "opacity"),
        ("/phases/orbit/spawn", "jitter"),
        ("/phases/orbit/lifeFrames/1", "x"),
        ("/triggers/sendMessage", "outro"),
    ] {
        let mut doc = sample();
        doc.pointer_mut(pointer).unwrap().as_object_mut().unwrap().insert(key.into(), json!(1));
        assert!(refused(&doc).contains("unknown key"), "{pointer}/{key}");
    }
    let mut doc = sample();
    doc["phases"]["breathe"]["ease"] = json!({"bezier": [0, 0, 1, 1], "spring": {"response": 1}});
    assert!(refused(&doc).contains("exactly one"));
}

#[test]
fn limits_are_refused_past_their_edge_and_accepted_at_it() {
    let mut doc = sample();
    doc["phases"]["lone"]["duration"] = json!(MIN_DURATION_MS);
    validate(&doc).expect("50 ms");
    doc["phases"]["lone"]["duration"] = json!(49);
    assert_eq!(refused(&doc), "phases.lone.duration: must be from 50 to 30000");
    doc["phases"]["lone"]["duration"] = json!(30_001);
    assert!(refused(&doc).starts_with("phases.lone.duration"));

    let mut doc = sample();
    doc["phases"]["breathe"]["frames"][0]["dots"][1][2] = json!(4);
    validate(&doc).expect("scale 4");
    doc["phases"]["breathe"]["frames"][0]["dots"][1][2] = json!(4.01);
    assert_eq!(refused(&doc), "phases.breathe.frames[0].dots[1][2]: must be from 0 to 4");

    let mut doc = sample();
    doc["particle"]["max"] = json!(17);
    assert!(refused(&doc).starts_with("particle.max"));
    doc["particle"]["max"] = json!(2);
    assert!(refused(&doc).contains("particle.max allows 2"), "{}", refused(&doc));

    let mut doc = sample();
    let frames: Vec<Value> =
        (0..65).map(|i| json!({"at": f64::from(i) / 65.0, "dots": []})).collect();
    doc["phases"]["breathe"]["frames"] = json!(frames);
    assert!(refused(&doc).contains("1 to 64 frames"));

    let mut doc = sample();
    let phases = doc["phases"].as_object_mut().unwrap();
    for i in 0..30 {
        phases.insert(format!("p{i}"), json!({"duration": 100, "frames": [{"at": 0, "dots": []}]}));
    }
    assert!(refused(&doc).contains("1 to 32 phases"));

    let mut doc = sample();
    doc["formations"]["wide"] = json!(vec![json!([0, 0, 1]); 17]);
    assert!(refused(&doc).contains("allows 16"));

    let mut doc = sample();
    doc["phases"]["orbit"]["spawn"]["life"] = json!(4000);
    assert!(refused(&doc).contains("keeps 10 dots alive"), "{}", refused(&doc));
}

#[test]
fn a_document_past_32_kib_is_refused() {
    let mut doc = sample();
    let phases = doc["phases"].as_object_mut().unwrap();
    let frames: Vec<Value> = (0..64)
        .map(|i| json!({"at": f64::from(i) / 64.0, "dots": vec![json!([1.123456, 2.123456, 1.123456]); 4]}))
        .collect();
    for i in 0..8 {
        phases.insert(format!("big{i}"), json!({"duration": 1000, "frames": frames}));
    }
    assert!(refused(&doc).contains("the limit is 32768"));
}

#[test]
fn names_colors_eases_and_triggers_are_checked() {
    let cases: Vec<(&str, Value, &str)> = vec![
        ("/$schema", json!("cmux.particles/2"), "$schema: must be cmux.particles/1"),
        ("/particle/color", json!("orange"), "particle.color: must be a scene color token"),
        ("/particle/shape", json!("star"), "particle.shape"),
        ("/phases/breathe/ease", json!("bounce"), "phases.breathe.ease: must be one of"),
        ("/phases/breathe/ease", json!({"bezier": [1.5, 0, 0, 1]}), "bezier[0]"),
        ("/phases/breathe/frames/2/formation", json!("spiral"), "not a built-in"),
        ("/phases/breathe/frames/1/at", json!(0), "after the previous frame"),
        ("/phases/orbit/spawn/order/1", json!(2), "site index"),
        ("/phases/orbit/lifeFrames/0/pos", json!("edge"), "centre, site or between"),
        ("/triggers/read/0", json!("missing"), "not a phase of this document"),
    ];
    for (pointer, value, expected) in cases {
        let mut doc = sample();
        *doc.pointer_mut(pointer).unwrap() = value;
        let message = refused(&doc);
        assert!(message.contains(expected), "{pointer}: {message}");
    }
    let mut doc = sample();
    doc["triggers"]["toolCall"] = json!(["lone"]);
    assert_eq!(refused(&doc), "triggers.toolCall: is not an acpmux tool kind or session state");
    let mut doc = sample();
    doc["formations"]["row"] = json!([]);
    assert!(refused(&doc).contains("redefines a built-in"));
    let mut doc = sample();
    doc["particle"]["color"] = json!("#D97757");
    validate(&doc).expect("hex color");
    doc["phases"]["breathe"]["frames"][0] = json!({"at": 0});
    assert!(refused(&doc).contains("exactly one of dots or formation"));
    let mut doc = sample();
    doc["phases"]["orbit"].as_object_mut().unwrap().remove("spawn");
    assert!(refused(&doc).contains("needs spawn"));
}

/// A document named by `CMUX_PARTICLES_DOC` (a look's own, kept out of the tree) validates.
/// Passes when unset.
#[test]
fn a_document_named_by_the_environment_validates() {
    let Ok(path) = std::env::var("CMUX_PARTICLES_DOC") else { return };
    let text = std::fs::read_to_string(&path).expect("read CMUX_PARTICLES_DOC");
    let doc: Value = serde_json::from_str(&text).expect("JSON");
    validate(&doc).unwrap_or_else(|error| panic!("{path}: {error}"));
}

#[test]
fn a_scene_batch_keeps_a_valid_document_and_nulls_a_refused_one() {
    let mut bad = sample();
    bad["phases"]["lone"]["duration"] = json!(10);
    let mut ops = json!([
        {"op": "create", "id": "a", "type": "Particles", "props": {"choreography": sample(), "trigger": "read"}},
        {"op": "update", "id": "b", "props": {"choreography": bad}},
        {"op": "update", "id": "c", "props": {"choreography": null}},
        {"op": "children", "id": "root", "children": ["a", "b"]},
    ]);
    let messages = sanitize_scene_ops(&mut ops);
    assert_eq!(
        messages,
        vec!["Particles b: choreography refused: phases.lone.duration: must be from 50 to 30000"]
    );
    assert_eq!(ops[0]["props"]["choreography"], sample());
    assert_eq!(ops[1]["props"]["choreography"], Value::Null);
    assert_eq!(ops[2]["props"]["choreography"], Value::Null);
}

/// A sidebar row's `indicator: {choreography, trigger}` (`cmux.sidebar.rows/1`) is checked like a
/// node's; `"glyph"` names the look's setting, which the settings owner checks.
#[test]
fn a_row_indicator_document_is_checked_and_a_reference_is_kept() {
    let mut bad = sample();
    bad["particle"]["max"] = json!(99);
    let mut ops = json!([
        {"op": "create", "id": "r1", "type": "Group", "props": {"row": "w1", "indicator": {"choreography": sample(), "trigger": "execute"}}},
        {"op": "create", "id": "r2", "type": "Group", "props": {"row": "w2", "indicator": {"choreography": bad}}},
        {"op": "create", "id": "r3", "type": "Group", "props": {"row": "w3", "indicator": {"choreography": "glyph", "trigger": "read"}}},
        {"op": "create", "id": "r4", "type": "Group", "props": {"row": "w4", "indicator": "glyph"}},
    ]);
    let messages = sanitize_scene_ops(&mut ops);
    assert_eq!(messages.len(), 1, "{messages:?}");
    assert!(
        messages[0].starts_with("row r2: indicator.choreography refused: particle.max"),
        "{messages:?}"
    );
    assert_eq!(ops[0]["props"]["indicator"]["choreography"], sample());
    assert_eq!(ops[1]["props"]["indicator"]["choreography"], Value::Null);
    assert_eq!(ops[2]["props"]["indicator"]["choreography"], json!("glyph"));
    assert_eq!(ops[3]["props"]["indicator"], json!("glyph"));
}
