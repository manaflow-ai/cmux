use super::*;

#[test]
fn the_icon_line_is_set_replaced_and_removed_at_the_top_level_only() {
    let base = "schema = 1\nid = \"a\"\nname = \"A\"\ncommand = \"a\"\n\n[env]\nicon = \"x\"\n";
    let set = with_icon(base, Some("🦊"));
    assert_eq!(
        set,
        "schema = 1\nid = \"a\"\nname = \"A\"\nicon = \"🦊\"\ncommand = \"a\"\n\n[env]\nicon = \"x\"\n"
    );
    assert_eq!(top_level_icon(&set).as_deref(), Some("🦊"));
    let replaced = with_icon(&set, Some("hammer.fill"));
    assert!(replaced.contains("icon = \"hammer.fill\"\ncommand"), "{replaced}");
    assert_eq!(replaced.matches("icon = ").count(), 2, "{replaced}");
    assert_eq!(with_icon(&replaced, None), base);
    assert_eq!(top_level_icon(base), None);
    // No name line: after id.
    assert_eq!(
        with_icon("id = \"b\"\ncommand = \"b\"\n", Some("x")),
        "id = \"b\"\nicon = \"x\"\ncommand = \"b\"\n"
    );
}
