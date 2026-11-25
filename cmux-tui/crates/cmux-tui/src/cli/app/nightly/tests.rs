use serde_json::{Value, json};

use super::{Command, Switched, Target, human, parse, pick, switched};
use crate::localization::NightlyMessages;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn messages() -> &'static NightlyMessages {
    &crate::localization::catalog().app_control.nightly
}

/// The running build is 400; 500 is the bad one above it, 300 was pulled, 200 is kept.
fn listing() -> Value {
    let build = |number: &str, installed: bool, health: &str, switchable: bool| {
        json!({ "build": number, "version": "0.1", "date": "2026-11-01", "commit": "abcdef0123", "health": health,
                "pulled_reason": if health == "pulled" { json!("crashes on launch") } else { Value::Null },
                "installed": installed, "kept": number == "200", "switchable": switchable,
                "titles": ["Fix the sidebar", "Faster tabs"] })
    };
    json!({ "installed": "400", "switches": true, "builds": [
        build("500", false, "pending", true),
        build("400", true, "pending", false),
        build("300", false, "pulled", false),
        build("200", false, "promoted", true),
        build("1000", false, "held", true),
    ]})
}

fn picked(target: Target) -> Result<String, &'static str> {
    let listing = listing();
    pick(&listing, &target, messages())
        .map(|build| build["build"].as_str().unwrap().to_owned())
        .map_err(|(code, _)| code)
}

#[test]
fn nightly_parse_reads_list_and_install() {
    assert_eq!(parse(&words(&["list"])).unwrap(), Command::List { limit: 10 });
    assert_eq!(parse(&words(&["list", "--limit", "5"])).unwrap(), Command::List { limit: 5 });
    assert_eq!(parse(&words(&["list", "--limit=30"])).unwrap(), Command::List { limit: 30 });
    assert_eq!(
        parse(&words(&["install", "previous"])).unwrap(),
        Command::Install { target: Target::Previous }
    );
    assert_eq!(
        parse(&words(&["install", "4152702995101"])).unwrap(),
        Command::Install { target: Target::Build("4152702995101".into()) }
    );
    assert!(parse(&words(&[])).is_err());
    assert!(parse(&words(&["install"])).is_err());
    assert!(parse(&words(&["install", "../x"])).is_err());
    assert!(parse(&words(&["install", "previous", "extra"])).is_err());
    assert!(parse(&words(&["list", "--limit", "0"])).is_err());
    assert!(parse(&words(&["list", "--bogus"])).is_err());
}

#[test]
fn nightly_cli_routes_to_the_nightly_command() {
    assert_eq!(
        super::super::parse(&words(&["nightly", "install", "previous"])).unwrap(),
        Some(super::super::AppCommand::Nightly(Command::Install { target: Target::Previous }))
    );
}

/// `previous` is the newest installable build below the running one: never the bad build above
/// it, never a pulled build, and builds compare as numbers (1000 is above 400, not below).
#[test]
fn nightly_previous_skips_newer_and_pulled_builds() {
    assert_eq!(picked(Target::Previous), Ok("200".into()));
}

#[test]
fn nightly_install_refuses_the_running_pulled_and_unknown_builds() {
    assert_eq!(picked(Target::Build("500".into())), Ok("500".into()));
    assert_eq!(picked(Target::Build("400".into())), Err("nightly.installed"));
    assert_eq!(picked(Target::Build("300".into())), Err("nightly.pulled"));
    assert_eq!(picked(Target::Build("7".into())), Err("nightly.unknown_build"));
}

#[test]
fn nightly_install_refuses_an_app_that_follows_no_feed() {
    let mut listing = listing();
    listing["switches"] = json!(false);
    let result = pick(&listing, &Target::Previous, messages()).map_err(|(code, _)| code);
    assert_eq!(result.err(), Some("nightly.cannot_switch"));
    let only_newer = json!({ "installed": "400", "switches": true, "builds": [
        { "build": "500", "switchable": true, "health": "pending" } ] });
    let result = pick(&only_newer, &Target::Previous, messages()).map_err(|(code, _)| code);
    assert_eq!(result.err(), Some("nightly.no_previous"));
}

#[test]
fn nightly_list_marks_the_running_kept_and_pulled_builds() {
    let text = human(&listing(), messages());
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 5);
    assert!(lines[1].starts_with("* 400"), "{}", lines[1]);
    assert!(lines[2].contains(messages().pulled_tag));
    assert!(lines[3].contains(messages().kept));
    assert!(lines[0].contains("abcdef01") && lines[0].contains("Fix the sidebar; Faster tabs"));
    assert_eq!(human(&json!({ "builds": [] }), messages()), format!("{}\n", messages().no_builds));
}

/// Only a connection that closes with no answer counts as the restart; an answer, a refusal and an
/// unreadable line are reported as they are.
#[test]
fn nightly_install_counts_only_a_closed_connection_as_the_restart() {
    assert!(matches!(switched(""), Switched::Restarted));
    assert!(matches!(switched("\n"), Switched::Restarted));
    assert!(matches!(
        switched(r#"{"id":1,"ok":true,"result":{"switching_to":"200"}}"#),
        Switched::Answer(Ok(_))
    ));
    assert!(matches!(
        switched(r#"{"id":1,"ok":false,"error":{"code":"switch_refused","message":"no"}}"#),
        Switched::Answer(Err(_))
    ));
    assert!(matches!(switched("{not json"), Switched::Failed(_)));
}

#[test]
fn help_words_ask_for_the_usage_text() {
    for args in [&["help"][..], &["--help"], &["-h"], &["list", "--help"], &["install", "-h"]] {
        assert_eq!(parse(&words(args)).unwrap(), Command::Help, "{args:?}");
    }
}
