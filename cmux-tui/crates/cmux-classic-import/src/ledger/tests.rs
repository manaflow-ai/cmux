use super::*;

#[test]
fn a_ledger_round_trips() {
    let root = tempfile::tempdir().unwrap();
    let folder = Folder::new(root.path().join("m"));
    assert_eq!(folder.load(), Load::None);
    let mut ledger = Ledger::new(State::Completed);
    ledger.groups.insert("g".into(), "grp_1".into());
    ledger.runs = 2;
    ledger.workspaces.insert("k".into(), Entry::new(Stage::Done, Some("w"), None));
    folder.save(&ledger).unwrap();
    assert_eq!(folder.load(), Load::Ledger(ledger));
}

/// A ledger an earlier build wrote reads here, and this build's reads there.
#[test]
fn the_earlier_builds_ledger_json_reads_and_is_written_the_same_way() {
    let earlier = r#"{
          "appVersion" : "0.70.1",
          "groups" : { "11111111-1111-4111-8111-111111111111" : "grp_1" },
          "runs" : 1,
          "schema" : 1,
          "source" : { "bundleID" : "com.cmuxterm.app", "createdAt" : 1761000000.5, "modifiedAt" : 1761000001.75,
                       "path" : "/s/session-com.cmuxterm.app.json", "size" : 4096 },
          "state" : "inProgress",
          "updatedAt" : 1761000002.25,
          "workspaces" : {
            "a" : { "nextWorkspace" : "ws_1", "stage" : "done" },
            "b" : { "stage" : "pending" },
            "c" : { "reason" : "cloud-vm", "stage" : "skipped" }
          }
        }"#;
    let ledger: Ledger = serde_json::from_str(earlier).unwrap();
    assert_eq!(ledger.state, State::InProgress);
    assert_eq!(ledger.source.as_ref().unwrap().bundle_id, "com.cmuxterm.app");
    assert_eq!(ledger.workspaces["c"], Entry::new(Stage::Skipped, None, Some("cloud-vm")));
    let written = serde_json::to_value(&ledger).unwrap();
    assert_eq!(written, serde_json::from_str::<serde_json::Value>(earlier).unwrap());
}

/// A newer cmux NEXT's ledger is left as it is; this build only stops.
#[test]
fn a_newer_ledger_is_left_alone() {
    let root = tempfile::tempdir().unwrap();
    let folder = Folder::new(root.path().join("m"));
    std::fs::create_dir_all(&folder.directory).unwrap();
    std::fs::write(folder.ledger_path(), r#"{"schema":7,"future":true}"#).unwrap();
    assert_eq!(folder.load(), Load::Newer(7));
    assert_eq!(
        std::fs::read_to_string(folder.ledger_path()).unwrap(),
        r#"{"schema":7,"future":true}"#
    );
}

/// A ledger that is there but cannot be read is not a first run.
#[test]
fn a_ledger_that_cannot_be_read_is_not_a_first_run() {
    let root = tempfile::tempdir().unwrap();
    let folder = Folder::new(root.path().join("m"));
    std::fs::create_dir_all(folder.ledger_path()).unwrap();
    assert!(matches!(folder.load(), Load::Failed(_)));
    assert!(folder.ledger_path().is_dir());
}

#[test]
fn a_damaged_ledger_is_moved_aside() {
    let root = tempfile::tempdir().unwrap();
    let folder = Folder::new(root.path().join("m"));
    std::fs::create_dir_all(&folder.directory).unwrap();
    std::fs::write(folder.ledger_path(), "{not json").unwrap();
    assert_eq!(folder.load(), Load::Unreadable);
    let names: Vec<String> = std::fs::read_dir(&folder.directory)
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().into_string().unwrap())
        .collect();
    assert!(!names.contains(&"ledger.json".to_string()));
    assert!(names.iter().any(|name| name.starts_with("ledger.unreadable-")), "{names:?}");
}

/// Backups copy classic's files; the originals keep their bytes and dates.
#[test]
fn backups_copy_and_never_touch_classic_files() {
    let root = tempfile::tempdir().unwrap();
    let session = root.path().join("support/cmux/session-com.cmuxterm.app.json");
    std::fs::create_dir_all(session.parent().unwrap()).unwrap();
    std::fs::write(&session, "{\"windows\":[]}").unwrap();
    let date = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
    std::fs::File::options().write(true).open(&session).unwrap().set_modified(date).unwrap();
    let folder = Folder::new(root.path().join("m"));
    for index in 0..7 {
        let made = folder
            .backup(
                &[session.clone(), root.path().join("missing.json")],
                &format!("2026101{index}"),
            )
            .unwrap()
            .unwrap();
        assert_eq!(
            std::fs::read(made.join("session-com.cmuxterm.app.json")).unwrap(),
            b"{\"windows\":[]}"
        );
    }
    assert_eq!(std::fs::read(&session).unwrap(), b"{\"windows\":[]}");
    assert_eq!(std::fs::metadata(&session).unwrap().modified().unwrap(), date);
    let mut kept: Vec<String> = std::fs::read_dir(folder.backups_path())
        .unwrap()
        .flatten()
        .map(|entry| entry.file_name().into_string().unwrap())
        .collect();
    kept.sort();
    assert_eq!(kept, (2..7).map(|index| format!("2026101{index}")).collect::<Vec<_>>());
    assert_eq!(folder.backup(&[root.path().join("missing.json")], "x").unwrap(), None);
}

#[test]
fn a_backup_stamp_is_the_utc_time_then_its_suffix() {
    assert_eq!(backup_stamp(0, "ab12"), "19700101T000000Z-ab12");
    assert_eq!(backup_stamp(1_794_133_715, "x"), "20261108T102835Z-x");
    assert_eq!(backup_stamp(951_782_400, "x"), "20000229T000000Z-x");
}

#[test]
fn the_folder_is_named_only_by_a_plain_bundle_id() {
    let home = Path::new("/Users/me");
    assert_eq!(
            default_directory(home, "com.cmuxterm.app.nightly.cmux-next").unwrap(),
            home.join("Library/Application Support/cmux-next/com.cmuxterm.app.nightly.cmux-next/classic-migration")
        );
    for bad in ["", "../x", "a/b", ".hidden", "a..b"] {
        assert_eq!(default_directory(home, bad), None, "{bad}");
    }
}
