use super::*;

const FIXTURE: &str = include_str!("../tests/fixtures/browser_site_engines.json");

fn fixture() -> Value {
    serde_json::from_str(FIXTURE).expect("the fixture parses")
}

#[test]
fn the_shared_cases_match_the_app() {
    let fixture = fixture();
    let defaults = fixture["defaults"].as_object().expect("defaults").clone();
    for suite in fixture["suites"].as_array().expect("suites") {
        let rules = match &suite["rules"] {
            Value::String(name) if name == "defaults" => defaults.clone(),
            Value::Object(rules) => rules.clone(),
            other => panic!("bad rules {other}"),
        };
        for case in suite["cases"].as_array().expect("cases") {
            let url = case[0].as_str().expect("url");
            let expected = case[1].as_str().map(|engine| engine_tag(engine).expect("engine"));
            assert_eq!(site_engine(&rules, url), expected, "{url}");
        }
    }
}
