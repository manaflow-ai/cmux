//! Workspace name provenance in the registry (hq#1957): an additive
//! migration, user-owned legacy rows, and older daemons' renames.

use super::*;
use crate::resource_name::NameSource;
use serde_json::json;

const KEY: &str = "00000000-0000-4000-8000-0000000000a1";

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-registry-{label}-{}", new_uuid_v4()))
}

fn named(source: NameSource, revision: u64) -> RegistryWorkspace {
    RegistryWorkspace {
        id: 1,
        public_id: WorkspacePublicId::parse(format!("ws_{:032x}", 0xa1)).unwrap(),
        key: KEY.into(),
        name: "Fix Login".into(),
        name_source: source,
        name_revision: revision,
        group_key: "default".into(),
    }
}

fn commit(registry: &mut WorkspaceRegistry, id: &str, workspace: RegistryWorkspace) {
    let revision = registry.snapshot().unwrap().revision;
    registry
        .commit(
            &WorkspaceMutation::daemon(id, "test").unwrap(),
            &json!({"op":id}),
            None,
            Some(revision),
            "workspace-renamed",
            KEY,
            &[workspace],
            &json!({"key":KEY}),
        )
        .unwrap();
}

#[test]
fn workspace_name_source_persists_across_registry_restart() {
    let root = temp_root("workspace-name-restart");
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit(&mut registry, "create", named(NameSource::Auto, 2));
        let workspace = &registry.snapshot().unwrap().workspaces[0];
        assert_eq!(workspace.name_source, NameSource::Auto);
        assert_eq!(workspace.name_revision, 2);
    }
    let restored = WorkspaceRegistry::open(&root, "session").unwrap();
    let workspace = restored.snapshot().unwrap().workspaces[0].clone();
    assert_eq!(workspace, named(NameSource::Auto, 2));
    drop(restored);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn workspace_name_source_legacy_rows_read_as_user() {
    for missing in [&["name_source", "name_revision"][..], &["name_source"], &["name_revision"]] {
        let root = temp_root("workspace-name-column-upgrade");
        {
            let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
            commit(&mut registry, "create", named(NameSource::Auto, 2));
            let mut downgrade = String::from("DROP TRIGGER workspace_legacy_name_owner;");
            for column in missing {
                downgrade.push_str(&format!("ALTER TABLE workspaces DROP COLUMN {column};"));
            }
            registry.connection.get().execute_batch(&downgrade).unwrap();
        }
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let workspace = registry.snapshot().unwrap().workspaces[0].clone();
        let source =
            if missing.contains(&"name_source") { NameSource::User } else { NameSource::Auto };
        let revision = if missing.contains(&"name_revision") { 0 } else { 2 };
        assert_eq!(workspace.name_source, source, "missing {missing:?}");
        assert_eq!(workspace.name_revision, revision, "missing {missing:?}");
        assert_eq!(workspace.name, "Fix Login");
        drop(registry);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn workspace_name_source_older_daemon_rename_claims_user_ownership() {
    let root = temp_root("workspace-name-legacy-writer");
    let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
    commit(&mut registry, "create", named(NameSource::Auto, 2));
    // A pre-provenance daemon's write: it cannot name the new columns.
    registry
        .connection
        .get()
        .execute(
            "UPDATE workspaces SET name = 'Billing', updated_revision = 9 WHERE workspace_key = ?1",
            [KEY],
        )
        .unwrap();
    let workspace = registry.snapshot().unwrap().workspaces[0].clone();
    assert_eq!(workspace.name, "Billing");
    assert_eq!(workspace.name_source, NameSource::User);
    assert_eq!(workspace.name_revision, 3);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
