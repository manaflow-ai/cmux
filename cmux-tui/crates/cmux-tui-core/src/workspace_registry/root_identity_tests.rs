use super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-root-identity-{label}-{}", new_uuid_v4()))
}

#[test]
fn a_machine_id_cut_by_a_full_disk_is_replaced_and_a_foreign_one_is_not() {
    for cut in [&b""[..], b"mach", b"machine_", b"machine_0123abcd"] {
        let root = temp_root("machine-cut");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join(MACHINE_ID_FILE), cut).unwrap();
        let id = load_or_create_machine_id(&root).unwrap();
        let written = fs::read(root.join(MACHINE_ID_FILE)).unwrap();
        assert_eq!(written, format!("{}\n", id.as_str()).into_bytes());
        assert_eq!(load_or_create_machine_id(&root).unwrap(), id, "created once");
        assert!(!root.join("machine-id.new").exists());
        fs::remove_dir_all(root).unwrap();
    }
    assert!(!is_cut_machine_id(b"machine_not-an-id\n"));
    assert!(!is_cut_machine_id(b"machine_0123\n"));
    assert!(!is_cut_machine_id(b"xmachine_"));
    assert!(!is_cut_machine_id(format!("machine_{}", "a".repeat(32)).as_bytes()));
}

#[test]
fn a_pepper_cut_by_a_full_disk_is_replaced_only_without_a_registry() {
    // A registry from schema 7 on has receipts bound to the pepper: the
    // cut file stays, and the start fails closed. Before 7 it is replaced.
    for (schema, replaced) in [(None, true), (Some(6), true), (Some(7), false), (Some(14), false)] {
        let root = temp_root("pepper-cut");
        let session = root.join("session");
        fs::create_dir_all(&session).unwrap();
        if let Some(schema) = schema {
            Connection::open(session.join(WORKSPACE_REGISTRY_FILE))
                .unwrap()
                .execute_batch(&format!(
                    "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                         INSERT INTO meta VALUES('schema_version', '{schema}');"
                ))
                .unwrap();
        }
        fs::write(root.join(RESOURCE_EFFECT_PEPPER_FILE), b"cut").unwrap();
        let loaded = load_or_create_resource_effect_pepper(&root);
        let on_disk = fs::read(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
        if replaced {
            assert_eq!(on_disk, loaded.unwrap().0.as_ref(), "{schema:?}");
            assert!(!root.join("resource-effect-pepper.new").exists());
        } else {
            let error = format!("{:#}", loaded.err().expect("fails closed"));
            assert!(error.contains("resource receipt pepper is corrupt"), "{schema:?}: {error}");
            assert_eq!(on_disk, b"cut", "{schema:?} keeps the file");
        }
        fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn an_identity_write_never_replaces_a_file_and_leaves_no_temporary() {
    let root = temp_root("identity-write");
    fs::create_dir_all(&root).unwrap();
    let path = root.join(MACHINE_ID_FILE);
    // A stale temporary file from a killed writer does not block one.
    fs::write(root.join("machine-id.new"), b"stale").unwrap();
    write_identity_file(&root, &path, b"first\n", false).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"first\n");
    let error = write_identity_file(&root, &path, b"second\n", false).unwrap_err();
    assert!(error.to_string().contains("appeared while it was written"), "{error:#}");
    assert_eq!(fs::read(&path).unwrap(), b"first\n");
    assert!(!root.join("machine-id.new").exists());
    write_identity_file(&root, &path, b"third\n", true).unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"third\n");
    // A failed write (here the target is a directory) leaves nothing beside it.
    let blocked = root.join("blocked");
    fs::create_dir_all(blocked.join("child")).unwrap();
    assert!(write_identity_file(&root, &blocked, b"x", true).is_err());
    assert!(!root.join("blocked.new").exists());
    fs::remove_dir_all(root).unwrap();
}
