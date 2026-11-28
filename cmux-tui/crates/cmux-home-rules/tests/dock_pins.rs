//! Parity with HomeSidebarLaunchCacheSchemaTests, HomeSidebarLaunchCache's save coalescing,
//! HomePinMigration and HomeSidebarSource's pin and hide rules, through the `dock.*` op table.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: &Value) -> Value {
    call(&format!("dock.{name}"), request).unwrap_or_else(|err| panic!("dock.{name}: {err}"))
}

#[test]
fn the_fingerprint_is_fnv1a_in_16_hex_digits() {
    assert_eq!(op("launch_cache_fingerprint", &json!({"shape": ""})), json!("cbf29ce484222325"));
    assert_eq!(op("launch_cache_fingerprint", &json!({"shape": "a"})), json!("af63dc4c8601ec8c"));
    let before = op("launch_cache_fingerprint", &json!({"shape": "Before|account:Swift.String"}));
    let after = op("launch_cache_fingerprint", &json!({"shape": "Before|account:Swift.Int"}));
    assert_eq!(before.as_str().map(str::len), Some(16));
    assert_ne!(before, after);
}

#[test]
fn the_cache_file_and_keys() {
    assert_eq!(
        op("launch_cache_path", &json!({"owner": "me@x.com/1"})),
        json!("cmux-home/me-x-com-1/sidebar.json")
    );
    assert_eq!(
        op("launch_cache_path", &json!({"owner": "ok_-9"})),
        json!("cmux-home/ok_-9/sidebar.json")
    );
    assert_eq!(op("launch_cache_inbox_key", &json!({"owners": ["a", "b"]})), json!("a,b"));
    let accepts = |schema: &str, account: &str| {
        op(
            "launch_cache_load_accepts",
            &json!({"schema": "s", "fileSchema": schema, "account": "me", "fileAccount": account}),
        )
    };
    assert_eq!(accepts("s", "me"), json!(true));
    assert_eq!(accepts("old", "me"), json!(false), "a file of another schema");
    assert_eq!(accepts("s", "other"), json!(false), "another account's file");
}

fn save(state: &Value, event: Value) -> Value {
    op("launch_cache_step", &json!({"state": state, "event": event}))
}

#[test]
fn saves_coalesce_into_one_write() {
    let state = json!({});
    let first = save(&state, json!({"type": "save", "snapshot": {"n": 1}}));
    assert_eq!(first["schedule"], json!(true));
    let second = save(&first["state"], json!({"type": "save", "snapshot": {"n": 2}}));
    assert_eq!(second["schedule"], json!(false), "one write in flight");
    let flush = save(&second["state"], json!({"type": "flush"}));
    assert_eq!(flush["write"], json!({"n": 2}), "the latest save is written");
    let written = save(&flush["state"], json!({"type": "written", "snapshot": {"n": 2}}));
    let same = save(&written["state"], json!({"type": "save", "snapshot": {"n": 2}}));
    assert_eq!(same["schedule"], json!(false), "what is on disk is not written again");
    assert_eq!(same["state"]["pending"], Value::Null);
    let empty = save(&same["state"], json!({"type": "flush"}));
    assert_eq!(empty["write"], Value::Null);
}

#[test]
fn the_pin_migration_drops_pins_the_owner_has_and_sends_the_rest() {
    let rows = json!([
        {"id": "a", "pinned": true},
        {"id": "b", "pinned": false},
        {"id": "b", "pinned": true},
        {"id": "c", "pinned": false},
        {"id": "d", "pinned": false},
    ]);
    let run = op(
        "pin_migration_run",
        &json!({"cloud": "ok", "rows": rows, "kept": ["a", "b", "c", "d", "gone"], "sending": ["c"], "refused": ["d"]}),
    );
    assert_eq!(
        run,
        json!({"drop": ["a"], "send": ["b"], "sending": ["b", "c"]}),
        "the first row of an id wins"
    );
    let unavailable =
        op("pin_migration_run", &json!({"cloud": "unavailable", "rows": rows, "kept": ["a"]}));
    assert_eq!(unavailable, json!({"drop": [], "send": [], "sending": []}));
    let empty = op("pin_migration_run", &json!({"rows": [], "kept": ["a"]}));
    assert_eq!(empty["send"], json!([]));
    let adopted = op(
        "pin_migration_adopted",
        &json!({"ids": ["b", "e"], "accepted": ["b"], "sending": ["b", "c", "e"]}),
    );
    assert_eq!(adopted, json!({"sending": ["c"], "refused": ["e"], "drop": ["b"]}));
    let dropped = op(
        "pin_drop",
        &json!({"pins": {"pinned": ["a", "b"], "positions": {"a": 1, "b": 2}}, "gone": ["a"]}),
    );
    assert_eq!(dropped, json!({"pinned": ["b"], "positions": {"b": 2}}));
}

#[test]
fn a_hidden_row_shows_again_after_a_new_message() {
    let rows =
        json!([{"id": "a", "lastSeq": 5}, {"id": "b", "lastSeq": 7}, {"id": "c", "lastSeq": 1}]);
    let shown = op("sidebar_shows", &json!({"rows": rows, "hidden": {"a": 5, "b": 6}}));
    assert_eq!(shown, json!(["b", "c"]));
    let hidden = op("sidebar_hide", &json!({"id": "c", "rows": rows, "hidden": {"a": 5}}));
    assert_eq!(hidden, json!({"a": 5, "c": 1}));
    assert_eq!(op("sidebar_hide", &json!({"id": "zz", "rows": rows})), Value::Null);
}

#[test]
fn placing_a_pin_numbers_the_order_per_owner() {
    let inboxes = json!([["a", "c"], null, ["b"]]);
    assert_eq!(op("sidebar_owner_of", &json!({"id": "b", "inboxes": inboxes})), json!(2));
    assert_eq!(op("sidebar_owner_of", &json!({"id": "x", "inboxes": inboxes})), Value::Null);
    let plan = op(
        "sidebar_place",
        &json!({"pinned": ["a", "b", "x", "c"], "id": "c", "index": 0, "base": 100, "inboxes": inboxes}),
    );
    assert_eq!(
        plan,
        json!({
            "inboxes": [[{"id": "c", "position": 100}, {"id": "a", "position": 101}], [], [{"id": "b", "position": 102}]],
            "local": [{"id": "x", "position": 103}],
        })
    );
    let clamped = op("sidebar_place", &json!({"pinned": ["a"], "id": "x", "index": 9, "base": 0}));
    assert_eq!(clamped["local"], json!([{"id": "a", "position": 0}, {"id": "x", "position": 1}]));
    let negative =
        op("sidebar_place", &json!({"pinned": ["a"], "id": "x", "index": -3, "base": 0}));
    assert_eq!(negative["local"][0]["id"], json!("x"));
}

#[test]
fn marking_unread_changes_only_when_it_differs() {
    assert_eq!(
        op("sidebar_mark_unread", &json!({"on": true, "id": "a", "marks": ["b"]})),
        json!(["a", "b"])
    );
    assert_eq!(
        op("sidebar_mark_unread", &json!({"on": true, "id": "a", "marks": ["a"]})),
        Value::Null
    );
    assert_eq!(
        op("sidebar_mark_unread", &json!({"on": false, "id": "a", "marks": ["a"]})),
        json!([])
    );
}
