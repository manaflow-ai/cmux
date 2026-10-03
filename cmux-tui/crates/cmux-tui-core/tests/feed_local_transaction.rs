//! B2 (plans/cmux-next/feed.md 9.1): a notification and its local feed post
//! are one SQLite transaction. Only public API plus a second connection to
//! the registry file, so this test also runs against a daemon without the
//! local feed owner (where it fails: the table does not exist).
#![cfg(unix)]

use std::path::{Path, PathBuf};

use cmux_tui_core::{Mux, NotificationLevel, SurfaceOptions};

fn registry_file(root: &Path) -> PathBuf {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                stack.push(path);
            } else if path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3") {
                return path;
            }
        }
    }
    panic!("no workspace registry under {}", root.display());
}

fn committed_creates(db: &rusqlite::Connection) -> i64 {
    db.query_row(
        "SELECT COUNT(*) FROM resource_effect_receipts
         WHERE operation = 'notification.create' AND state = 'committed'",
        [],
        |row| row.get(0),
    )
    .unwrap()
}

#[test]
fn cmux_next_feed_local_post_commits_in_the_notification_transaction() {
    let root = std::env::temp_dir().join(format!("cmux-feed-b2-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let options = || SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "sleep 60".into()]),
        ..Default::default()
    };
    let session = format!("feed-b2-{}", std::process::id());
    let mux = Mux::open_persistent(session, options(), &root).unwrap();
    let surface = mux.new_workspace(None, None).unwrap();
    mux.post_notification("first".into(), "".into(), NotificationLevel::Info, Some(surface.id))
        .unwrap();

    let db = rusqlite::Connection::open(registry_file(&root)).unwrap();
    db.busy_timeout(std::time::Duration::from_secs(5)).unwrap();
    let items: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM feed_local_items WHERE item_json LIKE '%\"title\":\"first\"%'",
            [],
            |row| row.get(0),
        )
        .expect("the notification's local feed item is committed with it");
    assert_eq!(items, 1);
    assert_eq!(committed_creates(&db), 1);

    // Refuse every feed write: the notification must not commit without it.
    db.execute_batch(
        "CREATE TRIGGER refuse_feed_insert BEFORE INSERT ON feed_local_items
           BEGIN SELECT RAISE(ABORT, 'feed write refused'); END;
         CREATE TRIGGER refuse_feed_update BEFORE UPDATE ON feed_local_items
           BEGIN SELECT RAISE(ABORT, 'feed write refused'); END;",
    )
    .unwrap();
    let refused = mux.post_notification(
        "second".into(),
        "".into(),
        NotificationLevel::Info,
        Some(surface.id),
    );
    assert!(refused.is_err(), "a failed feed write fails the notification commit");
    assert_eq!(committed_creates(&db), 1, "no receipt without its feed post");
    db.execute_batch("DROP TRIGGER refuse_feed_insert; DROP TRIGGER refuse_feed_update;").unwrap();
    let feed_rows: i64 =
        db.query_row("SELECT COUNT(*) FROM feed_local_items", [], |row| row.get(0)).unwrap();
    assert_eq!(feed_rows, 1, "the refused post left no feed row");
    // A post after the refusal commits both again.
    mux.post_notification("third".into(), "".into(), NotificationLevel::Info, Some(surface.id))
        .unwrap();
    assert_eq!(committed_creates(&db), 2);
    drop(db);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
}
