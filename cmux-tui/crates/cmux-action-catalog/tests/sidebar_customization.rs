//! The native sidebar and palette share one discoverable customization action.
use cmux_action_catalog::{Decision, PALETTE, find, strings};

#[test]
fn sidebar_customization_is_discoverable_and_localized() {
    let action = find("sidebar.customize").expect("sidebar customization action");
    assert_ne!(action.surfaces & PALETTE, 0);
    assert_eq!(action.surface_plan.palette, Decision::Offered);
    assert!(action.surface_plan.context_menus.iter().any(|placement| {
        placement.context == "sidebarBackground"
            && placement.parent.is_none()
            && placement.folder.is_none()
    }));
    for (index, locale) in strings::LOCALES.iter().enumerate() {
        let title = strings::lookup(action.title.table, action.title.key, index)
            .unwrap_or_else(|| panic!("missing sidebar customization title for {locale}"));
        assert!(!title.is_empty());
        if *locale != "en" {
            assert_ne!(title, action.title.en, "untranslated title for {locale}");
        }
    }
}
