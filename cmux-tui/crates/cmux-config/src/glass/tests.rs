use serde_json::{Value, json};

use super::{GlassLook, MATERIALS, ROLES, rows};

static FIXTURE: &str = include_str!("../../../../../schemas/settings/fixtures/glass-resolve.json");
static DESIGN_SCALE: &str = include_str!("../../../../../schemas/design-scale/design-scale.json");
static SURFACE_ROLES: &str =
    include_str!("../../../../../schemas/surface-roles/surface-roles.json");
static SOURCE: &str = include_str!("../../../../../schemas/settings/source/glass.json");

/// Numbers compare as numbers (`1` and `1.0` are the same strength).
fn same(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        (Value::Object(a), Value::Object(b)) => {
            a.len() == b.len() && a.iter().all(|(k, v)| b.get(k).is_some_and(|w| same(v, w)))
        }
        _ => left == right,
    }
}

#[test]
fn the_shared_cases_resolve_as_the_fixture_says() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let look = GlassLook::resolve(&case["settings"]);
        let role = case["role"].as_str().unwrap();
        let resolved = serde_json::to_value(look.role(role).unwrap()).unwrap();
        assert!(same(&resolved, &case["resolved"]), "{}: {resolved}", case["name"]);
    }
}

#[test]
fn an_empty_document_is_todays_look() {
    let look = GlassLook::resolve(&json!({}));
    assert!(look.is_default());
    for (role, glass) in &look.roles {
        assert_eq!(glass.material, None, "{role}");
        assert_eq!(glass.tint, None, "{role}");
        assert_eq!(glass.veil, None, "{role}");
    }
    let set = json!({"appearance": {"glass": {"menu": {"veil": 0.4}}}});
    assert!(!GlassLook::resolve(&set).is_default());
}

/// The default strengths are the glass levels' (`GlassLevel.tintStrength`: chrome 1, popover and
/// menu the transient material's `nativeTintStrength`, chip 1.5), so an unset key draws what the
/// app drew before.
#[test]
fn default_strengths_match_the_glass_levels() {
    let scale: Value = serde_json::from_str(DESIGN_SCALE).unwrap();
    let transient = scale["transientMaterial"]["nativeTintStrength"].as_f64().unwrap();
    let level = |role: &str| match role {
        "popover" | "toast" | "sheet" | "menu" | "composer" => transient,
        "tooltip" => 1.5,
        _ => 1.0,
    };
    let look = GlassLook::resolve(&json!({}));
    for role in ROLES {
        assert_eq!(look.role(role).unwrap().tint_strength, level(role), "{role}");
    }
}

#[test]
fn the_roles_are_the_surface_roles_the_composer_and_chrome() {
    let roles: Value = serde_json::from_str(SURFACE_ROLES).unwrap();
    let mut names: Vec<String> = roles["roles"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|role| role["name"].as_str().map(str::to_owned))
        .collect();
    names.extend(["composer".into(), "chrome".into()]);
    let ours: Vec<String> = ROLES.iter().map(|role| (*role).to_owned()).collect();
    assert_eq!(ours, names);
}

#[test]
fn every_role_has_its_four_rows_and_the_source_lists_the_materials() {
    let keys = &rows().keys;
    assert_eq!(keys.len(), ROLES.len() * 4);
    for role in ROLES {
        for field in ["material", "tint", "tintStrength", "veil"] {
            let key = format!("appearance.glass.{role}.{field}");
            assert!(keys.contains(&key), "{key}");
        }
    }
    let source: Value = serde_json::from_str(SOURCE).unwrap();
    for row in source["lists"][0]["rows"].as_array().unwrap() {
        if row["kind"] == "choice" {
            let values: Vec<&str> = row["choices"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|choice| choice["value"].as_str())
                .collect();
            assert_eq!(values, MATERIALS, "{}", row["key"]);
        }
    }
}

#[test]
fn to_json_names_every_role() {
    let set = json!({"appearance": {"glass": {"chrome": {"tint": "#112233"}}}});
    let json = GlassLook::resolve(&set).to_json();
    assert_eq!(json.as_object().unwrap().len(), ROLES.len());
    assert_eq!(json["chrome"]["tint"], "#112233");
    assert_eq!(json["popover"]["tintStrength"], 1.25);
}

/// A number past its row's range clamps to the nearest end (as `AppearanceTuning` clamps
/// `glassTransparency`), so a theme file written for a wider range still draws legible glass.
#[test]
fn out_of_range_numbers_clamp_into_the_row_range() {
    let set = json!({"appearance": {"glass": {
        "card": {"tintStrength": 9, "veil": -1},
        "composer": {"tintStrength": -2, "veil": 4},
    }}});
    let look = GlassLook::resolve(&set);
    let card = look.role("card").unwrap();
    assert_eq!((card.tint_strength, card.veil), (3.0, Some(0.0)));
    let composer = look.role("composer").unwrap();
    assert_eq!((composer.tint_strength, composer.veil), (0.0, Some(1.0)));
}

#[test]
fn the_web_glass_modes_are_materials() {
    for mode in ["plain", "lens", "spectrum"] {
        let set = json!({"appearance": {"glass": {"composer": {"material": mode}}}});
        let look = GlassLook::resolve(&set);
        assert_eq!(look.role("composer").unwrap().material.as_deref(), Some(mode));
    }
}
