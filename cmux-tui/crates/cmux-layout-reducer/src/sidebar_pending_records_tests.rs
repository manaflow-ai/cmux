//! Mirrors the Swift tests of `SidebarDocPendingRecords` (SidebarSpaceOwnsPinsAndGroupsTests'
//! aPendingItemUpdateWritesItsFields and aPendingNewGroupKeepsItsSpace, and the store's pending
//! rename and recolor) on the rules alone.

use super::*;

fn link(id: &str, section: &str, label: Option<&str>) -> Item {
    Item {
        id: id.into(),
        section: section.into(),
        parent: None,
        group: None,
        shows_label: true,
        span: None,
        label: label.map(Into::into),
        icon_url: None,
        room: None,
    }
}

fn group(id: &str, section: &str, parent: Option<&str>, name: &str) -> Item {
    Item {
        parent: parent.map(Into::into),
        group: Some(GroupBody { name: name.into(), ..GroupBody::default() }),
        ..link(id, section, None)
    }
}

fn records(list: Vec<Item>) -> BTreeMap<String, Item> {
    list.into_iter().map(|item| (item.id.clone(), item)).collect()
}

fn laid(ops: Value, items: &BTreeMap<String, Item>) -> BTreeMap<String, Item> {
    let writes = writes(&ops, items).unwrap();
    apply(items.clone(), &writes)
}

#[test]
fn a_pending_item_update_writes_its_fields() {
    let items = records(vec![link("itm_l", "pinned", Some("Old"))]);
    let ops = json!([
        {"op": "move", "items": ["itm_l"], "to": {"section": "pinned"}},
        {"op": "item.update", "id": "itm_l", "patch": {"room": "work", "label": null, "shows_label": false}},
    ]);
    assert_eq!(writes(&ops, &items).unwrap().len(), 1, "the move writes nothing");
    let item = &laid(ops, &items)["itm_l"];
    assert_eq!(item.room.as_deref(), Some("work"));
    assert_eq!(item.label, None);
    assert!(!item.shows_label);
    let empty = json!([{"op": "item.update", "id": "itm_l", "patch": {}}]);
    assert!(writes(&empty, &items).unwrap().is_empty());
}

#[test]
fn a_pending_new_group_keeps_its_space() {
    let ops = json!([{"op": "group.create", "id": "itm_gn", "name": "New", "color": "blue",
        "items": [], "profile": "work", "to": {"section": "custom"}}]);
    let items = laid(ops, &BTreeMap::new());
    let created = &items["itm_gn"];
    assert_eq!(created.room.as_deref(), Some("work"));
    assert_eq!(created.section, "custom");
    assert_eq!(
        created.group,
        Some(GroupBody { name: "New".into(), color: Some("blue".into()), ..GroupBody::default() })
    );
}

#[test]
fn a_new_group_with_no_target_takes_its_first_items_place() {
    let items = records(vec![group("g", "mac", None, "G"), link("a", "mac", None)]);
    let mut nested = items.clone();
    nested.insert("a".into(), Item { parent: Some("g".into()), ..link("a", "mac", None) });
    let created = &laid(json!([{"op": "group.create", "id": "n", "items": ["a"]}]), &nested)["n"];
    assert_eq!((created.section.as_str(), created.parent.as_deref()), ("mac", Some("g")));
    let elsewhere = &laid(
        json!([{"op": "group.create", "id": "n", "items": ["a"], "to": {"section": "other"}}]),
        &nested,
    )["n"];
    assert_eq!((elsewhere.section.as_str(), elsewhere.parent.as_deref()), ("other", None));
    let unknown = &laid(json!([{"op": "group.create", "id": "n", "items": ["zz"]}]), &items)["n"];
    assert_eq!(unknown.section, "");
    let kept = laid(json!([{"op": "group.create", "id": "g", "name": "Other"}]), &items);
    assert_eq!(kept["g"].group.as_ref().map(|g| g.name.as_str()), Some("G"), "no overwrite");
}

#[test]
fn a_rename_and_recolor_show_before_the_echo_and_a_fold_writes_nothing() {
    let items = records(vec![group("g", "mac", None, "Old"), link("l", "mac", None)]);
    let ops = json!([
        {"op": "group.update", "id": "g", "patch": {"name": "New", "color": "red"}},
        {"op": "group.update", "id": "g", "patch": {"collapsed": true}},
        {"op": "group.update", "id": "g", "patch": {"icon": null}},
        {"op": "group.update", "id": "l", "patch": {"name": "not a group"}},
    ]);
    assert_eq!(writes(&ops, &items).unwrap().len(), 3);
    let laid = laid(ops, &items);
    let body = laid["g"].group.clone().unwrap();
    assert_eq!((body.name.as_str(), body.color.as_deref(), body.icon), ("New", Some("red"), None));
    assert_eq!(laid["l"], items["l"], "only a group takes a group's patch");
}

#[test]
fn writes_apply_in_order_and_a_cleared_color_clears() {
    let items = records(vec![Item {
        group: Some(GroupBody {
            name: "G".into(),
            color: Some("blue".into()),
            ..GroupBody::default()
        }),
        ..link("g", "mac", None)
    }]);
    let ops = json!([
        {"op": "group.update", "id": "g", "patch": {"color": "red"}},
        {"op": "group.update", "id": "g", "patch": {"color": null, "name": "H"}},
    ]);
    let body = laid(ops, &items)["g"].group.clone().unwrap();
    assert_eq!((body.name.as_str(), body.color), ("H", None));
}

#[test]
fn ops_that_are_no_op_array_write_nothing() {
    assert_eq!(writes(&json!({"op": "move"}), &BTreeMap::new()), None);
    assert_eq!(writes(&json!([1]), &BTreeMap::new()), None);
    assert_eq!(writes(&json!([{"op": "item.update"}]), &BTreeMap::new()), Some(vec![]));
    let span = json!([{"op": "item.update", "id": "x", "patch": {"span": 2.0}}]);
    assert_eq!(
        writes(&span, &BTreeMap::new()),
        Some(vec![Write::Item(ItemPatch {
            id: "x".into(),
            span: Some(Some(2)),
            ..ItemPatch::default()
        })])
    );
}

#[test]
fn the_writes_round_trip_through_json() {
    let ops = json!([
        {"op": "group.update", "id": "g", "patch": {"color": null}},
        {"op": "item.update", "id": "x", "patch": {"span": null, "label": "L"}},
        {"op": "group.create", "id": "n", "name": "N"},
    ]);
    let list = writes(&ops, &BTreeMap::new()).unwrap();
    let wire = serde_json::to_value(&list).unwrap();
    assert_eq!(wire[0], json!({"update": {"id": "g", "color": null}}));
    assert_eq!(wire[1], json!({"item": {"id": "x", "span": null, "label": "L"}}));
    let back: Vec<Write> = serde_json::from_value(wire).unwrap();
    assert_eq!(back, list);
}
