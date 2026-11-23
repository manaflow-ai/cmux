use super::*;

#[test]
fn writes_keeps_backup_and_mode() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("c.json");
    assert!(
        update(&file, |old| {
            assert!(old.is_none());
            Ok("one".into())
        })
        .unwrap()
    );
    assert!(!backup_path(&file).exists(), "no backup of a file that was not there");
    assert!(update(&file, |old| Ok(format!("{}+two", old.unwrap()))).unwrap());
    assert_eq!(fs::read_to_string(&file).unwrap(), "one+two");
    assert_eq!(fs::read_to_string(backup_path(&file)).unwrap(), "one");
    assert!(!update(&file, |old| Ok(old.unwrap().to_owned())).unwrap(), "no change, no write");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    }
    let leftovers: Vec<_> = fs::read_dir(dir.path())
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
        .collect();
    assert!(leftovers.is_empty());
}

#[test]
fn a_write_under_it_is_kept() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("c.json");
    fs::write(&file, "agent-1").unwrap();
    let mut calls = 0;
    update(&file, |old| {
        calls += 1;
        if calls == 1 {
            // The agent writes between cmux's read and its rename.
            fs::write(&file, "agent-2 longer").unwrap();
        }
        Ok(format!("{}+cmux", old.unwrap()))
    })
    .unwrap();
    assert_eq!(calls, 2);
    assert_eq!(fs::read_to_string(&file).unwrap(), "agent-2 longer+cmux");
}
