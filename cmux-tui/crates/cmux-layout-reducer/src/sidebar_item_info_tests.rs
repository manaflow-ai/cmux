use super::*;
use serde_json::{Value, json};

fn r(kind: &str, value: &str) -> Ref {
    Ref { kind: kind.into(), value: value.into() }
}

fn item(id: &str, kind: &str, value: &str, label: Option<&str>) -> Item {
    Item { id: id.into(), reference: r(kind, value), label: label.map(Into::into) }
}

// ForumEntryTests: the Forum hides while its experiment is off; Automations never does.
#[test]
fn the_forum_hides_while_its_experiment_is_off() {
    let forum = built_in_named("forum").map(|b| built_in_look(b, true, false));
    assert!(forum.is_some_and(|l| l.is_hidden));
    let shown = built_in_named("forum").map(|b| built_in_look(b, true, true));
    assert!(shown.is_some_and(|l| !l.is_hidden));
    let automations = built_in_named("automations").map(|b| built_in_look(b, true, false));
    assert!(automations.is_some_and(|l| !l.is_hidden));
}

// AppStoreHiddenUntilReadyTests: the App Store hides until Labs shows it, and keeps its caption.
#[test]
fn the_app_store_hides_until_it_shows_and_keeps_its_caption() {
    let hidden = built_in_named("app_store").map(|b| built_in_look(b, false, false));
    assert_eq!(
        hidden,
        Some(BuiltInLook {
            symbol: "bag".into(),
            icon: Some("store".into()),
            has_caption: true,
            is_hidden: true
        })
    );
    assert!(built_in_named("app_store").is_some_and(|b| !built_in_look(b, true, false).is_hidden));
}

// The Chief draws the sparkles symbol, not the icon pack's crown (Lawrence 2026-11-23).
#[test]
fn the_chief_draws_its_symbol_and_home_its_house() {
    assert_eq!(built_in_named("chief").map(|b| (b.symbol, b.icon)), Some(("sparkles", None)));
    assert_eq!(built_in_named("home").map(|b| b.symbol), Some("house"));
    assert!(built_in_named("new_workspace").is_none(), "a retired built-in names no look");
}

// First-party apps read as their former built-ins until the registry answers (R63/R64).
#[test]
fn a_first_party_app_keeps_its_built_ins_look() {
    let face = fallback(&r("app", "cmux/home"), None, false);
    assert_eq!(face.built_in.as_deref(), Some("home"));
    assert!(!face.is_missing);
    let other = fallback(&r("app", "acme/notes"), None, false);
    assert_eq!(other.icon.as_deref(), Some("app.generic"));
    assert!(other.is_missing);
}

// SidebarRestoreClosedPinsTests / #42372: a closed workspace never draws its raw reference.
#[test]
fn a_closed_workspace_dims_under_its_name_or_hides() {
    let named = fallback(&r("workspace", "s1:ws_1"), Some("Build"), true);
    assert_eq!(named.title.as_deref(), Some("Build"));
    assert!(named.is_missing && !named.is_hidden);
    let nameless = fallback(&r("workspace", "s1:ws_1"), None, true);
    assert!(nameless.is_hidden);
    let bare_ref = fallback(&r("workspace", "s1:ws_1"), None, false);
    assert!(!bare_ref.is_hidden, "the ref fallback alone does not hide");
    assert_eq!(fallback(&r("plugin", "x"), None, false).icon.as_deref(), Some("icon.missing"));
}

// NewWindowSidebarFirstFrameTests: the bands skip a nameless pin no workspace answers.
#[test]
fn hidden_items_are_the_infos_hidden_and_the_nameless_undescribed_workspaces() {
    let sections = vec![Section {
        items: vec![
            item("closed", "workspace", "s:ws_1", None),
            item("named", "workspace", "s:ws_2", Some("Old")),
            item("open", "workspace", "s:ws_3", None),
            item("store", "built_in", "app_store", None),
        ],
    }];
    let infos = BTreeMap::from([("open".to_string(), false), ("store".to_string(), true)]);
    assert_eq!(hidden_items(&sections, &infos), vec!["closed".to_string(), "store".to_string()]);
}

// AccountAvatarImagesTests: "Leo Li" is "LL", the initial stays the first letter.
#[test]
fn avatar_initials_take_the_first_and_last_words() {
    assert_eq!(initials("Leo Li"), "LL");
    assert_eq!(initials("leo.li@cmux.com"), "L");
    assert_eq!(initials("Ada  Byron Lovelace"), "AL");
    assert_eq!(initials("  "), "?");
    assert_eq!(initial("Leo"), "L");
    assert_eq!(initial("-- 9lives"), "9");
    assert_eq!(initial("!!"), "?");
}

#[test]
fn item_info_vectors_match_the_swift_transliteration() {
    let vectors: Value =
        serde_json::from_str(include_str!("../../../../schemas/sidebar-item-info/vectors.json"))
            .unwrap_or(Value::Null);
    let cases = vectors["cases"].as_array().cloned().unwrap_or_default();
    assert!(cases.len() > 500, "the vectors load");
    for case in cases {
        let request: Request = serde_json::from_value(case["request"].clone())
            .unwrap_or_else(|e| panic!("{e}: {}", case["request"]));
        let reply = serde_json::to_value(respond(&request)).unwrap_or(Value::Null);
        assert_eq!(reply, case["reply"], "request {}", case["request"]);
    }
    assert_eq!(json!(initials("Zoë Ng")), json!("ZN"));
}
