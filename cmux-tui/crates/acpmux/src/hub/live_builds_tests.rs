use super::*;
use std::time::SystemTime;

fn now_ms() -> u64 {
    epoch_ms(SystemTime::now())
}

#[test]
fn a_beacon_names_its_tree_surface_and_time() {
    let built = parse(r#"{"at": 1700000000000, "surface": "rust", "tree": "/w/cmux"}"#).unwrap();
    assert_eq!(built, Built { surface: "rust".into(), tree: "/w/cmux".into(), at: 1700000000000 });
    assert_eq!(parse(r#"{"at": 1, "tree": "/w"}"#).unwrap().surface, "build");
    for not_one in
        ["", "{}", r#"{"at": 1}"#, r#"{"tree": "/w"}"#, r#"{"at": 1, "tree": " "}"#, "nope"]
    {
        assert_eq!(parse(not_one), None, "{not_one}");
    }
}

#[test]
fn a_new_beacon_is_seen_once_and_an_old_one_never() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("live-build-done.json");
    let mut seen = None;
    assert_eq!(changed(&path, &mut seen), None, "no beacon yet");

    std::fs::write(&path, format!(r#"{{"at": {}, "surface": "rust", "tree": "/w"}}"#, now_ms()))
        .unwrap();
    assert_eq!(changed(&path, &mut seen).map(|b| b.tree), Some("/w".to_owned()));
    assert_eq!(changed(&path, &mut seen), None, "the same beacon asks once");

    // A beacon from a swap long ago (a copied home): seen, no frame.
    let old = now_ms() - FRESH.as_millis() as u64 - 1000;
    std::fs::write(&path, format!(r#"{{"at": {old}, "tree": "/w"}}"#)).unwrap();
    let file = std::fs::File::options().write(true).open(&path).unwrap();
    file.set_modified(SystemTime::now() + Duration::from_secs(5)).unwrap();
    assert_eq!(changed(&path, &mut seen), None);
    assert!(seen.is_some());
}

#[test]
fn the_beacon_lives_in_the_user_cache() {
    let path = beacon_path().unwrap();
    assert!(path.ends_with("cmux-next/live-build-done.json"), "{path:?}");
}
