//! Mixed personal order (`personal-mixed-order-v1`, plans/cmux-next
//! sidebar mixed order): a group has a slot among the loose workspaces and
//! keeps it when other workspaces move or go away.

use super::super::*;

const S: &str = "00000000-0000-4000-8000-0000000000aa";
const OTHER: &str = "00000000-0000-4000-8000-0000000000bb";

fn place(registry: &mut WorkspaceRegistry, session: &str, key: &str, index: Option<usize>) {
    registry
        .set_personal_workspace(
            session,
            key,
            PersonalWorkspaceUpdate { index, ..PersonalWorkspaceUpdate::default() },
        )
        .unwrap();
}

/// The sidebar order of the loose workspaces and groups, as the app merges
/// them: a group right before the workspace at its `top_index`, groups with
/// no slot at the end.
fn shown(registry: &WorkspaceRegistry) -> Vec<String> {
    let snapshot = registry.personal_snapshot().unwrap();
    let mut out = Vec::new();
    for workspace in &snapshot.workspaces {
        for group in snapshot.groups.iter().filter(|group| group.top_index == Some(workspace.index))
        {
            out.push(format!("[{}]", group.id));
        }
        if workspace.group.is_none() {
            out.push(workspace.workspace_key.clone());
        }
    }
    let count = snapshot.workspaces.len();
    for group in
        snapshot.groups.iter().filter(|group| group.top_index.is_none_or(|top| top >= count))
    {
        out.push(format!("[{}]", group.id));
    }
    out
}

fn registry_with(keys: &[&str]) -> WorkspaceRegistry {
    let mut registry = WorkspaceRegistry::in_memory("mixed-order").unwrap();
    registry
        .put_session(S, Some("mac"), Some("s"), &serde_json::json!({"kind":"local"}), None, None)
        .unwrap();
    for key in keys {
        place(&mut registry, S, key, None);
    }
    registry.create_personal_group(Some("grp_g".into()), None, "G", None, false, None).unwrap();
    registry
}

#[test]
fn a_group_takes_a_slot_between_loose_workspaces() {
    let mut registry = registry_with(&["ka", "kb", "kc"]);
    assert_eq!(shown(&registry), ["ka", "kb", "kc", "[grp_g]"], "no slot: after every loose one");
    let (group, changed) = registry.set_personal_group_top("grp_g", Some(1)).unwrap();
    assert!(changed);
    assert_eq!(group.top_index, Some(1));
    assert_eq!(shown(&registry), ["ka", "[grp_g]", "kb", "kc"]);
    // The same slot again changes nothing; None goes back to the end.
    assert!(!registry.set_personal_group_top("grp_g", Some(1)).unwrap().1);
    registry.set_personal_group_top("grp_g", None).unwrap();
    assert_eq!(shown(&registry), ["ka", "kb", "kc", "[grp_g]"]);
}

/// Tie rule: a group and a workspace on the same slot show group first.
#[test]
fn a_new_workspace_after_an_end_group_shows_after_it() {
    let mut registry = registry_with(&["ka", "kb"]);
    registry.set_personal_group_top("grp_g", Some(2)).unwrap();
    place(&mut registry, S, "kc", None);
    assert_eq!(shown(&registry), ["ka", "kb", "[grp_g]", "kc"]);
}

#[test]
fn a_group_keeps_its_slot_when_other_workspaces_move() {
    let mut registry = registry_with(&["ka", "kb", "kc"]);
    registry.set_personal_group_top("grp_g", Some(1)).unwrap();
    // kc to the front: the group stays between ka and kb.
    place(&mut registry, S, "kc", Some(0));
    assert_eq!(shown(&registry), ["kc", "ka", "[grp_g]", "kb"]);
    // ka to the end: the group stays before kb.
    place(&mut registry, S, "ka", Some(2));
    assert_eq!(shown(&registry), ["kc", "[grp_g]", "kb", "ka"]);
}

#[test]
fn a_group_keeps_its_slot_when_its_next_workspace_goes_away() {
    let mut registry = registry_with(&["ka"]);
    registry
        .put_session(
            OTHER,
            Some("mac2"),
            Some("o"),
            &serde_json::json!({"kind":"local"}),
            None,
            None,
        )
        .unwrap();
    place(&mut registry, OTHER, "kx", None);
    place(&mut registry, S, "kb", None);
    registry.set_personal_group_top("grp_g", Some(1)).unwrap();
    assert_eq!(shown(&registry), ["ka", "[grp_g]", "kx", "kb"]);
    registry.forget_session(OTHER, true).unwrap();
    assert_eq!(shown(&registry), ["ka", "[grp_g]", "kb"]);
}

#[test]
fn a_registry_without_the_slot_column_gains_it_at_open() {
    let root = std::env::temp_dir().join(format!("cmux-mixed-order-{}", new_uuid_v4()));
    {
        let mut registry = WorkspaceRegistry::open(&root, "mixed").unwrap();
        registry
            .create_personal_group(Some("grp_old".into()), None, "Old", None, false, None)
            .unwrap();
        registry
            .connection
            .execute_batch("ALTER TABLE personal_groups DROP COLUMN top_position")
            .ok();
    }
    let mut registry = WorkspaceRegistry::open(&root, "mixed").unwrap();
    let group = registry
        .personal_snapshot()
        .unwrap()
        .groups
        .into_iter()
        .find(|g| g.id == "grp_old")
        .unwrap();
    assert_eq!(group.top_index, None, "an older group keeps the older order");
    assert!(registry.set_personal_group_top("grp_old", Some(0)).unwrap().1);
    drop(registry);
    let _ = fs::remove_dir_all(&root);
}
