use super::*;

const LOCAL: &str = "local";

fn ws(id: &str) -> Workspace {
    Workspace { id: id.into(), machine: LOCAL.into(), ..Workspace::default() }
}

fn ws_on(id: &str, machine: &str) -> Workspace {
    Workspace { id: id.into(), machine: machine.into(), ..Workspace::default() }
}

fn loose(id: &str) -> Node {
    Node::Workspace { workspace: ws(id) }
}

fn group(id: &str, members: &[&str]) -> Group {
    Group {
        id: id.into(),
        name: id.into(),
        parent: None,
        pinned: false,
        collapsed: false,
        members: members.iter().map(|id| Member::Workspace { workspace: ws(id) }).collect(),
    }
}

fn node(group: Group) -> Node {
    Node::Group { group }
}

fn machine(id: &str) -> SectionId {
    SectionId::Machine { id: id.into() }
}

fn section(nodes: Vec<Node>) -> Section {
    Section { id: machine(LOCAL), collapsed: false, nodes }
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|id| (*id).to_owned()).collect()
}

/// The section's top-level rows: a workspace's id or a group's id.
fn order(section: &Section) -> Vec<String> {
    section
        .nodes
        .iter()
        .map(|node| match node {
            Node::Workspace { workspace } => workspace.id.clone(),
            Node::Group { group } => group.id.clone(),
            Node::Item { r#ref } => format!("item{ref}"),
        })
        .collect()
}

fn members(sections: &[Section], id: &str) -> Vec<String> {
    let (s, n) = locate_group(id, sections).expect("group listed");
    let Node::Group { group } = &sections[s].nodes[n] else { panic!("not a group") };
    group
        .members
        .iter()
        .map(|member| match member {
            Member::Workspace { workspace } => workspace.id.clone(),
            Member::Item { r#ref } => format!("item{ref}"),
        })
        .collect()
}

fn at(group: Option<&str>, index: i64) -> Position {
    Position { section: machine(LOCAL), group: group.map(str::to_owned), index }
}

// MARK: Group ordering verbs (Swift SidebarGroupOrderTests)

/// Loose `a`, `b`; group `g1` (`c`); group `g2` (`d`, `e`, collapsed); loose `f`.
fn ordering(g2_collapsed: bool, g1_collapsed: bool) -> Vec<Section> {
    let mut g1 = group("g1", &["c"]);
    g1.collapsed = g1_collapsed;
    let mut g2 = group("g2", &["d", "e"]);
    g2.collapsed = g2_collapsed;
    vec![section(vec![loose("a"), loose("b"), node(g1), node(g2), loose("f")])]
}

fn moved(group: &str, step: GroupMove) -> Vec<String> {
    let mut sections = ordering(true, false);
    let index = group_index(group, step, &sections).expect("an index");
    assert!(apply(&Intent::ReorderGroup { group: group.into(), index }, &mut sections));
    order(&sections[0])
}

#[test]
fn move_group_to_top_goes_above_every_row() {
    assert_eq!(moved("g2", GroupMove::Top), ids(&["g2", "a", "b", "g1", "f"]));
}

#[test]
fn move_group_to_bottom_goes_below_every_row() {
    assert_eq!(moved("g1", GroupMove::Bottom), ids(&["a", "b", "g2", "f", "g1"]));
}

#[test]
fn move_group_down_steps_below_the_next_row() {
    assert_eq!(moved("g1", GroupMove::Down), ids(&["a", "b", "g2", "g1", "f"]));
}

#[test]
fn move_group_up_steps_above_the_row_above() {
    assert_eq!(moved("g2", GroupMove::Up), ids(&["a", "b", "g2", "g1", "f"]));
    assert_eq!(moved("g1", GroupMove::Up), ids(&["a", "g1", "b", "g2", "f"]));
}

#[test]
fn a_group_move_that_changes_nothing_has_no_index() {
    let mut sections = ordering(true, false);
    let top = group_index("g2", GroupMove::Top, &sections).expect("an index");
    apply(&Intent::ReorderGroup { group: "g2".into(), index: top }, &mut sections);
    assert_eq!(group_index("g2", GroupMove::Top, &sections), None);
    assert_eq!(group_index("g2", GroupMove::Up, &sections), None);
    assert_eq!(group_index("missing", GroupMove::Down, &sections), None);
}

#[test]
fn collapse_others_toggles_the_other_open_groups_and_opens_this_one() {
    assert_eq!(groups_toggled_by_collapsing_others("g1", &ordering(false, false)), ids(&["g2"]));
    assert_eq!(
        groups_toggled_by_collapsing_others("g1", &ordering(false, true)),
        ids(&["g1", "g2"])
    );
    assert!(groups_toggled_by_collapsing_others("g1", &ordering(true, false)).is_empty());
}

#[test]
fn a_selection_moves_to_the_top_of_its_group_as_one_block() {
    let mut sections = vec![section(vec![loose("a"), node(group("g2", &["d", "e", "x"]))])];
    let moving = tree_order(&ids(&["x", "e"]), &sections);
    assert_eq!(moving, ids(&["e", "x"]), "the block keeps sidebar order");
    assert!(apply(&Intent::Reorder { ids: moving, position: at(Some("g2"), 0) }, &mut sections));
    assert_eq!(members(&sections, "g2"), ids(&["e", "x", "d"]));
}

// MARK: Nested groups (Swift SidebarSubgroupReorderTests)

/// Loose `a`; group `g` (`c`) with subgroup `s` (`d`); group `h` (`e`); loose `z`.
fn nested(g_collapsed: bool) -> Vec<Section> {
    let mut g = group("g", &["c"]);
    g.collapsed = g_collapsed;
    let mut s = group("s", &["d"]);
    s.parent = Some("g".into());
    vec![section(vec![loose("a"), node(g), node(s), node(group("h", &["e"])), loose("z")])]
}

fn key(id: &str, direction: Direction, g_collapsed: bool) -> Option<Position> {
    keyboard_target(&ids(&[id]), direction, &nested(g_collapsed))
}

#[test]
fn moving_down_from_a_groups_last_member_enters_its_subgroup() {
    assert_eq!(key("c", Direction::Down, false), Some(at(Some("s"), 0)));
}

#[test]
fn moving_down_from_a_subgroups_last_member_leaves_the_whole_group() {
    // The gap before `h` (node 3 once `d` is out of `s`).
    assert_eq!(key("d", Direction::Down, false), Some(at(None, 3)));
}

#[test]
fn moving_up_from_a_groups_first_member_leaves_it_above_its_header() {
    assert_eq!(key("e", Direction::Up, false), Some(at(None, 3)));
}

#[test]
fn moving_up_from_below_a_group_enters_its_end() {
    assert_eq!(key("z", Direction::Up, false), Some(at(Some("h"), 1)));
    // From the top-level gap above `h`, one step up is the end of `s`, the last gap drawn inside `g`.
    let slots = order::slots(&nested(false)[0]);
    let above = slots.iter().position(|slot| *slot == at(None, 3)).expect("slot above h");
    assert_eq!(slots[above - 1], at(Some("s"), 1));
}

#[test]
fn no_slot_names_a_subgroup_as_a_top_level_row() {
    assert!(
        !order::slots(&nested(false)[0]).contains(&at(None, 2)),
        "the gap before s is inside g"
    );
}

#[test]
fn a_subgroup_under_a_collapsed_group_is_stepped_over() {
    // `a` out: g, s, h, z. One step down passes collapsed `g` and its hidden `s` to the gap before `h`.
    assert_eq!(key("a", Direction::Down, true), Some(at(None, 2)));
    assert_eq!(key("a", Direction::Down, true).and_then(|p| p.group), None);
    assert!(!order::slots(&nested(true)[0]).iter().any(|slot| slot.group.as_deref() == Some("s")));
}

#[test]
fn the_keyboard_never_leaves_the_section() {
    assert_eq!(key("a", Direction::Up, false), None);
    assert_eq!(key("z", Direction::Down, false), None);
    assert_eq!(keyboard_target(&ids(&["missing"]), Direction::Down, &nested(false)), None);
}

#[test]
fn move_group_down_passes_the_next_group_whole() {
    // `g` with `s` out: a, s, h, z; `g` goes after `h` (index 3: before z).
    assert_eq!(group_index("g", GroupMove::Down, &nested(false)), Some(3));
}

#[test]
fn move_group_up_lands_above_the_group_not_its_subgroup() {
    assert_eq!(group_index("h", GroupMove::Up, &nested(false)), Some(1));
}

#[test]
fn a_subgroup_is_not_moved_out_of_its_parent() {
    assert_eq!(group_index("s", GroupMove::Up, &nested(false)), None);
    assert_eq!(group_index("s", GroupMove::Down, &nested(false)), None);
}

// MARK: Reorder, move and prune

#[test]
fn a_move_that_empties_a_group_drops_it_unless_the_preview_keeps_it() {
    let base = vec![section(vec![loose("a"), node(group("g", &["b"]))])];
    let intent = Intent::Reorder { ids: ids(&["b"]), position: at(None, 0) };
    let reply = edit(&EditRequest { sections: base.clone(), intent: intent.clone(), prunes: true });
    assert!(reply.changed);
    assert_eq!(order(&reply.sections.expect("changed")[0]), ids(&["b", "a"]));
    let preview = edit(&EditRequest { sections: base, intent, prunes: false });
    assert_eq!(
        order(&preview.sections.expect("changed")[0]),
        ids(&["b", "a", "g"]),
        "an emptied group is a drop target"
    );
}

#[test]
fn a_group_that_was_empty_already_stays() {
    let mut sections =
        vec![section(vec![node(group("kept", &[])), node(group("g", &["a"])), loose("b")])];
    assert!(apply(
        &Intent::Reorder { ids: ids(&["b"]), position: at(Some("g"), 0) },
        &mut sections
    ));
    assert_eq!(order(&sections[0]), ids(&["kept", "g"]));
}

#[test]
fn a_leaving_workspace_keeps_the_groups_item_rows() {
    let mut g = group("g", &["a", "b"]);
    g.members.insert(1, Member::Item { r#ref: 7 });
    let mut sections = vec![section(vec![node(g), loose("c")])];
    assert!(apply(&Intent::Reorder { ids: ids(&["a"]), position: at(None, 1) }, &mut sections));
    assert_eq!(members(&sections, "g"), ids(&["item7", "b"]));
    // An index into a group counts its item rows.
    assert!(apply(
        &Intent::Reorder { ids: ids(&["c"]), position: at(Some("g"), 1) },
        &mut sections
    ));
    assert_eq!(members(&sections, "g"), ids(&["item7", "c", "b"]));
}

#[test]
fn a_group_whose_only_rows_are_items_is_not_pruned() {
    let mut g = group("g", &["a"]);
    g.members.push(Member::Item { r#ref: 0 });
    let mut sections = vec![section(vec![node(g)])];
    assert!(apply(&Intent::Reorder { ids: ids(&["a"]), position: at(None, 0) }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["a", "g"]));
}

#[test]
fn a_drop_on_another_machine_is_refused() {
    let base = vec![
        section(vec![loose("a")]),
        Section {
            id: machine("vm"),
            collapsed: false,
            nodes: vec![Node::Workspace { workspace: ws_on("v", "vm") }],
        },
    ];
    let reply = edit(&EditRequest {
        sections: base,
        intent: Intent::Reorder { ids: ids(&["v"]), position: at(None, 0) },
        prunes: true,
    });
    assert_eq!(reply, EditReply { changed: false, sections: None });
}

#[test]
fn a_group_slot_outside_a_machine_section_is_refused() {
    let mut sections = vec![Section {
        id: SectionId::Pinned,
        collapsed: false,
        nodes: vec![node(group("g", &["a"]))],
    }];
    let position = Position { section: SectionId::Pinned, group: Some("g".into()), index: 0 };
    assert!(!apply(&Intent::Reorder { ids: ids(&["a"]), position }, &mut sections));
}

#[test]
fn move_appends_to_the_group_after_its_other_members() {
    let mut sections = vec![section(vec![loose("a"), node(group("g", &["b", "c"]))])];
    assert!(apply(&Intent::Move { ids: ids(&["a", "b"]), group: "g".into() }, &mut sections));
    assert_eq!(members(&sections, "g"), ids(&["c", "a", "b"]));
    assert_eq!(order(&sections[0]), ids(&["g"]));
}

#[test]
fn reorder_group_clamps_its_index() {
    let mut sections = vec![section(vec![node(group("g", &["a"])), loose("b")])];
    assert!(apply(&Intent::ReorderGroup { group: "g".into(), index: 99 }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["b", "g"]));
    assert!(!apply(&Intent::ReorderGroup { group: "g".into(), index: 7 }, &mut sections));
}

// MARK: Groups

#[test]
fn create_group_forms_at_the_first_workspace_and_takes_its_section_only() {
    let mut sections = vec![
        section(vec![loose("a"), loose("b"), loose("c")]),
        Section {
            id: machine("vm"),
            collapsed: false,
            nodes: vec![Node::Workspace { workspace: ws_on("v", "vm") }],
        },
    ];
    let intent = Intent::CreateGroup {
        id: "n".into(),
        ids: ids(&["c", "b", "v"]),
        anchor: None,
        collapsed: true,
        index: None,
    };
    assert!(apply(&intent, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["a", "n"]));
    assert_eq!(members(&sections, "n"), ids(&["b", "c"]));
    let Node::Group { group } = &sections[0].nodes[1] else { panic!() };
    assert!(group.collapsed);
    assert_eq!(order(&sections[1]), ids(&["v"]));
}

#[test]
fn create_group_forms_at_an_onto_drops_target_row() {
    let mut sections = vec![section(vec![loose("a"), loose("b"), loose("c")])];
    let intent = Intent::CreateGroup {
        id: "n".into(),
        ids: ids(&["a", "c"]),
        anchor: Some("c".into()),
        collapsed: false,
        index: None,
    };
    assert!(apply(&intent, &mut sections));
    // `c` was node 2; `a` before it leaves, so the group lands at 1.
    assert_eq!(order(&sections[0]), ids(&["b", "n"]));
    assert_eq!(members(&sections, "n"), ids(&["a", "c"]));
}

#[test]
fn create_group_from_grouped_members_lands_after_their_group_and_prunes_it() {
    let mut sections = vec![section(vec![node(group("old", &["a"])), loose("b")])];
    let intent = Intent::CreateGroup {
        id: "n".into(),
        ids: ids(&["a", "b"]),
        anchor: None,
        collapsed: false,
        index: None,
    };
    assert!(apply(&intent, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["n"]));
}

#[test]
fn create_group_is_refused_for_a_known_id_or_outside_a_machine() {
    let mut sections = vec![section(vec![node(group("g", &["a"])), loose("b")])];
    let taken = Intent::CreateGroup {
        id: "g".into(),
        ids: ids(&["b"]),
        anchor: None,
        collapsed: false,
        index: None,
    };
    assert!(!apply(&taken, &mut sections));
    let mut pinned =
        vec![Section { id: SectionId::Pinned, collapsed: false, nodes: vec![loose("p")] }];
    let outside = Intent::CreateGroup {
        id: "n".into(),
        ids: ids(&["p"]),
        anchor: None,
        collapsed: false,
        index: None,
    };
    assert!(!apply(&outside, &mut pinned));
}

#[test]
fn create_group_at_an_explicit_index() {
    let mut sections = vec![section(vec![loose("a"), loose("b"), loose("c")])];
    let intent = Intent::CreateGroup {
        id: "n".into(),
        ids: ids(&["c"]),
        anchor: None,
        collapsed: false,
        index: Some(0),
    };
    assert!(apply(&intent, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["n", "a", "b"]));
}

#[test]
fn ungroup_puts_the_workspaces_where_the_group_was() {
    let mut g = group("g", &["b", "c"]);
    g.members.push(Member::Item { r#ref: 1 });
    let mut sections = vec![section(vec![loose("a"), node(g), loose("d")])];
    assert!(apply(&Intent::Ungroup { group: "g".into() }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["a", "b", "c", "d"]));
    assert!(!apply(&Intent::Ungroup { group: "g".into() }, &mut sections));
}

#[test]
fn closing_a_pinned_group_keeps_it_empty_and_folded() {
    let mut pinned = group("p", &["a"]);
    pinned.pinned = true;
    pinned.members.push(Member::Item { r#ref: 2 });
    let mut sections = vec![section(vec![node(pinned), node(group("g", &["b"]))])];
    assert!(apply(&Intent::CloseGroup { group: "p".into() }, &mut sections));
    assert_eq!(members(&sections, "p"), ids(&["item2"]));
    let Node::Group { group: p } = &sections[0].nodes[0] else { panic!() };
    assert!(p.collapsed);
    assert!(apply(&Intent::CloseGroup { group: "g".into() }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["p"]));
}

#[test]
fn closing_a_member_keeps_its_group() {
    let mut sections = vec![section(vec![node(group("g", &["a"]))])];
    assert!(apply(&Intent::Close { ids: ids(&["a"]) }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["g"]));
    assert!(!apply(&Intent::Close { ids: ids(&["a"]) }, &mut sections));
}

#[test]
fn group_flags_and_section_fold() {
    let mut sections = vec![section(vec![node(group("g", &["a"]))])];
    assert!(apply(&Intent::SetGroupPinned { group: "g".into(), pinned: true }, &mut sections));
    assert!(apply(&Intent::ToggleGroup { group: "g".into() }, &mut sections));
    assert!(apply(&Intent::ToggleSection { section: machine(LOCAL) }, &mut sections));
    let Node::Group { group: g } = &sections[0].nodes[0] else { panic!() };
    assert!(g.pinned && g.collapsed && sections[0].collapsed);
    assert!(!apply(&Intent::ToggleGroup { group: "missing".into() }, &mut sections));
}

// MARK: Pins

#[test]
fn pinning_adds_the_pinned_section_and_appends() {
    let mut sections = vec![section(vec![loose("a"), loose("b"), loose("c")])];
    assert!(apply(&Intent::SetPinned { ids: ids(&["c", "a"]), pinned: true }, &mut sections));
    assert_eq!(sections[0].id, SectionId::Pinned);
    assert_eq!(order(&sections[0]), ids(&["a", "c"]));
    assert_eq!(order(&sections[1]), ids(&["b"]));
}

#[test]
fn unpinning_returns_each_workspace_to_the_top_of_its_machine() {
    let pinned = Section {
        id: SectionId::Pinned,
        collapsed: false,
        nodes: vec![Node::Workspace { workspace: ws_on("v", "vm") }, loose("a"), loose("p")],
    };
    let mut sections = vec![
        pinned,
        section(vec![loose("b")]),
        Section {
            id: machine("vm"),
            collapsed: false,
            nodes: vec![Node::Workspace { workspace: ws_on("w", "vm") }],
        },
    ];
    assert!(apply(&Intent::SetPinned { ids: ids(&["v", "a", "b"]), pinned: false }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["p"]));
    assert_eq!(order(&sections[1]), ids(&["a", "b"]));
    assert_eq!(order(&sections[2]), ids(&["v", "w"]));
}

#[test]
fn unpinning_with_no_pinned_section_does_nothing() {
    let mut sections = vec![section(vec![loose("a")])];
    assert!(!apply(&Intent::SetPinned { ids: ids(&["a"]), pinned: false }, &mut sections));
}

// MARK: Queries

#[test]
fn position_counts_a_groups_item_rows() {
    let mut g = group("g", &["a", "b"]);
    g.members.insert(0, Member::Item { r#ref: 0 });
    let sections = vec![section(vec![loose("x"), node(g)])];
    assert_eq!(position_of("b", &sections), Some(at(Some("g"), 2)));
    assert_eq!(position_of("x", &sections), Some(at(None, 0)));
    assert_eq!(locate("b", &sections), Some(Location { section: 0, node: 1, child: Some(1) }));
}

#[test]
fn a_group_holds_one_machines_workspaces() {
    let sections = vec![
        section(vec![node(group("g", &["a"])), loose("b"), node(group("h", &[]))]),
        Section {
            id: machine("vm"),
            collapsed: false,
            nodes: vec![Node::Workspace { workspace: ws_on("v", "vm") }, node(group("vg", &[]))],
        },
    ];
    assert!(can_move(&ids(&["b"]), "g", &sections));
    assert!(!can_move(&ids(&["v"]), "g", &sections));
    assert!(!can_move(&[], "g", &sections));
    assert_eq!(joinable_groups("a", &sections), ids(&["h"]));
    assert_eq!(joinable_groups("v", &sections), ids(&["vg"]));
}

// MARK: Named groups

#[test]
fn group_names_are_labels_not_ids() {
    assert!(valid_group_name("GUI push · lanes"));
    for name in
        ["", "  ", "grp_123", "WS_abc", "workspace_group:x", "5F2A9C3E-1B2D-4C5E-8F90-123456789ABC"]
    {
        assert!(!valid_group_name(name), "{name:?} is no label");
    }
    assert!(valid_group_name("5F2A9C3E-1B2D-4C5E-8F90"));
    assert!(same_group_name(" GUI push ", "gui push"));
    assert!(!same_group_name("gui push", "gui-push"));
}

fn named(name: &str, members: &[Workspace]) -> Node {
    let first = members.first().map_or("", |ws| ws.id.as_str());
    let mut g = group(&format!("id-{name}-{first}"), &[]);
    g.name = name.into();
    g.members = members.iter().cloned().map(|workspace| Member::Workspace { workspace }).collect();
    node(g)
}

#[test]
fn the_first_group_of_that_name_that_may_hold_the_workspace() {
    let sections = vec![
        Section {
            id: machine("vm"),
            collapsed: false,
            nodes: vec![named("lanes", &[ws_on("v", "vm")])],
        },
        section(vec![loose("a"), named("lanes", &[ws("b")])]),
    ];
    assert_eq!(group_named("lanes", "a", &sections, None), Some("id-lanes-b".into()));
    // Only the vm's group may hold a vm workspace.
    assert_eq!(group_named("lanes", "new", &sections, Some("vm")), Some("id-lanes-v".into()));
    assert_eq!(group_named("other", "a", &sections, None), None);
}

#[test]
fn a_variant_label_joins_only_when_no_exact_group_is_listed() {
    let sections = vec![section(vec![loose("a"), named("GUI push", &[ws("b")])])];
    assert_eq!(group_named("gui push ", "a", &sections, None), Some("id-GUI push-b".into()));
    // An exact group that cannot hold the workspace means a new group of that name, not the variant.
    let mixed = vec![
        Section {
            id: machine("vm"),
            collapsed: false,
            nodes: vec![named("gui push", &[ws_on("v", "vm")])],
        },
        section(vec![loose("a"), named("GUI push", &[ws("b")])]),
    ];
    assert_eq!(group_named("gui push", "a", &mixed, None), None);
}

#[test]
fn the_predecessor_row_is_this_macs_row_of_that_title() {
    let row = |id: &str, title: &str, machine: &str| NamedRow {
        id: id.into(),
        title: title.into(),
        machine: machine.into(),
    };
    let first = vec![NamedGroup { name: "Lanes".into(), rows: vec![row("w1", "lane", LOCAL)] }];
    let second = vec![NamedGroup {
        name: "lanes".into(),
        rows: vec![row("vm1", "lane", "vm"), row("w2", "lane", LOCAL)],
    }];
    assert_eq!(
        predecessor("lane", "lanes", &[first.clone(), second.clone()]),
        Some("w2".into()),
        "the exact name wins"
    );
    assert_eq!(
        predecessor("lane", "LANES", &[first.clone(), second]),
        Some("w1".into()),
        "a variant when none is exact"
    );
    let exact_without_row = vec![NamedGroup { name: "LANES".into(), rows: vec![] }];
    assert_eq!(predecessor("lane", "LANES", &[first, exact_without_row]), None);
}

// MARK: Placement

#[test]
fn global_index_anchors_on_a_listed_neighbour() {
    let local = ids(&["b", "new", "d"]);
    let global = ids(&["a", "b", "c", "d"]);
    assert_eq!(global_index(0, &local, &global), 1);
    // `new` is not listed yet: no anchor; the next listed one (`d`) is.
    assert_eq!(global_index(1, &local, &global), 3);
    assert_eq!(global_index(3, &local, &global), 4);
    assert_eq!(global_index(9, &ids(&["new"]), &global), 4);
    assert_eq!(global_index(-2, &local, &global), 1);
}

#[test]
fn personal_placements_position_the_unplaced_rows_before_the_slot_first() {
    let plan = personal_placements(&ids(&["m"]), 2, &ids(&["a", "x", "b"]), &ids(&["a", "b"]));
    assert_eq!(
        plan,
        vec![
            PersonalPlacement { key: "x".into(), index: 2 },
            PersonalPlacement { key: "m".into(), index: 1 }
        ],
    );
    let top = personal_placements(&ids(&["m", "n"]), 0, &ids(&["a"]), &ids(&["a"]));
    assert_eq!(
        top,
        vec![
            PersonalPlacement { key: "m".into(), index: 0 },
            PersonalPlacement { key: "n".into(), index: 1 }
        ]
    );
}

// MARK: Wire

#[test]
fn the_json_op_round_trips() {
    let request = serde_json::json!({
        "op": "edit",
        "sections": [{"id": {"kind": "machine", "id": "local"}, "nodes": [
            {"kind": "workspace", "workspace": {"id": "a", "machine": "local"}},
            {"kind": "group", "group": {"id": "g", "members": [
                {"kind": "workspace", "workspace": {"id": "b", "machine": "local"}},
                {"kind": "item", "ref": 3}
            ]}},
            {"kind": "item", "ref": 4}
        ]}],
        "intent": {"kind": "move", "ids": ["a"], "group": "g"}
    });
    let request: Request = serde_json::from_value(request).expect("decodes");
    let reply: EditReply =
        serde_json::from_slice(&respond(&request).expect("encodes")).expect("reply");
    assert!(reply.changed);
    let sections = reply.sections.expect("changed");
    assert_eq!(members(&sections, "g"), ids(&["b", "item3", "a"]));
    assert_eq!(order(&sections[0]), ids(&["g", "item4"]));

    let index: Option<i64> = serde_json::from_slice(
        &respond(
            &serde_json::from_value(serde_json::json!({
                "op": "group_index", "sections": [], "group": "g", "step": "top"
            }))
            .expect("decodes"),
        )
        .expect("encodes"),
    )
    .expect("reply");
    assert_eq!(index, None);
}

// MARK: Subgroups move and leave with their parent (review of #37322)

fn sub(id: &str, parent: &str, members: &[&str]) -> Node {
    let mut g = group(id, members);
    g.parent = Some(parent.into());
    node(g)
}

fn parents(section: &Section) -> Vec<(String, Option<String>)> {
    section
        .nodes
        .iter()
        .filter_map(|node| match node {
            Node::Group { group } => Some((group.id.clone(), group.parent.clone())),
            Node::Workspace { .. } | Node::Item { .. } => None,
        })
        .collect()
}

#[test]
fn a_group_moves_with_its_subgroups() {
    // a, g, s (in g), t (in s), h, z: Move Group Down sends g past h, with s and t.
    let mut sections = vec![section(vec![
        loose("a"),
        node(group("g", &["c"])),
        sub("s", "g", &["d"]),
        sub("t", "s", &["e"]),
        node(group("h", &["f"])),
        loose("z"),
    ])];
    let index = group_index("g", GroupMove::Down, &sections).expect("an index");
    assert!(apply(&Intent::ReorderGroup { group: "g".into(), index }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["a", "h", "g", "s", "t", "z"]));
    let index = group_index("g", GroupMove::Top, &sections).expect("an index");
    assert!(apply(&Intent::ReorderGroup { group: "g".into(), index }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["g", "s", "t", "a", "h", "z"]));
    let index = group_index("g", GroupMove::Bottom, &sections).expect("an index");
    assert!(apply(&Intent::ReorderGroup { group: "g".into(), index }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["a", "h", "z", "g", "s", "t"]));
}

#[test]
fn a_group_move_up_past_a_group_keeps_that_groups_subgroups_with_it() {
    let mut sections = vec![section(vec![
        node(group("g", &["c"])),
        sub("s", "g", &["d"]),
        node(group("h", &["e"])),
    ])];
    let index = group_index("h", GroupMove::Up, &sections).expect("an index");
    assert!(apply(&Intent::ReorderGroup { group: "h".into(), index }, &mut sections));
    assert_eq!(order(&sections[0]), ids(&["h", "g", "s"]));
}

#[test]
fn a_closed_or_pruned_parent_leaves_its_subgroups_at_the_top_level() {
    let nested = || {
        vec![section(vec![
            node(group("g", &["c"])),
            sub("s", "g", &["d"]),
            sub("t", "s", &["e"]),
            loose("z"),
        ])]
    };
    let mut closed = nested();
    assert!(apply(&Intent::CloseGroup { group: "g".into() }, &mut closed));
    assert_eq!(parents(&closed[0]), vec![("s".into(), None), ("t".into(), Some("s".into()))]);
    let mut pruned = nested();
    assert!(apply(&Intent::Reorder { ids: ids(&["c"]), position: at(None, 0) }, &mut pruned));
    assert_eq!(order(&pruned[0]), ids(&["c", "s", "t", "z"]));
    assert_eq!(parents(&pruned[0]), vec![("s".into(), None), ("t".into(), Some("s".into()))]);
    let mut ungrouped = nested();
    assert!(apply(&Intent::Ungroup { group: "g".into() }, &mut ungrouped));
    assert_eq!(parents(&ungrouped[0]), vec![("s".into(), None), ("t".into(), Some("s".into()))]);
}

#[test]
fn an_edit_that_leaves_the_tree_as_it_was_changed_nothing() {
    let base = vec![section(vec![node(group("g", &["a"]))])];
    let same = |intent: Intent| edit(&EditRequest { sections: base.clone(), intent, prunes: true });
    assert_eq!(
        same(Intent::SetGroupPinned { group: "g".into(), pinned: false }),
        EditReply { changed: false, sections: None },
        "a flag set to its own value"
    );
    assert_eq!(
        same(Intent::Reorder { ids: ids(&["a"]), position: at(Some("g"), 0) }),
        EditReply { changed: false, sections: None },
        "a drop where the row is"
    );
    let pinned = same(Intent::SetGroupPinned { group: "g".into(), pinned: true });
    assert!(pinned.changed && pinned.sections.is_some());
}
