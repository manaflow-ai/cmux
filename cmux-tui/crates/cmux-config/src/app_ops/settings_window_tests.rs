//! Ports of the Swift tests of `SettingsAnchor`, `SettingsDeepLink` and the Appearance routes
//! (`AppearanceRouteTests`), plus the cases the Swift code answers by construction.

use super::*;

fn ask(op: &str, request: Value) -> Value {
    call(op, &request).expect("a settings_window op").expect("answers")
}

fn anchor_of(key: &str) -> Value {
    ask("settings_window.anchor", json!({ "key": key }))
}

#[test]
fn other_areas_ops_are_not_ours() {
    assert!(call("jsonc.parse", &json!({})).is_none());
    assert!(matches!(
        super::super::call("settings_window.nope", &json!({})),
        Err(OpError::Unknown)
    ));
}

#[test]
fn a_schema_row_the_page_shows_is_its_own_anchor() {
    assert_eq!(
        anchor_of("tabs.newTabPosition"),
        json!({ "anchor": { "section": "general", "id": "tabs.newTabPosition", "header": false } })
    );
    // trimmed
    assert_eq!(anchor_of("  app.language\n")["anchor"]["id"], "app.language");
}

#[test]
fn a_row_the_page_hides_or_cmux_next_does_not_read_is_no_anchor() {
    assert_eq!(anchor_of("machines.hosts"), json!({}));
    assert_eq!(anchor_of("browser.toolbar.back"), json!({}));
}

#[test]
fn blank_and_unknown_names_are_no_anchor() {
    assert_eq!(anchor_of(""), json!({}));
    assert_eq!(anchor_of("   "), json!({}));
    assert_eq!(anchor_of("no.such.thing"), json!({}));
    assert_eq!(anchor_of("card.noSuchCard"), json!({}));
}

#[test]
fn a_card_is_named_bare_or_with_its_anchor_id() {
    let theme =
        json!({ "anchor": { "section": "appearance", "id": "card.theme", "header": false } });
    assert_eq!(anchor_of("theme"), theme);
    assert_eq!(anchor_of("card.theme"), theme);
    assert_eq!(anchor_of("browserProfiles")["anchor"]["section"], "rooms");
    assert_eq!(anchor_of("card.machines")["anchor"]["section"], "machines");
}

#[test]
fn a_section_header_is_named_by_its_id() {
    assert_eq!(
        anchor_of("section.keyboard"),
        json!({ "anchor": { "section": "keyboard", "id": "section.keyboard", "header": true } })
    );
    assert_eq!(anchor_of("section.nope"), json!({}));
}

#[test]
fn an_action_button_is_named_by_its_id_or_its_anchor_id() {
    assert_eq!(
        anchor_of("importFromBrowser"),
        json!({ "anchor": { "section": "browser", "id": "action.browser.importFromBrowser", "header": false } })
    );
    assert_eq!(anchor_of("action.browser.importFromBrowser")["anchor"]["section"], "browser");
    // The same action sits on two pages; the first section in order owns the bare name.
    assert_eq!(anchor_of("reloadConfiguration")["anchor"]["section"], "terminal");
    assert_eq!(anchor_of("action.advanced.reloadConfiguration")["anchor"]["section"], "advanced");
    // An action of another section is not named by this section's anchor id.
    assert_eq!(anchor_of("action.keyboard.importFromBrowser"), json!({}));
}

#[test]
fn every_section_action_is_found() {
    for section in sections() {
        for action in actions_in(section) {
            let found = anchor(&format!("action.{section}.{action}")).expect("anchored");
            assert_eq!(
                (found.section.as_str(), found.id.as_str()),
                (section, format!("action.{section}.{action}").as_str())
            );
        }
    }
}

#[test]
fn a_setting_routes_to_its_section_and_focuses_its_row() {
    let route = |request| ask("settings_window.route", request);
    assert_eq!(
        route(json!({ "setting": "tabs.newTabPosition", "dev_build": false })),
        json!({ "route": "#/settings/general?focus=tabs.newTabPosition" })
    );
    // the setting wins over a section
    assert_eq!(
        route(json!({ "section": "browser", "setting": "app.language" }))["route"],
        "#/settings/general?focus=app.language"
    );
    // a name that is no row opens the section
    assert_eq!(
        route(json!({ "section": "browser", "setting": "card.theme" }))["route"],
        "#/settings/browser"
    );
    assert_eq!(route(json!({ "section": "keyboard" }))["route"], "#/settings/keyboard");
    assert_eq!(route(json!({})), json!({}));
}

#[test]
fn development_opens_only_in_a_dev_build() {
    let route = |request| ask("settings_window.route", request);
    assert_eq!(route(json!({ "section": "development", "dev_build": false })), json!({}));
    assert_eq!(
        route(json!({ "section": "development", "dev_build": true }))["route"],
        "#/settings/development"
    );
    assert_eq!(route(json!({ "setting": "app.internalDeveloperMode" })), json!({}));
    assert_eq!(
        route(json!({ "setting": "app.internalDeveloperMode", "dev_build": true }))["route"],
        "#/settings/development?focus=app.internalDeveloperMode"
    );
}

#[test]
fn a_link_reads_its_arguments_as_the_app_does() {
    let link = |request| ask("settings_window.link", request);
    assert_eq!(
        link(
            json!({ "section": "browser", "setting": "  tabs.newTabPosition ", "route": "#/settings/customize?focus=card.x" })
        ),
        json!({ "section": "browser", "setting": "tabs.newTabPosition", "route": "#/settings/customize?focus=card.x" })
    );
    // an unknown section is ignored, a blank setting is none, a route must be a settings route
    assert_eq!(
        link(json!({ "section": "nope", "setting": "  ", "route": "https://example.com" })),
        json!({})
    );
    assert_eq!(link(json!({})), json!({}));
}

#[test]
fn personalization_opens_appearance() {
    assert_eq!(
        ask("settings_window.appearance_route", json!({}))["route"],
        "#/settings/appearance"
    );
}

#[test]
fn change_background_is_a_new_route_on_the_background_picker_each_time() {
    let route = |open| {
        ask(
            "settings_window.appearance_route",
            json!({ "background": true, "workspace": "ws 1", "open": open }),
        )["route"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let first = route(1);
    assert_eq!(first, "#/settings/appearance?focus=appearance.background&open=1&workspace=ws%201");
    assert_ne!(route(2), first);
    // a workspace alone adds no focus; percent-encoding keeps letters, digits and non-ASCII letters
    assert_eq!(
        ask("settings_window.appearance_route", json!({ "workspace": "a/b é" }))["route"],
        "#/settings/appearance?workspace=a%2Fb%20é"
    );
}

#[test]
fn reopening_customization_returns_to_sidebar() {
    assert_eq!(
        ask("settings_window.sidebar_route", json!({ "open": 7 }))["route"],
        "#/settings/sidebar?open=7"
    );
    assert!(call("settings_window.sidebar_route", &json!({})).unwrap().is_err());
}

#[test]
fn the_devices_join_consent_switches_are_page_anchors() {
    assert_eq!(
        ask("settings_window.page_anchor", json!({ "key": " devices.join.control " })),
        json!({ "anchor": {
            "id": "devices.join.control",
            "category": "devices",
            "route": "#/settings/devices?focus=devices.join.control",
        } })
    );
    assert_eq!(
        ask("settings_window.page_anchor", json!({ "key": "devices.join.other" })),
        json!({})
    );
    assert_eq!(ask("settings_window.page_anchor", json!({ "key": "" })), json!({}));
}

#[test]
fn the_cards_list_matches_the_sections_they_sit_in() {
    let cards = ask("settings_window.cards", json!({}));
    let cards = cards["cards"].as_array().unwrap();
    assert_eq!(cards.len(), 7);
    let known: Vec<&str> = sections().collect();
    for card in cards {
        assert!(known.contains(&card["section"].as_str().unwrap()), "{card}");
    }
}
