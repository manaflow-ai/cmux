//! Every big part of the window resolves to a Customize… element (Leo: "you should maybe be even
//! able to right click customize on anything", "or at least the big things"), and each element
//! names real settings and theme tokens and is offered in the menus it lists.
use std::collections::BTreeSet;

use cmux_action_catalog::customize_elements::{
    BIG_SURFACES, ELEMENT_CASES, ELEMENTS, element, element_for_menu,
};
use cmux_action_catalog::{ArgKind, CONTEXT_MENU, find, strings};

// The settings export, not the defaults snapshot: the snapshot is bot-only (#21946), so a pull
// request that adds a setting and names it here carries a fresh export but the base's snapshot.
const SETTINGS_SCHEMA: &str = include_str!("../../../../schemas/settings/settings-schema.json");
const DESIGN_TOKENS: &str =
    include_str!("../../../../plans/cmux-next/spec-proposals/visuals/design-tokens.json");

/// The setting keys cmux knows (the export's rows; the defaults snapshot's `setting.` keys).
fn setting_keys() -> BTreeSet<String> {
    let schema: serde_json::Value =
        serde_json::from_str(SETTINGS_SCHEMA).expect("settings schema JSON");
    schema["rows"]
        .as_array()
        .expect("settings schema rows")
        .iter()
        .map(|row| row["key"].as_str().expect("a row key").to_owned())
        .collect()
}

/// The theme token names (`ThemeTokens`, the spec's formulas).
fn token_names() -> BTreeSet<String> {
    let spec: serde_json::Value = serde_json::from_str(DESIGN_TOKENS).expect("design tokens JSON");
    spec["theme"]["formulas"].as_object().expect("theme formulas").keys().cloned().collect()
}

#[test]
fn every_big_surface_resolves_to_an_element() {
    for surface in BIG_SURFACES {
        assert!(
            ELEMENTS.iter().any(|e| e.surface == *surface),
            "the big surface {surface} has no Customize… element"
        );
    }
    for e in ELEMENTS {
        assert!(BIG_SURFACES.contains(&e.surface), "{}: unknown surface {}", e.id, e.surface);
        assert_eq!(element(e.id), Some(e));
    }
    let ids: BTreeSet<_> = ELEMENTS.iter().map(|e| e.id).collect();
    assert_eq!(ids.len(), ELEMENTS.len(), "duplicate element id");
}

#[test]
fn every_element_names_real_settings_and_theme_tokens() {
    let (settings, tokens) = (setting_keys(), token_names());
    assert!(settings.len() > 500, "read {} setting keys", settings.len());
    for e in ELEMENTS {
        assert!(!e.settings.is_empty(), "{}: no settings", e.id);
        assert!(!e.tokens.is_empty(), "{}: no theme tokens", e.id);
        for key in e.settings {
            assert!(settings.contains(*key), "{}: no setting {key}", e.id);
        }
        for token in e.tokens {
            assert!(tokens.contains(*token), "{}: no theme token {token}", e.id);
        }
    }
}

#[test]
fn every_menu_an_element_lists_offers_customize_for_it() {
    let action = find("customize.open").expect("the Customize… action");
    assert_ne!(action.surfaces & CONTEXT_MENU, 0, "Customize… is not on right-click menus");
    let placed: BTreeSet<_> = action.surface_plan.context_menus.iter().map(|p| p.context).collect();
    let listed: BTreeSet<_> = ELEMENTS.iter().flat_map(|e| e.menus.iter().copied()).collect();
    assert_eq!(placed, listed, "Customize… menus and the element map's menus differ");
    for menu in &listed {
        let owners = ELEMENTS.iter().filter(|e| e.menus.contains(menu)).count();
        assert_eq!(owners, 1, "{menu} belongs to {owners} elements");
        assert!(element_for_menu(menu).is_some());
    }
}

#[test]
fn the_element_argument_takes_every_element() {
    let action = find("customize.open").expect("the Customize… action");
    let argument =
        action.arguments.iter().find(|a| a.name == "element").expect("an element argument");
    assert!(!argument.required, "Customize… from the palette or the app menu has no element");
    let ArgKind::Enumeration(cases) = argument.kind else {
        panic!("element is not an enumeration")
    };
    assert_eq!(cases, ELEMENT_CASES);
    let values: Vec<_> = cases.iter().map(|c| c.value).collect();
    let ids: Vec<_> = ELEMENTS.iter().map(|e| e.id).collect();
    assert_eq!(values, ids);
}

#[test]
fn every_element_title_is_translated() {
    for e in ELEMENTS {
        for (index, locale) in strings::LOCALES.iter().enumerate().skip(1) {
            assert!(
                strings::lookup(e.title.table, e.title.key, index).is_some(),
                "{}: no title for {locale}",
                e.id
            );
        }
    }
}

#[test]
fn reset_takes_one_element_and_runs_from_the_palette_and_the_cli() {
    let action = find("customize.reset").expect("the Reset action");
    let argument =
        action.arguments.iter().find(|a| a.name == "element").expect("an element argument");
    assert!(argument.required, "Reset needs the element whose settings it removes");
    let ArgKind::Enumeration(cases) = argument.kind else {
        panic!("element is not an enumeration")
    };
    assert_eq!(cases, ELEMENT_CASES);
    assert_eq!(action.surface_plan.cli, Some(cmux_action_catalog::Decision::Offered));
}
