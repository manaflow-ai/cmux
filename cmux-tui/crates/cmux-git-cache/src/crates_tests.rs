use super::*;

#[test]
fn config_replaces_crates_io() {
    let t = cargo_config_text(47380);
    assert!(t.starts_with(HEADER));
    assert!(t.contains("[source.crates-io]\nreplace-with = \"cmux-crates-cache\"\n"));
    assert!(t.contains("registry = \"sparse+http://127.0.0.1:47380/crates/index/\""));
}

#[test]
fn segments_refuse_traversal() {
    assert!(safe_segment("serde_json"));
    assert!(safe_segment("1.0.0+wasi-0.2"));
    for bad in ["", ".", "..", "a/b", "a b", "%2e%2e"] {
        assert!(!safe_segment(bad), "{bad}");
    }
    assert!(safe_index_path("se/rd/serde"));
    assert!(safe_index_path("3/s/syn"));
    assert!(!safe_index_path("../etc/passwd"));
    assert!(!safe_index_path("a/../../b"));
    assert!(!safe_index_path("/abs"));
}

#[test]
fn remove_only_ours() {
    let dir = tempfile::tempdir().unwrap();
    let ours = dir.path().join("config.toml");
    crate::gitconfig::write_include(&ours, &cargo_config_text(1)).unwrap();
    remove_cargo_config(&ours);
    assert!(!ours.exists());
    std::fs::write(&ours, "[build]\n").unwrap();
    remove_cargo_config(&ours);
    assert!(ours.exists());
}
