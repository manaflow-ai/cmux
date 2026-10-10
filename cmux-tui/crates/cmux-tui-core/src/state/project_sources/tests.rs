//! The editor project sources (plans/cmux-next/projects.md section 3), against fixture folders laid
//! out as each editor writes them (formats read from installed VS Code, Cursor and Zed, 2026-10-09).

use std::path::{Path, PathBuf};

use super::*;

fn fixture_home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("cmux-project-sources-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    home
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn vscdb(path: &Path, recent: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = rusqlite::Connection::open(path).unwrap();
    db.execute_batch("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        .unwrap();
    db.execute(
        "INSERT INTO ItemTable(key, value) VALUES('history.recentlyOpenedPathsList', ?1)",
        [recent],
    )
    .unwrap();
}

fn paths(scan: &SourceScan) -> Vec<&str> {
    scan.entries.iter().map(|entry| entry.path.as_str()).collect()
}

#[test]
fn project_sources_vscode_family_reads_recent_folders_newest_first_and_skips_remote_and_files() {
    let home = fixture_home("vscode");
    let support = home.join("Library/Application Support");
    vscdb(
        &support.join("Cursor/User/globalStorage/state.vscdb"),
        r#"{"entries":[
            {"folderUri":"file:///Users/me/src/app"},
            {"folderUri":"vscode-remote://ssh-remote%2Bbox/home/me/x"},
            {"fileUri":"file:///Users/me/notes.md"},
            {"folderUri":"file:///Users/me/My%20Projects/web"},
            {"workspace":{"id":"1","configPath":"file:///Users/me/w.code-workspace"}}
        ]}"#,
    );
    write(
        &support.join("Code/User/globalStorage/storage.json"),
        r#"{"profileAssociations":{"workspaces":{"file:///Users/me/src/api":"__default__profile__"},"emptyWindows":{}}}"#,
    );
    let scans = scan_vscode_family(&Layout::macos(&home));
    let cursor = scans.iter().find(|scan| scan.source == "cursor").expect("cursor scanned");
    assert_eq!(paths(cursor), vec!["/Users/me/src/app", "/Users/me/My Projects/web"]);
    assert!(
        cursor.entries[0].last_used_ms > cursor.entries[1].last_used_ms,
        "newest first keeps its order"
    );
    let code = scans.iter().find(|scan| scan.source == "vscode").expect("vscode scanned");
    assert_eq!(paths(code), vec!["/Users/me/src/api"]);
    assert!(
        scans.iter().all(|scan| scan.source != "windsurf"),
        "an editor that is not installed reports nothing"
    );
}

#[test]
fn project_sources_zed_reads_local_workspace_roots_and_skips_remote_and_file_roots() {
    let home = fixture_home("zed");
    let db_path = home.join("Library/Application Support/Zed/db/0-stable/db.sqlite");
    std::fs::create_dir_all(db_path.parent().unwrap()).unwrap();
    let db = rusqlite::Connection::open(&db_path).unwrap();
    db.execute_batch(
        "CREATE TABLE workspaces (workspace_id INTEGER PRIMARY KEY, paths TEXT, paths_order TEXT,
           remote_connection_id INTEGER, timestamp TEXT DEFAULT CURRENT_TIMESTAMP NOT NULL);
         INSERT INTO workspaces VALUES (1, '/Users/me/src/app', '0', NULL, '2026-10-02 00:31:29');
         INSERT INTO workspaces VALUES (2, '/Users/me/src/one' || char(10) || '/Users/me/src/two/main.rs', '0,1', NULL, '2026-09-28 05:53:28');
         INSERT INTO workspaces VALUES (3, '/home/me/remote', '0', 7, '2026-10-03 00:00:00');",
    )
    .unwrap();
    let scan = scan_zed(&Layout::macos(&home)).expect("zed scanned");
    assert_eq!(scan.source, "zed");
    assert_eq!(paths(&scan), vec!["/Users/me/src/app", "/Users/me/src/one"]);
    assert_eq!(scan.entries[0].last_used_ms, 1_790_901_089_000, "UTC timestamp to ms");
}

#[test]
fn project_sources_missing_or_corrupt_files_report_nothing() {
    let home = fixture_home("corrupt");
    let support = home.join("Library/Application Support");
    write(&support.join("Code/User/globalStorage/storage.json"), "{not json");
    write(&support.join("Zed/db/0-stable/db.sqlite"), "not a database");
    assert!(scan_vscode_family(&Layout::macos(&home)).iter().all(|scan| scan.entries.is_empty()));
    assert!(scan_zed(&Layout::macos(&home)).is_none_or(|scan| scan.entries.is_empty()));
    let empty = fixture_home("empty");
    assert!(scan_vscode_family(&Layout::macos(&empty)).is_empty());
    assert!(scan_zed(&Layout::macos(&empty)).is_none());
}

#[test]
fn project_sources_linux_and_windows_layouts_name_each_editors_folder() {
    let home = Path::new("/home/me");
    let linux = Layout::linux(home, None, None);
    assert_eq!(linux.vscode_user_dir("Code"), PathBuf::from("/home/me/.config/Code/User"));
    assert_eq!(linux.zed_db(), PathBuf::from("/home/me/.local/share/zed/db/0-stable/db.sqlite"));
    let xdg = Layout::linux(home, Some(Path::new("/x/config")), Some(Path::new("/x/data")));
    assert_eq!(xdg.vscode_user_dir("Cursor"), PathBuf::from("/x/config/Cursor/User"));
    assert_eq!(xdg.zed_db(), PathBuf::from("/x/data/zed/db/0-stable/db.sqlite"));
    let windows = Layout::windows(
        Path::new("C:/Users/me/AppData/Roaming"),
        Path::new("C:/Users/me/AppData/Local"),
    );
    assert_eq!(
        windows.vscode_user_dir("Code"),
        PathBuf::from("C:/Users/me/AppData/Roaming/Code/User")
    );
    assert_eq!(
        windows.zed_db(),
        PathBuf::from("C:/Users/me/AppData/Local/Zed/db/0-stable/db.sqlite")
    );
}
