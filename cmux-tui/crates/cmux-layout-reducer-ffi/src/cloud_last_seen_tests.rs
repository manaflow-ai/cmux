use super::*;

const NOW: i64 = 1_800_000_000_000;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-last-seen-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn rows() -> Vec<Row> {
    vec![Row {
        id: "m1".into(),
        name: "box".into(),
        stage: "paused".into(),
        evict_at: None,
        size: None,
    }]
}

#[test]
fn saves_loads_and_forgets() {
    let dir = temp_dir("roundtrip");
    let d = dir.to_string_lossy().into_owned();
    let saved = save(&Save {
        dir: d.clone(),
        user: "u".into(),
        team: Some("t".into()),
        at: NOW,
        machines: rows(),
    });
    assert_eq!(saved, json!({"ok": true, "written": true}));
    let loaded =
        load(&Load { dir: d.clone(), user: "u".into(), team: Some("t".into()), now: NOW + 1 });
    assert_eq!(loaded["snapshot"]["machines"][0]["id"], "m1");
    assert_eq!(loaded["snapshot"]["at"], NOW);
    // Another team reads nothing.
    let other = load(&Load { dir: d.clone(), user: "u".into(), team: Some("t2".into()), now: NOW });
    assert_eq!(other, json!({"snapshot": null}));
    // A file of someone else's beside the lists stays.
    fs::write(dir.join(FOLDER).join("keep.json"), "{}").unwrap();
    assert_eq!(forget(&Forget { dir: d.clone() }), json!({"removed": 1}));
    assert!(dir.join(FOLDER).join("keep.json").exists());
    let gone = load(&Load { dir: d, user: "u".into(), team: Some("t".into()), now: NOW });
    assert_eq!(gone, json!({"snapshot": null}));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn signed_out_or_no_folder_keeps_nothing() {
    let dir = temp_dir("signedout");
    let d = dir.to_string_lossy().into_owned();
    assert_eq!(
        save(&Save { dir: d, user: String::new(), team: None, at: NOW, machines: rows() }),
        json!({"ok": false, "written": false})
    );
    assert_eq!(
        save(&Save { dir: String::new(), user: "u".into(), team: None, at: NOW, machines: rows() }),
        json!({"ok": false, "written": false})
    );
    assert!(!dir.join(FOLDER).exists());
    let _ = fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn the_file_is_private() {
    use std::os::unix::fs::PermissionsExt;
    let dir = temp_dir("mode");
    let d = dir.to_string_lossy().into_owned();
    save(&Save { dir: d, user: "u".into(), team: None, at: NOW, machines: rows() });
    let path = dir.join(FOLDER).join(last_seen::file_name("u", None));
    assert_eq!(fs::metadata(path).unwrap().permissions().mode() & 0o777, 0o600);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn an_unchanged_list_is_not_written_twice() {
    let dir = temp_dir("dedupe");
    let d = dir.to_string_lossy().into_owned();
    let save_at = |at: i64, machines: Vec<Row>| {
        save(&Save { dir: d.clone(), user: "u".into(), team: None, at, machines })
    };
    assert_eq!(save_at(NOW, rows()), json!({"ok": true, "written": true}));
    let path = dir.join(FOLDER).join(last_seen::file_name("u", None));
    let first = fs::read_to_string(&path).unwrap();
    // The same rows a minute later: on disk already, the file (and its time) unchanged.
    assert_eq!(save_at(NOW + 60_000, rows()), json!({"ok": true, "written": false}));
    assert_eq!(fs::read_to_string(&path).unwrap(), first);
    // A change is written; so is the same list an hour on.
    let mut changed = rows();
    changed[0].stage = "ready".into();
    assert_eq!(save_at(NOW + 120_000, changed.clone()), json!({"ok": true, "written": true}));
    assert_eq!(
        save_at(NOW + 120_000 + last_seen::REWRITE_AFTER_MS, changed),
        json!({"ok": true, "written": true})
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn forget_removes_leftover_temporary_files() {
    let dir = temp_dir("leftover");
    let d = dir.to_string_lossy().into_owned();
    let folder = dir.join(FOLDER);
    fs::create_dir_all(&folder).unwrap();
    let kept = last_seen::file_name("u", Some("t"));
    // A write interrupted between its write and its rename, by this process or an earlier one.
    fs::write(folder.join(format!("{kept}.4242.tmp")), "{").unwrap();
    fs::write(folder.join(format!("{kept}.{}.tmp", std::process::id())), "{").unwrap();
    // Someone else's temporary file stays.
    fs::write(folder.join("other.json.1.tmp"), "{").unwrap();
    assert_eq!(forget(&Forget { dir: d }), json!({"removed": 2}));
    assert!(folder.join("other.json.1.tmp").exists());
    assert_eq!(fs::read_dir(&folder).unwrap().count(), 1);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn refresh_due_backs_off() {
    let due = |failures: u32, since: Option<i64>| {
        refresh_due(&RefreshDue { failures, since_last_ms: since })
    };
    assert_eq!(due(0, None), json!({"due": true, "waitMs": 0}));
    assert_eq!(due(1, Some(1_000)), json!({"due": false, "waitMs": 2_000}));
    assert_eq!(due(1, Some(2_000)), json!({"due": true, "waitMs": 2_000}));
    assert_eq!(due(30, Some(60_000))["due"], false);
}
