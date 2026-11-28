//! Mirrors `SidebarSpaceOwnsPinsAndGroupsTests`, `SidebarGroupSortTests`, `SidebarDocAppSectionAfterListTests` and the
//! machine-order cases of `SidebarDocArrangeIdempotenceTests`, at the rule level.

use super::*;

const WORK: &str = "prof_work";
const HOME: &str = DEFAULT_ROOM;

fn group(id: &str, section: &str, room: Option<&str>) -> BandGroup {
    BandGroup {
        id: id.into(),
        section: section.into(),
        room: room.map(Into::into),
        ..BandGroup::default()
    }
}

fn set(ids: &[&str]) -> BTreeSet<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

/// Pinned: empty group `itm_gw` made in Work. Work: empty `itm_gc` made in Work, empty `itm_go` with no space,
/// `itm_gl` (no space) whose open workspace `ws-9` lists elsewhere.
fn fixture() -> Vec<BandGroup> {
    let mut gl = group("itm_gl", "sec_custom", None);
    gl.open_members = vec!["ws-9".into()];
    vec![
        group("itm_gw", "sec_pinned", Some(WORK)),
        group("itm_gc", "sec_custom", Some(WORK)),
        group("itm_go", "sec_custom", None),
        gl,
    ]
}

fn layout() -> Vec<LayoutSection> {
    vec![
        LayoutSection { id: "sec_pinned".into(), content: "items".into() },
        LayoutSection { id: "sec_custom".into(), content: "items".into() },
        LayoutSection { id: "sec_m".into(), content: "workspaces".into() },
    ]
}

fn drawn(room: Option<&str>, pulled: &[&str]) -> BTreeSet<String> {
    let (before, after) =
        sections(&layout(), &fixture(), &set(pulled), &BTreeSet::new(), room, None, None);
    before
        .iter()
        .chain(&after)
        .flat_map(|section| section.groups.iter().map(|group| group.id.clone()))
        .collect()
}

#[test]
fn a_group_draws_only_in_the_space_it_was_made_in() {
    assert_eq!(drawn(Some(WORK), &[]), set(&["itm_gw", "itm_gc"]));
    assert_eq!(drawn(Some(HOME), &[]), set(&["itm_go"]));
}

#[test]
fn without_a_space_every_group_draws() {
    assert_eq!(drawn(None, &[]), set(&["itm_gw", "itm_gc", "itm_go", "itm_gl"]));
}

#[test]
fn a_group_lists_where_its_open_workspace_lists() {
    assert!(drawn(Some(WORK), &["itm_gl"]).contains("itm_gl"));
}

#[test]
fn the_groups_left_out_follow_the_windows_space() {
    let groups = fixture();
    let none = BTreeSet::new();
    assert_ne!(
        not_listed_here(&groups, &none, Some(WORK), None, &none),
        not_listed_here(&groups, &none, Some(HOME), None, &none)
    );
}

#[test]
fn a_nested_group_goes_with_its_parent() {
    let mut child = group("itm_gk", "sec_custom", Some(WORK));
    child.parent = Some("itm_gp".into());
    let groups = vec![group("itm_gp", "sec_custom", None), child];
    let none = BTreeSet::new();
    assert_eq!(
        not_listed_here(&groups, &none, Some(WORK), None, &none),
        set(&["itm_gp", "itm_gk"])
    );
    assert!(not_listed_here(&groups, &none, Some(HOME), None, &none).is_empty());
}

#[test]
fn a_kept_child_keeps_its_parents() {
    let mut parent = group("itm_gp", "sec_pinned", None);
    parent.open_members = vec!["ws-1".into()];
    let mut child = group("itm_pc", "sec_pinned", None);
    child.parent = Some("itm_gp".into());
    let groups = vec![parent, child];
    let none = BTreeSet::new();
    assert_eq!(
        not_listed_here(&groups, &none, Some(HOME), None, &none),
        set(&["itm_gp", "itm_pc"])
    );
    assert!(not_listed_here(&groups, &none, Some(HOME), None, &set(&["itm_pc"])).is_empty());
}

#[test]
fn a_gone_spaces_groups_list_in_default() {
    let groups = vec![
        group("itm_gg", "sec_custom", Some("prof_gone")),
        group("itm_gw", "sec_custom", Some(WORK)),
    ];
    let spaces = set(&[WORK]);
    let none = BTreeSet::new();
    assert_eq!(not_listed_here(&groups, &none, Some(HOME), Some(&spaces), &none), set(&["itm_gw"]));
    assert_eq!(not_listed_here(&groups, &none, Some(WORK), Some(&spaces), &none), set(&["itm_gg"]));
    assert_eq!(owning_room(None, Some(&spaces)), HOME);
    assert_eq!(owning_room(Some("prof_gone"), None), "prof_gone");
}

#[test]
fn a_parent_cycle_ends() {
    let mut a = group("a", "s", Some(WORK));
    a.parent = Some("b".into());
    let mut b = group("b", "s", Some(WORK));
    b.parent = Some("a".into());
    let groups = vec![a, b];
    let none = BTreeSet::new();
    assert!(not_listed_here(&groups, &none, Some(HOME), None, &none).is_empty());
    assert_eq!(listed_elsewhere(&groups, &none), none);
    assert_eq!(top_rooms(&groups).len(), 2);
}

#[test]
fn an_open_workspace_elsewhere_takes_its_group_and_those_above() {
    let mut parent = group("p", "s", None);
    parent.parent = None;
    let mut child = group("c", "s", None);
    child.parent = Some("p".into());
    child.open_members = vec!["ws-2".into()];
    assert_eq!(listed_elsewhere(&[parent, child], &set(&["ws-2"])), set(&["p", "c"]));
}

#[test]
fn an_app_section_after_the_lists_draws_with_no_groups() {
    let layout = vec![
        LayoutSection { id: "sec_m".into(), content: "workspaces".into() },
        LayoutSection { id: "sec_app".into(), content: "app".into() },
        LayoutSection { id: "sec_empty".into(), content: "items".into() },
    ];
    let none = BTreeSet::new();
    let (before, after) = sections(&layout, &[], &none, &none, None, None, None);
    assert!(before.is_empty());
    assert_eq!(after, vec![ListSection { id: "sec_app".into(), groups: vec![] }]);
}

#[test]
fn a_header_alone_takes_the_confirmed_fold() {
    let groups = vec![group("g", "sec_custom", None)];
    let folds = BTreeMap::from([("g".to_owned(), true)]);
    let none = BTreeSet::new();
    let (before, _) = sections(&layout(), &groups, &none, &none, None, None, Some(&folds));
    assert_eq!(
        before[1].groups,
        vec![SectionGroup { id: "g".into(), pulled: false, collapsed: Some(true) }]
    );
    let (before, _) = sections(&layout(), &groups, &set(&["g"]), &none, None, None, Some(&folds));
    assert_eq!(
        before[1].groups,
        vec![SectionGroup { id: "g".into(), pulled: true, collapsed: None }]
    );
}

fn node(id: NodeId, item: Option<&str>) -> MappedNode {
    MappedNode { id, item: item.map(Into::into) }
}

#[test]
fn a_machine_list_draws_its_links_in_document_order() {
    let nodes = vec![
        node(NodeId::Workspace("w1".into()), Some("i1")),
        node(NodeId::Workspace("w2".into()), Some("i2")),
    ];
    let order =
        vec![Entry::Workspace("i2".into()), Entry::Link("l".into()), Entry::Workspace("i1".into())];
    assert_eq!(
        machine_nodes(&nodes, Some(&order)),
        vec![
            Placed::Node(NodeId::Workspace("w2".into())),
            Placed::Link("l".into()),
            Placed::Node(NodeId::Workspace("w1".into())),
        ]
    );
    let no_link = vec![Entry::Workspace("i2".into()), Entry::Workspace("i1".into())];
    assert_eq!(machine_nodes(&nodes, Some(&no_link)), machine_nodes(&nodes, None));
}

#[test]
fn an_unplaced_row_keeps_its_mapped_slot() {
    let nodes = vec![
        node(NodeId::Workspace("new".into()), None),
        node(NodeId::Workspace("w1".into()), Some("i1")),
        node(NodeId::Workspace("tail".into()), None),
    ];
    let order = vec![Entry::Link("l".into()), Entry::Workspace("i1".into())];
    assert_eq!(
        machine_nodes(&nodes, Some(&order)),
        vec![
            Placed::Link("l".into()),
            Placed::Node(NodeId::Workspace("new".into())),
            Placed::Node(NodeId::Workspace("w1".into())),
            Placed::Node(NodeId::Workspace("tail".into())),
        ]
    );
}

#[test]
fn a_member_follows_the_nearest_shown_workspace_before_it() {
    let members = Members {
        listed: vec![
            Listed { id: "l1".into(), after: Some("i2".into()), ..Listed::default() },
            Listed { id: "l2".into(), ..Listed::default() },
        ],
        member_items: vec!["i1".into(), "i2".into()],
        shown: BTreeMap::from([("i1".to_owned(), "w1".to_owned())]),
        ..Members::default()
    };
    assert_eq!(
        member_items(&members),
        Some(vec![
            GroupItem { id: "l1".into(), after: Some("w1".into()) },
            GroupItem { id: "l2".into(), after: None }
        ])
    );
    assert_eq!(member_items(&Members::default()), None);
}

#[test]
fn a_pinned_groups_member_of_its_space_draws_only_there() {
    let listed = |id: &str, room: Option<&str>| Listed {
        id: id.into(),
        room: room.map(Into::into),
        item_room: room.map(Into::into),
        ..Listed::default()
    };
    let members = |room: &str| Members {
        listed: vec![listed("own", Some(WORK)), listed("none", None), listed("other", Some(HOME))],
        pinned: true,
        band: true,
        group_room: Some(WORK.into()),
        room: Some(room.into()),
        ..Members::default()
    };
    let ids = |room: &str| -> Vec<String> {
        member_items(&members(room)).unwrap_or_default().into_iter().map(|item| item.id).collect()
    };
    assert_eq!(ids(WORK), vec!["own", "none"]);
    assert_eq!(ids(HOME), vec!["none", "other"]);
}

#[test]
fn only_a_member_draws_its_pin_mark() {
    let rows = vec![
        MarkRow { item: Some("a".into()), in_group: false },
        MarkRow { item: Some("a".into()), in_group: true },
        MarkRow { item: None, in_group: true },
    ];
    let marks = marks(&rows, &set(&["a"]), &set(&["a"]));
    assert_eq!(
        marks,
        vec![
            Mark { archived: true, pinned_in_group: false },
            Mark { archived: true, pinned_in_group: true },
            Mark { archived: false, pinned_in_group: false },
        ]
    );
}

fn member(name_rank: i64, last_activity: Option<f64>) -> SortMember {
    SortMember { name_rank, last_activity, ..SortMember::default() }
}

#[test]
fn manual_keeps_the_stored_order_and_name_ties_keep_it_too() {
    let members = vec![member(2, Some(5.0)), member(0, None), member(1, Some(9.0))];
    assert_eq!(ordered(Sort::Manual, &members), vec![0, 1, 2]);
    assert_eq!(ordered(Sort::Name, &members), vec![1, 2, 0]);
    assert_eq!(
        ordered(Sort::Name, &[member(1, None), member(1, None), member(0, None)]),
        vec![2, 0, 1]
    );
}

#[test]
fn recent_puts_the_latest_first_and_no_activity_last() {
    let members = vec![
        member(0, Some(-600.0)),
        member(0, None),
        member(0, Some(0.0)),
        member(0, None),
        member(0, Some(-60.0)),
    ];
    assert_eq!(ordered(Sort::Recent, &members), vec![2, 4, 0, 1, 3]);
}

#[test]
fn pinned_stay_first_and_archived_last() {
    let mut archived = member(2, None);
    archived.archived = true;
    let mut pinned = member(3, None);
    pinned.pinned = true;
    assert_eq!(
        ordered(Sort::Name, &[archived, member(1, None), pinned, member(0, None)]),
        vec![2, 3, 1, 0]
    );
}

#[test]
fn a_group_with_no_stored_sort_is_manual() {
    let stored = BTreeMap::from([("g1".to_owned(), Sort::Recent)]);
    assert_eq!(sorts(&["g1".into(), "g2".into()], &stored), vec![Sort::Recent, Sort::Manual]);
}

#[test]
fn the_ops_answer_in_json() {
    let request: Request = serde_json::from_value(json!({"op": "ordered", "sort": "name",
        "members": [{"name_rank": 1}, {"name_rank": 0}]}))
    .expect("request");
    assert_eq!(respond(request), json!({"order": [1, 0]}));
    let request: Request = serde_json::from_value(json!({"op": "member_items"})).expect("request");
    assert_eq!(respond(request), json!({"items": null}));
}
