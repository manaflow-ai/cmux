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

fn try_commit(
    registry: &mut WorkspaceRegistry,
    id: &str,
    workspace: RegistryWorkspace,
) -> anyhow::Result<()> {
    let revision = registry.snapshot()?.revision;
    registry.commit(
        &WorkspaceMutation::daemon(id, "test")?,
        &json!({"op":id}),
        None,
        Some(revision),
        "workspace-renamed",
        KEY,
        &[workspace],
        &json!({"key":KEY}),
    )?;
    Ok(())
}

fn commit(registry: &mut WorkspaceRegistry, id: &str, workspace: RegistryWorkspace) {
    try_commit(registry, id, workspace).unwrap();
}

fn renamed(name: &str, source: NameSource, revision: u64) -> RegistryWorkspace {
    RegistryWorkspace { name: name.into(), ..named(source, revision) }
}

fn refusal(error: &anyhow::Error) -> (String, Value) {
    let error = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<crate::resource::ResourceError>())
        .unwrap_or_else(|| panic!("untyped refusal: {error:#}"));
    (
        error.code.clone(),
        error
            .details
            .get("extra")
            .and_then(|extra| extra.get("reason_code"))
            .cloned()
            .unwrap_or(Value::Null),
    )
}

fn resource_upsert(
    registry: &mut WorkspaceRegistry,
    id: &str,
    workspace: RegistryWorkspace,
) -> anyhow::Result<()> {
    // No revision precondition: only the stored name row fences this write.
    registry.commit_resource_patch(
        &WorkspaceMutation::daemon(id, "test")?,
        "workspace.rename",
        &json!({"op":id}),
        None,
        None,
        &ResourcePatch {
            changes: vec![ResourceChange::UpsertWorkspace {
                workspace,
                position: 0,
                active_screen: None,
            }],
        },
        &json!({"key":KEY}),
        &json!([]),
    )?;
    Ok(())
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

/// Memory read the automatic name at revision 2, then another writer stored
/// a user rename at revision 3. The write built from memory must not land.
#[test]
fn workspace_name_source_store_refuses_a_rename_older_than_storage() {
    let root = temp_root("workspace-name-store-fence");
    let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
    commit(&mut registry, "create", renamed("Fix Login", NameSource::Auto, 2));
    commit(&mut registry, "pin", renamed("Billing", NameSource::User, 3));
    let pinned = renamed("Billing", NameSource::User, 3);

    // The auto rename memory approved against revision 2.
    let stale = try_commit(&mut registry, "stale-auto", renamed("Topic", NameSource::Auto, 3));
    assert_eq!(refusal(&stale.unwrap_err()).0, "revision.conflict");
    // Any write carrying memory's older revision, renamed or not.
    let behind = try_commit(&mut registry, "stale-copy", renamed("Fix Login", NameSource::Auto, 2));
    assert_eq!(refusal(&behind.unwrap_err()).0, "revision.conflict");
    // The resource patch path is fenced the same way.
    let patched =
        resource_upsert(&mut registry, "stale-patch", renamed("Topic", NameSource::Auto, 3));
    assert_eq!(refusal(&patched.unwrap_err()).0, "revision.conflict");
    // A revision that agrees with storage still cannot auto-name over a user name.
    let over_user = try_commit(&mut registry, "over-user", renamed("Topic", NameSource::Auto, 4));
    assert_eq!(
        refusal(&over_user.unwrap_err()),
        ("operation.failed".to_string(), json!("name_pinned"))
    );
    assert_eq!(registry.snapshot().unwrap().workspaces[0], pinned);

    // Writes that agree with storage still land.
    commit(&mut registry, "same", pinned);
    commit(&mut registry, "user", renamed("Payments", NameSource::User, 4));
    commit(&mut registry, "release", renamed("Payments", NameSource::Auto, 5));
    resource_upsert(&mut registry, "auto", renamed("Refunds", NameSource::Auto, 6)).unwrap();
    assert_eq!(registry.snapshot().unwrap().workspaces[0], renamed("Refunds", NameSource::Auto, 6));
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn workspace_name_source_default_named_user_rows_heal_to_auto() {
    let root = temp_root("workspace-name-default-heal");
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit(&mut registry, "create", renamed("workspace-201", NameSource::User, 0));
    }
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let workspace = registry.snapshot().unwrap().workspaces[0].clone();
    assert_eq!(workspace.name_source, NameSource::Auto);
    assert_eq!(workspace.name_revision, 0);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn workspace_name_source_chosen_or_renamed_names_stay_user() {
    for (name, revision) in [("Fix Login", 0), ("workspace-7", 1), ("workspace-7b", 0)] {
        let root = temp_root("workspace-name-default-keep");
        {
            let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
            commit(&mut registry, "create", renamed(name, NameSource::User, revision));
        }
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let workspace = registry.snapshot().unwrap().workspaces[0].clone();
        assert_eq!(workspace.name_source, NameSource::User, "{name} r{revision}");
        drop(registry);
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn requested_default_workspace_name_is_auto() {
    use crate::resource_name::NameSource as S;
    assert_eq!(S::for_requested_workspace_name(None), S::Auto);
    assert_eq!(S::for_requested_workspace_name(Some("workspace-12")), S::Auto);
    assert_eq!(S::for_requested_workspace_name(Some("workspace-")), S::User);
    assert_eq!(S::for_requested_workspace_name(Some("workspace-1x")), S::User);
    assert_eq!(S::for_requested_workspace_name(Some("vim notes")), S::User);
}
