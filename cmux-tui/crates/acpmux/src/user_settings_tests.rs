use super::*;

fn project(text: &str) -> cmux_config::project::ProjectLayer {
    cmux_config::project::ProjectLayer::from_text(
        Path::new("/p"),
        text,
        cmux_config::Schema::embedded(),
    )
}

fn cache(settings: &Settings) -> Option<Value> {
    match settings {
        Settings::Parsed(doc) => value(doc, "agents.promptCache"),
        _ => None,
    }
}

#[test]
fn a_project_value_wins_over_the_users_but_not_a_managed_one() {
    let layer = project(r#"{"agents": {"promptCache": "5m"}, "appearance": {"theme": "x"}}"#);
    let user = || Settings::Parsed(serde_json::json!({"agents.promptCache": "1h", "a": 1}));
    let merged = overlay(user(), &layer, &|_| false);
    assert_eq!(cache(&merged), Some(Value::from("5m")));
    let Settings::Parsed(doc) = &merged else { panic!() };
    assert_eq!(doc["a"], 1, "the user's other keys stay");
    assert_eq!(
        value(doc, "appearance.theme"),
        None,
        "a key that is not per project is ignored"
    );
    let managed = overlay(user(), &layer, &|key| key == "agents.promptCache");
    assert_eq!(cache(&managed), Some(Value::from("1h")));
    let missing = overlay(Settings::Missing, &layer, &|_| false);
    assert_eq!(cache(&missing), Some(Value::from("5m")));
    let broken = overlay(Settings::Unreadable("bad".into()), &layer, &|_| false);
    assert!(matches!(broken, Settings::Unreadable(_)));
}

#[test]
fn with_no_home_both_files_stay_relative() {
    assert_eq!(
        paths_from(|_| None, || None),
        [PathBuf::from(".config/cmux/cmux-next.json"), PathBuf::from(".config/cmux/cmux.json")]
    );
}

#[test]
fn home_and_override_resolve_as_cmux_config_does() {
    let home = |name: &str| (name == "HOME").then(|| OsString::from("/h"));
    assert_eq!(
        paths_from(home, || None),
        [
            PathBuf::from("/h/.config/cmux/cmux-next.json"),
            PathBuf::from("/h/.config/cmux/cmux.json")
        ]
    );
    let fallback = paths_from(|_| None, || Some(PathBuf::from("/d")));
    assert_eq!(fallback[1], PathBuf::from("/d/.config/cmux/cmux.json"));
    let over = |name: &str| match name {
        "HOME" => Some(OsString::from("/h")),
        CONFIG_OVERRIDE => Some(OsString::from("~/t.json")),
        _ => None,
    };
    assert_eq!(paths_from(over, || None), [PathBuf::from("/h/t.json")]);
}
