//! Mirrors the app's SidebarLayoutReducerTests and SectionFlowTests reducer
//! cases, the shared fixture, and a seeded property test for invariants
//! L1-L4 and the revision rule.

use super::*;
use serde_json::json;

fn op(value: serde_json::Value) -> Op {
    serde_json::from_value(value).expect("op")
}

fn ok(document: &Document, value: serde_json::Value) -> Document {
    reduce(document, &op(value)).expect("accepted")
}

fn err(document: &Document, value: serde_json::Value) -> Reject {
    reduce(document, &op(value)).expect_err("rejected")
}

fn ids(document: &Document) -> Vec<String> {
    document.sections.iter().flat_map(|s| s.items.iter().map(|i| i.id.clone())).collect()
}

fn section_ids(document: &Document, region: Region) -> Vec<String> {
    document.sections.iter().filter(|s| s.region == region).map(|s| s.id.clone()).collect()
}

fn find<'a>(document: &'a Document, id: &str) -> &'a Section {
    document.sections.iter().find(|s| s.id == id).expect("section")
}

#[test]
fn defaults_match_the_app() {
    let doc = defaults();
    let value = serde_json::to_value(&doc).unwrap();
    assert_eq!(value["sections"][0]["items"][0]["ref"], json!({"kind": "built_in", "value": "home"}));
    assert_eq!(value["sections"][1]["content"], "workspaces");
    assert_eq!(value["sections"][2]["arrangement"], json!({"layout": "inline", "align": "fill"}));
    assert_eq!(value["sections"][2]["items"][1]["shows_label"], false);
    assert_eq!(value["sections"][0]["look"], "built_in");
    let round: Document = serde_json::from_value(value).unwrap();
    assert_eq!(round, doc);
}

#[test]
fn remove_home_and_revision() {
    let doc = ok(&defaults(), json!({"kind": "item.remove", "id": "itm_home"}));
    assert_eq!(find(&doc, "sec_top").items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["itm_app_store"]);
    assert_eq!(doc.revision, 1);
    let copy = json!({"id": "itm_h2", "ref": {"kind": "built_in", "value": "home"}});
    let two = ok(&defaults(), json!({"kind": "item.add", "item": copy, "section": "sec_bottom", "index": 0}));
    let none = ok(&two, json!({"kind": "item.remove_ref", "ref": {"kind": "built_in", "value": "home"}}));
    assert!(none.sections.iter().all(|s| s.items.iter().all(|i| i.reference.value != "home")));
    assert_eq!(err(&none, json!({"kind": "item.remove_ref", "ref": {"kind": "built_in", "value": "home"}})), Reject::UnknownItem);
}

#[test]
fn add_clamps_and_dedupes() {
    let item = json!({"id": "itm_ws", "ref": {"kind": "workspace", "value": "local:ws_1"}});
    let doc = ok(&defaults(), json!({"kind": "item.add", "item": item, "section": "sec_top", "index": 99}));
    assert_eq!(find(&doc, "sec_top").items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["itm_home", "itm_app_store", "itm_ws"]);
    let front = ok(&defaults(), json!({"kind": "item.add", "item": item, "section": "sec_top", "index": -3}));
    assert_eq!(find(&front, "sec_top").items[0].id, "itm_ws");
    let again = json!({"id": "itm_home2", "ref": {"kind": "built_in", "value": "home"}});
    let same = ok(&defaults(), json!({"kind": "item.add", "item": again, "section": "sec_top", "index": 0}));
    assert_eq!(same, defaults());
    let other = ok(&defaults(), json!({"kind": "item.add", "item": again, "section": "sec_bottom", "index": 0}));
    assert_eq!(find(&other, "sec_bottom").items[0].id, "itm_home2");
}

#[test]
fn workspaces_section_rules() {
    let item = json!({"id": "itm_x", "ref": {"kind": "built_in", "value": "history"}});
    let d = defaults();
    assert_eq!(err(&d, json!({"kind": "item.add", "item": item, "section": "sec_workspaces", "index": 0})), Reject::WorkspacesRequired);
    assert_eq!(err(&d, json!({"kind": "item.move", "id": "itm_home", "section": "sec_workspaces", "index": 0})), Reject::WorkspacesRequired);
    assert_eq!(err(&d, json!({"kind": "section.remove", "id": "sec_workspaces"})), Reject::WorkspacesRequired);
    let second = json!({"id": "sec_w2", "region": "top", "look": "list", "content": "workspaces"});
    assert_eq!(err(&d, json!({"kind": "section.add", "section": second, "index": 0})), Reject::WorkspacesRequired);
    assert_eq!(err(&d, json!({"kind": "section.update", "id": "sec_workspaces", "patch": {"room": "prof_a"}})), Reject::WorkspacesRequired);
}

#[test]
fn moves() {
    let d = defaults();
    let across = ok(&d, json!({"kind": "item.move", "id": "itm_home", "section": "sec_bottom", "index": 1}));
    assert_eq!(find(&across, "sec_bottom").items.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["itm_settings", "itm_home", "itm_account"]);
    let within = ok(&d, json!({"kind": "item.move", "id": "itm_settings", "section": "sec_bottom", "index": 1}));
    assert_eq!(find(&within, "sec_bottom").items[1].id, "itm_settings");
    assert_eq!(ok(&d, json!({"kind": "item.move", "id": "itm_home", "section": "sec_top", "index": 0})), d);
    let to_top = ok(&d, json!({"kind": "section.move", "id": "sec_workspaces", "region": "top", "index": 1}));
    assert_eq!(section_ids(&to_top, Region::Top), ["sec_top", "sec_workspaces"]);
    let bottom_first = ok(&d, json!({"kind": "section.move", "id": "sec_top", "region": "bottom", "index": 0}));
    assert_eq!(section_ids(&bottom_first, Region::Bottom), ["sec_top", "sec_bottom"]);
}

#[test]
fn duplicate_ref_on_move_and_unknowns() {
    let copy = json!({"id": "itm_home2", "ref": {"kind": "built_in", "value": "home"}});
    let d = ok(&defaults(), json!({"kind": "item.add", "item": copy, "section": "sec_bottom", "index": 0}));
    assert_eq!(err(&d, json!({"kind": "item.move", "id": "itm_home", "section": "sec_bottom", "index": 0})), Reject::DuplicateRef);
    let d = defaults();
    assert_eq!(err(&d, json!({"kind": "item.remove", "id": "itm_nope"})), Reject::UnknownItem);
    assert_eq!(err(&d, json!({"kind": "item.move", "id": "itm_home", "section": "sec_nope", "index": 0})), Reject::UnknownSection);
    assert_eq!(err(&d, json!({"kind": "item.update", "id": "itm_nope", "shows_label": true})), Reject::UnknownItem);
    let dup = json!({"id": "itm_settings", "ref": {"kind": "built_in", "value": "history"}});
    assert_eq!(err(&d, json!({"kind": "item.add", "item": dup, "section": "sec_top", "index": 0})), Reject::DuplicateId);
}

#[test]
fn sections_add_update_remove() {
    let d = defaults();
    let s = json!({"id": "sec_p", "title": "Project", "region": "top", "look": "list", "content": "items"});
    assert_eq!(section_ids(&ok(&d, json!({"kind": "section.add", "section": s, "index": 0})), Region::Top), ["sec_p", "sec_top"]);
    assert_eq!(section_ids(&ok(&d, json!({"kind": "section.add", "section": s, "index": 5})), Region::Top), ["sec_top", "sec_p"]);
    let set = ok(&d, json!({"kind": "section.update", "id": "sec_bottom",
        "patch": {"title": "Tools", "look": "list", "room": "prof_a", "max_rows": 3, "shows_title": false}}));
    let b = find(&set, "sec_bottom");
    assert_eq!((b.title.as_deref(), b.look, b.room.as_deref(), b.max_rows, b.shows_title), (Some("Tools"), Look::List, Some("prof_a"), Some(3), false));
    let cleared = ok(&set, json!({"kind": "section.update", "id": "sec_bottom", "patch": {"title": null, "room": null, "max_rows": null}}));
    let b = find(&cleared, "sec_bottom");
    assert_eq!((b.title.clone(), b.room.clone(), b.max_rows), (None, None, None));
    assert_eq!(err(&d, json!({"kind": "section.update", "id": "sec_bottom", "patch": {"title": ""}})), Reject::InvalidTitle);
    assert_eq!(err(&d, json!({"kind": "section.update", "id": "sec_bottom", "patch": {"title": "x".repeat(81)}})), Reject::InvalidTitle);
    assert_eq!(err(&d, json!({"kind": "section.update", "id": "sec_bottom", "patch": {"max_rows": 0}})), Reject::InvalidMaxRows);
    assert_eq!(err(&d, json!({"kind": "section.update", "id": "sec_bottom", "patch": {"max_rows": 51}})), Reject::InvalidMaxRows);
    assert_eq!(err(&d, json!({"kind": "section.update", "id": "sec_top", "patch": {"layout": "grid", "columns": 40}})), Reject::InvalidArrangement);
    let grid = ok(&d, json!({"kind": "section.update", "id": "sec_top", "patch": {"layout": "grid"}}));
    assert_eq!(find(&grid, "sec_top").arrangement.align, Alignment::Leading);
    let gap = ok(&d, json!({"kind": "section.update", "id": "sec_bottom", "patch": {"gap": 6}}));
    assert_eq!(find(&gap, "sec_bottom").arrangement.layout, ArrangementLayout::Inline);
    assert_eq!(ok(&d, json!({"kind": "section.update", "id": "sec_top", "patch": {}})), d);
    let removed = ok(&d, json!({"kind": "section.remove", "id": "sec_bottom"}));
    assert!(removed.sections.iter().all(|s| s.id != "sec_bottom"));
    assert_eq!(err(&d, json!({"kind": "section.remove", "id": "sec_nope"})), Reject::UnknownSection);
}

#[test]
fn limits_reset_and_unknown_refs() {
    let mut d = defaults();
    for n in 0..(MAX_SECTIONS - d.sections.len()) {
        let s = json!({"id": format!("sec_{n}"), "region": "top", "look": "list", "content": "items"});
        d = ok(&d, json!({"kind": "section.add", "section": s, "index": 0}));
    }
    let over = json!({"id": "sec_over", "region": "top", "look": "list", "content": "items"});
    assert_eq!(err(&d, json!({"kind": "section.add", "section": over, "index": 0})), Reject::TooMany);
    let edited = ok(&defaults(), json!({"kind": "item.remove", "id": "itm_home"}));
    let reset = ok(&edited, json!({"kind": "layout.reset"}));
    assert_eq!((reset.sections.clone(), reset.revision), (defaults().sections, edited.revision + 1));
    assert_eq!(ok(&defaults(), json!({"kind": "layout.reset"})), defaults());
    let future = json!({"id": "itm_f", "ref": {"kind": "hologram", "value": "x"}});
    let doc = ok(&defaults(), json!({"kind": "item.add", "item": future, "section": "sec_top", "index": 1}));
    let doc = ok(&doc, json!({"kind": "item.move", "id": "itm_home", "section": "sec_bottom", "index": 0}));
    assert_eq!(serde_json::to_value(&find(&doc, "sec_top").items[0]).unwrap()["ref"], json!({"kind": "hologram", "value": "x"}));
    let label = ok(&defaults(), json!({"kind": "item.update", "id": "itm_account", "shows_label": true}));
    assert!(find(&label, "sec_bottom").items[1].shows_label);
}

/// SplitMix64, so a failure reproduces from its seed (no proptest
/// dependency in this crate).
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    fn pick<'a>(&mut self, values: &[&'a str]) -> &'a str {
        values[self.below(values.len() as u64) as usize]
    }

    fn flag(&mut self) -> bool {
        self.below(2) == 1
    }
}

fn random_op(rng: &mut Rng, step: usize) -> Op {
    let section = rng.pick(&["sec_top", "sec_workspaces", "sec_bottom", "sec_r0", "sec_r1", "sec_ghost"]).to_string();
    let item = rng.pick(&["itm_home", "itm_settings", "itm_account", "itm_r0", "itm_r1", "itm_ghost"]).to_string();
    let region = [Region::Top, Region::Middle, Region::Bottom][rng.below(3) as usize];
    let reference = rng.pick(&["home", "settings", "history", "ws_1"]).to_string();
    let index = rng.below(6) as i64 - 1;
    let flag = rng.flag();
    let rows = rng.below(53) as i64;
    match rng.below(9) {
        0 => Op::SectionAdd {
            section: Section {
                id: format!("sec_r{}", step % 2),
                title: None,
                shows_title: true,
                region,
                look: Look::List,
                arrangement: Arrangement::default(),
                room: None,
                max_rows: None,
                content: if flag && rows == 0 { Content::Workspaces } else { Content::Items },
                items: vec![],
            },
            index,
        },
        1 => Op::SectionUpdate {
            id: section,
            patch: SectionPatch {
                max_rows: Update::Set(rows),
                title: Update::Set(format!("T{step}")),
                layout: Some(if flag { ArrangementLayout::Grid } else { ArrangementLayout::Inline }),
                gap: Update::Set(rows - 2),
                columns: if flag { Update::Clear } else { Update::Set(rows % 14) },
                ..Default::default()
            },
        },
        2 => Op::SectionMove { id: section, region, index },
        3 => Op::SectionRemove { id: section },
        4 | 5 => Op::ItemAdd {
            item: Item { id: format!("itm_r{}", step % 2), reference: ItemRef { kind: "built_in".into(), value: reference }, shows_label: flag },
            section,
            index,
        },
        6 => Op::ItemMove { id: item, section, index },
        7 if flag => Op::ItemRemove { id: item },
        7 => Op::ItemRemoveRef { reference: ItemRef { kind: "built_in".into(), value: reference } },
        _ if rows == 0 => Op::Reset,
        _ => Op::ItemUpdate { id: item, shows_label: flag },
    }
}

/// Random op sequences keep L1 (one workspaces section, never
/// room-scoped), L2 (unique ids; moves conserve items), L3 (one ref per
/// section), L4 limits, and bump the revision by one per change.
#[test]
fn random_ops_keep_invariants() {
    for seed in [1u64, 7, 42, 1_234, 98_765, 31_337, 271_828, 3_141_592] {
        let mut rng = Rng(seed);
        let mut doc = defaults();
        for step in 0..400 {
            let op = random_op(&mut rng, step);
            let before = doc.clone();
            let Ok(next) = reduce(&doc, &op) else { continue };
            doc = next;
            assert_eq!(doc.sections.iter().filter(|s| s.content == Content::Workspaces).count(), 1, "seed {seed}");
            assert!(doc.sections.iter().filter(|s| s.content == Content::Workspaces).all(|s| s.room.is_none()));
            let all = ids(&doc);
            let mut unique = all.clone();
            unique.sort();
            unique.dedup();
            assert_eq!(unique.len(), all.len(), "seed {seed}");
            for section in &doc.sections {
                let mut refs: Vec<_> = section.items.iter().map(|i| (i.reference.kind.clone(), i.reference.value.clone())).collect();
                let count = refs.len();
                refs.sort();
                refs.dedup();
                assert_eq!(refs.len(), count, "seed {seed}");
            }
            assert!(doc.sections.len() <= MAX_SECTIONS && all.len() <= MAX_ITEMS);
            assert!(doc.sections.iter().all(|s| s.arrangement.is_valid() && s.max_rows.is_none_or(|r| MAX_ROWS.contains(&r))));
            if matches!(op, Op::ItemMove { .. } | Op::SectionMove { .. }) {
                let mut a = all.clone();
                let mut b = ids(&before);
                a.sort();
                b.sort();
                assert_eq!(a, b, "seed {seed}");
            }
            assert_eq!(doc.revision, before.revision + u64::from(doc.sections != before.sections), "seed {seed}");
        }
    }
}

/// The cases shared with the app's reducer
/// (Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json).
#[test]
fn shared_cases_match_the_app() {
    let file: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../../Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json"
    ))
    .unwrap();
    let cases = file["cases"].as_array().unwrap();
    assert!(cases.len() >= 20);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let result = reduce(&defaults(), &op(case["op"].clone()));
        match (case["expect"].as_str().unwrap(), result) {
            ("accept", Ok(doc)) => {
                assert_eq!(doc.revision, case["revision"].as_u64().unwrap(), "{name}");
                if let Some(id) = case["section"].as_str() {
                    let section = find(&doc, id);
                    if let Some(items) = case["items"].as_array() {
                        let actual: Vec<_> = section.items.iter().map(|i| json!(i.id)).collect();
                        assert_eq!(&actual, items, "{name}");
                    }
                    if let Some(arrangement) = case.get("arrangement") {
                        assert_eq!(&serde_json::to_value(section.arrangement).unwrap(), arrangement, "{name}");
                    }
                }
            }
            ("reject", Err(reject)) => assert_eq!(reject.as_str(), case["reason"].as_str().unwrap(), "{name}"),
            (expect, other) => panic!("{name}: expected {expect}, got {other:?}"),
        }
    }
}
