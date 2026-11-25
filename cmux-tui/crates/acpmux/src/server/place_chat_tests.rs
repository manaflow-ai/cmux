//! `_acpmux/place_chat`: the reply `place_chat_decision` builds from the request params and
//! this host's budget, through `cmux_host_budget::place::decide`.

use super::place_chat_decision;
use cmux_host_budget::Level;
use cmux_host_budget::place::HereBudget;
use serde_json::{Value, json};

fn over() -> Option<HereBudget> {
    Some(HereBudget { level: Level::Warning, over: vec!["load1 9.0 >= 8 (8 cores)".into()] })
}

fn within() -> Option<HereBudget> {
    Some(HereBudget { level: Level::Normal, over: vec![] })
}

fn cloud(headroom: Value) -> Value {
    json!({"where": "auto", "targets": [{"place": "cloud", "headroom": headroom}]})
}

#[test]
fn place_chat_over_budget_spills_to_a_cloud_target_with_room() {
    let v = place_chat_decision(&cloud(json!("room")), over());
    assert_eq!(v["placement"], json!({"at": "there", "place": "cloud"}));
    assert_eq!(v["reason"]["code"], "over_budget");
    assert_eq!(v["reason"]["level"], "warning");
    assert_eq!(v["reason"]["over"], json!(["load1 9.0 >= 8 (8 cores)"]));
    assert_eq!(v["targets"], 1);
    let why = v["why"].as_str().unwrap();
    assert!(why.starts_with("this machine is over budget (Warning: load1 9.0"), "{why}");
}

#[test]
fn place_chat_without_targets_stays_here_and_says_none_is_available() {
    for params in [json!({"where": "auto", "targets": []}), json!({})] {
        let v = place_chat_decision(&params, over());
        assert_eq!(v["placement"], json!({"at": "here"}));
        assert_eq!(v["reason"]["code"], "no_room");
        assert_eq!(v["reason"]["places"], json!([]));
        assert_eq!(v["targets"], 0);
        let why = v["why"].as_str().unwrap();
        assert!(why.contains("no other machine is available"), "{why}");
    }
}

#[test]
fn place_chat_within_budget_stays_here() {
    let v = place_chat_decision(&cloud(json!("room")), within());
    assert_eq!(v["placement"], json!({"at": "here"}));
    assert_eq!(v["reason"], json!({"code": "within_budget", "level": "normal"}));
    assert_eq!(v["targets"], 1);
}

#[test]
fn place_chat_without_a_budget_reading_stays_here() {
    let v = place_chat_decision(&cloud(json!("room")), None);
    assert_eq!(v["placement"], json!({"at": "here"}));
    assert_eq!(v["reason"], json!({"code": "budget_unknown"}));
    assert_eq!(v["why"], "this machine's budget could not be read");
}

#[test]
fn place_chat_where_here_wins_over_the_budget() {
    let params = json!({"where": "here", "targets": [{"place": "cloud", "headroom": "room"}]});
    let v = place_chat_decision(&params, over());
    assert_eq!(v["placement"], json!({"at": "here"}));
    assert_eq!(v["reason"], json!({"code": "asked_here"}));
    let to = place_chat_decision(&json!({"where": "cloud"}), within());
    assert_eq!(to["placement"], json!({"at": "there", "place": "cloud"}));
    assert_eq!(to["reason"], json!({"code": "asked_there"}));
}

#[test]
fn place_chat_never_spills_to_a_target_whose_room_is_not_known() {
    for headroom in [json!("unknown"), json!("stale"), json!(null), json!({"full": ["mem 95%"]})] {
        let v = place_chat_decision(&cloud(headroom.clone()), over());
        assert_eq!(v["placement"], json!({"at": "here"}), "{headroom}");
        assert_eq!(v["reason"]["code"], "no_room", "{headroom}");
        assert_eq!(v["reason"]["places"][0]["place"], "cloud");
    }
    let v = place_chat_decision(&cloud(json!("bogus")), over());
    assert_eq!(v["reason"]["places"][0]["headroom"], "unknown");
    assert!(v["why"].as_str().unwrap().contains("cloud room unknown"));
}

#[test]
fn place_chat_with_auto_cloud_off_has_no_fork() {
    let params = json!({"where": "auto", "parent": {"machine": "vm_a", "fork": true}, "key": "s1"});
    let v = super::with_fork(place_chat_decision(&params, within()), &params, false);
    assert!(v.get("fork").is_none(), "{v}");
}

#[test]
fn place_chat_with_auto_cloud_on_forks_the_parent_and_keeps_the_warm_placement() {
    let params = json!({"where": "auto", "targets": [{"place": "cloud", "headroom": "room"}],
        "parent": {"machine": "vm_a", "fork": true}, "key": "s1"});
    let v = super::with_fork(place_chat_decision(&params, over()), &params, true);
    assert_eq!(v["fork"], json!({"at": "fork", "machine": "vm_a", "clientKey": "autocloud-s1"}));
    assert_eq!(v["placement"], json!({"at": "there", "place": "cloud"}));
    let local = json!({"where": "auto", "key": "s1"});
    let v = super::with_fork(place_chat_decision(&local, within()), &local, true);
    assert_eq!(v["fork"]["at"], "warm");
}
