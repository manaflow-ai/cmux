//! Customize… opens customize-by-asking without a terminal (Leo: "how can i try out the
//! customizations right now?"): one action for the palette, the app menu and a shortcut.
use cmux_action_catalog::{Decision, KEYBOARD, MENU, PALETTE, find, strings};

#[test]
fn customize_is_in_the_palette_and_the_app_menu_beside_settings() {
    let action = find("customize.open").expect("the Customize… action");
    assert_eq!(action.title.en, "Customize…");
    assert_eq!(action.surfaces & (PALETTE | KEYBOARD | MENU), PALETTE | KEYBOARD | MENU);
    assert_eq!(action.surface_plan.palette, Decision::Offered);
    assert_eq!(action.main_menu, Some("app"));
    // Same menu and category as Settings…, so the app menu draws them with no separator between.
    let settings = find("openSettings").expect("Settings…");
    assert_eq!(action.main_menu, settings.main_menu);
    assert_eq!(action.category, settings.category);
    // It opens a panel that takes the keyboard; the CLI's own door is `cmux customize`.
    assert_eq!(action.surface_plan.cli, Some(Decision::Exempt("guiOnly")));
}

#[test]
fn customize_title_is_translated_in_every_locale() {
    let action = find("customize.open").expect("the Customize… action");
    for (index, locale) in strings::LOCALES.iter().enumerate() {
        let title = strings::lookup(action.title.table, action.title.key, index)
            .unwrap_or_else(|| panic!("no Customize… title for {locale}"));
        assert!(title.ends_with('…'), "{locale}: {title}");
        if *locale != "en" {
            assert_ne!(title, action.title.en, "untranslated title for {locale}");
        }
    }
}
