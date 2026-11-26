use serde_json::json;

use super::super::design::{Surface, check_in};
use super::{FILE, System};

fn custom() -> System {
    System::from_json(&json!({
        "design": "cmux.design/1",
        "name": "Leo's widgets",
        "type": {
            "numeral": {"size": 40, "weight": "bold"},
            "display": {"size": 28, "weight": "semibold"}
        },
        "space": [0, 4, 8, 12, 16, 24, 32],
        "colors": {"brand": "accent", "muted": "secondary"},
        "limits": {"typeRoles": 5, "accents": 1}
    }))
    .expect("a valid system")
}

#[test]
fn a_persons_system_overrides_and_adds_roles_over_cmuxs() {
    let system = custom();
    assert_eq!(system.name, "Leo's widgets");
    let numeral = system.roles.iter().find(|r| r.name == "numeral").unwrap();
    assert_eq!((numeral.size, numeral.weight.as_str(), numeral.helper), (40.0, "bold", None));
    assert!(system.roles.iter().any(|r| r.name == "display" && r.size == 28.0));
    // Roles it leaves alone keep cmux's helper.
    let caption = system.roles.iter().find(|r| r.name == "caption").unwrap();
    assert_eq!(caption.helper, Some("Caption"));
    assert_eq!(system.space, vec![0.0, 4.0, 8.0, 12.0, 16.0, 24.0, 32.0]);
    assert_eq!(system.colors.get("brand").map(String::as_str), Some("accent"));
    assert_eq!((system.max_roles, system.max_accents), (5, 1));
}

#[test]
fn the_check_holds_a_scene_to_the_persons_system() {
    let ops = json!([
        {"op": "create", "id": "r", "type": "VStack", "props": {"spacing": 6}},
        {"op": "create", "id": "a", "type": "Text", "props": {"text": "72", "font": 40, "weight": "bold", "lineLimit": 1}},
        {"op": "create", "id": "b", "type": "Text", "props": {"text": "Sun", "font": 28, "weight": "semibold", "lineLimit": 1}},
        {"op": "children", "id": "r", "children": ["a", "b"]},
        {"op": "root", "id": "r"}
    ]);
    // cmux's system: 40 and 28 are off its scale; 6 is on it.
    let cmux: Vec<_> =
        check_in(&[&ops], Surface::Widget, &System::cmux()).into_iter().map(|f| f.check).collect();
    assert_eq!(cmux, vec!["type-size", "type-size"]);
    // The person's: both sizes are roles, and 6 is off their scale, with their step named.
    let theirs = check_in(&[&ops], Surface::Widget, &custom());
    assert_eq!(theirs.iter().map(|f| f.check).collect::<Vec<_>>(), vec!["spacing"]);
    assert!(theirs[0].fix.contains("Leo's widgets space: 0 4 8"), "{}", theirs[0].fix);
}

#[test]
fn an_off_scale_size_names_the_persons_role_by_its_call() {
    let ops = json!([
        {"op": "create", "id": "t", "type": "Text", "props": {"text": "x", "font": 27, "lineLimit": 1}},
        {"op": "root", "id": "t"}
    ]);
    let findings = check_in(&[&ops], Surface::Widget, &custom());
    assert!(
        findings[0].fix.starts_with("use design.text(\"display\", ...) (28 pt)"),
        "{}",
        findings[0].fix
    );
}

#[test]
fn a_bad_system_names_the_field_and_its_fix() {
    let bad = |doc: serde_json::Value| System::from_json(&doc).unwrap_err();
    assert!(bad(json!({"type": {}})).contains("\"design\" must be"));
    let base = |extra: serde_json::Value| {
        let mut doc = json!({"design": "cmux.design/1"});
        doc.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        doc
    };
    assert!(bad(base(json!({"type": {"x": {"size": 100}}}))).contains("type.x.size"));
    assert!(
        bad(base(json!({"type": {"x": {"size": 12, "weight": "thin"}}}))).contains("type.x.weight")
    );
    assert!(bad(base(json!({"space": [4, 8]}))).contains("start at 0"));
    assert!(bad(base(json!({"space": [0, 8, 4]}))).contains("go up"));
    assert!(bad(base(json!({"colors": {"brand": "#ff0000"}}))).contains("colors.brand"));
    assert!(bad(base(json!({"limits": {"accents": 9}}))).contains("limits.accents"));
    assert!(bad(base(json!({"limits": {"accents": 1.5}}))).contains("limits.accents"));
    assert!(
        bad(base(json!({"type": {"x": {"size": 12, "weight": 600}}}))).contains("type.x.weight")
    );
    assert!(
        bad(base(json!({"type": {"x": {"size": 12, "monospaced": "yes"}}})))
            .contains("type.x.monospaced")
    );
    // Whole-number floats and a null weight read as the SDK reads them.
    let system = System::from_json(&base(json!({
        "type": {"x": {"size": 12, "weight": null}},
        "limits": {"accents": 2.0}
    })))
    .expect("a valid system");
    assert_eq!(system.max_accents, 2);
}

#[test]
fn a_tie_rounds_to_the_larger_step_as_the_sdk_does() {
    // 2 is as near 0 as 4 on this scale; 0 would make the gap vanish.
    assert_eq!(custom().nearest_step(2.0), 4.0);
    assert_eq!(System::cmux().nearest_step(10.0), 12.0);
}

#[test]
fn a_folder_without_a_file_uses_cmuxs_system_and_a_broken_one_says_so() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(System::load(dir.path()), (System::cmux(), None));
    std::fs::write(dir.path().join(FILE), "{ not json").unwrap();
    let (system, problem) = System::load(dir.path());
    assert_eq!(system, System::cmux());
    let problem = problem.expect("a system finding");
    assert_eq!(problem.check, "system");
    assert!(problem.message.starts_with(FILE), "{}", problem.message);
    // A file that is there but does not read as text is a finding too, not "no file".
    std::fs::write(dir.path().join(FILE), [0xff, 0xfe, 0x00]).unwrap();
    assert_eq!(System::load(dir.path()).1.map(|f| f.check), Some("system"));
}

#[test]
fn cmux_space_is_the_sdk_space_from_the_app_scales() {
    // scene-scale.json is the SDK's SPACE and the check's alike (gen-type-scale.py writes tokens.ts
    // from it), so an extension spaced by SPACE passes the check.
    let space = System::cmux().space;
    assert_eq!(space, vec![0.0, 2.0, 4.0, 6.0, 8.0, 12.0, 16.0, 20.0, 24.0, 32.0, 48.0]);
    let tokens = include_str!("../../../../cmux-extension-sdk/typescript/src/tokens.ts");
    let line = tokens.lines().find(|line| line.starts_with("export const SPACE = ")).unwrap();
    let values: Vec<f64> = line
        .split(", ")
        .filter_map(|pair| pair.rsplit(": ").next()?.trim_end_matches(" } as const").parse().ok())
        .collect();
    assert_eq!(values, space, "{line}");
}
