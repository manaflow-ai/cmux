use super::*;

fn write_schema(path: &Path, version: Option<&str>) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch("CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);")
        .unwrap();
    if let Some(version) = version {
        connection.execute("INSERT INTO meta VALUES('schema_version', ?1)", [version]).unwrap();
    }
}

fn temp_root(name: &str) -> std::path::PathBuf {
    let root =
        std::env::temp_dir().join(format!("cmux-store-schemas-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn store_schemas_readable_names_every_rollback_store() {
    let readable = readable();
    assert_eq!(
        readable.get("workspace_registry"),
        Some(&crate::workspace_registry::SCHEMA_VERSION)
    );
    assert_eq!(
        readable.get("conversation_store"),
        Some(&crate::conversation_store::SCHEMA_VERSION)
    );
    assert_eq!(readable.len(), 2);
}

#[test]
fn store_schemas_stored_takes_the_newest_across_sessions() {
    let root = temp_root("newest");
    for (session, registry) in [("a-1", "14"), ("b-2", "15")] {
        let dir = root.join(session);
        std::fs::create_dir_all(&dir).unwrap();
        write_schema(&dir.join(crate::workspace_registry::WORKSPACE_REGISTRY_FILE), Some(registry));
    }
    write_schema(&root.join("a-1").join(crate::conversation_store::CONVERSATIONS_FILE), Some("2"));
    // A store without a schema yet, and a stray file at the root, add nothing.
    let empty = root.join("c-3");
    std::fs::create_dir_all(&empty).unwrap();
    write_schema(&empty.join(crate::conversation_store::CONVERSATIONS_FILE), None);
    std::fs::write(root.join("machine-id"), b"x").unwrap();

    let stored = stored(&root).unwrap();
    assert_eq!(stored.get("workspace_registry"), Some(&15));
    assert_eq!(stored.get("conversation_store"), Some(&2));
    assert_eq!(stored.len(), 2);
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn store_schemas_stored_is_empty_without_state() {
    let root = std::env::temp_dir().join(format!("cmux-store-schemas-none-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    assert!(stored(&root).unwrap().is_empty());
}

#[test]
fn store_schemas_stored_refuses_an_unreadable_schema() {
    let root = temp_root("invalid");
    let dir = root.join("a-1");
    std::fs::create_dir_all(&dir).unwrap();
    write_schema(&dir.join(crate::workspace_registry::WORKSPACE_REGISTRY_FILE), Some("fifteen"));
    assert!(stored(&root).is_err());
    std::fs::remove_dir_all(&root).unwrap();
}

#[test]
fn store_schemas_cli_prints_json_and_rejects_other_arguments() {
    let readable: BTreeMap<String, i64> = serde_json::from_str(&run(&[]).unwrap()).unwrap();
    assert_eq!(readable, super::readable());
    assert!(run(&["--bogus".to_string()]).is_err());
}
