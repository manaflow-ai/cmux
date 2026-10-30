//! `choice_or_url` (Swift `SettingKind.choiceOrURL`, `home.server`): one of the
//! choices, or an object whose only member `url_key` is an http(s) origin. The
//! daemon must load a schema with such a row and agree with Swift on it.

use cmux_config::Domains;
use cmux_config::schema::{Schema, accepts};
use serde_json::{Value, json};

fn schema() -> Schema {
    let row = json!({
        "key": "home.server", "path": ["home", "server"], "section": "home",
        "group": {"text": "Messages Server", "key": "settings.group.messagesServer"},
        "title": {"text": "Server", "key": "settings.home.server"},
        "kind": "choice_or_url", "url_key": "selfHosted",
        "choices": [{"value": "hosted", "title": {"text": "cmux Cloud", "key": "settings.choice.homeServer.hosted"}}],
        "default": "hosted", "keywords": [], "agent_settable": false, "kept_on_reset_all": false,
        "validation": "portable", "accepts": [], "refuses": [],
    });
    let document = json!({"version": 1, "sections": [], "page": {"categories": []}, "rows": [row]});
    Schema::parse(&document.to_string()).expect("a choice_or_url row parses")
}

fn accepted(value: Value) -> bool {
    let schema = schema();
    let row = schema.row("home.server").expect("row");
    accepts(row, &value, &Domains::default()).is_ok()
}

#[test]
fn a_choice_or_a_self_hosted_origin_is_accepted() {
    for value in [
        json!("hosted"),
        json!({"selfHosted": "http://mini.tail1234.ts.net:7320"}),
        json!({"selfHosted": "http://mini.tail1234.ts.net:7320/"}),
        json!({"selfHosted": "https://100.101.102.103"}),
    ] {
        assert!(accepted(value.clone()), "{value}");
    }
}

#[test]
fn anything_else_is_refused() {
    for value in [
        json!("selfHosted"),
        json!(1),
        json!(true),
        json!({"selfHosted": "ftp://mini.tail1234.ts.net"}),
        json!({"selfHosted": "http://mini.tail1234.ts.net/path"}),
        json!({"selfHosted": "http://mini.tail1234.ts.net?x=1"}),
        json!({"selfHosted": "http://user@mini.tail1234.ts.net"}),
        json!({"selfHosted": "not a url"}),
        json!({"selfHosted": 7320}),
        json!({"other": "http://mini.tail1234.ts.net"}),
        json!({"selfHosted": "http://mini.tail1234.ts.net", "extra": "x"}),
    ] {
        assert!(!accepted(value.clone()), "{value}");
    }
}

#[test]
fn the_kind_keeps_its_export_name() {
    let schema = schema();
    assert_eq!(schema.row("home.server").expect("row").kind.name(), "choice_or_url");
}
