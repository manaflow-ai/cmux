use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{GALLERIES, SOURCES, TOKEN_GROUPS, components, tokens, ts};

fn component(name: &str) -> Value {
    let all = components(Some(name)).expect("a kit component");
    all["components"][0].clone()
}

fn prop<'a>(component: &'a Value, name: &str) -> &'a Value {
    component["props"]
        .as_array()
        .and_then(|props| props.iter().find(|p| p["name"] == name))
        .unwrap_or_else(|| panic!("{} has no prop {name}: {component:#}", component["name"]))
}

fn strings(value: &Value) -> Vec<&str> {
    value.as_array().map(|a| a.iter().filter_map(Value::as_str).collect()).unwrap_or_default()
}

#[test]
fn every_barrel_export_is_compiled_in() {
    assert!(
        ts::barrel_misses().is_empty(),
        "kit/index.ts re-exports from files sources.rs lacks: {:?}",
        ts::barrel_misses()
    );
}

#[test]
fn every_component_has_props_and_an_example() {
    let all = components(None).expect("components");
    let list = all["components"].as_array().expect("a list");
    let names: Vec<&str> = list.iter().filter_map(|c| c["name"].as_str()).collect();
    for want in [
        "Row",
        "List",
        "Pill",
        "Avatar",
        "Field",
        "Glass",
        "GlassMenu",
        "PopoverButton",
        "Button",
        "Popover",
        "Input",
        "Icon",
        "StatusGlyph",
        "Spinner",
        "Tooltip",
        "Menu",
        "MenuItem",
        "Surface",
        "Panel",
        "Card",
        "MinimalSessions",
        "SessionList",
    ] {
        assert!(names.contains(&want), "{want} missing from {names:?}");
    }
    assert_eq!(all["count"], list.len());
    for c in list {
        // A prop-less component (MenuSeparator) lists an empty array.
        assert!(c["props"].is_array(), "{} has no props list: {c:#}", c["name"]);
        let example = c["example"].as_str().unwrap_or_default();
        assert!(
            example.starts_with(&format!("<{}", c["name"].as_str().unwrap_or_default())),
            "{example}"
        );
        assert!(
            !c["summary"].as_str().unwrap_or_default().is_empty(),
            "{} has no summary",
            c["name"]
        );
    }
}

#[test]
fn union_props_list_their_values_and_defaults() {
    let pill = component("pill");
    let tone = prop(&pill, "tone");
    assert_eq!(strings(&tone["values"]), ["neutral", "accent", "success", "attention", "danger"]);
    assert_eq!(tone["default"], "\"neutral\"");
    assert_eq!(strings(&pill["variants"]["tone"]), strings(&tone["values"]));
    assert!(!pill["galleryEntries"].as_array().expect("entries").is_empty(), "{pill:#}");

    let button = component("Button");
    assert_eq!(strings(&prop(&button, "variant")["values"]), ["ghost", "subtle", "solid"]);
    assert!(button["extends"].to_string().contains("ComponentProps"), "{button:#}");

    let popover_button = component("PopoverButton");
    assert_eq!(strings(&prop(&popover_button, "variant")["values"]), ["ghost", "subtle", "solid"]);

    let glyph = component("StatusGlyph");
    assert!(strings(&prop(&glyph, "name")["values"]).contains(&"idle"), "{glyph:#}");

    let panel = component("Panel");
    assert_eq!(panel["aliasOf"], "Surface", "{panel:#}");
    assert!(strings(&prop(&panel, "role")["values"]).contains(&"card"), "{panel:#}");
    assert!(panel["example"].as_str().unwrap_or_default().starts_with("<Panel"), "{panel:#}");

    let spinner = component("Spinner");
    assert!(spinner["file"].as_str().unwrap_or_default().ends_with("Spinner.tsx"), "{spinner:#}");
}

#[test]
fn unknown_names_are_errors_that_list_the_choices() {
    let err = components(Some("Nope")).expect_err("no such component");
    assert!(err.contains("Pill"), "{err}");
    let err = tokens(Some("nope")).expect_err("no such group");
    assert!(err.contains("radius"), "{err}");
}

#[test]
fn every_token_group_has_values() {
    let all = tokens(None).expect("tokens");
    for group in TOKEN_GROUPS {
        let value = &all[*group];
        let empty = match value {
            Value::Array(a) => a.is_empty(),
            Value::Object(o) => o.is_empty(),
            _ => true,
        };
        assert!(!empty, "{group} is empty: {value}");
    }
    let radius = tokens(Some("radius")).expect("radius");
    let md =
        radius["radius"].as_array().and_then(|r| r.iter().find(|s| s["name"] == "md")).expect("md");
    assert_eq!(md["px"], 6);
    assert_eq!(md["var"], "--ds-radius-md");
}

fn galleries_under(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            galleries_under(&path, out);
        } else if path.to_string_lossy().ends_with(".gallery.tsx") {
            out.push(path);
        }
    }
}

/// A gallery entry that covers a compiled-in source must be compiled in too.
#[test]
fn every_gallery_covering_a_kit_source_is_compiled_in() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../webviews/src");
    let mut found = Vec::new();
    galleries_under(&root, &mut found);
    for path in found {
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let rel =
            path.strip_prefix(&root).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let covers = SOURCES.iter().any(|(src, _)| text.contains(&format!("\"{src}#")));
        if covers {
            assert!(
                GALLERIES.iter().any(|(g, _)| *g == rel),
                "{rel} covers a kit source; add it to GALLERIES in kit/sources.rs"
            );
        }
    }
}
