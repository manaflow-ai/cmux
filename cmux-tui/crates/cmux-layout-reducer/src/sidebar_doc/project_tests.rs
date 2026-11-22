//! [`project`]: the sections one window's rows draw (the app's
//! `SidebarDocProjection`, moved here with its tests).

use super::project::{Node, ProjectedSection, Projection, project};
use super::view::{LiveWorkspace, Row, ViewRequest, view};
use super::*;
use serde_json::json;

const S: &str = "mini";

fn reference(id: &str) -> WorkspaceRef {
    WorkspaceRef::new(S, id)
}

fn ws_id(id: &str) -> ItemId {
    workspace_item_id(&reference(id))
}

fn live(ids: &[&str]) -> Vec<LiveWorkspace> {
    ids.iter()
        .map(|id| LiveWorkspace { session_id: S.into(), workspace_id: (*id).into(), title: None })
        .collect()
}

fn item(id: &str, section: &str, parent: Option<&str>, order: &str, body: Body) -> Item {
    let mut item = Item::new(id, section, body);
    item.parent = parent.map(str::to_string);
    item.order = order.into();
    item
}

fn workspace(id: &str, section: &str, parent: Option<&str>, order: &str) -> Item {
    item(&ws_id(id), section, parent, order, Body::Workspace { reference: reference(id) })
}

fn group(id: &str, section: &str, parent: Option<&str>, order: &str) -> Item {
    let body =
        Body::Group { name: id.into(), color: None, icon: None, collapsed: false, profile: None };
    item(id, section, parent, order, body)
}

fn url(id: &str, section: &str, parent: Option<&str>, order: &str) -> Item {
    let body = Body::Url { url: format!("https://{id}.example"), title: None, icon_url: None };
    item(id, section, parent, order, body)
}

fn machine() -> Section {
    let mut section = Section::machine(S);
    section.order = "m".into();
    section
}

fn pinned() -> Section {
    let mut section = Section::pinned();
    section.order = "a".into();
    section
}

fn projection(doc: &Doc, live_ids: &[&str]) -> (Vec<Row>, Projection) {
    let rows = view(
        doc,
        &ViewRequest { live: live(live_ids), collapsed: Some(vec![]), ..Default::default() },
    );
    let projection = project(doc, &rows);
    (rows, projection)
}

fn groups(nodes: &[Node]) -> Vec<&project::Group> {
    nodes
        .iter()
        .filter_map(|node| match node {
            Node::Group { group } => Some(group),
            _ => None,
        })
        .collect()
}

/// project > branch > leaf(a1), and a2 directly in project after the
/// branch; a3 loose.
fn nested() -> Doc {
    let sec = machine_section_id(S);
    Doc::from_parts(
        1,
        vec![machine()],
        vec![
            group("g_project", &sec, None, "a"),
            group("g_branch", &sec, Some("g_project"), "a"),
            group("g_leaf", &sec, Some("g_branch"), "a"),
            workspace("a1", &sec, Some("g_leaf"), "a"),
            workspace("a2", &sec, Some("g_project"), "b"),
            workspace("a3", &sec, None, "b"),
        ],
    )
}

#[test]
fn each_nested_group_lists_with_its_parent_depth_and_own_members() {
    let (_, projection) = projection(&nested(), &["a1", "a2", "a3"]);
    let nodes = &projection.machines[S];
    let groups = groups(nodes);
    assert_eq!(
        groups.iter().map(|g| g.id.as_str()).collect::<Vec<_>>(),
        ["g_project", "g_branch", "g_leaf"]
    );
    assert_eq!(
        groups.iter().map(|g| g.parent.as_deref()).collect::<Vec<_>>(),
        [None, Some("g_project"), Some("g_branch")]
    );
    assert_eq!(groups.iter().map(|g| g.depth).collect::<Vec<_>>(), [0, 1, 2]);
    let members: Vec<Vec<&str>> = groups
        .iter()
        .map(|g| g.members.iter().map(|m| m.reference.workspace_id.as_str()).collect())
        .collect();
    assert_eq!(members, [vec!["a2"], vec![], vec!["a1"]], "each group holds only its own members");
    let loose: Vec<&str> = nodes
        .iter()
        .filter_map(|node| match node {
            Node::Workspace { reference, .. } => Some(reference.workspace_id.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(loose, ["a3"]);
}

#[test]
fn every_placed_workspace_keeps_its_item() {
    let (_, projection) = projection(&nested(), &["a1", "a2", "a3"]);
    for id in ["a1", "a2", "a3"] {
        assert!(
            projection.items.iter().any(|m| m.reference == reference(id) && m.item == ws_id(id)),
            "{id} is placed"
        );
    }
    assert_eq!(projection.machine_sections[S], machine_section_id(S));
    assert_eq!(projection.machine_order, [machine_section_id(S)]);
}

#[test]
fn bands_list_before_the_workspace_list_with_their_items_and_groups() {
    let sec = machine_section_id(S);
    let mut link = url("itm_link", PINNED_SECTION_ID, None, "a");
    link.extra.insert("room".into(), json!("work"));
    let doc = Doc::from_parts(
        1,
        vec![pinned(), machine()],
        vec![
            link,
            url("itm_shared", PINNED_SECTION_ID, None, "b"),
            group("g_pin", PINNED_SECTION_ID, None, "c"),
            workspace("p1", PINNED_SECTION_ID, Some("g_pin"), "a"),
            url("itm_member", PINNED_SECTION_ID, Some("g_pin"), "b"),
            workspace("p2", PINNED_SECTION_ID, Some("g_pin"), "c"),
            workspace("a1", &sec, None, "a"),
        ],
    );
    // p2 is closed: Pinned keeps it, dimmed, not an open member.
    let (_, projection) = projection(&doc, &["p1", "a1"]);
    let [ProjectedSection::Band { section, items }, ProjectedSection::Workspaces { like }] =
        projection.sections.as_slice()
    else {
        panic!("Pinned, then the workspace list: {:?}", projection.sections);
    };
    assert_eq!(section.id, PINNED_SECTION_ID);
    assert_eq!(like.as_ref().map(|s| s.id.as_str()), Some(sec.as_str()));
    let band: Vec<(&str, Option<&str>)> =
        items.iter().map(|b| (b.item.id.as_str(), b.room.as_deref())).collect();
    assert_eq!(
        band,
        [("itm_link", Some("work")), ("itm_shared", Some("default"))],
        "a Pinned link draws in its space, the default one when it stores none"
    );
    let [band_group] = projection.band_groups.as_slice() else { panic!("one band group") };
    assert!(band_group.pinned);
    assert_eq!(
        band_group.members.iter().map(|m| m.item.as_str()).collect::<Vec<_>>(),
        [ws_id("p1"), ws_id("p2")]
    );
    assert_eq!(band_group.open_members, [reference("p1")]);
    let [listed] = band_group.listed.as_slice() else { panic!("one listed member") };
    assert_eq!(listed.item.id, "itm_member");
    assert_eq!(listed.after.as_deref(), Some(ws_id("p1").as_str()), "it follows p1");
    assert!(projection.items.iter().any(|m| m.item == ws_id("p1")), "a band member is placed");
}

#[test]
fn unplaced_live_workspaces_and_a_machine_without_a_section() {
    let doc = Doc::from_parts(1, vec![], vec![]);
    let (_, projection) = projection(&doc, &["n1", "n2"]);
    assert_eq!(projection.unplaced, [reference("n1"), reference("n2")]);
    assert_eq!(projection.machine_order, [machine_section_id(S)]);
    assert!(matches!(
        projection.sections.as_slice(),
        [ProjectedSection::Workspaces { like: Some(_) }]
    ));
}

#[test]
fn no_machine_section_puts_the_workspace_list_last() {
    let doc =
        Doc::from_parts(1, vec![pinned()], vec![url("itm_link", PINNED_SECTION_ID, None, "a")]);
    let (_, projection) = projection(&doc, &[]);
    assert!(matches!(
        projection.sections.as_slice(),
        [ProjectedSection::Band { .. }, ProjectedSection::Workspaces { like: None }]
    ));
}

#[test]
fn links_in_a_machine_section_list_in_order_and_in_their_group() {
    let sec = machine_section_id(S);
    let doc = Doc::from_parts(
        1,
        vec![machine()],
        vec![
            url("itm_top", &sec, None, "a"),
            workspace("a1", &sec, None, "b"),
            group("g", &sec, None, "c"),
            url("itm_first", &sec, Some("g"), "a"),
            workspace("a2", &sec, Some("g"), "b"),
        ],
    );
    let (_, projection) = projection(&doc, &["a1", "a2"]);
    let nodes = &projection.machines[S];
    assert!(matches!(&nodes[0], Node::Link { item } if item.id == "itm_top"));
    assert!(matches!(&nodes[1], Node::Workspace { item, .. } if *item == ws_id("a1")));
    let listed = groups(nodes);
    let [g] = listed.as_slice() else { panic!("one group") };
    assert_eq!(g.listed.len(), 1);
    assert_eq!(g.listed[0].after, None, "a member before any workspace member comes first");
    assert!(g.open_members.is_empty(), "a machine group carries no open members");
}

#[test]
fn archived_sorted_pinned_and_host_group_marks() {
    let sec = machine_section_id(S);
    let mut section = machine();
    section.host_group = true;
    let mut sorted = group("g", &sec, None, "a");
    sorted.extra.insert(GROUP_SORT_KEY.into(), json!("name"));
    sorted.extra.insert(ARCHIVED_KEY.into(), json!(true));
    sorted.extra.insert(GROUP_ROW_LIMIT_KEY.into(), json!("all"));
    sorted.extra.insert(GROUP_REVEALED_KEY.into(), json!(40));
    let mut member = workspace("a1", &sec, Some("g"), "a");
    member.extra.insert(PINNED_IN_GROUP_KEY.into(), json!(true));
    let doc = Doc::from_parts(1, vec![section], vec![sorted, member]);
    let (_, projection) = projection(&doc, &["a1"]);
    assert_eq!(
        projection.archived,
        ["g".to_string(), ws_id("a1")],
        "a row under an archived group draws archived"
    );
    assert_eq!(projection.group_sorts.get("g").map(String::as_str), Some("name"));
    assert_eq!(projection.pinned_in_group, [ws_id("a1")]);
    assert_eq!(projection.group_row_limits.get("g"), Some(&0), "the group's own cap: All");
    assert_eq!(projection.group_revealed.get("g"), Some(&40));
    assert_eq!(projection.host_groups, [sec]);
}

#[test]
fn a_pending_rename_draws_from_the_document() {
    let mut doc = nested();
    reduce::apply_in_place(
        &mut doc,
        &[Op::GroupUpdate {
            id: "g_leaf".into(),
            patch: GroupPatch { name: Some("renamed".into()), ..GroupPatch::default() },
        }],
        &mut String::new,
    )
    .expect("a rename applies");
    let (_, projection) = projection(&doc, &["a1", "a2", "a3"]);
    let names: Vec<&str> =
        groups(&projection.machines[S]).iter().map(|g| g.name.as_str()).collect();
    assert_eq!(names, ["g_project", "g_branch", "renamed"]);
}

#[test]
fn projection_round_trips_as_json() {
    let (_, projection) = projection(&nested(), &["a1", "a2", "a3", "new"]);
    let text = serde_json::to_string(&projection).expect("serializes");
    let back: Projection = serde_json::from_str(&text).expect("reads back");
    assert_eq!(back, projection);
}
