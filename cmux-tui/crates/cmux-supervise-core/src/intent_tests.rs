use super::*;

#[test]
fn an_intent_covers_its_epoch_and_older_never_a_newer_start() {
    let dir = std::env::temp_dir().join(format!("supervise-intent-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let intent = Intent::new(dir.join("stop-intent.json"));
    assert!(intent.meant(1).is_none());
    intent.record("person quit", 3).unwrap();
    assert_eq!(intent.meant(3).unwrap().reason, "person quit");
    assert!(intent.meant(2).is_some());
    assert!(intent.meant(4).is_none(), "a start after the quit is not covered");
    intent.clear().unwrap();
    intent.clear().unwrap();
    assert!(intent.read().is_none());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_intent_file_that_does_not_parse_still_means_stop() {
    let dir = std::env::temp_dir().join(format!("supervise-intent-torn-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let intent = Intent::new(dir.join("stop-intent.json"));
    std::fs::write(intent.path(), b"{\"reason\": \"person q").unwrap();
    assert!(intent.meant(7).unwrap().reason.contains("cannot be read"));
    intent.clear().unwrap();
    assert!(intent.meant(7).is_none(), "an explicit start ends it");
    let _ = std::fs::remove_dir_all(&dir);
}
