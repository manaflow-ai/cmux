//! The native sidebar and palette share one discoverable customization action.
use cmux_action_catalog::{Decision, PALETTE, find, strings};

#[test]
fn sidebar_customization_is_discoverable_and_localized() {
    let action = find("sidebar.customize").expect("sidebar customization action");
    assert_ne!(action.surfaces & PALETTE, 0);
    assert_eq!(action.surface_plan.palette, Decision::Offered);
    // The sidebar background menu offers it once, flat in its View group: the menu's
    // Customize… (`customize.open`) opens an agent chat, not Settings > Sidebar, and is
    // hidden from right-click menus by default, so it is no second way to this screen.
    assert_eq!(action.surface_plan.context_menus.len(), 1);
    assert_eq!(action.surface_plan.context_menus[0].context, "sidebarBackground");
    assert_eq!(action.surface_plan.context_menu(), Some(Decision::Offered));
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
