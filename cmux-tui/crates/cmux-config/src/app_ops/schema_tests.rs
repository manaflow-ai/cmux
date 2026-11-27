//! Pins `schema.*` to the Swift behaviour it replaces, case by case (CmuxNextSettingsTests:
//! ChoiceListPaletteOptionTests, BrowserHibernationUnsetSettingTests, BackdropPaletteOptionTests,
//! LegacyBackdropArtValueTests, UltraConnectionLegacyKeyTests, MarkdownFontSizeSettingTests,
//! AgentPaneDisplaySettingTests, InternalDeveloperModeSettingTests).

use serde_json::{Value, json};

use super::*;
use crate::app_ops::{OpError, call};

fn op(name: &str, request: Value) -> Value {
    call(name, &request).unwrap_or_else(|error| panic!("{name} {request}: {error:?}"))
}

fn value(name: &str, request: Value) -> Value {
    op(name, request)["value"].clone()
}

fn options(request: Value) -> Vec<Value> {
    op("schema.palette_options", request)["options"].as_array().cloned().unwrap_or_default()
}

fn title_texts(options: &[Value]) -> Vec<String> {
    options
        .iter()
        .map(|option| {
            let title = &option["title"];
            title["text"]
                .as_str()
                .or_else(|| title["arg"]["text"].as_str())
                .unwrap_or_default()
                .to_owned()
        })
        .collect()
}

fn values(options: &[Value]) -> Vec<Value> {
    options.iter().map(|option| option.get("value").cloned().unwrap_or(Value::Null)).collect()
}

fn current(options: &[Value]) -> Vec<&Value> {
    options.iter().filter(|option| option["current"] == true).collect()
}

fn option_titled<'a>(options: &'a [Value], title: &str) -> &'a Value {
    let titles = title_texts(options);
    let index = titles
        .iter()
        .position(|t| t == title)
        .unwrap_or_else(|| panic!("no {title} in {titles:?}"));
    &options[index]
}

fn summary_texts(request: Value) -> Option<Vec<String>> {
    let reply = op("schema.palette_options", request);
    reply["summary"].as_array().map(|texts| {
        texts.iter().map(|text| text["text"].as_str().unwrap_or_default().to_owned()).collect()
    })
}

// MARK: requests

#[test]
fn an_unknown_key_or_a_missing_member_is_invalid() {
    assert!(matches!(
        call("schema.accepts", &json!({"key": "no.such", "value": 1})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        call("schema.accepts", &json!({"key": "app.language"})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        call("schema.typed", &json!({"key": "app.language"})),
        Err(OpError::Invalid(_))
    ));
    assert_eq!(call("schema.nope", &json!({})), Err(OpError::Unknown));
}

// MARK: values

/// MarkdownFontSizeSettingTests.
#[test]
fn a_number_reads_its_default_and_a_stored_size() {
    let empty = json!({});
    assert_eq!(
        value("schema.effective", json!({"key": "markdown.font.size", "root": empty})),
        json!(16)
    );
    let root = json!({"markdown": {"font": {"size": 18}}});
    assert_eq!(
        value("schema.effective", json!({"key": "markdown.font.size", "root": root})),
        json!(18)
    );
    assert_eq!(
        op("schema.customized", json!({"key": "markdown.font.size", "root": root}))["customized"],
        true
    );
    for size in [8.0, 12.0, 16.0, 40.0] {
        assert_eq!(
            op("schema.accepts", json!({"key": "markdown.font.size", "value": size}))["accepted"],
            true
        );
    }
}

#[test]
fn a_stored_default_is_not_customized_whatever_its_number_form() {
    let root = json!({"markdown": {"font": {"size": 16.0}}});
    assert_eq!(
        op("schema.customized", json!({"key": "markdown.font.size", "root": root}))["customized"],
        false
    );
    assert_eq!(
        op("schema.customized", json!({"key": "markdown.font.size", "root": {}}))["customized"],
        false
    );
}

#[test]
fn a_refused_value_applies_the_default() {
    let root = json!({"markdown": {"font": {"size": "huge"}}});
    assert_eq!(
        value("schema.effective", json!({"key": "markdown.font.size", "root": root})),
        json!(16)
    );
    let out_of_range = json!({"markdown": {"font": {"size": 4000}}});
    assert_eq!(
        value("schema.effective", json!({"key": "markdown.font.size", "root": out_of_range})),
        json!(16)
    );
    let bad_choice = json!({"app": {"language": "klingon"}});
    assert_eq!(
        value("schema.effective", json!({"key": "app.language", "root": bad_choice})),
        json!("system")
    );
}

/// UltraConnectionLegacyKeyTests.
#[test]
fn the_old_ultra_switch_reads_as_its_choice() {
    let on = json!({"remote": {"ultraMode": true}});
    assert_eq!(
        value("schema.effective", json!({"key": "remote.ultra", "root": on})),
        json!("always")
    );
    assert_eq!(
        op("schema.customized", json!({"key": "remote.ultra", "root": on}))["customized"],
        true
    );
    let off = json!({"remote": {"ultraMode": false}});
    assert_eq!(
        value("schema.effective", json!({"key": "remote.ultra", "root": off})),
        json!("auto")
    );
    let both = json!({"remote": {"ultraMode": true, "ultra": "off"}});
    assert_eq!(
        value("schema.effective", json!({"key": "remote.ultra", "root": both})),
        json!("off")
    );
}

#[test]
fn a_renamed_switch_reads_through_the_values_table() {
    let root = json!({"computerUse": {"enabled": false}});
    assert_eq!(
        value("schema.stored", json!({"key": "computerUse.mode", "root": root})),
        json!("off")
    );
    assert_eq!(value("schema.stored", json!({"key": "computerUse.mode", "root": {}})), Value::Null);
}

/// A row that replaced several retired keys (`updates.automatic`, three toggles) reads the
/// first of them, in the table's order, whose value the table lists, as `replaced_value` does.
#[test]
fn a_row_that_replaced_several_keys_reads_the_first_listed() {
    let stored =
        |root: Value| value("schema.stored", json!({"key": "updates.automatic", "root": root}));
    let both = json!({"updates": {"checkAutomatically": false, "installWhenIdle": true}});
    assert_eq!(stored(both), json!("off"), "checks off wins");
    let idle = json!({"updates": {"checkAutomatically": true, "installWhenIdle": true}});
    assert_eq!(stored(idle), json!("idle"), "an unlisted first key gives way to the next");
    assert_eq!(
        stored(json!({"updates": {"checkAutomatically": true}})),
        Value::Null,
        "the default"
    );
}

/// LegacyBackdropArtValueTests.
#[test]
fn the_old_backdrop_art_key_reads_as_the_background() {
    let key = "appearance.background";
    let painting = json!({"appearance": {"backdropArt": "van-gogh-starry-night"}});
    assert_eq!(
        value("schema.stored", json!({"key": key, "root": painting})),
        json!("van-gogh-starry-night")
    );
    assert_eq!(
        value("schema.effective", json!({"key": key, "root": painting})),
        json!("van-gogh-starry-night")
    );
    let none = json!({"appearance": {"backdropArt": "none"}});
    assert_eq!(value("schema.effective", json!({"key": key, "root": none})), json!("none"));
    let both =
        json!({"appearance": {"background": "daily", "backdropArt": "van-gogh-starry-night"}});
    assert_eq!(value("schema.effective", json!({"key": key, "root": both})), json!("daily"));
}

#[test]
fn an_old_backdrop_id_the_list_lacks_asks_the_app_s_catalog() {
    let key = "appearance.background";
    let retired = json!({"appearance": {"backdropArt": "wheat-field-with-cypresses"}});
    let need = op("schema.effective", json!({"key": key, "root": retired}));
    assert_eq!(need, json!({"need": {"art": "wheat-field-with-cypresses"}}));
    let arts = json!({"wheat-field-with-cypresses": "van-gogh-wheat-field-cypresses"});
    assert_eq!(
        value("schema.effective", json!({"key": key, "root": retired, "arts": arts})),
        json!("van-gogh-wheat-field-cypresses")
    );
    // Anything else paints nothing: the row shows no wallpaper, not Shuffle Daily.
    for old in ["daily", "desktop", "garbage"] {
        let root = json!({"appearance": {"backdropArt": old}});
        let arts = json!({ old: null });
        assert_eq!(
            value("schema.effective", json!({"key": key, "root": root, "arts": arts})),
            json!("none")
        );
    }
    let number = json!({"appearance": {"backdropArt": 3}});
    assert_eq!(value("schema.effective", json!({"key": key, "root": number})), json!("none"));
}

/// AgentPaneDisplaySettingTests: the minimap's old switch.
#[test]
fn the_minimap_s_old_switch_reads_as_full_or_the_default() {
    let on = json!({"agentPane": {"display": {"minimap": true}}});
    assert_eq!(
        value("schema.effective", json!({"key": "agentPane.display.minimap", "root": on})),
        json!("full")
    );
    let off = json!({"agentPane": {"display": {"minimap": false}}});
    assert_eq!(
        value("schema.effective", json!({"key": "agentPane.display.minimap", "root": off})),
        json!("compact")
    );
}

#[test]
fn a_toggle_flips_what_applies_and_other_kinds_do_not() {
    let key = "history.terminalCommands";
    assert_eq!(value("schema.toggled", json!({"key": key, "root": {}})), json!(true));
    let on = json!({"history": {"terminalCommands": true}});
    assert_eq!(value("schema.toggled", json!({"key": key, "root": on})), json!(false));
    let bad = json!({"history": {"terminalCommands": "yes"}});
    assert_eq!(value("schema.toggled", json!({"key": key, "root": bad})), json!(true));
    assert_eq!(value("schema.toggled", json!({"key": "app.language", "root": {}})), Value::Null);
}

#[test]
fn typed_text_becomes_the_row_s_value_when_accepted() {
    assert_eq!(
        value("schema.typed", json!({"key": "markdown.font.size", "text": " 18 "})),
        json!(18)
    );
    assert_eq!(
        value("schema.typed", json!({"key": "markdown.font.size", "text": "18.5"})),
        json!(18.5)
    );
    assert_eq!(
        value("schema.typed", json!({"key": "markdown.font.size", "text": "big"})),
        Value::Null
    );
    assert_eq!(
        value("schema.typed", json!({"key": "markdown.font.size", "text": "4000"})),
        Value::Null
    );
    assert_eq!(
        value("schema.typed", json!({"key": "markdown.font.size", "text": "inf"})),
        Value::Null
    );
    // A choice-or-number row takes either.
    assert_eq!(
        value("schema.typed", json!({"key": "browser.hibernation", "text": "45"})),
        json!(45)
    );
    assert_eq!(
        value("schema.typed", json!({"key": "browser.hibernation", "text": "off"})),
        json!("off")
    );
    assert_eq!(
        value("schema.typed", json!({"key": "browser.hibernation", "text": "soon"})),
        Value::Null
    );
    // An address is the object form; a choice stays a string.
    assert_eq!(
        value("schema.typed", json!({"key": "home.server", "text": "hosted"})),
        json!("hosted")
    );
    assert_eq!(
        value("schema.typed", json!({"key": "home.server", "text": "https://cmux.example.com"})),
        json!({"selfHosted": "https://cmux.example.com"})
    );
    assert_eq!(value("schema.typed", json!({"key": "home.server", "text": "nope"})), Value::Null);
    // A color takes a hex color only.
    assert_eq!(
        value("schema.typed", json!({"key": "appearance.highlightColor", "text": "#FF8800"})),
        json!("#FF8800")
    );
    assert_eq!(
        value("schema.typed", json!({"key": "appearance.highlightColor", "text": "orange"})),
        Value::Null
    );
}

#[test]
fn a_json_row_checks_its_top_level_type_only() {
    let key = "sidebar.workspaceRow.lines";
    assert_eq!(
        op("schema.accepts", json!({"key": key, "value": [["anything"]]}))["accepted"],
        true
    );
    assert_eq!(op("schema.accepts", json!({"key": key, "value": "lines"}))["accepted"], false);
}

#[test]
fn a_per_kind_order_inherits_all_workspaces_order() {
    let root = json!({"sidebar": {"workspaceRow": {"secondLineOrder": ["ports", "branch"]}}});
    let inherited = value(
        "schema.inherited",
        json!({"key": "sidebar.workspaceRow.agent.secondLineOrder", "root": root}),
    );
    assert_eq!(inherited, json!(["ports", "branch"]));
    let default = value(
        "schema.inherited",
        json!({"key": "sidebar.workspaceRow.agent.secondLineOrder", "root": {}}),
    );
    assert_eq!(default[0], "notification");
    assert_eq!(
        value(
            "schema.inherited",
            json!({"key": "sidebar.workspaceRow.secondLineOrder", "root": root})
        ),
        Value::Null
    );
    assert_eq!(
        value("schema.inherited", json!({"key": "app.language", "root": root})),
        Value::Null
    );
}

// MARK: palette: ChoiceListPaletteOptionTests

#[test]
fn a_browser_toolbar_button_row_toggles_it_in_the_choices_order() {
    let request =
        json!({"key": "browser.toolbarButtons", "current": ["media", "zoom", "downloads"]});
    let options = options(request);
    let zoom = option_titled(&options, "Zoom Level");
    assert_eq!(zoom["current"], true);
    assert_eq!(zoom["value"], json!(["media", "downloads"]));
    let bookmarks = option_titled(&options, "Bookmarks");
    assert_eq!(bookmarks["current"], false);
    assert_eq!(bookmarks["value"], json!(["media", "zoom", "favorites", "downloads"]));
}

#[test]
fn a_pinned_tab_bar_button_list_keeps_its_order() {
    let options =
        options(json!({"key": "tabs.toolbarButtons", "current": ["splitDown", "splitRight"]}));
    assert_eq!(title_texts(&options)[..2], ["Split Down".to_owned(), "Split Right".to_owned()]);
    assert_eq!(option_titled(&options, "Split Right")["value"], json!(["splitDown"]));
    assert_eq!(
        option_titled(&options, "Diff Viewer")["value"],
        json!(["splitDown", "splitRight", "openDiffViewer"])
    );
}

#[test]
fn a_full_order_moves_a_choice_to_the_front_of_the_order_that_applies() {
    let options = options(
        json!({"key": "sidebar.workspaceRow.secondLineOrder", "current": ["branch", "directory"]}),
    );
    let applied =
        ["branch", "directory", "notification", "process", "agentStatus", "ports", "lastActivity"];
    let moved: Vec<String> =
        options.iter().map(|o| o["value"][0].as_str().unwrap().to_owned()).collect();
    assert_eq!(moved, applied);
    assert!(current(&options).is_empty());
    let ports = option_titled(&options, "Ports");
    assert_eq!(ports["title"]["format"]["key"], "settings.palette.moveToFront");
    assert_eq!(ports["title"]["format"]["text"], "Move %@ to Front");
    assert_eq!(
        ports["value"],
        json!([
            "ports",
            "branch",
            "directory",
            "notification",
            "process",
            "agentStatus",
            "lastActivity"
        ])
    );
}

#[test]
fn a_per_kind_order_starts_from_the_one_it_inherits() {
    let options = options(json!({
        "key": "sidebar.workspaceRow.terminal.secondLineOrder",
        "current": null,
        "inherited": ["ports", "branch"],
    }));
    // Unset first (Same as All Workspaces), current.
    assert_eq!(options[0].get("value"), None);
    assert_eq!(options[0]["title"]["text"], "Same as All Workspaces");
    assert_eq!(options[0]["current"], true);
    assert_eq!(
        option_titled(&options, "Folder")["value"],
        json!([
            "directory",
            "ports",
            "branch",
            "notification",
            "process",
            "agentStatus",
            "lastActivity"
        ])
    );
}

#[test]
fn a_list_row_summarises_its_value() {
    let picked =
        summary_texts(json!({"key": "browser.toolbarButtons", "current": ["media", "zoom"]}));
    assert_eq!(picked, Some(vec!["Media Controls".to_owned(), "Zoom Level".to_owned()]));
    let reply =
        op("schema.palette_options", json!({"key": "browser.toolbarButtons", "current": []}));
    assert_eq!(reply["summary"], json!([{"text": "None", "key": "settings.choice.none"}]));
    let order = summary_texts(
        json!({"key": "sidebar.workspaceRow.secondLineOrder", "current": ["branch"]}),
    );
    assert_eq!(
        order.unwrap().join(", "),
        "Git Branch, Latest Notification, Folder, Running Program, Agent Status, Ports, Last Activity"
    );
    // A key left unset: the unset row's title says it.
    let unset = summary_texts(
        json!({"key": "sidebar.workspaceRow.terminal.secondLineOrder", "current": null}),
    );
    assert_eq!(unset, None);
    assert_eq!(summary_texts(json!({"key": "app.language", "current": "system"})), None);
}

// MARK: palette: BrowserHibernationUnsetSettingTests

#[test]
fn hibernation_lists_never_discard_first() {
    let none = options(json!({"key": "browser.hibernation", "current": null}));
    assert_eq!(values(&none), [Value::Null, json!("moderate"), json!("aggressive"), json!("off")]);
    assert_eq!(none[0]["title"]["text"], "Never Discard");
    assert_eq!(none[0]["current"], true);
    let moderate = options(json!({"key": "browser.hibernation", "current": "moderate"}));
    assert_eq!(
        title_texts(&current(&moderate).into_iter().cloned().collect::<Vec<_>>()),
        ["After 30 Minutes"]
    );
    let custom = options(json!({"key": "browser.hibernation", "current": 45}));
    assert!(current(&custom).is_empty());
    let freeze = options(json!({"key": "browser.freezeHiddenTabs", "current": null}));
    assert!(freeze.iter().all(|option| option.get("value").is_some()));
}

// MARK: palette: other kinds

#[test]
fn a_toggle_lists_on_and_off() {
    let options = options(json!({"key": "history.terminalCommands", "current": null}));
    assert_eq!(values(&options), [json!(true), json!(false)]);
    assert_eq!(options[0]["title"], json!({"text": "On", "key": "settings.choice.on"}));
    assert_eq!(options[1]["title"], json!({"text": "Off", "key": "settings.choice.off"}));
    assert_eq!(options[1]["current"], true, "the default, off, is current");
}

#[test]
fn a_narrow_number_lists_every_step_with_its_unit() {
    let options = options(json!({"key": "updates.keepPreviousVersions", "current": 3}));
    assert_eq!(values(&options), [json!(0), json!(1), json!(2), json!(3), json!(4), json!(5)]);
    assert_eq!(options[3]["title"], json!({"number": 3, "unit": "count"}));
    assert_eq!(current(&options).len(), 1);
    assert_eq!(current(&options)[0]["value"], json!(3));
}

#[test]
fn a_number_with_no_default_lists_unset_first() {
    let options = options(json!({"key": "appearance.metrics.tabFontSize", "current": null}));
    assert_eq!(options[0].get("value"), None);
    assert_eq!(options[0]["current"], true);
    assert_eq!(options.len(), 1 + 9);
}

#[test]
fn a_wide_number_samples_its_grid_and_keeps_the_value() {
    let range =
        NumberRange { min: 1.0, max: 3650.0, step: 1.0, unit: "days".to_owned(), placeholder: 1.0 };
    let sampled = number_values(&range, None);
    assert_eq!(sampled.len(), 39);
    assert_eq!(sampled[..5], [1.0, 97.0, 193.0, 289.0, 385.0]);
    assert_eq!(sampled[36..], [3458.0, 3554.0, 3650.0]);
    let with = number_values(&range, Some(30.0));
    assert_eq!(with.len(), 40);
    assert!(with.contains(&30.0));
    assert_eq!(number_values(&range, Some(9999.0)).len(), 39, "a value out of range is not listed");
    let fraction = NumberRange {
        min: 0.1,
        max: 1.0,
        step: 0.05,
        unit: "fraction".to_owned(),
        placeholder: 0.1,
    };
    let steps = number_values(&fraction, None);
    assert_eq!(steps.first(), Some(&0.1));
    assert_eq!(steps.last(), Some(&1.0));
}

#[test]
fn a_color_lists_the_theme_first_then_its_colors_once() {
    let colors = json!([
        {"red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1.0},
        {"red": 1.0, "green": 0.5, "blue": 0.0, "alpha": 1.0},
        {"red": 0.0, "green": 0.0, "blue": 1.0, "alpha": 0.5},
    ]);
    let options = options(
        json!({"key": "appearance.highlightColor", "current": null, "theme_colors": colors}),
    );
    assert_eq!(values(&options), [Value::Null, json!("#FF8000"), json!("#0000FF80")]);
    assert_eq!(
        options[0]["title"],
        json!({"text": "Terminal Theme", "key": "settings.default.terminalTheme"})
    );
    assert_eq!(options[0]["current"], true);
    assert_eq!(options[1]["swatch"], json!({"theme": 0}));
    assert_eq!(options[2]["swatch"], json!({"theme": 2}));
    let themed = options_for_color("#ff8000", &colors);
    assert_eq!(current(&themed).len(), 1);
    assert_eq!(current(&themed)[0]["value"], "#FF8000");
    let custom = options_for_color("#123", &colors);
    let last = custom.last().unwrap();
    assert_eq!(last["value"], "#123");
    assert_eq!(last["swatch"], json!({"hex": "#112233"}));
    assert_eq!(last["current"], true);
}

fn options_for_color(current: &str, colors: &Value) -> Vec<Value> {
    options(json!({"key": "appearance.highlightColor", "current": current, "theme_colors": colors}))
}

#[test]
fn css_hex_reads_as_the_theme_does() {
    assert_eq!(Rgba::css_hex(" #fff ").map(|c| c.hex()), Some("#FFFFFF".to_owned()));
    assert_eq!(Rgba::css_hex("336699").map(|c| c.hex()), Some("#336699".to_owned()));
    assert_eq!(Rgba::css_hex("#33669980").map(|c| c.hex()), Some("#33669980".to_owned()));
    assert_eq!(Rgba::css_hex("#336699FF").map(|c| c.hex()), Some("#336699".to_owned()));
    assert_eq!(Rgba::css_hex("#12345"), None);
    assert_eq!(Rgba::css_hex("#GGGGGG"), None);
}

#[test]
fn free_text_kinds_list_nothing() {
    for key in ["appearance.appFont", "notifications.sound", "browser.newTabPage", "tabs.newTabApp"]
    {
        assert!(options(json!({"key": key, "current": null})).is_empty(), "{key}");
    }
}

// MARK: palette: BackdropPaletteOptionTests

#[test]
fn a_background_the_list_lacks_asks_the_app_and_shows_by_name() {
    let key = "appearance.background";
    let image = "file:/Users/Shared/Harbor.png";
    let need = op("schema.palette_options", json!({"key": key, "current": image}));
    assert_eq!(need, json!({"need": {"selection": image}}));
    let options = options(
        json!({"key": key, "current": image, "selection": {"id": image, "title": "Harbor"}}),
    );
    let current_options = current(&options);
    assert_eq!(current_options.len(), 1);
    assert_eq!(current_options[0]["title"]["text"], "Harbor");
    assert_eq!(current_options[0]["value"], image);
}

#[test]
fn a_retired_painting_marks_its_replacement() {
    let options = options(json!({
        "key": "appearance.background",
        "current": "wheat-field-with-cypresses",
        "selection": {"id": "van-gogh-wheat-field-cypresses", "title": "Wheat Field with Cypresses"},
    }));
    let marked: Vec<_> =
        current(&options).into_iter().map(|option| option["value"].clone()).collect();
    assert_eq!(marked, [json!("van-gogh-wheat-field-cypresses")]);
}

#[test]
fn a_listed_background_is_unchanged() {
    let listed = options(json!({"key": "appearance.background", "current": "none"}));
    let marked: Vec<_> =
        current(&listed).into_iter().map(|option| option["value"].clone()).collect();
    assert_eq!(marked, [json!("none")]);
    assert_eq!(
        listed.len(),
        options(json!({"key": "appearance.background", "current": null})).len()
    );
    let unresolved =
        options(json!({"key": "appearance.background", "current": "gone", "selection": null}));
    assert!(current(&unresolved).is_empty());
    assert_eq!(unresolved.len(), listed.len());
}

// MARK: palette rows: InternalDeveloperModeSettingTests

#[test]
fn the_palette_lists_development_rows_only_with_developer_tools() {
    let with = op("schema.palette_rows", json!({"developer_tools": true}))["keys"].clone();
    let without = op("schema.palette_rows", json!({"developer_tools": false}))["keys"].clone();
    let has = |keys: &Value, key: &str| keys.as_array().unwrap().iter().any(|k| k == key);
    assert!(has(&with, "app.internalDeveloperMode"));
    assert!(!has(&without, "app.internalDeveloperMode"));
    assert!(!without.as_array().unwrap().is_empty());
    let schema = Schema::embedded();
    assert!(without.as_array().unwrap().iter().all(|key| {
        schema.row(key.as_str().unwrap()).is_some_and(|row| row.section != "development")
    }));
    // A row the palette does not offer (toggled by its own command) is never listed.
    assert!(!has(&with, "tabs.toolbarButtons"));
}
