//! Mirrors `SidebarHostGroupTests`, `SidebarMachineMarkTests`, `SidebarCloudMachineHeaderTests` and
//! `SidebarListPatchCopyTests`, at the rule level.

use super::*;

#[test]
fn a_host_group_drawn_as_one_group_has_its_group_bar_instead() {
    assert!(keeps_header(true, false));
    assert!(!keeps_header(true, true));
    assert!(!keeps_header(false, false));
}

#[test]
fn the_rows_label_names_the_machine_once_and_only_in_one_list() {
    assert_eq!(
        machine_label(true, Some(MachineKind::Ssh), false),
        Some(Label { name: true, status: false })
    );
    assert_eq!(machine_label(false, Some(MachineKind::Ssh), false), None);
    assert_eq!(machine_label(true, Some(MachineKind::Local), true), None);
    assert_eq!(machine_label(true, None, true), None);
}

#[test]
fn a_failed_machines_status_is_still_spoken() {
    assert_eq!(
        machine_label(true, Some(MachineKind::Server), true),
        Some(Label { name: true, status: true })
    );
}

#[test]
fn a_cloud_row_never_names_its_machine() {
    assert_eq!(machine_label(true, Some(MachineKind::Cloud), false), None);
    assert_eq!(
        machine_label(true, Some(MachineKind::Cloud), true),
        Some(Label { name: false, status: true })
    );
}

#[test]
fn a_look_added_changed_or_dropped_is_changed() {
    let old = BTreeMap::from([
        ("a".to_owned(), json!(1)),
        ("b".to_owned(), json!(2)),
        ("c".to_owned(), json!(3)),
    ]);
    let new = BTreeMap::from([
        ("a".to_owned(), json!(1)),
        ("b".to_owned(), json!(5)),
        ("d".to_owned(), json!(4)),
    ]);
    assert_eq!(changed(&old, &new), vec!["b", "d", "c"]);
}

#[test]
fn a_launch_lists_a_saved_row_beside_its_live_one() {
    let sections = vec![
        vec![Node::Workspace("w".into()), Node::Item, Node::Group(vec!["x".into(), "w".into()])],
        vec![Node::Workspace("x".into())],
    ];
    let paths = paths(&sections);
    assert_eq!(
        paths["w"],
        vec![
            Path { section: 0, node: 0, member: None },
            Path { section: 0, node: 2, member: Some(1) }
        ]
    );
    assert_eq!(patched(&BTreeSet::from(["x".to_owned()]), &sections).len(), 2);
}

#[test]
fn another_group_at_the_patched_place_is_not_the_same_place() {
    let nodes = vec![Node::Group(vec!["a".into()]), Node::Workspace("w".into())];
    assert!(lists("a", 0, Some(0), &nodes));
    assert!(!lists("a", 0, Some(1), &nodes));
    assert!(!lists("a", 0, None, &nodes));
    assert!(lists("w", 1, None, &nodes));
    assert!(!lists("w", 1, Some(0), &nodes));
    assert!(!lists("w", 5, None, &nodes));
}
