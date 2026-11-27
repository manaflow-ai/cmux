use super::Capability;

#[test]
fn keys_map_to_their_capability() {
    assert_eq!(Capability::of_key("appearance.background"), Capability::Backgrounds);
    assert_eq!(Capability::of_key("appearance.backgroundOpacity"), Capability::Backgrounds);
    assert_eq!(Capability::of_key("ui.animationSpeed"), Capability::Motion);
    assert_eq!(Capability::of_key("appearance.tabShape"), Capability::Tabs);
    assert_eq!(Capability::of_key("appearance.metrics.tabHeight"), Capability::Tabs);
    assert_eq!(Capability::of_key("terminal.fontFamily"), Capability::Fonts);
    assert_eq!(Capability::of_key("appearance.metrics.chromeFontSize"), Capability::Fonts);
    assert_eq!(Capability::of_key("sidebar.sectionLook"), Capability::Components);
    assert_eq!(Capability::of_key("appearance.accent"), Capability::Tokens);
    // The terminal palette is colors, however it is written.
    assert_eq!(Capability::of_key("ghostty"), Capability::Colors);
    assert_eq!(Capability::of_key("colors"), Capability::Colors);
    assert_eq!(Capability::of_key("appearance.themeEdits"), Capability::Colors);
    assert_eq!(Capability::of_key("appearance.themeEdits.Nord/background"), Capability::Colors);
    assert_eq!(Capability::of_key("colorsish"), Capability::Tokens);
    assert_eq!(Capability::of_key("slots"), Capability::Components);
}

#[test]
fn names_round_trip() {
    for capability in Capability::ALL {
        assert_eq!(Capability::parse(capability.name()), Some(capability));
    }
    assert_eq!(Capability::parse("shell"), None);
}
