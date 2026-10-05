use super::*;
use std::collections::{HashMap, HashSet};

fn machine(id: &str) -> SectionId {
    SectionId::Machine { id: id.to_string() }
}
fn workspace(id: &str, machine: &str) -> Workspace {
    Workspace { id: id.to_string(), machine: machine.to_string() }
}
fn sections() -> Vec<Section> {
    vec![
        Section {
            id: SectionId::Pinned,
            machine: None,
            nodes: vec![Node::Workspace { workspace: workspace("p1", "local") }],
        },
        Section {
            id: machine("local"),
            machine: Some("local".into()),
            nodes: vec![
                Node::Workspace { workspace: workspace("a", "local") },
                Node::Group {
                    id: "g1".into(),
                    machine: Some("local".into()),
                    workspaces: vec![
                        workspace("g1", "local"),
                        workspace("g2", "local"),
                        workspace("g3", "local"),
                    ],
                },
                Node::Workspace { workspace: workspace("b", "local") },
                Node::Group {
                    id: "g2".into(),
                    machine: Some("local".into()),
                    workspaces: vec![workspace("h1", "local"), workspace("h2", "local")],
                },
                // The drag origin remains in the authoritative tree even when
                // its row is excluded from the drop layout.
                Node::Workspace { workspace: workspace("c", "local") },
            ],
        },
        Section {
            id: machine("cloud"),
            machine: Some("cloud".into()),
            nodes: vec![
                Node::Workspace { workspace: workspace("x", "cloud") },
                Node::Workspace { workspace: workspace("y", "cloud") },
            ],
        },
    ]
}

#[allow(clippy::too_many_arguments)] // one positional fixture per Row field, as the Swift tests built them
fn row(
    key: RowKey,
    y: f64,
    section: SectionId,
    group: Option<&str>,
    sibling_index: i32,
    parent_index: Option<i32>,
    is_last_in_group: bool,
    is_collapsed: bool,
    child_count: i32,
) -> Row {
    Row {
        key,
        y,
        height: 10.0,
        section,
        group: group.map(str::to_string),
        workspace: None,
        sibling_index,
        parent_index,
        is_last_in_group,
        is_collapsed,
        child_count,
    }
}
fn rows() -> Vec<Row> {
    vec![
        row(
            RowKey::Section { id: SectionId::Pinned },
            0.0,
            SectionId::Pinned,
            None,
            0,
            None,
            false,
            false,
            1,
        ),
        row(
            RowKey::Workspace { id: "p1".into() },
            12.0,
            SectionId::Pinned,
            None,
            0,
            None,
            false,
            false,
            0,
        ),
        row(
            RowKey::Section { id: machine("local") },
            24.0,
            machine("local"),
            None,
            0,
            None,
            false,
            false,
            4,
        ),
        row(
            RowKey::Workspace { id: "a".into() },
            36.0,
            machine("local"),
            None,
            0,
            None,
            false,
            false,
            0,
        ),
        row(
            RowKey::Group { id: "g1".into() },
            48.0,
            machine("local"),
            Some("g1"),
            1,
            None,
            false,
            false,
            3,
        ),
        row(
            RowKey::Workspace { id: "g1".into() },
            60.0,
            machine("local"),
            Some("g1"),
            0,
            Some(1),
            false,
            false,
            0,
        ),
        row(
            RowKey::Workspace { id: "g2".into() },
            72.0,
            machine("local"),
            Some("g1"),
            1,
            Some(1),
            false,
            false,
            0,
        ),
        row(
            RowKey::Workspace { id: "g3".into() },
            84.0,
            machine("local"),
            Some("g1"),
            2,
            Some(1),
            true,
            false,
            0,
        ),
        row(
            RowKey::Workspace { id: "b".into() },
            96.0,
            machine("local"),
            None,
            2,
            None,
            false,
            false,
            0,
        ),
        row(
            RowKey::Group { id: "g2".into() },
            108.0,
            machine("local"),
            Some("g2"),
            3,
            None,
            false,
            true,
            0,
        ),
        row(
            RowKey::Section { id: machine("cloud") },
            120.0,
            machine("cloud"),
            None,
            0,
            None,
            false,
            false,
            2,
        ),
        row(
            RowKey::Workspace { id: "x".into() },
            132.0,
            machine("cloud"),
            None,
            0,
            None,
            false,
            false,
            0,
        ),
        row(
            RowKey::Workspace { id: "y".into() },
            144.0,
            machine("cloud"),
            None,
            1,
            None,
            false,
            false,
            0,
        ),
    ]
}
fn request(y: f64, payload: Payload) -> Request {
    Request {
        y,
        payload,
        rows: rows(),
        sections: sections(),
        ungrouped_first: false,
        group_edge_fraction: GROUP_EDGE_FRACTION,
        group_exit_fraction: GROUP_EXIT_FRACTION,
        section_top_fraction: SECTION_TOP_FRACTION,
    }
}

fn request_with_rows(y: f64, payload: Payload, rows: Vec<Row>, sections: Vec<Section>) -> Request {
    Request { y, payload, rows, sections, ..request(0.0, Payload::Workspaces { ids: vec![] }) }
}

fn rows_without(excluded: &[&str], excluded_group: Option<&str>) -> Vec<Row> {
    let excluded: HashSet<&str> = excluded.iter().copied().collect();
    let mut rows = rows();
    rows.retain(|row| match &row.key {
        RowKey::Workspace { id } => !excluded.contains(id.as_str()),
        RowKey::Group { id } => Some(id.as_str()) != excluded_group,
        RowKey::Tab { workspace, .. } => !excluded.contains(workspace.as_str()),
        _ => true,
    });
    let mut y = 0.0;
    for row in &mut rows {
        row.y = y;
        y += row.height + 2.0;
    }
    let mut top_level = HashMap::<SectionId, i32>::new();
    let mut child_index = HashMap::<String, i32>::new();
    let mut group_parent = HashMap::<String, i32>::new();
    for row in &mut rows {
        match &row.key {
            RowKey::Section { id } => {
                row.child_count = 0;
                top_level.insert(id.clone(), 0);
            }
            RowKey::Group { id } => {
                let index = top_level.entry(row.section.clone()).or_insert(0);
                row.sibling_index = *index;
                *index += 1;
                group_parent.insert(id.clone(), row.sibling_index);
                child_index.insert(id.clone(), 0);
                row.child_count = sections()
                    .iter()
                    .find_map(|section| {
                        section.nodes.iter().find_map(|node| match node {
                            Node::Group { id: group_id, workspaces, .. } if group_id == id => {
                                Some(workspaces.len() as i32)
                            }
                            _ => None,
                        })
                    })
                    .unwrap_or(row.child_count);
            }
            RowKey::Workspace { .. } if row.group.is_none() => {
                let index = top_level.entry(row.section.clone()).or_insert(0);
                row.sibling_index = *index;
                *index += 1;
            }
            RowKey::Workspace { .. } => {
                let group = row.group.clone().unwrap();
                row.sibling_index = *child_index.entry(group.clone()).or_insert(0);
                *child_index.get_mut(&group).unwrap() += 1;
                row.parent_index = group_parent.get(&group).copied();
            }
            _ => {}
        }
    }
    for row in &mut rows {
        if let RowKey::Section { id } = &row.key {
            row.child_count = top_level.get(id).copied().unwrap_or_default();
        }
    }
    rows
}
fn tab_request(y: f64, source_machine: Option<&str>) -> TabRequest {
    TabRequest {
        y,
        rows: rows(),
        sections: sections(),
        source_machine: source_machine.map(str::to_string),
        group_edge_fraction: GROUP_EDGE_FRACTION,
        group_exit_fraction: GROUP_EXIT_FRACTION,
        section_top_fraction: SECTION_TOP_FRACTION,
        tab_into_start: TAB_INTO_START,
        tab_into_end: TAB_INTO_END,
    }
}

#[test]
fn workspace_drop_preserves_edge_and_group_rules() {
    assert_eq!(
        resolve(&request(97.0, Payload::Workspaces { ids: vec!["a".into()] })),
        Some(Target::Position { section: machine("local"), group: None, index: 2 })
    );
    assert_eq!(
        resolve(&request(75.0, Payload::Workspaces { ids: vec!["a".into()] })),
        Some(Target::Position { section: machine("local"), group: Some("g1".into()), index: 1 })
    );
    assert_eq!(
        resolve(&request(112.0, Payload::Workspaces { ids: vec!["a".into()] })),
        Some(Target::IntoGroup { group: "g2".into() })
    );
}

#[test]
fn group_drag_treats_expanded_group_as_one_block() {
    assert_eq!(
        resolve(&request(55.0, Payload::Group { id: "g2".into() })),
        Some(Target::Position { section: machine("local"), group: None, index: 1 })
    );
    assert_eq!(
        resolve(&request(90.0, Payload::Group { id: "g2".into() })),
        Some(Target::Position { section: machine("local"), group: None, index: 2 })
    );
    assert_eq!(resolve(&request(136.0, Payload::Group { id: "g2".into() })), None);
}

#[test]
fn tab_drop_stays_on_source_machine() {
    assert_eq!(
        resolve_tab_drop(&tab_request(97.0, Some("local"))),
        Some(TabDrop::NewWorkspace { section: machine("local"), group: None, index: 2 })
    );
    assert_eq!(resolve_tab_drop(&tab_request(137.0, Some("local"))), None);
    assert_eq!(
        resolve_tab_drop(&tab_request(137.0, Some("cloud"))),
        Some(TabDrop::IntoWorkspace { workspace: "x".into() })
    );
}

#[test]
fn gaps_and_ungrouped_first_are_stable() {
    assert_eq!(base_y(50.0, Some(100.0), 40.0), Some(50.0));
    assert_eq!(base_y(120.0, Some(100.0), 40.0), None);
    assert_eq!(base_y(160.0, Some(100.0), 40.0), Some(120.0));
    let mut request = request(105.0, Payload::Workspaces { ids: vec!["a".into()] });
    request.ungrouped_first = true;
    assert_eq!(
        resolve(&request),
        Some(Target::Position { section: machine("local"), group: None, index: 0 })
    );
}

#[test]
fn tab_refusals_name_their_reason() {
    assert_eq!(
        tab_drop_refusal(&tab_request(137.0, Some("local"))).map(|value| value.reason),
        Some(Refusal::OtherMachine)
    );
    assert_eq!(
        tab_drop_refusal(&tab_request(13.0, Some("local"))).map(|value| value.reason),
        Some(Refusal::PinnedArea)
    );
}

#[test]
fn drop_math_covers_row_edges_and_group_boundaries() {
    let sections = sections();
    let rows = rows_without(&["c"], None);
    let row_y = |id: &str, fraction: f64| {
        let row = rows.iter().find(|row| row.key == RowKey::Workspace { id: id.into() }).unwrap();
        row.y + row.height * fraction
    };
    let target = |id: &str, fraction: f64, moving: &[&str]| {
        let rows = rows_without(moving, None);
        let row = rows.iter().find(|row| row.key == RowKey::Workspace { id: id.into() }).unwrap();
        resolve(&request_with_rows(
            row.y + row.height * fraction,
            Payload::Workspaces { ids: moving.iter().map(|id| (*id).into()).collect() },
            rows,
            sections.clone(),
        ))
    };
    assert_eq!(
        target("b", 0.2, &["c"]),
        Some(Target::Position { section: machine("local"), group: None, index: 2 })
    );
    assert_eq!(
        target("b", 0.7, &["c"]),
        Some(Target::Position { section: machine("local"), group: None, index: 3 })
    );
    assert_eq!(
        target("g2", 0.3, &["a"]),
        Some(Target::Position { section: machine("local"), group: Some("g1".into()), index: 1 })
    );
    assert_eq!(
        target("g2", 0.6, &["a"]),
        Some(Target::Position { section: machine("local"), group: Some("g1".into()), index: 2 })
    );
    assert_eq!(
        target("g3", 0.6, &["a"]),
        Some(Target::Position { section: machine("local"), group: Some("g1".into()), index: 3 })
    );
    assert_eq!(
        target("g3", 0.9, &["a"]),
        Some(Target::Position { section: machine("local"), group: None, index: 1 })
    );
    let _ = row_y("b", 0.2);
}

#[test]
fn drop_math_covers_headers_sections_and_clamping() {
    let sections = sections();
    let rows = rows_without(&["a"], None);
    let row_y = |key: RowKey, fraction: f64| {
        let row = rows.iter().find(|row| row.key == key).unwrap();
        row.y + row.height * fraction
    };
    let resolve_at = |y: f64| {
        resolve(&request_with_rows(
            y,
            Payload::Workspaces { ids: vec!["a".into()] },
            rows.clone(),
            sections.clone(),
        ))
    };
    assert_eq!(
        resolve_at(row_y(RowKey::Group { id: "g2".into() }, 0.1)),
        Some(Target::Position { section: machine("local"), group: None, index: 2 })
    );
    assert_eq!(
        resolve_at(row_y(RowKey::Group { id: "g2".into() }, 0.5)),
        Some(Target::IntoGroup { group: "g2".into() })
    );
    assert_eq!(
        resolve_at(row_y(RowKey::Group { id: "g2".into() }, 0.9)),
        Some(Target::Position { section: machine("local"), group: None, index: 3 })
    );
    assert_eq!(
        resolve_at(row_y(RowKey::Group { id: "g1".into() }, 0.2)),
        // The layout excludes a, so g1 is the first top-level node.
        Some(Target::Position { section: machine("local"), group: None, index: 0 })
    );
    assert_eq!(
        resolve_at(row_y(RowKey::Group { id: "g1".into() }, 0.7)),
        Some(Target::Position { section: machine("local"), group: Some("g1".into()), index: 0 })
    );
    assert_eq!(
        resolve_at(row_y(RowKey::Section { id: machine("local") }, 0.8)),
        Some(Target::Position { section: machine("local"), group: None, index: 0 })
    );
    assert_eq!(
        resolve_at(row_y(RowKey::Section { id: machine("local") }, 0.1)),
        Some(Target::Position { section: SectionId::Pinned, group: None, index: 1 })
    );
    assert_eq!(
        resolve(&request_with_rows(
            rows.last().unwrap().max_y() + 500.0,
            Payload::Workspaces { ids: vec!["a".into()] },
            rows.clone(),
            sections.clone(),
        )),
        None
    );
    assert_eq!(base_y(160.0, None, 0.0), Some(160.0));
}

#[test]
fn group_drag_and_cross_machine_targets_match_swift() {
    let sections = sections();
    let rows = rows_without(&["c"], Some("g2"));
    let g1 = rows.iter().find(|row| row.key == RowKey::Group { id: "g1".into() }).unwrap();
    let g3 = rows.iter().find(|row| row.key == RowKey::Workspace { id: "g3".into() }).unwrap();
    let top = g1.y;
    let bottom = g3.max_y();
    let request_at = |y| {
        request_with_rows(y, Payload::Group { id: "g2".into() }, rows.clone(), sections.clone())
    };
    assert_eq!(
        resolve(&request_at(top + (bottom - top) * 0.3)),
        Some(Target::Position { section: machine("local"), group: None, index: 1 })
    );
    assert_eq!(
        resolve(&request_at(top + (bottom - top) * 0.7)),
        Some(Target::Position { section: machine("local"), group: None, index: 2 })
    );
    let cloud = rows.iter().find(|row| row.key == RowKey::Workspace { id: "x".into() }).unwrap();
    assert_eq!(resolve(&request_at(cloud.y + cloud.height / 2.0)), None);
}

#[test]
fn external_tab_drop_covers_edges_middle_and_refusals() {
    for (id, fraction, expected) in [
        ("b", 0.5, Some(TabDrop::IntoWorkspace { workspace: "b".into() })),
        (
            "b",
            0.1,
            Some(TabDrop::NewWorkspace { section: machine("local"), group: None, index: 2 }),
        ),
        (
            "b",
            0.9,
            Some(TabDrop::NewWorkspace { section: machine("local"), group: None, index: 3 }),
        ),
        ("g2", 0.3, Some(TabDrop::IntoWorkspace { workspace: "g2".into() })),
        (
            "g2",
            0.9,
            Some(TabDrop::NewWorkspace {
                section: machine("local"),
                group: Some("g1".into()),
                index: 2,
            }),
        ),
    ] {
        let row =
            rows().into_iter().find(|row| row.key == RowKey::Workspace { id: id.into() }).unwrap();
        assert_eq!(
            resolve_tab_drop(&tab_request(row.y + row.height * fraction, Some("local"))),
            expected
        );
    }
    let x = rows().into_iter().find(|row| row.key == RowKey::Workspace { id: "x".into() }).unwrap();
    assert_eq!(resolve_tab_drop(&tab_request(x.y + x.height / 2.0, Some("local"))), None);
    assert_eq!(
        resolve_tab_drop(&tab_request(x.y + x.height / 2.0, Some("cloud"))),
        Some(TabDrop::IntoWorkspace { workspace: "x".into() })
    );
    let p1 =
        rows().into_iter().find(|row| row.key == RowKey::Workspace { id: "p1".into() }).unwrap();
    assert_eq!(
        resolve_tab_drop(&tab_request(p1.y + p1.height / 2.0, Some("local"))),
        Some(TabDrop::IntoWorkspace { workspace: "p1".into() })
    );
    assert_eq!(resolve_tab_drop(&tab_request(p1.y + p1.height * 0.1, Some("local"))), None);
    assert_eq!(
        tab_drop_refusal(&tab_request(p1.y + p1.height * 0.1, Some("local"))).unwrap().reason,
        Refusal::PinnedArea
    );
    assert_eq!(
        resolve_tab_drop(&tab_request(p1.y + p1.height / 2.0, None)),
        Some(TabDrop::IntoWorkspace { workspace: "p1".into() })
    );
}

#[test]
fn tab_drop_refusal_covers_every_row_coordinate() {
    for source in [Some("local"), Some("cloud")] {
        let rows = rows();
        let bottom = rows.last().unwrap().max_y() + 40.0;
        let mut y = -20.0;
        while y < bottom {
            let request = tab_request(y, source);
            let drop = resolve_tab_drop(&request);
            let refusal = tab_drop_refusal(&request);
            assert_ne!(drop.is_some(), refusal.is_some(), "y={y} source={source:?}");
            y += 2.0;
        }
    }
}

#[test]
fn ungrouped_first_remaps_only_top_level_slots() {
    let sections = vec![Section {
        id: machine("local"),
        machine: Some("local".into()),
        nodes: vec![
            Node::Workspace { workspace: workspace("a", "local") },
            Node::Workspace { workspace: workspace("b", "local") },
            Node::Group {
                id: "g1".into(),
                machine: Some("local".into()),
                workspaces: vec![workspace("g1", "local"), workspace("g2", "local")],
            },
        ],
    }];
    let rows = vec![
        row(
            RowKey::Section { id: machine("local") },
            0.0,
            machine("local"),
            None,
            0,
            None,
            false,
            false,
            3,
        ),
        row(
            RowKey::Workspace { id: "b".into() },
            12.0,
            machine("local"),
            None,
            0,
            None,
            false,
            false,
            0,
        ),
        row(
            RowKey::Group { id: "g1".into() },
            24.0,
            machine("local"),
            Some("g1"),
            1,
            None,
            false,
            false,
            2,
        ),
        row(
            RowKey::Workspace { id: "g1".into() },
            36.0,
            machine("local"),
            Some("g1"),
            0,
            Some(1),
            false,
            false,
            0,
        ),
        row(
            RowKey::Workspace { id: "g2".into() },
            48.0,
            machine("local"),
            Some("g1"),
            1,
            Some(1),
            true,
            false,
            0,
        ),
    ];
    let mut request = request_with_rows(
        200.0,
        Payload::Workspaces { ids: vec!["a".into()] },
        rows.clone(),
        sections.clone(),
    );
    request.ungrouped_first = true;
    assert_eq!(
        resolve(&request),
        Some(Target::Position { section: machine("local"), group: None, index: 1 })
    );
    let g1_row = rows.iter().find(|row| row.key == RowKey::Workspace { id: "g1".into() }).unwrap();
    let mut into = request_with_rows(
        g1_row.y + 1.0,
        Payload::Workspaces { ids: vec!["a".into()] },
        rows.clone(),
        sections.clone(),
    );
    into.ungrouped_first = true;
    assert_eq!(
        resolve(&into),
        Some(Target::Position { section: machine("local"), group: Some("g1".into()), index: 0 })
    );
    let mut without = request_with_rows(
        200.0,
        Payload::Workspaces { ids: vec!["a".into()] },
        into.rows,
        sections,
    );
    without.ungrouped_first = false;
    assert_eq!(
        resolve(&without),
        Some(Target::Position { section: machine("local"), group: None, index: 2 })
    );
}

#[test]
fn headerless_machine_list_still_accepts_top_drop() {
    let section = machine("local");
    let sections = vec![Section {
        id: section.clone(),
        machine: Some("local".into()),
        nodes: vec![
            Node::Workspace { workspace: workspace("a", "local") },
            Node::Workspace { workspace: workspace("b", "local") },
        ],
    }];
    let rows = vec![
        row(
            RowKey::Workspace { id: "a".into() },
            0.0,
            section.clone(),
            None,
            0,
            None,
            false,
            false,
            0,
        ),
        row(
            RowKey::Workspace { id: "b".into() },
            12.0,
            section.clone(),
            None,
            1,
            None,
            false,
            false,
            0,
        ),
    ];
    assert_eq!(
        resolve(&request_with_rows(
            0.0,
            Payload::Workspaces { ids: vec!["b".into()] },
            rows,
            sections
        )),
        Some(Target::Position { section, group: None, index: 0 })
    );
}

#[test]
fn empty_group_machine_is_optional_in_the_wire_shape() {
    let section = Section {
        id: machine("local"),
        machine: Some("local".into()),
        nodes: vec![Node::Group { id: "empty".into(), machine: None, workspaces: vec![] }],
    };
    let json = serde_json::to_string(&section).unwrap();
    let decoded: Section = serde_json::from_str(&json).unwrap();
    assert_eq!(decoded, section);
}

/// Swift `previousExpandedSection` takes the section header right above and
/// answers nil when it is collapsed; it never skips past a collapsed section
/// to an expanded one further up.
#[test]
fn a_collapsed_previous_section_is_not_skipped_for_the_one_above_it() {
    let mut rows: Vec<Row> = rows()
        .into_iter()
        .filter(|row| row.section != machine("local") || matches!(row.key, RowKey::Section { .. }))
        .collect();
    for row in &mut rows {
        if row.key == (RowKey::Section { id: machine("local") }) {
            row.is_collapsed = true;
        }
    }
    let mut y = 0.0;
    for row in &mut rows {
        row.y = y;
        y += row.height + 2.0;
    }
    let cloud =
        rows.iter().find(|row| row.key == RowKey::Section { id: machine("cloud") }).unwrap();
    let request = request_with_rows(
        cloud.y + cloud.height * 0.1,
        Payload::Workspaces { ids: vec!["y".into()] },
        rows,
        sections(),
    );
    assert_eq!(
        resolve(&request),
        Some(Target::Position { section: machine("cloud"), group: None, index: 0 })
    );
}
