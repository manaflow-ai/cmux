//! The local migration of shared groups and order into personal rows
//! (plans/cmux-next/data-model.md 2.2) runs once and is idempotent.

use super::*;
use serde_json::json;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-personal-{label}-{}", new_uuid_v4()))
}

fn seed(registry: &mut WorkspaceRegistry, keys: &[&str]) {
    let mut desired = Vec::new();
    for (offset, key) in keys.iter().enumerate() {
        let revision = registry.snapshot().unwrap().revision;
        let id = offset as u64 + 1;
        desired.push(RegistryWorkspace {
            id,
            public_id: WorkspacePublicId::parse(format!("ws_{id:032x}")).unwrap(),
            key: (*key).into(),
            name: format!("Workspace {id}"),
            group_key: "default".into(),
        });
        registry
            .commit(
                &WorkspaceMutation::daemon(format!("create-{key}"), "test").unwrap(),
                &json!({"op":"create","key":key}),
                None,
                Some(revision),
                "workspace-added",
                key,
                &desired,
                &json!({"key":key}),
            )
            .unwrap();
    }
}

fn count(registry: &WorkspaceRegistry, table: &str) -> i64 {
    registry
        .connection
        .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| row.get(0))
        .unwrap()
}

fn strings(registry: &WorkspaceRegistry, sql: &str) -> Vec<String> {
    let mut statement = registry.connection.prepare(sql).unwrap();
    statement.query_map([], |row| row.get::<_, String>(0)).unwrap().map(Result::unwrap).collect()
}

/// Every personal row and the personal revision, for before/after equality.
fn dump(registry: &WorkspaceRegistry) -> Vec<Vec<String>> {
    [
        "SELECT profile_id || name || position FROM profiles ORDER BY profile_id",
        "SELECT profile_id || session_id FROM profile_follows ORDER BY 1",
        "SELECT session_id || migrated FROM sessions ORDER BY 1",
        "SELECT group_id || profile_id || position FROM personal_groups ORDER BY 1",
        "SELECT session_id || workspace_key || position FROM personal_workspaces ORDER BY 1",
        "SELECT value FROM meta WHERE key IN ('personal_revision', 'personal_migrated_v1') ORDER BY key",
    ]
    .iter()
    .map(|sql| strings(registry, sql))
    .collect()
}

#[test]
fn shared_groups_and_order_migrate_into_personal_rows_once() {
    let root = temp_root("migrate");
    let first = "00000000-0000-4000-8000-000000000001";
    let second = "00000000-0000-4000-8000-000000000002";
    let registry_id;
    {
        let mut registry = WorkspaceRegistry::open(&root, "personal").unwrap();
        registry_id = registry.registry_id().to_string();
        seed(&mut registry, &[first, second]);
        registry.create_workspace_group("grp_shared", "Shared", Some("red"), false, None).unwrap();
        registry
            .connection
            .execute(
                "INSERT INTO workspace_presentation(workspace_key, group_id) VALUES(?1, 'grp_shared')",
                [second],
            )
            .unwrap();
        // Simulate a registry written by a build without personal state.
        registry
            .connection
            .execute_batch(
                "DELETE FROM meta WHERE key IN ('personal_migrated_v1', 'personal_revision');
                 DELETE FROM profiles; DELETE FROM profile_follows; DELETE FROM sessions;
                 DELETE FROM personal_groups; DELETE FROM personal_workspaces;",
            )
            .unwrap();
    }
    let migrated = {
        let registry = WorkspaceRegistry::open(&root, "personal").unwrap();
        let rows = |sql: &str| strings(&registry, sql);
        assert_eq!(rows("SELECT profile_id FROM profiles ORDER BY position"), ["default"]);
        assert_eq!(
            rows("SELECT profile_id || '/' || session_id FROM profile_follows"),
            [format!("default/{registry_id}")]
        );
        assert_eq!(
            rows("SELECT session_id || '/' || migrated FROM sessions"),
            [format!("{registry_id}/1")]
        );
        assert_eq!(
            rows("SELECT group_id || '/' || profile_id FROM personal_groups ORDER BY position"),
            ["grp_shared/default"]
        );
        assert_eq!(
            rows(
                "SELECT session_id || '/' || workspace_key || '/' || COALESCE(group_id, '-')
                 FROM personal_workspaces ORDER BY position"
            ),
            [format!("{registry_id}/{first}/-"), format!("{registry_id}/{second}/grp_shared")]
        );
        dump(&registry)
    };
    // A second open changes nothing, even after the shared groups change.
    let mut registry = WorkspaceRegistry::open(&root, "personal").unwrap();
    registry.create_workspace_group("grp_late", "Late", None, false, None).unwrap();
    drop(registry);
    let registry = WorkspaceRegistry::open(&root, "personal").unwrap();
    assert_eq!(dump(&registry), migrated);
    assert_eq!(count(&registry, "personal_groups"), 1);
    drop(registry);
    let _ = fs::remove_dir_all(&root);
}

#[test]
fn personal_state_does_not_bump_the_schema_version() {
    let registry = WorkspaceRegistry::in_memory("personal-additive").unwrap();
    let schema: String = registry
        .connection
        .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| row.get(0))
        .unwrap();
    assert_eq!(schema, SCHEMA_VERSION.to_string());
    assert_eq!(count(&registry, "profiles"), 1);
}
