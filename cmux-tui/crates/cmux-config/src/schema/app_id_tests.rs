#[test]
fn the_manifest_schema_has_an_app_id_pattern() {
    assert!(super::app_id_pattern().is_some());
    assert!(super::is_valid_app_id("local/web-pane"));
    assert!(!super::is_valid_app_id("Foo/Bar"));
}
