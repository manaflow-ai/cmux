use super::*;

#[test]
fn the_table_has_cmux_roles_and_every_apple_style_name() {
    let names: Vec<&str> = roles().iter().map(|r| r.name.as_str()).collect();
    assert_eq!(names, ["numeral", "heading", "title", "label", "body", "caption", "footnote"]);
    for apple in [
        "largeTitle",
        "title",
        "title2",
        "title3",
        "headline",
        "body",
        "callout",
        "subheadline",
        "footnote",
        "caption",
        "caption2",
    ] {
        assert!(named(apple).is_some(), "{apple} has a row");
    }
    for style in apple_styles() {
        let role = style.role.as_deref().and_then(named).expect("a style names a role");
        assert_eq!(role.size, style.size, "{} names the role at its size", style.name);
    }
}

/// The SDK's `TYPE_ROLES` (tokens.ts) is a copy an extension bundles, so it cannot import the
/// table; it must say the same sizes and weights.
#[test]
fn the_sdk_type_roles_match_the_table() {
    let tokens = include_str!("../../../../cmux-extension-sdk/typescript/src/tokens.ts");
    for role in roles() {
        let row = format!("{}: {{ size: {}, weight: \"{}\" }}", role.name, role.size, role.weight);
        assert!(tokens.contains(&row), "tokens.ts TYPE_ROLES has `{row}`");
    }
}
