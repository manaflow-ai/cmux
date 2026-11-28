//! Ported from the app's `CloudFrontedChatsTests`.

use super::*;
use serde_json::json;

fn mac() -> Tab {
    Tab { machine: "local".into(), key: "mac-tab".into() }
}

fn front() -> Front {
    Front { machine: "vm-1".into(), key: "cloud-tab".into(), workspace: "cloud-ws".into() }
}

fn ids(fronts: &Fronted) -> Vec<String> {
    fronts.workspace_ids().into_iter().collect()
}

#[test]
fn a_start_holds_its_workspace_before_it_lists_and_the_mac_tab_shows_the_chat() {
    let mut fronts = Fronted::default();
    assert!(fronts.is_empty());
    fronts.hold("cloud-ws".into());
    assert_eq!(ids(&fronts), ["cloud-ws"]);
    assert_eq!(fronts.front_of(&mac()), None);
    fronts.front(mac(), front());
    assert_eq!(fronts.front_of(&mac()), Some(&front()));
    assert_eq!(ids(&fronts), ["cloud-ws"]);
    assert!(fronts.making.is_empty(), "the front took the held workspace");
    assert_eq!(fronts.mac_showing(&front().tab()), Some(mac()));
    assert_eq!(fronts.mac_showing_workspace("cloud-ws"), Some(mac()));
    assert_eq!(fronts.front_of(&Tab { machine: "vm-1".into(), key: "mac-tab".into() }), None);
}

#[test]
fn closing_the_mac_tab_ends_the_cloud_chat() {
    let mut fronts = Fronted::default();
    fronts.front(mac(), front());
    assert_eq!(fronts.gone(&mac()), Gone::CloseCloud { front: front() });
    assert!(fronts.is_empty());
    assert!(fronts.workspace_ids().is_empty());
}

#[test]
fn the_cloud_tab_going_gives_the_mac_tab_its_own_page_back() {
    let mut fronts = Fronted::default();
    fronts.front(mac(), front());
    assert_eq!(fronts.gone(&Tab { machine: "vm-1".into(), key: "other".into() }), Gone::Nothing);
    assert_eq!(fronts.front_of(&mac()), Some(&front()));
    assert_eq!(fronts.gone(&front().tab()), Gone::Reshow { mac: mac(), cloud: front().tab() });
    assert_eq!(fronts.front_of(&mac()), None);
}

#[test]
fn the_cloud_tab_going_says_which_chat_ended_when_the_mac_tab_draws_again() {
    let mut fronts = Fronted::default();
    fronts.front(mac(), front());
    assert!(
        matches!(fronts.gone(&mac()), Gone::CloseCloud { .. }),
        "closing the Mac tab ends the chat on purpose: no notice"
    );
    fronts.front(mac(), front());
    let Gone::Reshow { mac: shown, cloud } = fronts.gone(&front().tab()) else {
        panic!("a reshow")
    };
    assert_eq!((shown.key.as_str(), cloud.key.as_str()), ("mac-tab", "cloud-tab"));
}

#[test]
fn fronts_last_across_a_relaunch() {
    let mut fronts = Fronted::default();
    fronts.front(mac(), front());
    let kept = serde_json::to_value(fronts.persisted().expect("kept")).expect("json");
    assert_eq!(
        kept,
        json!([{"machine": "local", "key": "mac-tab", "front": {"machine": "vm-1", "key": "cloud-tab", "workspace": "cloud-ws"}}])
    );
    let mut relaunched = Fronted::default();
    relaunched.restore(serde_json::from_value(kept).expect("entries"));
    assert_eq!(relaunched.front_of(&mac()), Some(&front()));
    assert_eq!(ids(&relaunched), ["cloud-ws"]);
    relaunched.gone(&mac());
    assert_eq!(relaunched.persisted(), None, "no fronts: the key goes");
}

#[test]
fn the_kept_entries_are_sorted_and_one_per_mac_tab() {
    let mut fronts = Fronted::default();
    let tab = |machine: &str, key: &str| Tab { machine: machine.into(), key: key.into() };
    let front_on = |workspace: &str| Front {
        machine: "vm".into(),
        key: workspace.into(),
        workspace: workspace.into(),
    };
    fronts.front(tab("local", "b"), front_on("w1"));
    fronts.front(tab("local", "a"), front_on("w2"));
    fronts.front(tab("another", "z"), front_on("w3"));
    fronts.front(tab("local", "b"), front_on("w4"));
    let order: Vec<(&str, &str, &str)> = fronts
        .persisted()
        .expect("kept")
        .iter()
        .map(|entry| (entry.machine.as_str(), entry.key.as_str(), entry.front.workspace.as_str()))
        .collect();
    assert_eq!(order, [("another", "z", "w3"), ("local", "a", "w2"), ("local", "b", "w4")]);
    assert_eq!(DEFAULTS_KEY, "cmux.cloud.frontedChats");
}
