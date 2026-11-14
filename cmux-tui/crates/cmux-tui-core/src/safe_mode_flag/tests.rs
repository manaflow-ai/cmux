use super::*;

fn temp() -> PathBuf {
    let mut bytes = [0u8; 8];
    getrandom::fill(&mut bytes).unwrap();
    let dir = std::env::temp_dir().join(format!(
        "cmux-safe-mode-flag-{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn a_written_flag_reads_back_and_off_removes_the_file() {
    let dir = temp();
    let path = path_in(&dir.join("not-yet"));
    assert_eq!(read(&path), None, "a missing file is off");
    let flag = Flag {
        on: true,
        reason: Reason::CrashLoop,
        since_ms: 42,
        extensions: vec!["local/customize".into()],
    };
    write(&path, Some(&flag)).unwrap();
    assert_eq!(read(&path), Some(flag));
    let raw: serde_json::Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(raw["reason"], "crash-loop");
    assert_eq!(raw["sinceMs"], 42);
    write(&path, None).unwrap();
    assert!(!path.exists());
    write(&path, None).unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_broken_or_unknown_file_is_off() {
    let dir = temp();
    let path = path_in(&dir);
    std::fs::write(&path, b"{not json").unwrap();
    assert_eq!(read(&path), None);
    std::fs::write(&path, br#"{"version":2,"on":true,"reason":"user","sinceMs":1}"#).unwrap();
    assert_eq!(read(&path), None, "a future version is not guessed at");
    std::fs::write(&path, br#"{"version":1,"on":false,"reason":"user","sinceMs":1}"#).unwrap();
    assert_eq!(read(&path), None);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn env_values() {
    for yes in ["1", "true", "YES", " on "] {
        assert!(env_requests(Some(yes)), "{yes}");
    }
    for no in [None, Some(""), Some("0"), Some("false"), Some("off")] {
        assert!(!env_requests(no), "{no:?}");
    }
}
