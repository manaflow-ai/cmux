//! The shared cases (cmux-tui-core/tests/fixtures/browser_site_engines.json,
//! which the app's Swift test runs too) and the read's problems, pinned from
//! Swift `BrowserSiteEngines` and the daemon's copy before the move.

use serde_json::{Value, json};

use super::*;

const FIXTURE: &str = include_str!("../../cmux-tui-core/tests/fixtures/browser_site_engines.json");

fn pieces(url: &str) -> (String, String, String) {
    let parsed = url::Url::parse(url).expect("url");
    (
        parsed.scheme().to_owned(),
        parsed.host_str().unwrap_or("").to_owned(),
        parsed.path().to_owned(),
    )
}

fn engine_of(rules: &Value, url: &str) -> Option<&'static str> {
    let (scheme, host, path) = pieces(url);
    engine(rules.as_object().expect("rules"), &scheme, &host, &path)
}

#[test]
fn the_shared_cases() {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("the fixture parses");
    let defaults = fixture["defaults"].clone();
    for suite in fixture["suites"].as_array().expect("suites") {
        let rules = match &suite["rules"] {
            Value::String(name) if name == "defaults" => defaults.clone(),
            rules => rules.clone(),
        };
        let normal = Value::Object(normalized(rules.as_object().expect("rules")));
        for case in suite["cases"].as_array().expect("cases") {
            let url = case[0].as_str().expect("url");
            assert_eq!(engine_of(&rules, url), case[1].as_str(), "{url}");
            assert_eq!(engine_of(&normal, url), case[1].as_str(), "normalized: {url}");
        }
    }
}

#[test]
fn the_schema_default_is_the_shared_default_list() {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("the fixture parses");
    let row =
        crate::schema::Schema::embedded().row(KEY).expect("browser.siteEngines is in the schema");
    assert_eq!(row.default.as_ref(), Some(&fixture["defaults"]));
}

#[test]
fn the_most_specific_rule_wins() {
    let rules = json!({"example.com": "webkit", "app.example.com": "chromium", "example.com/docs": "chromium",
                       "example.com/docs/old": "webkit"});
    assert_eq!(engine_of(&rules, "https://www.example.com/"), Some("webkit"));
    assert_eq!(engine_of(&rules, "https://app.example.com/docs"), Some("chromium"));
    assert_eq!(engine_of(&rules, "https://example.com/docs/new"), Some("chromium"));
    assert_eq!(engine_of(&rules, "https://example.com/docs/old/a"), Some("webkit"));
    assert_eq!(engine_of(&rules, "https://example.com/docsx"), Some("webkit"));
}

#[test]
fn patterns_are_normalized() {
    let rules = json!({" HTTPS://*.Open.Spotify.com/ ": "webkit"});
    assert_eq!(
        Value::Object(normalized(rules.as_object().unwrap())),
        json!({"open.spotify.com": "webkit"})
    );
    assert_eq!(
        engine(rules.as_object().unwrap(), "HTTPS", "OPEN.spotify.com.", "/x"),
        Some("webkit")
    );
    assert_eq!(engine(rules.as_object().unwrap(), "https", "", "/"), None);
    assert_eq!(
        engine(rules.as_object().unwrap(), "https", "open.spotify.com", ""),
        Some("webkit"),
        "no path is /"
    );
    assert_eq!(normalize("/path"), None);
    assert_eq!(normalize("a b.com"), None);
    assert_eq!(normalize("example.com/"), Some("example.com".to_owned()));
}

#[test]
fn the_read_takes_good_entries_and_names_bad_ones() {
    let (rules, problems) = read(&json!({}));
    assert_eq!((rules, problems.len()), (None, 0), "missing: the default, quietly");
    let (rules, problems) = read(&json!({"browser": {"siteEngines": "webkit"}}));
    assert_eq!(rules, None);
    assert_eq!(
        problems,
        [Problem {
            message: "expected an object of site to \"chromium\" or \"webkit\"".to_owned()
        }]
    );
    let (rules, problems) = read(&json!({"browser": {"siteEngines": {}}}));
    assert_eq!((rules.map(|r| r.len()), problems.len()), (Some(0), 0));
    let (rules, problems) = read(&json!({"browser": {"siteEngines": {
        "Netflix.com": "chromium", "example.com": "webkit", "bad.com": "safari", "/x": "webkit"}}}));
    assert_eq!(
        Value::Object(rules.unwrap()),
        json!({"netflix.com": "chromium", "example.com": "webkit"})
    );
    let mut messages: Vec<String> = problems.into_iter().map(|p| p.message).collect();
    messages.sort();
    assert_eq!(
        messages,
        [
            "/x: expected a site and \"chromium\" or \"webkit\"",
            "bad.com: expected a site and \"chromium\" or \"webkit\"",
        ]
    );
}
