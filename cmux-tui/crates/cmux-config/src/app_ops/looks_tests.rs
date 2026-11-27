use super::*;
use serde_json::json;

#[test]
fn density_ops_keep_defaults_and_clamp_numbers() {
    let density = json!({
        "id": "my-tight",
        "name": "  My Tight  ",
        "level": -4,
        "fontSize": 80,
        "tokens": {"row": 22}
    });
    let value =
        call("densities.json", &json!({"density": density})).unwrap().unwrap()["value"].clone();
    assert_eq!(value["id"], json!("my-tight"));
    assert_eq!(value["name"], json!("My Tight"));
    assert_eq!(value["level"].as_f64(), Some(-1.0));
    assert_eq!(value["fontSize"].as_f64(), Some(20.0));
    assert_eq!(value["tokens"]["row"].as_f64(), Some(22.0));
}

#[test]
fn density_parse_skips_bad_and_duplicate_entries() {
    let reply = call(
        "densities.parse",
        &json!({
            "root": {"appearance": {"customDensities": [
                {"id": "my-tight", "name": "My Tight"},
                {"id": "my-tight", "name": "Again"},
                {"id": "Bad Id", "name": "Bad"}
            ]}}
        }),
    )
    .unwrap()
    .unwrap();
    assert_eq!(reply["densities"].as_array().map(Vec::len), Some(1));
    assert_eq!(reply["diagnostics"].as_array().map(Vec::len), Some(2));
}

#[test]
fn backdrop_ops_filter_recents_and_canonicalize_placement() {
    let root = json!({"appearance": {"background": "daily", "backgroundRecents": [
        "daily", "file:/wall.png", "file:/wall.png", "junk"
    ]}});
    let recents = call("backdrop.recents", &json!({"root": root})).unwrap().unwrap();
    assert_eq!(recents["recents"], json!(["daily", "file:/wall.png"]));
    assert_eq!(
        call("backdrop.previous", &json!({"root": {"appearance": {"background": "daily", "backgroundRecents": ["daily", "file:/wall.png"]}}}))
            .unwrap()
            .unwrap()["value"],
        json!("file:/wall.png")
    );
    assert_eq!(
        call("backdrop.placement", &json!({"action": "parse", "text": "fit 0.3000 0.7000"}),)
            .unwrap()
            .unwrap()["value"],
        json!("fit 0.3 0.7")
    );
}

#[test]
fn omnibar_search_template_matches_schema() {
    assert_eq!(
        call("omnibar.search_template", &json!({"text": "https://example.com/?q=%s"}))
            .unwrap()
            .unwrap()["valid"],
        json!(true)
    );
    assert_eq!(
        call("omnibar.search_template", &json!({"text": "https://example.com/"})).unwrap().unwrap()
            ["valid"],
        json!(false)
    );
}

#[test]
fn managed_guard_answers_the_swift_write_cases() {
    let managed = json!({"appearance.borders": {"source": "device"}});
    let blocked = call(
        "managed.guard_set",
        &json!({"managed": managed, "path": ["appearance"], "value": {"borders": "on"}}),
    )
    .unwrap()
    .unwrap();
    assert_eq!(blocked["key"], json!("appearance.borders"));
    assert_eq!(blocked["source"], json!("mdm"));
    assert_eq!(
        call("managed.guard_remove", &json!({"managed": managed, "path": ["appearance"]}))
            .unwrap()
            .unwrap(),
        json!({})
    );
}
