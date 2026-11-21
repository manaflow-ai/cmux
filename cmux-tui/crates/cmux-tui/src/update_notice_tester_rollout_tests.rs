use super::*;
use std::collections::BTreeMap;

fn inputs<'a>(
    channel: InstallChannel,
    forced: &'a BTreeMap<String, Value>,
    settings: Option<&'a Value>,
    env: &'a dyn Fn(&str) -> Option<String>,
) -> CheckInputs<'a> {
    CheckInputs { channel, managed_forced: forced, settings, release_build: true, env }
}

#[test]
fn only_package_installs_check_and_every_switch_turns_it_off() {
    let none: BTreeMap<String, Value> = BTreeMap::new();
    let no_env = |_: &str| -> Option<String> { None };
    assert_eq!(allowed(&inputs(InstallChannel::Npm, &none, None, &no_env)), Check::Allowed);
    assert_eq!(allowed(&inputs(InstallChannel::Pypi, &none, None, &no_env)), Check::Allowed);
    assert!(matches!(allowed(&inputs(InstallChannel::App, &none, None, &no_env)), Check::Off(_)));
    let off = serde_json::json!({"updates": {"checkAutomatically": false}});
    assert_eq!(
        allowed(&inputs(InstallChannel::Npm, &none, Some(&off), &no_env)),
        Check::Off("updates.checkAutomatically is false")
    );
    let managed = BTreeMap::from([("DisableAutoUpdate".to_string(), Value::Bool(true))]);
    assert_eq!(
        allowed(&inputs(InstallChannel::Npm, &managed, None, &no_env)),
        Check::Off("managed policy DisableAutoUpdate")
    );
    let ci = |name: &str| (name == "CI").then(|| "true".to_string());
    assert_eq!(allowed(&inputs(InstallChannel::Npm, &none, None, &ci)), Check::Off("CI"));
    let env_off = |name: &str| (name == "CMUX_TUI_UPDATE_CHECK").then(|| "off".to_string());
    assert_eq!(
        allowed(&inputs(InstallChannel::Npm, &none, None, &env_off)),
        Check::Off("CMUX_TUI_UPDATE_CHECK")
    );
    let mut local = inputs(InstallChannel::Npm, &none, None, &no_env);
    local.release_build = false;
    assert_eq!(allowed(&local), Check::Off("not a release build"));
}

#[test]
fn both_registries_name_the_latest_release() {
    assert_eq!(parse_latest(br#"{"version":"0.14.0"}"#).as_deref(), Some("0.14.0"));
    assert_eq!(parse_latest(br#"{"info":{"version":"1.2.3"}}"#).as_deref(), Some("1.2.3"));
    assert_eq!(parse_latest(br#"{"version":"latest"}"#), None);
    assert_eq!(parse_latest(b"<html>"), None);
}

#[test]
fn releases_order_by_number_and_a_release_beats_its_prerelease() {
    assert!(newer("0.14.0", "0.13.4"));
    assert!(newer("1.0.0", "0.99.99"));
    assert!(newer("0.10.0", "0.9.0"));
    assert!(newer("1.0.0", "1.0.0-rc.1"));
    assert!(!newer("0.13.4", "0.13.4"));
    assert!(!newer("0.13.3", "0.13.4"));
    assert!(!newer("1.0.0-rc.2", "1.0.0"));
    assert!(!newer("garbage", "0.1.0"));
    assert!(newer("1.1.0-next.4", "1.1.0-next.3"));
    assert!(newer("1.1.0-next.10", "1.1.0-next.9"));
    assert!(!newer("1.1.0-next.3", "1.1.0-next.3"));
    assert!(newer("1.1.0-next.1", "1.1.0-alpha.9"));
}

#[test]
fn one_answer_holds_for_a_day_and_one_channel() {
    let day = CHECK_INTERVAL.as_millis() as u64;
    let cached =
        Cached { checked_at_ms: 1_000, latest: "1.0.0".into(), next: None, channel: "npm".into() };
    assert!(due(None, InstallChannel::Npm, 1_000));
    assert!(!due(Some(&cached), InstallChannel::Npm, 1_000 + day - 1));
    assert!(due(Some(&cached), InstallChannel::Npm, 1_000 + day));
    assert!(due(Some(&cached), InstallChannel::Pypi, 1_000));
    // A clock that went back does not freeze the check.
    assert!(due(Some(&cached), InstallChannel::Npm, 10));
}

#[test]
fn the_notice_names_the_command_for_the_install() {
    let cached =
        Cached { checked_at_ms: 0, latest: "0.14.0".into(), next: None, channel: "pypi".into() };
    let english = crate::localization::update_notice_english().available;
    let line = notice(english, &cached, InstallChannel::Pypi, "0.13.4").unwrap();
    assert_eq!(line, "cmux 0.14.0 is available (you have 0.13.4). Update: uv tool upgrade cmux");
    assert_eq!(notice(english, &cached, InstallChannel::Npm, "0.13.4"), None);
    assert_eq!(notice(english, &cached, InstallChannel::Pypi, "0.14.0"), None);
    let japanese = crate::localization::update_notice_japanese().available;
    let line = notice(japanese, &cached, InstallChannel::Pypi, "0.13.4").unwrap();
    assert!(line.contains("0.14.0") && line.contains("uv tool upgrade cmux"), "{line}");
}

#[test]
fn a_tester_on_next_hears_about_the_newer_tag() {
    let english = crate::localization::update_notice_english().available;
    let cached = Cached {
        checked_at_ms: 0,
        latest: "1.0.0".into(),
        next: Some("1.1.0-next.4".into()),
        channel: "npm".into(),
    };
    let line = notice(english, &cached, InstallChannel::Npm, "1.1.0-next.3").unwrap();
    assert!(line.contains("1.1.0-next.4") && line.ends_with("cmux@next"), "{line}");
    // A stable install never hears about next.
    assert_eq!(notice(english, &cached, InstallChannel::Npm, "1.0.0"), None);
    // A stable release past next moves the tester to latest.
    let past = Cached { latest: "1.2.0".into(), ..cached };
    let line = notice(english, &past, InstallChannel::Npm, "1.1.0-next.3").unwrap();
    assert!(line.contains("1.2.0") && line.ends_with("cmux@latest"), "{line}");
}

#[test]
fn only_npm_has_a_next_tag() {
    assert_eq!(
        next_url(InstallChannel::Npm, "https://registry.npmjs.org/cmux/latest").as_deref(),
        Some("https://registry.npmjs.org/cmux/next")
    );
    assert_eq!(next_url(InstallChannel::Pypi, "https://pypi.org/pypi/cmux/json"), None);
}

#[test]
fn the_cache_round_trips() {
    let root = tempfile::tempdir().unwrap();
    let cached = Cached {
        checked_at_ms: 42,
        latest: "1.0.1".into(),
        next: Some("1.1.0-next.2".into()),
        channel: "npm".into(),
    };
    write_cache(root.path(), &cached).unwrap();
    assert_eq!(read_cache(root.path()), Some(cached));
}
