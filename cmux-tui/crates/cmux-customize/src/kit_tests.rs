use super::*;
use std::path::PathBuf;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parse_reads_each_action() {
    assert_eq!(parse("tokens", &[]), Ok(Request::List(None)));
    assert_eq!(parse("tokens", &words("list ink")), Ok(Request::List(Some("ink".into()))));
    assert_eq!(parse("tokens", &words("show seed.grid")), Ok(Request::Show("seed.grid".into())));
    assert_eq!(
        parse("tokens", &words("test 14 --as spacing")),
        Ok(Request::Test { subject: "14".into(), with: Some("spacing".into()) })
    );
    assert_eq!(
        parse("components", &words(r#"test Button {"size":"sm"}"#)),
        Ok(Request::Test { subject: "Button".into(), with: Some(r#"{"size":"sm"}"#.into()) })
    );
    assert!(parse("tokens", &words("show")).is_err());
    assert!(parse("tokens", &words("test 1 --as")).is_err());
}

#[test]
fn every_family_reads_its_scale() {
    for name in FAMILIES {
        let (steps, _, _) = family(name).unwrap();
        assert!(!steps.is_empty(), "{name} has no steps");
        assert!(steps.windows(2).all(|w| w[0].value <= w[1].value), "{name} is not sorted");
    }
    let spacing: Vec<f64> = family("spacing").unwrap().0.iter().map(|s| s.value).collect();
    assert_eq!(spacing, [4.0, 8.0, 12.0, 16.0, 24.0, 32.0]);
}

#[test]
fn every_instrument_token_lists_with_a_group() {
    let answer = tokens(&Request::List(None)).unwrap();
    let rows = answer.json["tokens"].as_array().unwrap();
    assert!(rows.len() > 100, "{} tokens", rows.len());
    let grid = rows.iter().find(|r| r["name"] == "seed.grid").unwrap();
    assert_eq!(grid["group"], "seed");
    assert_eq!(grid["css"], "--instrument-seed-grid");
    assert_eq!(grid["drawn"], true);
    assert!(answer.json["families"]["motion"]["steps"].as_array().is_some());
}

#[test]
fn a_group_or_family_filters_the_list() {
    let ink = tokens(&Request::List(Some("ink".into()))).unwrap();
    assert!(ink.json["tokens"].as_array().unwrap().iter().all(|r| r["group"] == "ink"));
    let radius = tokens(&Request::List(Some("radius".into()))).unwrap();
    assert_eq!(radius.json["scale"]["family"], "radius");
    assert!(tokens(&Request::List(Some("nope".into()))).is_err());
}

#[test]
fn show_finds_a_token_by_name_or_css_property() {
    let by_name = tokens(&Request::Show("seed.grid".into())).unwrap();
    let by_css = tokens(&Request::Show("--instrument-seed-grid".into())).unwrap();
    assert_eq!(by_name.json, by_css.json);
    let error = tokens(&Request::Show("seed".into())).err().unwrap();
    assert!(error.contains("did you mean"), "{error}");
}

#[test]
fn test_names_the_step_or_the_nearest() {
    let on = tokens(&Request::Test { subject: "12".into(), with: Some("spacing".into()) }).unwrap();
    assert_eq!(on.json["ok"], true);
    assert_eq!(on.json["families"][0]["steps"][0]["name"], "3");
    let off =
        tokens(&Request::Test { subject: "14px".into(), with: Some("spacing".into()) }).unwrap();
    assert_eq!(off.json["ok"], false);
    assert_eq!(off.json["families"][0]["nearest"]["value"], 12.0);
    assert!(off.json["families"][0]["fix"].as_str().unwrap().contains("use 3"));
    let motion = tokens(&Request::Test { subject: "180ms".into(), with: None }).unwrap();
    assert_eq!(motion.json["families"][0]["family"], "motion");
    assert_eq!(motion.json["ok"], true);
    let any = tokens(&Request::Test { subject: "11".into(), with: None }).unwrap();
    assert_eq!(any.json["ok"], true, "11 is the type scale's caption");
}

#[test]
fn no_manifest_reads_the_compiled_in_kit() {
    let answer = components(&Request::List(None), None).unwrap();
    assert_eq!(answer.json["available"], true);
    assert_eq!(answer.json["manifest"], BUILT_IN_SOURCE);
    let rows = answer.json["components"].as_array().unwrap();
    let pill = rows.iter().find(|c| c["name"] == "Pill").unwrap();
    assert_eq!(pill["tier"], "kit");
    let button = rows.iter().find(|c| c["name"] == "Button").unwrap();
    assert_eq!(button["tier"], "ui");
}

fn manifest() -> Value {
    json!({
        "galleryPath": "/gallery",
        "components": [
            { "name": "Button", "tier": "ui", "status": "stable", "summary": "A button.",
              "extends": ["ButtonHTMLAttributes"], "doc": "docs/Button.md",
              "props": [
                { "name": "size", "type": "\"sm\" | \"md\"", "optional": true },
                { "name": "tone", "type": "string", "optional": false }
              ] },
            { "name": "Pill", "tier": "kit", "status": "experimental", "summary": "A pill.",
              "extends": [], "props": [ { "name": "label", "type": "string", "optional": false } ] }
        ]
    })
}

#[test]
fn components_list_show_and_filter() {
    let path = Path::new("components.generated.json");
    let all = components_in(&Request::List(None), &manifest(), path).unwrap();
    assert_eq!(all.json["components"].as_array().unwrap().len(), 2);
    let kit = components_in(&Request::List(Some("kit".into())), &manifest(), path).unwrap();
    assert_eq!(kit.json["components"][0]["name"], "Pill");
    let shown = components_in(&Request::Show("button".into()), &manifest(), path).unwrap();
    assert_eq!(shown.json["component"]["doc"], "docs/Button.md");
    let error = components_in(&Request::Show("Butt".into()), &manifest(), path).err().unwrap();
    assert!(error.contains("Button"), "{error}");
}

#[test]
fn components_test_flags_unknown_and_missing_props() {
    let path = Path::new("components.generated.json");
    let test = |name: &str, props: &str| {
        components_in(
            &Request::Test { subject: name.into(), with: Some(props.into()) },
            &manifest(),
            path,
        )
        .unwrap()
        .json
    };
    let good = test("Pill", r#"{"label":"x","className":"a"}"#);
    assert_eq!(good["ok"], true);
    assert!(good["problems"].as_array().unwrap().is_empty());
    let bad = test("Pill", r#"{"lable":"x"}"#);
    assert_eq!(bad["ok"], false);
    let kinds: Vec<&str> =
        bad["problems"].as_array().unwrap().iter().filter_map(|p| p["problem"].as_str()).collect();
    assert_eq!(kinds, ["unknown", "missing"]);
    // A prop the component does not declare may pass through to what it extends.
    let inherited = test("Button", r#"{"tone":"a","onClick":1}"#);
    assert_eq!(inherited["ok"], true);
    assert_eq!(inherited["problems"][0]["problem"], "inherited?");
    assert!(
        components_in(
            &Request::Test { subject: "Pill".into(), with: Some("[1]".into()) },
            &manifest(),
            path
        )
        .is_err()
    );
}

// The compiled-in kit reader (kit/ts.rs), when no manifest is on disk.

fn component(name: &str) -> Value {
    components(&Request::Show(name.into()), None).expect("a kit component").json["component"]
        .clone()
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
fn every_built_in_component_has_props_and_an_example() {
    let list = built_in_manifest()["components"].as_array().expect("a list");
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
fn test_names_a_value_outside_a_union() {
    let test = |props: &str| {
        components(&Request::Test { subject: "Pill".into(), with: Some(props.into()) }, None)
            .unwrap()
            .json
    };
    let bad = test(r#"{"tone":"loud"}"#);
    assert_eq!(bad["ok"], false);
    let value = bad["problems"].as_array().unwrap().iter().find(|p| p["problem"] == "value");
    assert!(value.is_some_and(|p| p["fix"].as_str().unwrap().contains("neutral")), "{bad:#}");
    let good = test(r#"{"tone":"accent"}"#);
    assert!(!good["problems"].as_array().unwrap().iter().any(|p| p["problem"] == "value"));
}

#[test]
fn extra_token_groups_list_with_their_vars() {
    for group in EXTRA_GROUPS {
        let answer = tokens(&Request::List(Some((*group).into()))).expect(group);
        // elevation and glass are Instrument groups too; the scale's ride along.
        let rows = if answer.json["group"] == *group {
            &answer.json["tokens"]
        } else {
            &answer.json["designScale"]
        };
        let empty = match rows {
            Value::Array(a) => a.is_empty(),
            Value::Object(o) => o.is_empty(),
            _ => true,
        };
        assert!(!empty, "{group} is empty: {}", answer.json);
        let shown = tokens(&Request::Show((*group).into())).expect(group);
        assert_eq!(shown.json["group"], *group);
    }
    let color = tokens(&Request::List(Some("color".into()))).unwrap();
    let first = &color.json["tokens"]["roles"][0];
    assert!(first["var"].as_str().unwrap().starts_with("--ds-color-"), "{first}");
}

#[test]
fn family_steps_name_their_css_variable() {
    let radius = tokens(&Request::List(Some("radius".into()))).unwrap();
    let md = radius.json["scale"]["steps"]
        .as_array()
        .and_then(|r| r.iter().find(|s| s["name"] == "md"))
        .expect("md");
    assert_eq!(md["value"], 6.0);
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
