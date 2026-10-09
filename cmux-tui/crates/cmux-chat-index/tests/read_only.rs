//! The read-only contract for SQLite stores: a scan creates no file in the
//! harness folder, reads a live WAL writer's committed rows, refuses a WAL
//! without its shared-memory file, and a failing DB never drops chats.

mod common;

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use cmux_chat_index::{AdapterKind, ChatIndex, ChatRoot, RootSource};
use common::{ids, scan};
use rusqlite::Connection;

fn listing(dir: &Path) -> BTreeSet<PathBuf> {
    fs::read_dir(dir).unwrap().flatten().map(|child| child.path()).collect()
}

fn opencode_db(path: &Path, wal: bool) -> Connection {
    let conn = Connection::open(path).unwrap();
    if wal {
        conn.pragma_update(None, "journal_mode", "wal").unwrap();
    }
    conn.execute_batch(
        "CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, title TEXT,
           time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
         INSERT INTO session (id, directory, title, time_created, time_updated)
           VALUES ('ses_1', '/w', 'One', 1, 2);",
    )
    .unwrap();
    conn
}

#[test]
fn a_scan_of_closed_stores_creates_no_file_and_takes_no_lock() {
    let dir = tempfile::tempdir().unwrap();
    for wal in [false, true] {
        let root = dir.path().join(if wal { "wal" } else { "rollback" });
        fs::create_dir_all(&root).unwrap();
        drop(opencode_db(&root.join("opencode.db"), wal));
        let before = listing(&root);
        assert_eq!(ids(&scan(AdapterKind::OpenCode, &root)), ["ses_1".to_owned()].into());
        assert_eq!(listing(&root), before, "wal={wal}: the scan created a file");
        // No lock held: a writer commits at once after the scan.
        let writer = Connection::open(root.join("opencode.db")).unwrap();
        writer.execute("UPDATE session SET title = 'Two' WHERE id = 'ses_1'", []).unwrap();
    }
}

#[test]
fn a_live_wal_writer_is_read_and_never_blocked() {
    let dir = tempfile::tempdir().unwrap();
    let writer = opencode_db(&dir.path().join("opencode.db"), true);
    writer
        .execute(
            "INSERT INTO session (id, directory, title, time_created, time_updated)
             VALUES ('ses_2', '/w', 'Live', 1, 3)",
            [],
        )
        .unwrap();
    assert!(
        dir.path().join("opencode.db-wal").exists() && dir.path().join("opencode.db-shm").exists()
    );
    assert_eq!(
        ids(&scan(AdapterKind::OpenCode, dir.path())),
        ["ses_1", "ses_2"].map(String::from).into()
    );
    writer.execute("DELETE FROM session WHERE id = 'ses_2'", []).unwrap();
}

#[test]
fn a_failing_db_keeps_the_last_chats_instead_of_removing_them() {
    let dir = tempfile::tempdir().unwrap();
    let root_path = dir.path().join("opencode");
    fs::create_dir_all(&root_path).unwrap();
    // WAL mode: the header tells SQLite to use the `-wal` and `-shm` files.
    drop(opencode_db(&root_path.join("opencode.db"), true));
    let root = ChatRoot {
        harness: AdapterKind::OpenCode,
        path: root_path.clone(),
        real_path: fs::canonicalize(&root_path).unwrap(),
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: Vec::new(),
    };
    let mut index = ChatIndex::new(vec![root]);
    index.rescan_all();
    assert_eq!(index.chats().len(), 1);
    // A WAL whose shared-memory file is gone: opening it would create one,
    // so the DB is refused and the scan fails.
    fs::write(root_path.join("opencode.db-wal"), b"").unwrap();
    let before = listing(&root_path);
    let changes = index.rescan_all();
    assert!(changes.is_empty(), "a failed scan changed the index: {changes:?}");
    assert_eq!(index.chats().len(), 1);
    assert_eq!(listing(&root_path), before, "the refused DB got a -shm file");
}
