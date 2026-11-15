//! The native sidebar and palette share one discoverable customization action.
use cmux_action_catalog::{Decision, PALETTE, find, strings};

#[test]
fn sidebar_customization_is_discoverable_and_localized() {
    let action = find("sidebar.customize").expect("sidebar customization action");
    assert_ne!(action.surfaces & PALETTE, 0);
    assert_eq!(action.surface_plan.palette, Decision::Offered);
    // First row of the sidebar menu's Options folder: the menu's top level is full
    // (ActionSurfaceParityTests.everyMenuKeepsAShortTopLevel caps it at 12 rows).
    let placement = action
        .surface_plan
        .context_menus
        .iter()
        .find(|placement| placement.context == "sidebarBackground")
        .expect("placed in the sidebar's menu");
    assert!(placement.parent.is_none());
    assert_eq!(placement.folder, Some("options"));
    // It leads the folder's view rows.
    let first_view_option = cmux_action_catalog::actions()
        .flat_map(|other| other.surface_plan.context_menus.iter())
        .filter(|other| {
            other.context == "sidebarBackground"
                && other.folder == Some("options")
                && other.group == placement.group
        })
        .map(|other| other.rank)
        .min()
        .expect("the Options folder has view rows");
    assert_eq!(placement.group, "view");
    assert_eq!(first_view_option, placement.rank);
    assert_eq!(action.title.en, "Customize Sidebar…");
    for (index, locale) in strings::LOCALES.iter().enumerate() {
        let title = strings::lookup(action.title.table, action.title.key, index)
            .unwrap_or_else(|| panic!("missing sidebar customization title for {locale}"));
        assert!(!title.is_empty());
        if *locale != "en" {
            assert_ne!(title, action.title.en, "untranslated title for {locale}");
        }
    }
}

/// CMUX-383 slice 2: every sidebar hide has a way back that the palette and
/// Settings > Sidebar both offer, in every language.
#[test]
fn sidebar_hides_have_a_palette_way_back() {
    for (id, english) in [
        ("sidebar.showHidden", "Show Hidden Sidebar Items"),
        ("sidebar.resetLayout", "Reset Sidebar Sections and Order"),
    ] {
        let action = find(id).unwrap_or_else(|| panic!("{id} is in the catalog"));
        assert_ne!(action.surfaces & PALETTE, 0, "{id}");
        assert_eq!(action.surface_plan.palette, Decision::Offered, "{id}");
        assert!(action.surface_plan.context_menus.is_empty(), "{id} adds no menu row");
        assert_eq!(action.title.en, english);
        for (index, locale) in strings::LOCALES.iter().enumerate() {
            let title = strings::lookup(action.title.table, action.title.key, index)
                .unwrap_or_else(|| panic!("missing {id} title for {locale}"));
            assert!(!title.is_empty());
            if *locale != "en" {
                assert_ne!(title, action.title.en, "untranslated {id} title for {locale}");
            }
        }
    }
}
