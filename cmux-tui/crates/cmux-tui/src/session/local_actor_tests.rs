//! P8 landing 3b (plans/cmux-next/identity.md section 3): the workspace ops
//! of the in-process TUI (`Session::Local`) record the local user, never the
//! daemon. The rows are read back from the session's registry file.

use std::path::{Path, PathBuf};

use cmux_tui_core::SurfaceOptions;

use super::*;

/// The registry file under `dir`, at any depth.
fn registry_file(dir: &Path) -> Option<PathBuf> {
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if let Some(found) = registry_file(&path) {
                return Some(found);
            }
        } else if path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3") {
            return Some(path);
        }
    }
    None
}

/// The stored actors of `operation` in the `resource_mutations` ledger.
fn actors(root: &Path, operation: &str) -> Vec<String> {
    let path = registry_file(root).expect("the session's registry file");
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY;
    let connection = rusqlite::Connection::open_with_flags(path, flags).unwrap();
    let sql = "SELECT actor FROM resource_mutations WHERE operation = ?1";
    let mut statement = connection.prepare(sql).unwrap();
    statement
        .query_map([operation], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<Result<Vec<_>, _>>()
        .unwrap()
}

#[test]
fn local_workspace_ops_record_the_local_user() {
    let root = tempfile::tempdir().unwrap();
    let mux = Mux::open_persistent("tui-actor", SurfaceOptions::default(), root.path()).unwrap();
    let first = mux.create_empty_workspace(Some("one".into()), None, None).unwrap().workspace;
    mux.create_empty_workspace(Some("two".into()), None, None).unwrap();
    let session = Session::Local(mux);
    session.rename_workspace(first, "renamed".into()).unwrap();
    session.move_workspace(first, 2).unwrap();
    session.close_workspace(first).unwrap();
    for operation in ["workspace-renamed", "workspace-moved", "workspace-closed"] {
        assert_eq!(actors(root.path(), operation), ["user:user_local"], "{operation}");
    }
}
