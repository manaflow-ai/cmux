use super::*;

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
fn no_manifest_says_how_to_make_one() {
    let answer = components(&Request::List(None), None).unwrap();
    assert_eq!(answer.json["available"], false);
    assert!(answer.human.contains("gen-component-manifest"));
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
