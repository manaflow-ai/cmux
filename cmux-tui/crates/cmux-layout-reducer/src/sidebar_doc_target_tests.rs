//! Mirrors the Swift tests of the drop anchors and remote groups (SidebarDocMoveToTopTests,
//! SidebarHostGroupTests' groupIntentsGoToTheMachine, the nested-group anchor of the drag tests) on
//! the rules alone.

use super::*;

fn list(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| id.to_string()).collect()
}

fn set(ids: &[&str]) -> BTreeSet<String> {
    ids.iter().map(|id| id.to_string()).collect()
}

fn before(section: &str, id: &str) -> Target {
    Target { section: section.into(), before: Some(id.into()), ..Target::default() }
}

fn after(section: &str, id: &str) -> Target {
    Target { section: section.into(), after: Some(id.into()), ..Target::default() }
}

#[test]
fn move_to_top_anchors_before_the_first_row_and_counts_without_the_moved_rows() {
    let siblings = list(&["first", "second", "c", "moved"]);
    assert_eq!(target("s", None, 0, &siblings, &set(&["moved"])), before("s", "first"));
    assert_eq!(target("s", None, 0, &siblings, &set(&["first"])), before("s", "second"));
    assert_eq!(target("s", None, 3, &siblings, &set(&["moved"])), after("s", "c"), "past the end");
    assert_eq!(target("s", None, -1, &siblings, &BTreeSet::new()), after("s", "moved"));
    let empty = target("s", Some("g"), 0, &list(&["m"]), &set(&["m"]));
    assert_eq!(
        empty,
        Target {
            section: "s".into(),
            parent: Some("g".into()),
            index: Some(0),
            ..Target::default()
        }
    );
}

#[test]
fn a_top_level_slot_never_anchors_on_a_nested_group() {
    let siblings = list(&["a", "g", "sub", "b"]);
    let nested = set(&["sub"]);
    let none = BTreeSet::new();
    let slot = |index| {
        top_level_anchor(target("s", None, index, &siblings, &none), &siblings, &nested, &none)
    };
    assert_eq!(slot(1), before("s", "g"), "a top-level anchor stays");
    assert_eq!(
        slot(2),
        before("s", "b"),
        "the slot before a subgroup is the gap before the next row"
    );
    let tail = list(&["a", "g", "sub"]);
    let last = top_level_anchor(target("s", None, 3, &tail, &none), &tail, &nested, &none);
    assert_eq!(last, after("s", "g"), "after the last top-level row");
    let only = list(&["sub"]);
    assert_eq!(
        top_level_anchor(target("s", None, 0, &only, &none), &only, &nested, &none),
        Target { section: "s".into(), index: Some(0), ..Target::default() }
    );
}

#[test]
fn move_to_top_lifts_unplaced_rows_of_one_machine_only() {
    let row = |placed, session: Option<&str>| Unplaced { placed, session: session.map(Into::into) };
    assert_eq!(
        unplaced_target(false, 0, &[row(false, Some("mac")), row(false, Some("mac"))]),
        Some(Target { section: "sec_m_mac".into(), index: Some(0), ..Target::default() })
    );
    assert_eq!(unplaced_target(false, 0, &[row(true, Some("mac"))]), None, "a placed row");
    assert_eq!(unplaced_target(true, 0, &[row(false, Some("mac"))]), None, "in a group");
    assert_eq!(unplaced_target(false, 0, &[]), None);
    assert_eq!(unplaced_target(false, 0, &[row(false, Some("a")), row(false, Some("b"))]), None);
    assert_eq!(unplaced_target(false, 0, &[row(false, Some("a")), row(false, None)]), None);
    assert_eq!(unplaced_target(false, 0, &[row(false, Some(""))]), None);
}

#[test]
fn a_filtered_keyboard_move_goes_next_to_its_visible_neighbour() {
    let row = |id: &str, group: Option<&str>| Visible {
        id: id.into(),
        section: Some("s".into()),
        item: Some(format!("itm_{id}")),
        group: group.map(Into::into),
    };
    let visible = vec![row("a", None), row("m", None), row("b", Some("g"))];
    let items = vec![Some("itm_m".to_string())];
    let up = keyboard_move(&visible, &list(&["m"]), &items, true).unwrap();
    assert_eq!(up.target, before("s", "itm_a"));
    let down = keyboard_move(&visible, &list(&["m"]), &items, false).unwrap();
    assert_eq!(down.target, Target { parent: Some("g".into()), ..after("s", "itm_b") });
    assert_eq!(down.items, ["itm_m"]);
    assert_eq!(keyboard_move(&visible[1..], &list(&["m"]), &items, true), None, "nothing above");
    assert_eq!(keyboard_move(&visible, &list(&["m"]), &[None], true), None, "a row with no item");
    assert_eq!(keyboard_move(&visible, &list(&["x"]), &items, true), None, "not listed");
}

#[test]
fn group_intents_go_to_the_machine() {
    let host = host_group_id("m1");
    assert_eq!(host_machine(&host), Some("m1"));
    assert_eq!(host_machine("g-a"), None);
    let ends = BTreeMap::from([("m1".to_string(), 2)]);
    let machine = json!({"machine": "m1"});
    let resolve = |intent| resolving_host_group(intent, &ends);
    assert_eq!(
        resolve(Intent::ToggleCollapseGroup { group: host.clone() }),
        Some(Intent::ToggleCollapseSection { section: machine.clone() })
    );
    assert_eq!(
        resolve(Intent::NewWorkspace { machine: None, group: Some(host.clone()) }),
        Some(Intent::NewWorkspace { machine: Some("m1".into()), group: None })
    );
    let ids = list(&["w-9"]);
    assert_eq!(
        resolve(Intent::Move { ids: ids.clone(), group: host.clone() }),
        Some(Intent::Reorder {
            ids: ids.clone(),
            to: Position { section: machine.clone(), group: None, index: 2 }
        })
    );
    assert_eq!(
        resolve(Intent::Reorder {
            ids: ids.clone(),
            to: Position { section: machine.clone(), group: Some(host.clone()), index: 1 }
        }),
        Some(Intent::Reorder { ids, to: Position { section: machine, group: None, index: 1 } })
    );
    assert_eq!(resolve(Intent::GroupEdit { group: host }), None);
    let plain = Intent::GroupEdit { group: "g-a".into() };
    assert_eq!(resolve(plain.clone()), Some(plain));
    assert_eq!(resolve(Intent::Other), Some(Intent::Other));
}

#[test]
fn a_wrapped_section_counts_its_rows_as_the_document_holds_them() {
    let nodes = vec![
        HostNode::Group { host: true, parent: None, members: 3 },
        HostNode::Group { host: false, parent: Some("host:m1".into()), members: 5 },
        HostNode::Group { host: false, parent: Some("g".into()), members: 1 },
        HostNode::Row,
    ];
    assert_eq!(document_node_count(true, &nodes), 5);
    assert_eq!(document_node_count(false, &nodes), 4);
}
