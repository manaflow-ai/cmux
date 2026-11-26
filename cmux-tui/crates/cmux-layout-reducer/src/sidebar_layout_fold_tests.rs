use super::*;
use crate::sidebar_layout_engine::{MachineKind, make};
use serde_json::{Value, json};

// The Swift tests' cases (CmuxNextAppTests: SidebarLayoutFoldTests, SidebarCloseMoveSpliceTests; CmuxNextSidebarTests:
// SidebarDragLookSpliceTests): every splice is checked against `make` of the same sections, row for row.

const VECTORS: &str = include_str!("../../../../schemas/sidebar-layout-fold/vectors.json");

fn metrics() -> Metrics {
    serde_json::from_value(json!({
        "topPadding": 8.0, "bottomPadding": 12.0, "sectionHeaderHeight": 28.0, "sectionSpacing": 12.0,
        "rowHeight": 28.0, "rowHeightWithSubtitle": 44.0, "rowSpacing": 2.0, "emptySectionHeight": 28.0
    }))
    .expect("metrics")
}

fn ws_titled(id: &str, title: &str) -> Workspace {
    serde_json::from_value(json!({"id": id, "title": title, "height": 28.0, "machineId": "local"}))
        .expect("workspace")
}

fn ws(id: &str) -> Workspace {
    ws_titled(id, &format!("workspace {id}"))
}

fn done(id: &str) -> Workspace {
    Workspace { done: true, ..ws(id) }
}

fn group(id: &str, members: Vec<Workspace>) -> Group {
    serde_json::from_value(json!({"id": id, "name": format!("Group {id}"), "color": "green"}))
        .map(|g: Group| Group { workspaces: members, ..g })
        .expect("group")
}

fn item(id: &str) -> Item {
    Item { id: id.to_owned(), archived: false }
}

fn machine(nodes: Vec<Node>) -> Section {
    Section {
        kind: SectionKind::Machine { id: "local".to_owned(), kind: Default::default() },
        is_collapsed: false,
        is_host_group: false,
        draws_as_group: false,
        nodes,
    }
}

fn find_group<'a>(id: &str, sections: &'a [Section]) -> Option<&'a Group> {
    sections.iter().flat_map(|s| &s.nodes).find_map(|n| match n {
        Node::Group(g) if g.id == id => Some(g),
        _ => None,
    })
}

/// Every key of `layout` looks up its own position.
fn assert_indexed(l: &IndexedLayout, context: &str) {
    for (i, row) in l.layout().rows.iter().enumerate() {
        assert_eq!(l.position(&row.key), Some(i), "{context}: {:?}", row.key);
    }
}

// MARK: - Fold (SidebarLayoutFoldTests)

/// Loose rows, then six groups (g2 empty, g3 holding a link member), then loose rows again.
fn fold_sections() -> Vec<Section> {
    let mut nodes: Vec<Node> = (0..3).map(|i| Node::Workspace(ws(&format!("lead-{i}")))).collect();
    for g in 0..6 {
        let count = if g == 2 { 0 } else { 4 };
        let mut group =
            group(&format!("g{g}"), (0..count).map(|i| ws(&format!("g{g}-{i}"))).collect());
        if g == 3 {
            let after = group.workspaces.first().map(|w| w.id.clone());
            group.items = vec![GroupItem { item: item("link-g3"), after }];
        }
        nodes.push(Node::Group(group));
    }
    nodes.extend((0..3).map(|i| Node::Workspace(ws(&format!("tail-{i}")))));
    vec![machine(nodes)]
}

fn set_collapsed(id: &str, collapsed: bool, sections: &mut [Section]) {
    for node in sections.iter_mut().flat_map(|s| s.nodes.iter_mut()) {
        if let Node::Group(g) = node
            && g.id == id
        {
            g.is_collapsed = collapsed;
        }
    }
}

fn check_folds(steps: &[(String, bool)], active: Option<&str>) {
    let mut sections = fold_sections();
    let o = Options { active_workspace_id: active.map(str::to_owned), ..Options::default() };
    let m = metrics();
    let mut shown = IndexedLayout::new(make(&sections, &m, &o));
    for (id, collapsed) in steps {
        set_collapsed(id, *collapsed, &mut sections);
        let group = find_group(id, &sections).expect("group").clone();
        shown = folding(&shown, &group, *collapsed, &sections[0], &m, &o)
            .unwrap_or_else(|| panic!("the fold of {id} could not be spliced"));
        let full = make(&sections, &m, &o);
        assert_eq!(shown.layout(), &full, "{id} collapsed={collapsed}");
        assert_indexed(&shown, id);
    }
}

#[test]
fn collapse_then_expand_each_group() {
    let mut steps: Vec<(String, bool)> = (0..6).map(|g| (format!("g{g}"), true)).collect();
    steps.extend((0..6).rev().map(|g| (format!("g{g}"), false)));
    check_folds(&steps, None);
}

#[test]
fn collapsed_group_keeps_its_active_member() {
    let steps = [("g1".to_owned(), true), ("g1".to_owned(), false), ("g1".to_owned(), true)];
    check_folds(&steps, Some("g1-2"));
}

/// More folds than the key index keeps splices for (it is built again once): every lookup still answers.
#[test]
fn many_folds_compact_the_index() {
    let steps: Vec<(String, bool)> =
        (0..COMPACT_AFTER * 2 + 5).map(|i| (format!("g{}", i % 6), i % 12 < 6)).collect();
    check_folds(&steps, Some("g4-0"));
}

#[test]
fn chat_history_lays_the_list_out_again() {
    let sections = fold_sections();
    let m = metrics();
    let shown = make(&sections, &m, &Options::default());
    let mut layout = shown.clone();
    layout.earlier_chats_y = Some(40.0);
    let group = find_group("g1", &sections).expect("group");
    assert!(
        folding(&IndexedLayout::new(layout), group, true, &sections[0], &m, &Options::default())
            .is_none()
    );
    // The same layout without the chat history's block splices.
    assert!(
        folding(&IndexedLayout::new(shown), group, true, &sections[0], &m, &Options::default())
            .is_some()
    );
}

#[test]
fn a_filter_lays_the_list_out_again() {
    let sections = fold_sections();
    let o = Options { filter_matches: Some(["g1-0".to_owned()].into()), ..Options::default() };
    let m = metrics();
    let shown = IndexedLayout::new(make(&sections, &m, &o));
    let group = find_group("g1", &sections).expect("group");
    assert!(folding(&shown, group, true, &sections[0], &m, &o).is_none());
}

#[test]
fn a_refused_fold_leaves_the_layout_as_it_was() {
    let sections = fold_sections();
    let o = Options { folds_done: true, ..Options::default() };
    let m = metrics();
    let mut shown = IndexedLayout::new(make(&sections, &m, &o));
    let before = shown.layout().clone();
    let mut group = find_group("g1", &sections).expect("group").clone();
    group.parent = Some("g0".to_owned());
    assert!(!fold(&mut shown, &group, true, &sections[0], &m, &o));
    assert_eq!(shown.layout(), &before);
}

#[test]
fn an_excerpt_keeps_the_group_block_its_section_header_and_the_keys() {
    let sections = fold_sections();
    let shown = IndexedLayout::new(make(&sections, &metrics(), &Options::default()));
    let piece = excerpt(&shown, &[Key::Workspace("tail-1".to_owned())], "g1");
    let keys: Vec<Key> = piece.rows.iter().map(|r| r.key.clone()).collect();
    let mut expected = vec![Key::Group("g1".to_owned())];
    expected.extend((0..4).map(|i| Key::Workspace(format!("g1-{i}"))));
    expected.push(Key::Workspace("tail-1".to_owned()));
    assert_eq!(keys, expected);
    assert_eq!(
        (piece.total_height, piece.gap_y, piece.row_spacing),
        (shown.layout().total_height, None, 2.0)
    );
}

// MARK: - Key index

#[test]
fn the_key_index_follows_its_splices() {
    let key = |i: usize| Key::Workspace(format!("k{i}"));
    let mut keys: Vec<Key> = (0..20).map(key).collect();
    let mut index = KeyIndex::new(&keys);
    let mut next = 20;
    for step in 0..(COMPACT_AFTER * 3) {
        let start = (step * 7) % keys.len().max(1);
        let removed = (step % 3).min(keys.len() - start);
        let inserted: Vec<Key> = (0..(step % 4)).map(|j| key(next + j)).collect();
        next += inserted.len();
        keys.splice(start..start + removed, inserted.iter().cloned());
        index.splice(start, removed, &inserted, &keys);
        for (i, k) in keys.iter().enumerate() {
            assert_eq!(index.position(k), Some(i), "step {step}: {k:?}");
        }
    }
    assert_eq!(index.position(&key(next + 1)), None);
}

// MARK: - Insert and remove (SidebarCloseMoveSpliceTests)

/// 10 loose rows, a group (node 10), a loose row (11), a done row (12).
fn close_nodes() -> Vec<Node> {
    let mut nodes: Vec<Node> = (0..10).map(|i| Node::Workspace(ws(&format!("ci-{i}")))).collect();
    nodes.push(Node::Group(group("ci-g", vec![ws("ci-g0"), ws("ci-g1")])));
    nodes.push(Node::Workspace(ws("ci-after")));
    nodes.push(Node::Workspace(done("ci-done")));
    nodes
}

fn close_options() -> Options {
    Options { folds_done: true, ..Options::default() }
}

/// `nodes` with node `at` taken out, spliced if `remove_loose` can; else laid out again. Whether it spliced.
fn close(shown: &mut IndexedLayout, nodes: &mut Vec<Node>, at: usize) -> bool {
    let (m, o) = (metrics(), close_options());
    let node = nodes.remove(at);
    let Node::Workspace(workspace) = node else { panic!("not a loose row") };
    let removal = Removal { section: machine(nodes.clone()), node: at, workspace };
    let applied = remove_loose(shown, &removal, &m, &o);
    let full = make(&[machine(nodes.clone())], &m, &o);
    if applied {
        assert_eq!(shown.layout(), &full, "close at {at}");
        assert_indexed(shown, "close");
    } else {
        *shown = IndexedLayout::new(full);
    }
    applied
}

#[test]
fn a_close_shows_the_full_layout() {
    let (m, o) = (metrics(), close_options());
    for index in [0, 1, 5, 9, 11] {
        let mut nodes = close_nodes();
        let mut shown = IndexedLayout::new(make(&[machine(nodes.clone())], &m, &o));
        let spliced = close(&mut shown, &mut nodes, index);
        if index == 0 || index == 5 {
            assert!(spliced, "close at {index} laid the list out again");
        }
        // A second close right after the first takes its row out of the spliced layout.
        close(&mut shown, &mut nodes, 0);
    }
}

#[test]
fn a_move_shows_the_full_layout() {
    let (m, o) = (metrics(), close_options());
    let mut spliced = 0;
    for (from, to) in [(9, 0), (0, 9), (2, 10), (11, 3), (4, 10)] {
        for (a, b) in [(from, to), (to, from)] {
            let mut nodes = close_nodes();
            if (a, b) == (to, from) {
                let moved = nodes.remove(from);
                nodes.insert(to, moved);
            }
            let mut shown = IndexedLayout::new(make(&[machine(nodes.clone())], &m, &o));
            let Node::Workspace(workspace) = nodes[a].clone() else { continue };
            let removed = close(&mut shown, &mut nodes, a);
            nodes.insert(b, Node::Workspace(workspace.clone()));
            let insertion =
                Insertion { section: machine(nodes.clone()), node: b, workspace: Some(workspace) };
            let inserted = insert_loose(&mut shown, &insertion, &m, &o, &HashSet::new());
            let full = make(&[machine(nodes.clone())], &m, &o);
            if inserted {
                assert_eq!(shown.layout(), &full, "move {a} -> {b}");
                assert_indexed(&shown, "move");
                spliced += usize::from(removed);
            }
        }
    }
    assert!(spliced > 0, "no move spliced");
}

#[test]
fn a_move_to_another_section_shows_the_full_layout() {
    let (m, o) = (metrics(), close_options());
    let remote = |nodes: Vec<Node>| Section {
        kind: SectionKind::Machine { id: "ssh-ci-remote".to_owned(), kind: MachineKind::Ssh },
        ..machine(nodes)
    };
    let mut local: Vec<Node> = (0..10).map(|i| Node::Workspace(ws(&format!("ci-{i}")))).collect();
    let r0 = Node::Workspace(ws("ci-r0"));
    let r1 = Node::Workspace(ws("ci-r1"));
    let mut shown = IndexedLayout::new(make(
        &[machine(local.clone()), remote(vec![r0.clone(), r1.clone()])],
        &m,
        &o,
    ));
    let Node::Workspace(moved) = local.remove(4) else { panic!("not a loose row") };
    let removal = Removal { section: machine(local.clone()), node: 4, workspace: moved.clone() };
    assert!(remove_loose(&mut shown, &removal, &m, &o));
    let target = remote(vec![r0, Node::Workspace(moved.clone()), r1]);
    let insertion = Insertion { section: target.clone(), node: 1, workspace: Some(moved) };
    assert!(insert_loose(&mut shown, &insertion, &m, &o, &HashSet::new()));
    assert_eq!(shown.layout(), &make(&[machine(local), target], &m, &o));
    assert_indexed(&shown, "moved to the remote section");
}

#[test]
fn closing_the_last_drawn_row_lays_the_list_out_again() {
    let (m, o) = (metrics(), close_options());
    let archived = Workspace { archived: true, ..ws("ci-arch") };
    let mut nodes =
        vec![Node::Workspace(ws("ci-0")), Node::Workspace(ws("ci-1")), Node::Workspace(archived)];
    let mut shown = IndexedLayout::new(make(&[machine(nodes.clone())], &m, &o));
    close(&mut shown, &mut nodes, 0);
    assert!(!close(&mut shown, &mut nodes, 0), "the last drawn row's close spliced");
}

#[test]
fn an_insert_refuses_a_folded_row_and_a_row_already_drawn() {
    let (m, o) = (metrics(), close_options());
    let nodes = close_nodes();
    let mut shown = IndexedLayout::new(make(&[machine(nodes.clone())], &m, &o));
    let drawn = Insertion { section: machine(nodes.clone()), node: 0, workspace: Some(ws("ci-0")) };
    assert!(!insert_loose(&mut shown, &drawn, &m, &o, &HashSet::new()));
    let mut with_done = nodes;
    with_done.insert(0, Node::Workspace(done("ci-new")));
    let folded =
        Insertion { section: machine(with_done), node: 0, workspace: Some(done("ci-new")) };
    assert!(!insert_loose(&mut shown, &folded, &m, &o, &HashSet::new()));
}

// MARK: - Selection

#[test]
fn the_selected_row_is_its_own_or_its_collapsed_group_header() {
    let mut sections = fold_sections();
    set_collapsed("g1", true, &mut sections);
    let shown = IndexedLayout::new(make(&sections, &metrics(), &Options::default()));
    let key = |s: Selected| selected_row_key(&shown, Some(&s), &sections);
    assert_eq!(key(Selected::Workspace("lead-0".into())), Some(Key::Workspace("lead-0".into())));
    assert_eq!(key(Selected::Workspace("g1-2".into())), Some(Key::Group("g1".into())));
    assert_eq!(key(Selected::Group("g4".into())), Some(Key::Group("g4".into())));
    assert_eq!(key(Selected::TopItem("nowhere".into())), None);
    assert_eq!(key(Selected::Workspace("nowhere".into())), None);
    assert_eq!(selected_row_key(&shown, None, &sections), None);
}

#[test]
fn a_group_drawn_as_its_one_member_is_selected_as_that_row() {
    let sections = vec![machine(vec![Node::Group(Group {
        name: "solo".into(),
        ..group("solo", vec![ws_titled("so0", "solo")])
    })])];
    let shown = IndexedLayout::new(make(&sections, &metrics(), &Options::default()));
    assert_eq!(
        selected_row_key(&shown, Some(&Selected::Group("solo".into())), &sections),
        Some(Key::Workspace("so0".into()))
    );
}

// MARK: - Drag look (SidebarDragLookSpliceTests)

fn named(g: Group, name: &str) -> Group {
    Group { name: name.to_owned(), ..g }
}

fn collapsed(g: Group) -> Group {
    Group { is_collapsed: true, ..g }
}

fn nested(g: Group, parent: &str) -> Group {
    Group { parent: Some(parent.to_owned()), depth: 1, ..g }
}

fn with_members(g: Group, members: Vec<Owned>) -> Group {
    let mut g = g;
    set_members(&mut g, members);
    g
}

fn gn(g: Group) -> Node {
    Node::Group(g)
}

fn wn(id: &str) -> Node {
    Node::Workspace(ws(id))
}

/// The list shapes the drag harnesses use, and the states a drag meets in them.
fn shapes() -> Vec<(&'static str, Vec<Section>, Option<&'static str>)> {
    let tens: Vec<Node> = (0..3)
        .map(|g| gn(group(&format!("t{g}"), (0..10).map(|i| ws(&format!("t{g}-{i}"))).collect())))
        .collect();
    let loose =
        vec![wn("l0"), wn("l1"), gn(group("lg", vec![ws("lg0"), ws("lg1")])), wn("l2"), wn("l3")];
    let nested_nodes = vec![
        gn(group("na", vec![ws("na0"), ws("na1")])),
        gn(nested(group("na1", vec![ws("nb0"), ws("nb1")]), "na")),
        gn(group("nc", vec![ws("nc0")])),
        wn("n-loose"),
    ];
    let collapsed_nodes = vec![
        gn(collapsed(group("ca", vec![ws("ca0"), ws("ca1"), ws("ca2")]))),
        gn(group("cb", vec![ws("cb0"), ws("cb1")])),
        wn("c-loose"),
    ];
    let collapsed_parent = vec![
        gn(collapsed(group("pa", vec![ws("pa0")]))),
        gn(nested(group("pa1", vec![ws("pb0"), ws("pb1")]), "pa")),
        gn(group("pc", vec![ws("pc0"), ws("pc1")])),
        wn("p-loose"),
    ];
    let sole = vec![
        gn(named(group("solo", vec![ws_titled("so0", "solo")]), "solo")),
        gn(named(group("duo", vec![ws_titled("du0", "duo"), ws("du1")]), "duo")),
        gn(group("sb", vec![ws("sb0"), ws("sb1")])),
        wn("s-loose"),
    ];
    let items = vec![
        gn(with_members(
            group("ia", vec![]),
            vec![
                Owned::Workspace(ws("ia0")),
                Owned::Item(item("itm_link")),
                Owned::Workspace(ws("ia1")),
            ],
        )),
        Node::Item(item("itm_app")),
        gn(group("ib", vec![ws("ib0"), ws("ib1")])),
        wn("i-loose"),
    ];
    let old = Item { archived: true, ..item("itm_old") };
    let archived_link = vec![
        gn(with_members(
            group("xa", vec![]),
            vec![Owned::Workspace(ws("xa0")), Owned::Item(old), Owned::Workspace(ws("xa1"))],
        )),
        gn(group("xb", vec![ws("xb0"), ws("xb1")])),
        wn("x-loose"),
    ];
    let done_nodes = vec![
        gn(group("da", vec![ws("da0"), done("da1"), ws("da2")])),
        gn(group("db", vec![ws("db0"), ws("db1")])),
        wn("d-loose"),
    ];
    let done_loose =
        vec![wn("dl0"), Node::Workspace(done("dl1")), gn(group("dg", vec![ws("dg0"), ws("dg1")]))];
    let pinned = Section { kind: SectionKind::Pinned, ..machine(vec![wn("pin0")]) };
    vec![
        ("groups of 10", vec![machine(tens)], None),
        ("loose rows", vec![machine(loose.clone())], None),
        ("nested groups", vec![machine(nested_nodes)], None),
        ("collapsed group", vec![machine(collapsed_nodes)], Some("ca1")),
        ("collapsed parent", vec![machine(collapsed_parent)], None),
        ("sole member", vec![machine(sole)], None),
        ("items", vec![machine(items)], None),
        ("archived link in a group", vec![machine(archived_link)], None),
        ("done fold in a group", vec![machine(done_nodes)], None),
        ("done fold at the top level", vec![machine(done_loose)], None),
        ("pinned and a machine", vec![pinned, machine(loose)], None),
    ]
}

fn look_options(active: Option<&str>, archive: bool) -> Options {
    Options {
        shows_sole_machine_header: true,
        folds_done: true,
        flattens_machines: true,
        show_empty_pinned: true,
        archive_section: archive,
        active_workspace_id: active.map(str::to_owned),
        ..Options::default()
    }
}

fn section_workspaces(section: &Section) -> Vec<&Workspace> {
    section
        .nodes
        .iter()
        .flat_map(|n| match n {
            Node::Workspace(ws) => vec![ws],
            Node::Group(g) => g.workspaces.iter().collect(),
            Node::Item(_) => vec![],
        })
        .collect()
}

/// The workspace drags of a shape: each workspace alone, and the first two of each list together.
fn drags(sections: &[Section]) -> Vec<Vec<String>> {
    let mut drags = Vec::new();
    for section in sections {
        drags.extend(section_workspaces(section).iter().map(|w| vec![w.id.clone()]));
        for node in &section.nodes {
            if let Node::Group(g) = node
                && g.workspaces.len() >= 2
            {
                drags.push(g.workspaces.iter().take(2).map(|w| w.id.clone()).collect());
            }
        }
        let loose: Vec<String> = section
            .nodes
            .iter()
            .filter_map(|n| if let Node::Workspace(ws) = n { Some(ws.id.clone()) } else { None })
            .collect();
        if loose.len() >= 2 {
            drags.push(loose.into_iter().take(2).collect());
        }
    }
    drags
}

/// `SidebarEdits.removeWorkspaces`: the rows taken out in tree order; emptied groups stay.
fn remove_workspaces(ids: &HashSet<String>, sections: &mut [Section]) -> Vec<Workspace> {
    let mut removed = Vec::new();
    for section in sections.iter_mut() {
        let mut kept = Vec::new();
        for node in section.nodes.drain(..) {
            match node {
                Node::Workspace(ws) if ids.contains(&ws.id) => removed.push(ws),
                Node::Group(mut g) => {
                    removed.extend(g.workspaces.iter().filter(|w| ids.contains(&w.id)).cloned());
                    let members: Vec<Owned> = g
                        .members()
                        .iter()
                        .filter(|m| !matches!(m, Member::Workspace(ws) if ids.contains(&ws.id)))
                        .map(owned)
                        .collect();
                    set_members(&mut g, members);
                    kept.push(Node::Group(g));
                }
                other => kept.push(other),
            }
        }
        section.nodes = kept;
    }
    removed
}

/// `SidebarEdits.reorder(prunes: false)`: nil where it refuses.
fn reorder(ids: &[String], position: &Gap, sections: &[Section]) -> Option<Vec<Section>> {
    let s = sections.iter().position(|section| section.id() == position.section)?;
    if position.group.is_some() && sections[s].machine().is_none() {
        return None;
    }
    let wanted: HashSet<String> = ids.iter().cloned().collect();
    let moving: Vec<&Workspace> =
        sections.iter().flat_map(section_workspaces).filter(|w| wanted.contains(&w.id)).collect();
    if moving.is_empty() || !moving.iter().all(|w| can_place(w, &sections[s])) {
        return None;
    }
    if let Some(group) = &position.group
        && !sections[s].nodes.iter().any(|n| matches!(n, Node::Group(g) if g.id == *group))
    {
        return None;
    }
    let mut moved = sections.to_vec();
    let removed = remove_workspaces(&wanted, &mut moved);
    let nodes = &mut moved[s].nodes;
    match &position.group {
        Some(id) => {
            for node in nodes.iter_mut() {
                if let Node::Group(g) = node
                    && g.id == *id
                {
                    let mut members: Vec<Owned> = g.members().iter().map(owned).collect();
                    let at = clamp(position.index, members.len());
                    members.splice(at..at, removed.iter().cloned().map(Owned::Workspace));
                    set_members(g, members);
                }
            }
        }
        None => {
            let at = clamp(position.index, nodes.len());
            nodes.splice(at..at, removed.into_iter().map(Node::Workspace));
        }
    }
    Some(moved)
}

/// Every slot a drag of `ids` can reach, in the coordinates after the dragged rows are removed.
fn slots(sections: &[Section], ids: &[String]) -> Vec<Gap> {
    let mut removed = sections.to_vec();
    remove_workspaces(&ids.iter().cloned().collect(), &mut removed);
    let mut slots = Vec::new();
    for section in &removed {
        let index = |i: usize| isize::try_from(i).expect("index");
        slots.extend((0..=section.nodes.len()).map(|i| Gap {
            section: section.id(),
            group: None,
            index: index(i),
        }));
        for node in &section.nodes {
            if let Node::Group(g) = node {
                slots.extend((0..=g.members().len()).map(|i| Gap {
                    section: section.id(),
                    group: Some(g.id.clone()),
                    index: index(i),
                }));
            }
        }
    }
    slots
}

/// The look `displayLayout` drew before the splice: `make` of the moved sections, then the slot's gap.
fn made(sections: &[Section], ids: &[String], position: &Gap, o: &Options) -> Layout {
    let moved = reorder(ids, position, sections).unwrap_or_else(|| sections.to_vec());
    let m = metrics();
    let mut layout = make(&moved, &m, o);
    let slot: Vec<&Row> = layout
        .rows
        .iter()
        .filter(|r| matches!(&r.key, Key::Workspace(id) if ids.contains(id)))
        .collect();
    if let (Some(first), Some(last)) = (slot.first(), slot.last()) {
        let (gap_y, gap_shift) = (first.y, max_y(last) + m.row_spacing - first.y);
        layout.gap_y = Some(gap_y);
        layout.gap_shift = gap_shift;
    }
    layout
}

/// One shape: every drag to every slot. How many slots spliced and how many fell back.
fn check_drags(
    name: &str,
    sections: &[Section],
    active: Option<&str>,
    archive: bool,
) -> (usize, usize) {
    let (mut spliced, mut fell_back) = (0, 0);
    let m = metrics();
    for ids in drags(sections) {
        let mut look = look_options(active, archive);
        let dragged: Vec<&Workspace> =
            sections.iter().flat_map(section_workspaces).filter(|w| ids.contains(&w.id)).collect();
        // A drag that carries a Done or archived row draws unfolded (`dragUnfolds`).
        let unfolds = dragged.iter().any(|w| {
            look.active_workspace_id.as_deref() != Some(w.id.as_str())
                && ((look.folds_done && w.done)
                    || ((look.folds_archived || look.archive_section) && w.archived))
        });
        if unfolds {
            (look.folds_done, look.folds_archived, look.archive_section) = (false, false, false);
        }
        let mut base_options = look.clone();
        base_options.excluded_workspaces.extend(ids.iter().cloned());
        let base = make(sections, &m, &base_options);
        let splice = DragLook::new(base, sections.to_vec(), look.clone(), &ids);
        for position in slots(sections, &ids) {
            let Some(layout) = splice.layout(&position, &m) else {
                fell_back += 1;
                continue;
            };
            spliced += 1;
            let expected = made(sections, &ids, &position, &look);
            assert_eq!(layout, expected, "{name}: {ids:?} to {position:?}");
        }
    }
    (spliced, fell_back)
}

#[test]
fn every_slot_of_every_shape_splices_as_make_lays_it_out() {
    for (name, sections, active) in shapes() {
        let (spliced, _) = check_drags(name, &sections, active, false);
        assert!(spliced > 0, "{name}: no slot spliced");
    }
}

/// The common case: a workspace dragged within and between groups of one machine section, and out to the top
/// level, never falls back.
#[test]
fn groups_of_ten_never_fall_back() {
    let (name, sections, active) = shapes().into_iter().next().expect("shape");
    let (spliced, fell_back) = check_drags(name, &sections, active, false);
    assert!(fell_back == 0 && spliced > 0, "groups of 10: {fell_back} slots fell back");
}

/// With the Archive section drawn, an archived top-level row leaves its list, so the base's row indices are not
/// the nodes' the move counts: the splice matches `make` or falls back.
#[test]
fn an_archived_row_before_the_slot_never_shifts_the_splice() {
    let archived = Workspace { archived: true, ..ws("a0") };
    let sections = vec![machine(vec![
        wn("l0"),
        Node::Workspace(archived),
        wn("l1"),
        gn(group("ag", vec![ws("ag0"), ws("ag1")])),
        wn("l2"),
    ])];
    check_drags("archived row before the slot", &sections, None, true);
}

#[test]
fn a_workspace_of_another_computer_is_not_placed_in_this_one() {
    let elsewhere = Workspace { machine_id: Some("remote".into()), ..ws("r0") };
    let sections = [machine(vec![wn("l0"), wn("l1")])];
    assert!(!can_place(&elsewhere, &sections[0]));
    assert!(can_place(&ws("l0"), &sections[0]));
    assert!(can_place(&elsewhere, &Section { kind: SectionKind::Pinned, ..machine(vec![]) }));
}

#[test]
fn the_look_options_show_the_dragged_rows() {
    let o = Options {
        excluded_workspaces: ["a".to_owned()].into(),
        excluded_group: Some("g".into()),
        excluded_item: Some("i".into()),
        folds_done: true,
        ..Options::default()
    };
    let shown = DragLook::shown(&o, ["b".to_owned()].into());
    assert_eq!(shown.excluded_workspaces, ["b".to_owned()].into());
    assert_eq!((shown.excluded_group, shown.excluded_item, shown.folds_done), (None, None, true));
}

// MARK: - Wire

#[test]
fn the_vectors_replay() {
    let vectors: Value = serde_json::from_str(VECTORS).expect("vectors");
    let cases = vectors["cases"].as_array().expect("cases");
    assert!(cases.len() >= 20, "{} cases", cases.len());
    for case in cases {
        let request: Request = serde_json::from_value(case["request"].clone()).expect("request");
        let reply = serde_json::to_value(respond(&request)).expect("reply");
        assert!(same(&reply, &case["reply"]), "{}: {reply} vs {}", case["name"], case["reply"]);
    }
}

/// JSON equality with numbers compared as f64 (Python writes 30.0 where serde writes 30.0 or 30).
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(a, b)| same(a, b))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}
