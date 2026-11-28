use super::*;
use serde_json::json;

fn reply() -> Value {
    json!({"session": {"id": "c", "timeBreakdown": {"totalMs": 5, "spans": [{"turnSeq": 1}]}}})
}

#[test]
fn a_client_holding_the_copy_gets_no_breakdown() {
    let mut first = reply();
    apply_with(&mut first, &json!({}), false);
    let version = first["timeBreakdownVersion"].as_str().unwrap().to_owned();
    assert!(first["session"]["timeBreakdown"].is_object(), "sent without a held version");
    let mut again = reply();
    apply_with(&mut again, &json!({"timeBreakdownVersion": version}), false);
    assert!(again["session"].get("timeBreakdown").is_none());
    assert_eq!(again["timeBreakdownVersion"], json!(version));
}

#[test]
fn a_client_that_draws_none_gets_none_even_after_a_change() {
    let mut held = reply();
    apply_with(&mut held, &json!({}), false);
    let mut changed = reply();
    changed["session"]["timeBreakdown"]["totalMs"] = json!(6);
    apply_with(
        &mut changed,
        &json!({"omitTimeBreakdown": true,
                                "timeBreakdownVersion": held["timeBreakdownVersion"]}),
        false,
    );
    assert!(changed["session"].get("timeBreakdown").is_none());
    assert!(changed["timeBreakdownVersion"].is_string(), "the version is still named");
    let mut asked = reply();
    apply_with(&mut asked, &json!({"omitTimeBreakdown": false}), false);
    assert!(asked["session"]["timeBreakdown"].is_object());
}

#[test]
fn a_changed_or_unknown_copy_is_sent_whole() {
    let mut changed = reply();
    let mut held = reply();
    apply_with(&mut held, &json!({}), false);
    changed["session"]["timeBreakdown"]["totalMs"] = json!(6);
    apply_with(&mut changed, &json!({"timeBreakdownVersion": held["timeBreakdownVersion"]}), false);
    assert!(changed["session"]["timeBreakdown"].is_object());
    assert_ne!(changed["timeBreakdownVersion"], held["timeBreakdownVersion"]);
    let mut other = reply();
    apply_with(&mut other, &json!({"timeBreakdownVersion": "0000000000000000"}), false);
    assert!(other["session"]["timeBreakdown"].is_object());
}

#[test]
fn a_reply_without_a_breakdown_names_a_null_version() {
    let mut bare = json!({"session": {"id": "c"}});
    apply_with(&mut bare, &json!({"timeBreakdownVersion": "x"}), false);
    assert_eq!(bare["timeBreakdownVersion"], Value::Null);
    assert_eq!(bare["session"], json!({"id": "c"}));
}

#[test]
fn a_connection_that_asked_for_none_gets_none_whatever_the_attach_sends() {
    let mut bare = reply();
    apply_with(&mut bare, &json!({}), true);
    assert!(bare["session"].get("timeBreakdown").is_none(), "{bare}");
    assert!(bare["timeBreakdownVersion"].is_string(), "the version is still named");
    let mut row = reply()["session"].clone();
    without(&mut row);
    assert_eq!(row, json!({"id": "c"}));
}
