//! Writes `machine-id` and `resource-effect-pepper` beside their place and
//! renames them in, so a full disk leaves each whole or absent. Earlier builds
//! wrote in place and ENOSPC left a short file that failed every later start;
//! such a file was never used (the value was returned only after its fsync),
//! so a cut one is replaced when nothing can depend on it.

#[allow(unused_imports)]
use super::*;

#[cfg(test)]
mod tests {
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
    }

    #[test]
    fn a_pepper_cut_by_a_full_disk_is_replaced_only_without_a_registry() {
        // A registry from schema 7 on has receipts bound to the pepper: the
        // cut file stays, and the start fails closed. Before 7 it is replaced.
        for (schema, replaced) in
            [(None, true), (Some(6), true), (Some(7), false), (Some(14), false)]
        {
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
                assert!(
                    error.contains("resource receipt pepper is corrupt"),
                    "{schema:?}: {error}"
                );
                assert_eq!(on_disk, b"cut", "{schema:?} keeps the file");
            }
            fs::remove_dir_all(root).unwrap();
        }
    }
}
