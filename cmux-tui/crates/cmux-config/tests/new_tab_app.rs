//! `tabs.newTabApp` names an app by id: the owner accepts exactly the ids an
//! app manifest may have (cmux-app.schema.json `properties.id.pattern`, read
//! from that schema by the owner), so `cmux settings set` refuses an
//! id no app can carry, such as `Foo/Bar`.

use cmux_config::Domains;
use cmux_config::schema::{Schema, accepts};
use serde_json::{Value, json};

fn accepted(value: Value) -> bool {
    let schema = Schema::embedded();
    let row = schema.row("tabs.newTabApp").expect("tabs.newTabApp is a row");
    accepts(row, &value, &Domains::default()).is_ok()
}

#[test]
fn new_tab_app_accepts_manifest_app_ids() {
    for id in ["local/web-pane", "local/showcase-newtab", "manaflow-ai/launcher", "0x/a-b"] {
        assert!(accepted(json!(id)), "{id} is a manifest app id");
    }
}

#[test]
fn new_tab_app_refuses_what_no_manifest_can_be() {
    for id in [
        "Foo/Bar",
        "local/Web",
        "foo/bar/baz",
        "foo",
        "/bar",
        "foo/",
        "-foo/bar",
        "foo/-bar",
        "a b/c",
        "",
    ] {
        assert!(!accepted(json!(id)), "{id} is no manifest app id");
    }
    assert!(!accepted(json!(1)));
}
