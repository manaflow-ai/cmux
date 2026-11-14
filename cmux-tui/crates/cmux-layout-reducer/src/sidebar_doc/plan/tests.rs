use super::*;

fn doc_with(sections: Vec<Section>, items: Vec<Item>) -> Doc {
    Doc::from_parts(1, sections, items)
}

fn group_item(id: &str, parent: Option<&str>) -> Item {
    let mut item = Item::new(
        id,
        "sec_m_mini",
        Body::Group { name: id.into(), color: None, icon: None, collapsed: false, profile: None },
    );
    item.parent = parent.map(str::to_string);
    item.order = "a".into();
    item
}

/// A chain of `levels` nested groups g1 > g2 > ... in machine mini's section.
fn chain(levels: usize) -> Doc {
    let items = (1..=levels)
        .map(|level| {
            let parent = (level > 1).then(|| format!("g{}", level - 1));
            group_item(&format!("g{level}"), parent.as_deref())
        })
        .collect();
    doc_with(vec![Section::machine("mini")], items)
}

fn subgroup_request(parent: &str) -> PlanRequest {
    PlanRequest::Subgroup {
        parent: parent.into(),
        id: "g_new".into(),
        name: "feat-x".into(),
        color: Some("green".into()),
    }
}

#[test]
fn a_subgroup_is_one_group_create_inside_its_parent() {
    let ops = plan(&chain(1), &subgroup_request("g1")).expect("planned");
    let value = serde_json::to_value(&ops).expect("serializes");
    assert_eq!(
        value,
        json!([{"op": "group.create", "id": "g_new", "name": "feat-x", "color": "green", "items": [],
                    "to": {"section": "sec_m_mini", "parent": "g1"}}])
    );
}

#[test]
fn a_personal_group_id_names_its_item() {
    let doc = doc_with(vec![Section::machine("mini")], vec![group_item(&group_item_id("p"), None)]);
    let ops = plan(&doc, &subgroup_request("p")).expect("planned");
    let [Op::GroupCreate { to: Some(to), .. }] = ops.as_slice() else { panic!("one group.create") };
    assert_eq!(to.parent.as_deref(), Some(group_item_id("p").as_str()));
}

#[test]
fn the_deepest_level_plans_nothing() {
    assert!(
        plan(&chain(MAX_GROUP_DEPTH - 1), &subgroup_request(&format!("g{}", MAX_GROUP_DEPTH - 1)))
            .is_ok()
    );
    assert_eq!(
        plan(&chain(MAX_GROUP_DEPTH), &subgroup_request(&format!("g{MAX_GROUP_DEPTH}"))),
        Err(PlanRefusal::TooDeep)
    );
    assert!(plan(&chain(6), &subgroup_request("g6")).is_ok(), "six levels is far from the limit");
}

#[test]
fn a_blank_name_becomes_the_default_name() {
    for blank in ["", "  ", "\n\t"] {
        let request = PlanRequest::Subgroup {
            parent: "g1".into(),
            id: "g2".into(),
            name: blank.into(),
            color: None,
        };
        let ops = plan(&chain(1), &request).unwrap_or_default();
        assert!(
            matches!(ops.as_slice(), [Op::GroupCreate { name, .. }] if name == DEFAULT_GROUP_NAME),
            "{blank:?}: {ops:?}"
        );
    }
}

#[test]
fn an_unknown_parent_is_refused() {
    assert_eq!(plan(&chain(1), &subgroup_request("nope")), Err(PlanRefusal::UnknownGroup));
}

fn host(on: Option<bool>, title: Option<&str>) -> PlanRequest {
    PlanRequest::HostGroup { session: "mini".into(), on, title: title.map(str::to_string) }
}

fn machine(host_group: bool) -> Doc {
    let mut section = Section::machine("mini");
    section.host_group = host_group;
    doc_with(vec![section], vec![])
}

#[test]
fn unmarking_patches_only_a_remote_group() {
    let ops = plan(&machine(true), &host(Some(false), None)).expect("planned");
    assert_eq!(
        serde_json::to_value(&ops).expect("serializes"),
        json!([{"op": "section.update", "id": "sec_m_mini", "patch": {"host_group": false}}])
    );
    assert!(plan(&machine(false), &host(Some(false), None)).expect("planned").is_empty());
    assert!(plan(&doc_with(vec![], vec![]), &host(Some(false), None)).expect("planned").is_empty());
}

#[test]
fn marking_adds_the_section_when_the_document_has_none() {
    let ops = plan(&doc_with(vec![], vec![]), &host(None, Some("Build Mini"))).expect("planned");
    let [Op::SectionAdd { section, .. }] = ops.as_slice() else { panic!("one section.add") };
    assert_eq!(section.id, "sec_m_mini");
    assert!(section.host_group);
    assert_eq!(section.title.as_deref(), Some("Build Mini"));
    assert_eq!(section.kind, SectionKind::Machine { session_id: "mini".into() });
}

#[test]
fn marking_patches_what_differs() {
    let ops = plan(&machine(false), &host(None, None)).expect("planned");
    assert_eq!(
        serde_json::to_value(&ops).expect("serializes"),
        json!([{"op": "section.update", "id": "sec_m_mini", "patch": {"host_group": true}}])
    );
    let ops = plan(&machine(true), &host(None, Some("Build Mini"))).expect("planned");
    assert_eq!(
        serde_json::to_value(&ops).expect("serializes"),
        json!([{"op": "section.update", "id": "sec_m_mini", "patch": {"title": "Build Mini"}}]),
        "a remote group that exists is only renamed"
    );
    assert!(plan(&machine(true), &host(None, None)).expect("planned").is_empty());
    assert!(
        plan(&machine(true), &host(None, Some(""))).expect("planned").is_empty(),
        "an empty title keeps the host's name"
    );
}
