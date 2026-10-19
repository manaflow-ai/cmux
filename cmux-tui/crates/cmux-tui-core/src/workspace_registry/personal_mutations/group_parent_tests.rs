//! `workspace-group-nest-v1` in the registry: a registry from before the
//! nest (no `parent_id` column) opens with every group at the top level,
//! and a nested registry keeps its nest across opens.

use super::super::*;

fn open(root: &std::path::Path) -> WorkspaceRegistry {
    WorkspaceRegistry::open(root, "nest").unwrap()
}

fn parent(registry: &WorkspaceRegistry, id: &str) -> Option<String> {
    registry.personal_snapshot().unwrap().groups.into_iter().find(|g| g.id == id).unwrap().parent
}

#[test]
fn a_registry_from_before_the_nest_opens_flat_and_can_nest() {
    let root = std::env::temp_dir().join(format!("cmux-group-nest-old-{}", new_uuid_v4()));
    {
        let mut registry = open(&root);
        registry.create_personal_group(Some("grp_a".into()), None, "A", None, false, None).unwrap();
        registry.create_personal_group(Some("grp_b".into()), None, "B", None, false, None).unwrap();
        let connection = registry.connection.get();
        // The old shape: no column, so no trigger that names it either.
        connection
            .execute_batch(
                "DROP TRIGGER IF EXISTS sidebar_doc_group_parent;
                 ALTER TABLE personal_groups DROP COLUMN parent_id;",
            )
            .unwrap();
        let present = connection
            .prepare("SELECT 1 FROM pragma_table_info('personal_groups') WHERE name = 'parent_id'")
            .unwrap()
            .exists([])
            .unwrap();
        assert!(!present, "the old shape has no parent column");
    }
    let registry = open(&root);
    assert_eq!(parent(&registry, "grp_a"), None);
    assert_eq!(parent(&registry, "grp_b"), None);
    {
        let connection = registry.connection.get();
        let tx = connection.unchecked_transaction().unwrap();
        WorkspaceRegistry::set_personal_group_parent_in(&tx, "grp_b", Some("grp_a")).unwrap();
        tx.commit().unwrap();
    }
    drop(registry);
    let registry = open(&root);
    assert_eq!(parent(&registry, "grp_b").as_deref(), Some("grp_a"), "the nest survives a reopen");
    drop(registry);
    let _ = std::fs::remove_dir_all(&root);
}
