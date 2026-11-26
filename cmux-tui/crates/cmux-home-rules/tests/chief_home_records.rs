//! `chief_home` Chief records, archived Chiefs and cloud Chiefs: the cases of the Swift
//! `HomeChiefHostedSettingsTests`, `HomeArchivedChiefsDeletedTests` and `HomeChiefRosterTests`.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("chief_home.{name}"), &request)
        .unwrap_or_else(|err| panic!("chief_home.{name}: {err}"))
}

fn directory() -> Value {
    json!({
        "chiefs": [
            {"id": "agent", "display_name": "Chief", "is_default": true, "rev": 3, "main_conversation": "c1"},
            {"id": "agent_placed", "display_name": "Placed", "rev": 1, "brain_place": {"host": "h", "install": "i"}},
            {"id": "agent_old", "display_name": "Old", "rev": 2, "archived_at": "2026-11-01T00:00:00Z"},
            {"display_name": "no id"}
        ],
        "tombstones": [{"id": "agent_gone"}, {"id": "agent_old"}]
    })
}

#[test]
fn list_keeps_live_chiefs_and_archived_ids_add_tombstones() {
    let chiefs = op("record_list", json!({ "value": directory() }));
    let ids: Vec<&str> =
        chiefs["chiefs"].as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["agent", "agent_placed"]);
    assert_eq!(chiefs["chiefs"][0]["isDefault"], true);
    assert_eq!(chiefs["chiefs"][0]["mainConversation"], "c1");
    assert_eq!(chiefs["chiefs"][1]["placed"], true);
    assert_eq!(chiefs["chiefs"][0]["placed"], false);

    let mut no_stones = directory();
    no_stones.as_object_mut().unwrap().remove("tombstones");
    assert_eq!(op("archived_ids", json!({ "value": no_stones }))["ids"], json!(["agent_old"]));
    assert_eq!(
        op("archived_ids", json!({ "value": directory() }))["ids"],
        json!(["agent_old", "agent_gone"])
    );
    // One item that is no object drops the whole list, as `as? [[String: Any]]` does.
    let broken = json!({ "chiefs": [{"id": "agent"}, 3] });
    assert_eq!(op("record_list", json!({ "value": broken }))["chiefs"], json!([]));
}

#[test]
fn archived_chiefs_hide_their_rows_and_dms() {
    let rows = json!([
        {"id": "c-live", "kind": "chief", "participants": ["user_me", "agent"]},
        {"id": "c-old", "kind": "chief", "participants": ["user_me", "agent_old"]},
        {"id": "c-chat", "kind": "chat", "participants": ["user_me", "agent_old"]}
    ]);
    let base = json!({ "ids": ["agent_old"], "me": "user_me", "rows": rows });
    assert_eq!(op("archived_visible", base.clone())["visible"], json!(["c-live", "c-chat"]));
    assert_eq!(op("archived_hidden", base.clone())["hidden"], json!(["c-old"]));
    let mut than = base.clone();
    than["than"] = json!("c-other");
    assert_eq!(op("archived_other_chiefs", than)["count"], 1);
    let mut hides = base.clone();
    hides["participants"] = json!(["user_me", "agent_old"]);
    assert_eq!(op("archived_hides", hides.clone())["hides"], true);
    hides["participants"] = json!(["user_me", "agent_old", "agent"]);
    assert_eq!(op("archived_hides", hides)["hides"], false);
    let mut openable = base.clone();
    openable["chief"] = json!("c-old");
    assert_eq!(op("archived_openable", openable.clone())["openable"], Value::Null);
    openable["chief"] = json!("c-live");
    assert_eq!(op("archived_openable", openable.clone())["openable"], "c-live");
    openable["chief"] = json!("c-unlisted");
    openable["participants"] = json!(["user_me", "agent_old"]);
    assert_eq!(op("archived_openable", openable)["openable"], Value::Null);
    // Nothing archived shows everything and hides nothing.
    let none = json!({ "rows": base["rows"] });
    assert_eq!(op("archived_visible", none.clone())["visible"].as_array().unwrap().len(), 3);
    assert_eq!(op("archived_hidden", none)["hidden"], json!([]));
}

#[test]
fn cloud_chiefs_parse_and_switch_hosts() {
    let hosted = op("cloud_parse", json!({ "value": {"id": "h", "rev": 2, "main_conversation": "ch", "display_name": "Hosted"} }))["chief"].clone();
    let placed = op("cloud_parse", json!({ "value": {"id": "p", "rev": 1, "main_conversation": "cp", "brain_place": {"host": "mac", "install": "i1"}} }))["chief"].clone();
    assert_eq!(hosted["displayName"], "Hosted");
    assert_eq!(placed["brainPlace"], json!({"host": "mac", "install": "i1"}));
    assert_eq!(op("cloud_parse", json!({ "value": {"id": "x"} }))["chief"], Value::Null);
    assert_eq!(
        op(
            "cloud_parse",
            json!({ "value": {"id": "x", "rev": 1, "brain_place": {"host": "mac"}} })
        )["chief"]["brainPlace"],
        Value::Null
    );
    assert_eq!(op("cloud_choice", json!({ "choice": "placed" }))["choice"], "placed");
    assert_eq!(op("cloud_choice", json!({ "choice": "weird" }))["choice"], "hosted");

    let both = |conversation: &str| {
        op(
            "cloud_chiefs",
            json!({ "hosted": hosted, "placed": placed, "conversation": conversation, "choice": "placed" }),
        )
    };
    assert_eq!(both("ch")["otherHost"], "placed");
    assert_eq!(both("cp")["otherHost"], "hosted");
    assert_eq!(both("other")["otherHost"], Value::Null);
    assert_eq!(both("cp")["shown"]["id"], "p");
    assert_eq!(both("cp")["chiefFor"]["id"], "p");
    assert_eq!(both("ch")["canSwitch"], true);
    let only =
        op("cloud_chiefs", json!({ "hosted": hosted, "conversation": "ch", "choice": "placed" }));
    assert_eq!(only["otherHost"], Value::Null);
    assert_eq!(only["canSwitch"], false);
    assert_eq!(only["shown"]["id"], "h");
}
