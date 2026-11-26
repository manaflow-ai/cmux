use super::*;
use serde_json::{Value, json};

fn tab(id: &str) -> Tab {
    Tab { id: id.into(), pinned: false, group: None, audio: None }
}

fn member(id: &str, group: &str) -> Tab {
    Tab { group: Some(group.into()), ..tab(id) }
}

fn pinned(id: &str) -> Tab {
    Tab { pinned: true, ..tab(id) }
}

fn group(id: &str) -> Group {
    Group { id: id.into(), name: String::new(), tint: None, collapsed: false, saved: false }
}

fn ids(tabs: &[Tab]) -> Vec<&str> {
    tabs.iter().map(|tab| tab.id.as_str()).collect()
}

/// a, then group G (g1, g2), then x; x selected (MoveTabPastGroupTests' strip).
fn strip() -> Strip {
    Strip {
        tabs: vec![tab("a"), member("g1", "G"), member("g2", "G"), tab("x")],
        groups: vec![group("G")],
        selected: Some("x".into()),
    }
}

fn moved(id: &str, to: usize) -> Vec<String> {
    let mut tabs = strip().ordered();
    let from = tabs.iter().position(|tab| tab.id == id).unwrap();
    let item = tabs.remove(from);
    tabs.insert(to, item);
    normalized(&tabs, &HashSet::from(["G".to_owned()])).into_iter().map(|tab| tab.id).collect()
}

#[test]
fn a_tab_moved_into_a_group_span_lands_past_the_whole_group() {
    // MoveTabPastGroupTests: the daemon's move then the ordering.
    assert_eq!(moved("x", 1), ["a", "x", "g1", "g2"]);
    assert_eq!(moved("a", 2), ["g1", "g2", "a", "x"]);
    assert_eq!(moved("g1", 2), ["a", "g2", "g1", "x"]);
}

#[test]
fn normalized_puts_pinned_first_ungrouped_and_gathers_members() {
    let tabs = vec![
        member("g1", "G"),
        tab("a"),
        Tab { pinned: true, ..member("p", "G") },
        member("g2", "G"),
        member("u", "Gone"),
    ];
    let out = normalized(&tabs, &HashSet::from(["G".to_owned()]));
    assert_eq!(ids(&out), ["p", "g1", "g2", "a", "u"]);
    assert_eq!(out[0].group, None, "a pinned tab is never grouped");
    assert_eq!(out[4].group, None, "a tab naming a missing group is ungrouped");
}

#[test]
fn layout_puts_one_chip_before_each_group() {
    let mut collapsed = group("G");
    collapsed.collapsed = true;
    let items = layout_items(&strip().ordered(), &[collapsed], Some("x"));
    let value = serde_json::to_value(&items).unwrap();
    assert_eq!(
        value,
        json!([
            {"kind": "tab", "id": "a", "pinned": false, "selected": false, "collapsed": false},
            {"kind": "chip", "group": "G"},
            {"kind": "tab", "id": "g1", "pinned": false, "selected": false, "group": "G", "collapsed": true},
            {"kind": "tab", "id": "g2", "pinned": false, "selected": false, "group": "G", "collapsed": true},
            {"kind": "tab", "id": "x", "pinned": false, "selected": true, "collapsed": false},
        ])
    );
}

#[test]
fn collapsing_over_the_selection_picks_right_then_left_then_none() {
    let ordered = strip().ordered();
    let none = BTreeSet::new();
    assert_eq!(selection_after_collapsing("G", &ordered, &none, Some("g1")).as_deref(), Some("x"));
    let left = [tab("a"), member("g1", "G")];
    assert_eq!(selection_after_collapsing("G", &left, &none, Some("g1")).as_deref(), Some("a"));
    let only = [member("g1", "G")];
    assert_eq!(selection_after_collapsing("G", &only, &none, Some("g1")), None);
    assert_eq!(selection_after_collapsing("G", &ordered, &none, Some("a")).as_deref(), Some("a"));
    // Before collapsing, a strip that cannot open a tab falls back to the first non-member.
    let hidden = [member("h", "H"), member("g1", "G")];
    let collapsed = BTreeSet::from(["H".to_owned()]);
    assert_eq!(
        selection_before_collapsing("G", &hidden, &collapsed, Some("g1")).as_deref(),
        Some("h")
    );
    assert_eq!(selection_before_collapsing("G", &ordered, &none, Some("a")), None);
}

#[test]
fn set_color_applies_to_the_group() {
    // TabGroupCustomColorTests.
    let out =
        strip().apply(&Intent::SetGroupColor { group: "G".into(), tint: Some("#FF8800".into()) });
    assert!(out.applied);
    assert_eq!(out.strip.groups[0].tint.as_deref(), Some("#FF8800"));
}

#[test]
fn toggle_audio_mute_swaps_playing_and_muted() {
    // TabAudioToggleTests.
    let mut start = strip();
    start.tabs[0].audio = Some(Audio::Playing);
    let once = start.apply(&Intent::ToggleAudioMute { id: "a".into() });
    assert!(once.applied);
    assert_eq!(once.strip.tabs[0].audio, Some(Audio::Muted));
    let twice = once.strip.apply(&Intent::ToggleAudioMute { id: "a".into() });
    assert_eq!(twice.strip.tabs[0].audio, Some(Audio::Playing));
    assert!(
        !strip().apply(&Intent::ToggleAudioMute { id: "x".into() }).applied,
        "a silent tab has no speaker"
    );
}

#[test]
fn collapsing_the_only_visible_group_asks_for_a_tab_then_opens_it() {
    let only = Strip {
        tabs: vec![member("g1", "G")],
        groups: vec![group("G")],
        selected: Some("g1".into()),
    };
    let ask = only.apply(&Intent::ToggleGroupCollapsed { group: "G".into(), made: None });
    assert!(ask.needs_tab && !ask.applied);
    assert_eq!(ask.strip, only, "an ask changes nothing");
    let done =
        only.apply(&Intent::ToggleGroupCollapsed { group: "G".into(), made: Some(tab("n")) });
    assert!(done.applied);
    assert_eq!(ids(&done.strip.tabs), ["g1", "n"]);
    assert_eq!(done.strip.selected.as_deref(), Some("n"));
    assert!(done.strip.groups[0].collapsed);
}

#[test]
fn closing_a_group_selects_the_next_non_member_and_drops_the_group() {
    let mut start = strip();
    start.selected = Some("g2".into());
    let out = start.apply(&Intent::CloseGroup { group: "G".into() });
    assert_eq!(ids(&out.strip.tabs), ["a", "x"]);
    assert_eq!(out.strip.selected.as_deref(), Some("x"));
    assert!(out.strip.groups.is_empty());
}

#[test]
fn a_new_tab_from_a_member_joins_its_group_and_selecting_expands() {
    let mut start = strip();
    start.groups[0].collapsed = true;
    let out = start.apply(&Intent::NewTab { after: Some("g1".into()), made: Some(tab("n")) });
    assert_eq!(ids(&out.strip.tabs), ["a", "g1", "n", "g2", "x"]);
    assert_eq!(out.strip.tabs[2].group.as_deref(), Some("G"));
    assert!(!out.strip.groups[0].collapsed);
}

#[test]
fn pin_leaves_the_group_and_moves_to_the_pinned_end() {
    let mut start = strip();
    start.tabs.insert(0, pinned("p"));
    let out = start.apply(&Intent::Pin { id: "g2".into() });
    assert_eq!(ids(&out.strip.tabs), ["p", "g2", "a", "g1", "x"]);
    assert_eq!(out.strip.tabs[1].group, None);
}

#[test]
fn move_group_clamps_past_the_pinned_tabs() {
    let mut start = strip();
    start.tabs.insert(0, pinned("p"));
    let out = start.apply(&Intent::MoveGroup { group: "G".into(), to: 0 });
    assert_eq!(ids(&out.strip.tabs), ["p", "g1", "g2", "a", "x"]);
}

#[test]
fn intents_read_from_the_wire() {
    let intent: Intent = serde_json::from_value(
        json!({"kind": "addToGroup", "id": "a", "group": "G", "index": null}),
    )
    .unwrap();
    let out = strip().apply(&intent);
    assert_eq!(ids(&out.strip.tabs), ["g1", "g2", "a", "x"]);
}

#[test]
fn vectors_match_the_swift_rules() {
    let file: Value =
        serde_json::from_str(include_str!("../../../../schemas/tab-group-rules/vectors.json"))
            .unwrap();
    let cases = file["cases"].as_array().unwrap();
    assert!(cases.len() > 300, "{} cases", cases.len());
    for case in cases {
        let input = &case["input"];
        let got = match case["op"].as_str().unwrap() {
            "normalized" => {
                let tabs: Vec<Tab> = serde_json::from_value(input["tabs"].clone()).unwrap();
                let groups: HashSet<String> =
                    serde_json::from_value(input["groups"].clone()).unwrap();
                serde_json::to_value(normalized(&tabs, &groups)).unwrap()
            }
            "layout" => {
                let tabs: Vec<Tab> = serde_json::from_value(input["tabs"].clone()).unwrap();
                let groups: Vec<Group> = serde_json::from_value(input["groups"].clone()).unwrap();
                serde_json::to_value(layout_items(&tabs, &groups, input["selected"].as_str()))
                    .unwrap()
            }
            op @ ("selectionAfterCollapsing" | "selectionBeforeCollapsing") => {
                let tabs: Vec<Tab> = serde_json::from_value(input["tabs"].clone()).unwrap();
                let collapsed: BTreeSet<String> =
                    serde_json::from_value(input["collapsed"].clone()).unwrap();
                let rule = if op == "selectionAfterCollapsing" {
                    selection_after_collapsing
                } else {
                    selection_before_collapsing
                };
                json!(rule(
                    input["group"].as_str().unwrap(),
                    &tabs,
                    &collapsed,
                    input["selected"].as_str()
                ))
            }
            "apply" => {
                let strip: Strip = serde_json::from_value(input["strip"].clone()).unwrap();
                let intent: Intent = serde_json::from_value(input["intent"].clone()).unwrap();
                serde_json::to_value(strip.apply(&intent)).unwrap()
            }
            other => panic!("unknown op {other}"),
        };
        assert_eq!(got, case["expected"], "{}", case["name"]);
    }
}
