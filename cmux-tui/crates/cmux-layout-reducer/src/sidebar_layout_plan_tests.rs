//! The planners' cases: the app's pin, Add to Top, undo, planner, hidden-row
//! index, region reorder (SidebarAppBottomBandTests) and migration rules,
//! each checked against the reducer the owner commits with.

use super::*;
use crate::sidebar_layout::{defaults, reduce};
use serde_json::json;

fn workspace(value: &str) -> ItemRef {
    ItemRef::new("workspace", value)
}

fn apply(document: &Document, op: &Op) -> Document {
    reduce(document, op).expect("accepted")
}

fn apply_all(document: &Document, ops: &[Op]) -> Document {
    ops.iter().fold(document.clone(), |document, op| apply(&document, op))
}

fn region_ids(document: &Document, region: Region) -> Vec<String> {
    document.sections.iter().filter(|s| s.region == region).map(|s| s.id.clone()).collect()
}

fn items_of(document: &Document, id: &str) -> Vec<String> {
    section(document, id).expect("section").items.iter().map(|i| i.id.clone()).collect()
}

fn app_section(id: &str, region: Region, contribution: &str) -> Section {
    let mut section = Section::new(id, region, Look::List, Content::App);
    section.contribution = Some(contribution.into());
    section
}

fn doc(sections: Vec<Section>) -> Document {
    Document { revision: 0, sections }
}

// MARK: pins

#[test]
fn first_pin_adds_pinned_under_top_with_its_label() {
    let ws = workspace("s:ws_1");
    let op = pin_op(&defaults(), &ws, Some("Build"), "itm_a").expect("op");
    let Op::SectionAdd { section, index } = &op else { panic!("section.add: {op:?}") };
    assert_eq!(section.id, PINNED_SECTION_ID);
    assert_eq!(*index, 1);
    assert_eq!(section.items[0].extra.get("label"), Some(&json!("Build")));
    let pinned = apply(&defaults(), &op);
    assert_eq!(region_ids(&pinned, Region::Top), ["sec_top", "sec_pinned"]);
    assert!(pin_op(&pinned, &ws, None, "itm_b").is_none(), "pinned already");
    // The next pin appends to Pinned.
    let next = pin_op(&pinned, &workspace("s:ws_2"), None, "itm_b").expect("op");
    assert_eq!(
        next,
        Op::ItemAdd {
            item: Item::new("itm_b", workspace("s:ws_2"), true),
            section: PINNED_SECTION_ID.into(),
            index: i64::MAX,
        }
    );
}

#[test]
fn pin_without_sec_top_goes_last_in_the_top_region() {
    let document = apply(&defaults(), &Op::SectionRemove { id: "sec_top".into() });
    let op = pin_op(&document, &workspace("s:ws_1"), None, "itm_a").expect("op");
    assert!(matches!(op, Op::SectionAdd { index: i64::MAX, .. }));
}

#[test]
fn a_label_is_capped_and_an_empty_one_is_dropped() {
    let long = "x".repeat(300);
    let Some(Op::SectionAdd { section, .. }) =
        pin_op(&defaults(), &workspace("a"), Some(&long), "i")
    else {
        panic!()
    };
    assert_eq!(section.items[0].extra["label"].as_str().unwrap().chars().count(), MAX_LABEL_CHARS);
    let Some(Op::SectionAdd { section, .. }) = pin_op(&defaults(), &workspace("a"), Some(""), "i")
    else {
        panic!()
    };
    assert!(section.items[0].extra.get("label").is_none());
}

#[test]
fn pin_ops_plan_each_against_the_last_and_skip_the_settled() {
    let pins = |refs: &[&str]| -> Vec<PinRef> {
        refs.iter()
            .enumerate()
            .map(|(n, r)| PinRef {
                reference: workspace(r),
                label: None,
                new_item: format!("itm_{n}"),
            })
            .collect()
    };
    let ops = pin_ops(&defaults(), &pins(&["a", "b", "a"]), true);
    assert_eq!(ops.len(), 2, "the second a is pinned by then");
    let pinned = apply_all(&defaults(), &ops);
    assert_eq!(items_of(&pinned, PINNED_SECTION_ID), ["itm_0", "itm_1"]);
    let unpin = pin_ops(&pinned, &pins(&["b", "c"]), false);
    assert_eq!(unpin, vec![Op::ItemRemove { id: "itm_1".into() }]);
}

#[test]
fn unpin_leaves_a_top_row_of_the_same_ref() {
    let ws = workspace("a");
    let top =
        apply(&defaults(), &add_to_top_op(&defaults(), &ws, None, "itm_row", "sec_new").unwrap());
    let both = apply(&top, &pin_op(&top, &ws, None, "itm_tile").unwrap());
    assert_eq!(unpin_op(&both, &ws), Some(Op::ItemRemove { id: "itm_tile".into() }));
    assert_eq!(remove_from_top_op(&both, &ws), Some(Op::ItemRemove { id: "itm_row".into() }));
    assert!(unpin_op(&top, &ws).is_none());
}

#[test]
fn add_to_top_targets_sec_top_then_a_shared_items_section_then_a_new_one() {
    let ws = workspace("a");
    assert!(matches!(
        add_to_top_op(&defaults(), &ws, None, "i", "s"),
        Some(Op::ItemAdd { ref section, index: i64::MAX, .. }) if section == "sec_top"
    ));
    let mut custom = Section::new("sec_custom", Region::Top, Look::List, Content::Items);
    custom.items = vec![Item::new("itm_x", workspace("x"), true)];
    let mut roomed = Section::new("sec_room", Region::Top, Look::List, Content::Items);
    roomed.room = Some("work".into());
    let document =
        doc(vec![pinned_section(vec![]), roomed, custom, defaults().sections[1].clone()]);
    assert!(matches!(
        add_to_top_op(&document, &ws, None, "i", "s"),
        Some(Op::ItemAdd { ref section, .. }) if section == "sec_custom"
    ));
    let bare = doc(vec![defaults().sections[1].clone()]);
    let Some(Op::SectionAdd { section, index: 0 }) =
        add_to_top_op(&bare, &ws, Some("W"), "i", "sec_n")
    else {
        panic!()
    };
    assert_eq!(
        (section.id.as_str(), &section.look, &section.region),
        ("sec_n", &Look::BuiltIn, &Region::Top)
    );
    // A tile does not count as a top row; a row does.
    let tiled = apply(&defaults(), &pin_op(&defaults(), &ws, None, "t").unwrap());
    assert!(add_to_top_op(&tiled, &ws, None, "i", "s").is_some());
    let rowed = apply(&defaults(), &add_to_top_op(&defaults(), &ws, None, "i", "s").unwrap());
    assert!(add_to_top_op(&rowed, &ws, None, "j", "s").is_none());
}

#[test]
fn inverse_undoes_removes_and_adds() {
    let document = defaults();
    let remove = Op::ItemRemove { id: "itm_app_store".into() };
    let undo = inverse(&document, &remove).expect("undo");
    assert_eq!(apply(&apply(&document, &remove), &undo).sections, document.sections);

    let by_ref = Op::ItemRemoveRef { reference: ItemRef::new("app", "cmux/home") };
    let undo = inverse(&document, &by_ref).expect("one holder");
    assert_eq!(apply(&apply(&document, &by_ref), &undo).sections, document.sections);

    let add = add_to_top_op(&document, &workspace("a"), None, "itm_a", "s").unwrap();
    assert_eq!(inverse(&document, &add), Some(Op::ItemRemove { id: "itm_a".into() }));
    let added = apply(&document, &add);
    let again = Op::ItemAdd {
        item: Item::new("itm_b", workspace("a"), true),
        section: "sec_top".into(),
        index: 0,
    };
    assert!(inverse(&added, &again).is_none(), "a no-op add has nothing to undo");

    let pin = pin_op(&document, &workspace("a"), None, "itm_p").unwrap();
    assert_eq!(inverse(&document, &pin), Some(Op::ItemRemove { id: "itm_p".into() }));
    assert!(inverse(&apply(&document, &pin), &pin).is_none());
    assert!(inverse(&document, &Op::Reset).is_none());
    assert!(inverse(&document, &Op::ItemRemove { id: "nope".into() }).is_none());
}

#[test]
fn inverse_of_a_ref_two_items_hold_is_none() {
    let ws = workspace("a");
    let row = apply(&defaults(), &add_to_top_op(&defaults(), &ws, None, "r", "s").unwrap());
    let both = apply(&row, &pin_op(&row, &ws, None, "t").unwrap());
    assert!(inverse(&both, &Op::ItemRemoveRef { reference: ws }).is_none());
}

#[test]
fn legacy_pins_skip_refs_already_on_top() {
    let ws = workspace("a");
    let row = apply(&defaults(), &add_to_top_op(&defaults(), &ws, None, "r", "s").unwrap());
    let pins = vec![
        PinRef { reference: ws, label: None, new_item: "i1".into() },
        PinRef { reference: workspace("b"), label: Some("B".into()), new_item: "i2".into() },
    ];
    let ops = legacy_pin_migration_ops(&row, &pins);
    assert_eq!(ops.len(), 1);
    assert_eq!(items_of(&apply_all(&row, &ops), PINNED_SECTION_ID), ["i2"]);
}

// MARK: planner

#[test]
fn add_goes_first_on_top_last_elsewhere_and_never_twice() {
    let settings = ItemRef::new("built_in", "settings");
    let op =
        add_op(&defaults(), &settings, &Region::Bottom, &Look::BuiltIn, false, "itm_s", "sec_s")
            .unwrap();
    assert!(
        matches!(op, Op::ItemAdd { ref section, index: i64::MAX, .. } if section == "sec_bottom")
    );
    let home = ItemRef::new("app", "cmux/home");
    assert!(add_op(&defaults(), &home, &Region::Top, &Look::BuiltIn, true, "i", "s").is_none());
    let chief = ItemRef::new("built_in", "chief");
    assert!(matches!(
        add_op(&defaults(), &chief, &Region::Top, &Look::BuiltIn, true, "i", "s"),
        Some(Op::ItemAdd { index: 0, .. })
    ));
    let bare = doc(vec![defaults().sections[1].clone()]);
    let Some(Op::SectionAdd { section, index: 0 }) =
        add_op(&bare, &chief, &Region::Top, &Look::List, true, "i", "s")
    else {
        panic!()
    };
    assert_eq!(section.look, Look::List);
    assert_eq!(remove_op(&defaults(), &home), Some(Op::ItemRemoveRef { reference: home.clone() }));
    assert!(remove_op(&defaults(), &chief).is_none());
}

// MARK: hidden rows

#[test]
fn a_visible_slot_maps_past_hidden_rows() {
    let mut top = Section::new("sec_top", Region::Top, Look::BuiltIn, Content::Items);
    top.items = ["a", "h", "b", "c"].iter().map(|id| Item::new(id, workspace(id), true)).collect();
    let stored = doc(vec![top.clone()]);
    let mut visible = top;
    visible.items.retain(|item| item.id != "h");
    let projected = doc(vec![visible]);
    // Visible [a, b, c]: slot 1 (before b) is stored index 2.
    assert_eq!(stored_insertion_index(&stored, 1, "sec_top", &projected, None), 2);
    assert_eq!(stored_insertion_index(&stored, 3, "sec_top", &projected, None), 4);
    assert_eq!(stored_insertion_index(&stored, i64::MAX, "sec_top", &projected, None), 4);
    // Moving a: rest visible [b, c], stored [h, b, c].
    assert_eq!(stored_insertion_index(&stored, 0, "sec_top", &projected, Some("a")), 1);
    let moved = Op::ItemMove { id: "a".into(), section: "sec_top".into(), index: 2 };
    assert_eq!(
        translating_hidden_item_index(&moved, &projected, &stored),
        Op::ItemMove { id: "a".into(), section: "sec_top".into(), index: 3 }
    );
    // Nothing hidden: the index stands.
    assert_eq!(stored_insertion_index(&stored, 1, "sec_top", &stored, None), 1);
    assert_eq!(stored_insertion_index(&stored, 7, "sec_x", &projected, None), 7);
}

// MARK: region reorder

#[test]
fn an_item_moves_before_its_shown_neighbour() {
    let mut top = Section::new("sec_top", Region::Top, Look::BuiltIn, Content::Items);
    top.items = ["a", "h", "b", "c"].iter().map(|id| Item::new(id, workspace(id), true)).collect();
    let document = doc(vec![top.clone()]);
    let mut shown = top;
    shown.items = ["b", "a", "c"].iter().map(|id| Item::new(id, workspace(id), true)).collect();
    let op = region_move_op(&DragSubject::Item("a".into()), &[shown.clone()], &document).unwrap();
    assert_eq!(op, Op::ItemMove { id: "a".into(), section: "sec_top".into(), index: 2 });
    assert_eq!(items_of(&apply(&document, &op), "sec_top"), ["h", "b", "a", "c"]);
    shown.items = ["b", "c", "a"].iter().map(|id| Item::new(id, workspace(id), true)).collect();
    let op = region_move_op(&DragSubject::Item("a".into()), &[shown], &document).unwrap();
    assert_eq!(op, Op::ItemMove { id: "a".into(), section: "sec_top".into(), index: 3 });
}

#[test]
fn a_section_moves_within_its_region() {
    let first = app_section("sec_a", Region::Top, "x/a#a");
    let second = app_section("sec_b", Region::Top, "x/b#b");
    let document = doc(vec![first.clone(), second.clone(), defaults().sections[1].clone()]);
    let op =
        region_move_op(&DragSubject::Section("sec_b".into()), &[second, first], &document).unwrap();
    assert_eq!(op, Op::SectionMove { id: "sec_b".into(), region: Region::Top, index: 0 });
    assert!(region_move_op(&DragSubject::Section("nope".into()), &[], &document).is_none());
}

#[test]
fn dragging_an_app_to_bottom_uses_its_shown_neighbor_and_keeps_hidden_sections() {
    let moved = app_section("sec_moved", Region::Top, "local/customize#moved");
    let hidden = app_section("sec_hidden", Region::Bottom, "local/hidden#section");
    let first = app_section("sec_first", Region::Bottom, "local/customize#first");
    let last = app_section("sec_last", Region::Bottom, "local/customize#last");
    let workspaces = defaults().sections[1].clone();
    let document = doc(vec![moved, workspaces, hidden, first.clone(), last.clone()]);
    let op = app_section_move_op(
        "sec_moved",
        &Region::Bottom,
        Some("sec_last"),
        &[first, last],
        &document,
    )
    .unwrap();
    let updated = apply(&document, &op);
    assert_eq!(
        region_ids(&updated, Region::Bottom),
        ["sec_hidden", "sec_first", "sec_moved", "sec_last"]
    );
    assert!(region_ids(&updated, Region::Top).is_empty());
}

#[test]
fn dragging_the_app_back_to_top_keeps_the_document_order() {
    let moved = app_section("sec_moved", Region::Bottom, "local/customize#moved");
    let top = app_section("sec_top_app", Region::Top, "local/customize#top");
    let document = doc(vec![top.clone(), defaults().sections[1].clone(), moved]);
    let op = app_section_move_op("sec_moved", &Region::Top, Some("sec_top_app"), &[top], &document)
        .unwrap();
    let updated = apply(&document, &op);
    assert_eq!(region_ids(&updated, Region::Top), ["sec_moved", "sec_top_app"]);
    assert!(region_ids(&updated, Region::Bottom).is_empty());
}

#[test]
fn only_app_sections_move_and_only_to_a_pinned_band() {
    let document = defaults();
    assert!(app_section_move_op("sec_top", &Region::Bottom, None, &[], &document).is_none());
    let app = app_section("sec_app", Region::Top, "a/b#c");
    let document = doc(vec![app, defaults().sections[1].clone()]);
    assert!(app_section_move_op("sec_app", &Region::Middle, None, &[], &document).is_none());
}

// MARK: migrations

fn current_defaults() -> Document {
    // The app's defaults (no All chats section).
    let mut document = defaults();
    document.sections.retain(|section| section.id != sidebar_layout::RECENTS_SECTION_ID);
    document
}

#[test]
fn the_rail_default_migrates_to_the_current_default() {
    let rail = Document { revision: 7, sections: rail_defaults() };
    let migrated = apply_all(&rail, &layout_migration_ops(&rail));
    assert_eq!(migrated.sections, {
        let mut expected = current_defaults().sections;
        expected[0].items.push(item("itm_app_coderouter", "app", "cmux/coderouter", true, None));
        expected
    });
}

#[test]
fn older_footers_migrate_to_the_profile_control() {
    let inline = doc(inline_bottom_defaults());
    let migrated = apply_all(&inline, &layout_migration_ops(&inline));
    assert_eq!(
        section(&migrated, BOTTOM_SECTION_ID),
        section(&current_defaults(), BOTTOM_SECTION_ID)
    );
    assert_eq!(
        section(&migrated, TOP_SECTION_ID)
            .unwrap()
            .items
            .iter()
            .map(|i| i.reference.value.as_str())
            .collect::<Vec<_>>(),
        ["cmux/home", "cmux/app-store", "cmux/coderouter"]
    );

    let mut grid = current_defaults();
    grid.sections[2] = grid_bottom_section();
    let migrated = apply_all(&grid, &sections_migration_ops(&grid));
    assert_eq!(migrated.sections, current_defaults().sections);

    let mut minimal = current_defaults();
    minimal.sections[2] = minimal_bottom_section();
    assert_eq!(
        sections_migration_ops(&minimal),
        vec![Op::ItemRemove { id: "itm_settings".into() }]
    );
    assert_eq!(
        apply_all(&minimal, &sections_migration_ops(&minimal)).sections,
        current_defaults().sections
    );
}

#[test]
fn a_changed_layout_never_migrates() {
    let mut rail = doc(rail_defaults());
    rail.sections[0].title = Some("Mine".into());
    assert!(sections_migration_ops(&rail).is_empty());
    assert!(layout_migration_ops(&current_defaults()).is_empty());
}

#[test]
fn built_in_home_and_app_store_become_apps_keeping_id_place_and_span() {
    let mut top = Section::new("sec_top", Region::Top, Look::BuiltIn, Content::Items);
    top.items = vec![
        item("itm_x", "url", "https://cmux.com", true, None),
        item("itm_home", "built_in", "home", false, Some(2)),
    ];
    let document = doc(vec![top, defaults().sections[1].clone()]);
    let ops = app_ref_migration_ops(&document);
    assert_eq!(ops.len(), 2);
    let migrated = apply_all(&document, &ops);
    assert_eq!(
        section(&migrated, "sec_top").unwrap().items[1],
        item("itm_home", "app", "cmux/home", false, Some(2))
    );
}

#[test]
fn the_app_ref_migration_keeps_a_label_and_newer_keys() {
    let mut home = item("itm_home", "built_in", "home", true, None);
    home.extra.insert("label".into(), json!("Home"));
    home.extra.insert("future".into(), json!({"k": 1}));
    home.reference.extra.insert("future_ref".into(), json!(true));
    let mut top = Section::new("sec_top", Region::Top, Look::BuiltIn, Content::Items);
    top.items = vec![home.clone()];
    let document = doc(vec![top, defaults().sections[1].clone()]);
    let migrated = apply_all(&document, &app_ref_migration_ops(&document));
    let moved = &section(&migrated, "sec_top").unwrap().items[0];
    assert!(moved.reference.same(&ItemRef::new("app", "cmux/home")));
    assert_eq!(moved.reference.extra, home.reference.extra);
    assert_eq!(moved.extra, home.extra);
}

#[test]
fn a_label_is_cut_on_grapheme_clusters() {
    // 199 letters, then a family emoji of several scalars: the emoji is the 200th character.
    let label = format!("{}👨‍👩‍👧x", "a".repeat(199));
    let Some(Op::SectionAdd { section, .. }) =
        pin_op(&defaults(), &workspace("a"), Some(&label), "i")
    else {
        panic!()
    };
    assert_eq!(section.items[0].extra["label"], json!(format!("{}👨‍👩‍👧", "a".repeat(199))));
}

#[test]
fn retired_built_ins_are_removed() {
    let mut top = Section::new("sec_x", Region::Top, Look::BuiltIn, Content::Items);
    top.items = vec![
        item("itm_nw", "built_in", "new_workspace", true, None),
        item("itm_is", "built_in", "import_sync", true, None),
        item("itm_h", "built_in", "history", true, None),
    ];
    let document = doc(vec![top, defaults().sections[1].clone()]);
    let migrated = apply_all(&document, &layout_migration_ops(&document));
    assert_eq!(items_of(&migrated, "sec_x"), ["itm_h"]);
}

// MARK: wire

#[test]
fn the_wire_round_trips_ops_the_app_decodes() {
    let rail = serde_json::to_value(Document { revision: 3, sections: rail_defaults() }).unwrap();
    let request: Request =
        serde_json::from_value(json!({"plan": "migrate", "document": rail})).unwrap();
    let reply = serde_json::to_value(respond(&request)).unwrap();
    let ops = reply["ops"].as_array().unwrap();
    assert_eq!(ops[0], json!({"kind": "item.remove", "id": "itm_history"}));
    assert_eq!(
        ops[3],
        json!({"kind": "section.update", "id": "sec_top", "patch": {"max_rows": null}})
    );
    assert_eq!(
        ops[4],
        json!({"kind": "section.update", "id": "sec_bottom", "patch": {"layout": "inline", "align": "leading", "columns": null}})
    );
    // Every op the reply holds reads back as the reducer's op.
    for op in ops {
        let _: Op = serde_json::from_value(op.clone()).unwrap();
    }

    let document = serde_json::to_value(defaults()).unwrap();
    let request: Request = serde_json::from_value(json!({
        "plan": "pin", "document": document, "ref": {"kind": "workspace", "value": "s:ws"},
        "label": "Build", "new_item": "itm_p"
    }))
    .unwrap();
    let reply = serde_json::to_value(respond(&request)).unwrap();
    assert_eq!(reply["op"]["kind"], "section.add");
    assert_eq!(reply["op"]["index"], 1);
    assert_eq!(reply["op"]["section"]["items"][0]["label"], "Build");

    let request: Request = serde_json::from_value(json!({
        "plan": "unpin", "document": document, "ref": {"kind": "workspace", "value": "s:ws"}
    }))
    .unwrap();
    assert_eq!(serde_json::to_value(respond(&request)).unwrap(), json!({}));

    let request: Request = serde_json::from_value(json!({
        "plan": "stored_index", "stored": document, "projected": document, "section": "sec_top", "index": 9223372036854775807u64
    }))
    .unwrap();
    assert_eq!(serde_json::to_value(respond(&request)).unwrap(), json!({"index": i64::MAX}));

    let request: Request = serde_json::from_value(json!({
        "plan": "region_move", "subject": {"section": "sec_top"}, "shown": [], "document": document
    }))
    .unwrap();
    assert_eq!(respond(&request), Reply::default());
}
