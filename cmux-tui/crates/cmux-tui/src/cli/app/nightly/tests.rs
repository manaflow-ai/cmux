use serde_json::{Value, json};

use super::{Command, Switched, Target, feed, human, parse, parse_app, pick, switched};
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

/// `cmux app versions` and `cmux app use` are `nightly list` and `nightly install`.
#[test]
fn app_versions_and_use_are_the_nightly_commands() {
    assert_eq!(parse_app("versions", &words(&[])).unwrap(), Command::List { limit: 10 });
    assert_eq!(
        parse_app("versions", &words(&["--limit", "3"])).unwrap(),
        Command::List { limit: 3 }
    );
    assert_eq!(
        parse_app("use", &words(&["previous"])).unwrap(),
        Command::Install { target: Target::Previous }
    );
    assert_eq!(
        parse_app("use", &words(&["next"])).unwrap(),
        Command::Install { target: Target::Next }
    );
    assert_eq!(
        parse_app("use", &words(&["latest"])).unwrap(),
        Command::Install { target: Target::Latest }
    );
    assert_eq!(
        parse_app("use", &words(&["200"])).unwrap(),
        Command::Install { target: Target::Build("200".into()) }
    );
    assert_eq!(parse_app("use", &words(&["--help"])).unwrap(), Command::Help);
    assert!(parse_app("use", &words(&[])).is_err());
    assert!(parse_app("use", &words(&["older"])).is_err());
    assert_eq!(
        super::super::parse(&words(&["app", "use", "previous"])).unwrap(),
        Some(super::super::AppCommand::Nightly(Command::Install { target: Target::Previous }))
    );
    assert_eq!(
        super::super::parse(&words(&["app", "versions"])).unwrap(),
        Some(super::super::AppCommand::Nightly(Command::List { limit: 10 }))
    );
}

/// `next` is one step forward (the undo of `previous`), `latest` the newest; neither is a pulled
/// build, and both refuse when nothing installable is above the running build.
#[test]
fn app_use_next_and_latest_go_forward() {
    assert_eq!(picked(Target::Next), Ok("500".into()));
    assert_eq!(picked(Target::Latest), Ok("1000".into()));
    let back = json!({ "installed": "200", "switches": true, "builds": [
        { "build": "500", "switchable": true, "health": "pending" },
        { "build": "400", "switchable": true, "health": "pending", "kept": true },
        { "build": "300", "switchable": false, "health": "pulled" },
        { "build": "200", "switchable": false, "installed": true } ] });
    let next = pick(&back, &Target::Next, messages()).map(|build| build["build"].as_str().unwrap());
    assert_eq!(next.map_err(|(code, _)| code), Ok("400"));
    let top = json!({ "installed": "500", "switches": true, "builds": [
        { "build": "500", "switchable": false, "installed": true },
        { "build": "400", "switchable": true } ] });
    for target in [Target::Next, Target::Latest] {
        let result = pick(&top, &target, messages()).map_err(|(code, _)| code);
        assert_eq!(result.err(), Some("nightly.no_next"));
    }
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

/// A build the appcast offers before its notes land comes with no commit and no titles: it is
/// still the `*` row when it runs, and installable from an older build.
#[test]
fn nightly_lists_and_installs_a_build_whose_notes_lag_the_appcast() {
    let ahead = |installed: bool| {
        json!({ "build": "4495894547301", "version": "1.0.0-nightly.4495894547301", "date": "2026-11-21",
                "commit": Value::Null, "health": "pending", "installed": installed, "kept": false,
                "switchable": !installed, "titles": [] })
    };
    let older = |installed: bool| {
        json!({ "build": "4495375783401", "version": "1.0.0-nightly.4495375783401", "date": "2026-11-21",
                "commit": "afeb89238dab", "health": "pending", "installed": installed, "kept": false,
                "switchable": !installed, "titles": ["Faster tabs"] })
    };
    let running = json!({ "installed": "4495894547301", "switches": true,
                          "builds": [ahead(true), older(false)] });
    let text = human(&running, messages());
    let lines: Vec<&str> = text.lines().collect();
    assert!(lines[0].starts_with("* 4495894547301"), "{}", lines[0]);
    assert!(lines[1].starts_with("  4495375783401"), "{}", lines[1]);
    let previous = pick(&running, &Target::Previous, messages()).map_err(|(code, _)| code);
    assert_eq!(previous.map(|build| build["build"].clone()), Ok(json!("4495375783401")));

    let behind = json!({ "installed": "4495375783401", "switches": true,
                         "builds": [ahead(false), older(true)] });
    let target = Target::Build("4495894547301".into());
    let picked = pick(&behind, &target, messages()).map_err(|(code, _)| code);
    assert_eq!(picked.map(|build| build["build"].clone()), Ok(json!("4495894547301")));
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

/// Notes in today's shape (no `area`, `since` or `publishedAt`) and in the shape the publisher adds.
fn notes(build: &str, items: Value) -> Value {
    json!({ "build": build, "shortVersion": format!("1.0.0-nightly.{build}"), "builtAt": "2026-11-26T00:01:59Z",
            "date": "2026-11-26", "head": "0a6830e6", "items": items })
}

fn index() -> Value {
    json!({ "version": 1, "builds": [
        { "build": "4572038238101" }, { "build": "4569000000000" }, { "build": "4494208705801" },
    ]})
}

#[test]
fn whats_in_and_which_parse() {
    assert_eq!(parse(&words(&["whats-in"])), Ok(Command::WhatsIn { build: None }));
    assert_eq!(
        parse(&words(&["whats-in", "4572038238101"])),
        Ok(Command::WhatsIn { build: Some("4572038238101".into()) })
    );
    assert!(parse(&words(&["whats-in", "latest"])).is_err());
    assert!(parse(&words(&["whats-in", "1", "2"])).is_err());
    for word in [
        "57000",
        "#57000",
        "https://github.com/manaflow-ai/cmux/pull/57000",
        "https://github.com/manaflow-ai/cmux/pull/57000/",
    ] {
        assert_eq!(parse(&words(&["which", word])), Ok(Command::Which { pr: 57000 }), "{word}");
    }
    assert!(parse(&words(&["which"])).is_err());
    assert!(parse(&words(&["which", "abc"])).is_err());
    assert!(parse(&words(&["which", "1", "2"])).is_err());
}

#[test]
fn the_running_build_comes_from_either_build_spelling() {
    assert_eq!(feed::build_number("4572038238101").as_deref(), Some("4572038238101"));
    assert_eq!(feed::build_number("1.0.0-nightly.4572038238101").as_deref(), Some("4572038238101"));
    assert_eq!(feed::build_number("1.0.0-dev"), None);
}

#[test]
fn whats_in_groups_by_area_with_the_unnamed_last_and_takes_since_from_the_index() {
    let today = notes(
        "4572038238101",
        json!([
            { "author": "Leo", "pr": 56942, "title": "acpmux: move peers.rs" },
            { "author": "lawrence", "pr": 56940, "title": "Faster tabs", "area": "Terminal" },
            { "author": "aziz", "pr": 56930, "title": "Sidebar fix", "area": "Agent chat" },
            { "author": "lawrence", "pr": 56920, "title": "Tab drag", "area": "Terminal" },
        ]),
    );
    let report = feed::whats_in(&today, Some(&index()));
    assert_eq!(report["count"], 4);
    assert_eq!(report["since"]["build"], "4569000000000");
    assert_eq!(report["publishedAt"], "2026-11-26T00:01:59Z");
    let areas: Vec<Value> =
        report["areas"].as_array().unwrap().iter().map(|group| group["area"].clone()).collect();
    assert_eq!(areas, vec![json!("Agent chat"), json!("Terminal"), Value::Null]);
    assert_eq!(report["areas"][1]["items"][1]["pr"], 56920);
    assert_eq!(
        report["areas"][2]["items"][0]["url"],
        "https://github.com/manaflow-ai/cmux/pull/56942"
    );
    let text = feed::whats_in_human(&report, messages());
    assert!(text.starts_with("NIGHTLY 4572038238101 (1.0.0-nightly.4572038238101), published 2026-11-26T00:01:59Z: 4 PRs since build 4569000000000\n"), "{text}");
    assert!(
        text.contains(
            "\nTerminal\n  #56940 Faster tabs (@lawrence)\n  #56920 Tab drag (@lawrence)\n"
        ),
        "{text}"
    );
    assert!(text.ends_with("\nOther\n  #56942 acpmux: move peers.rs (@Leo)\n"), "{text}");
}

#[test]
fn whats_in_prefers_the_notes_own_since_and_published_time() {
    let mut later = notes("4572038238101", json!([]));
    later["since"] = json!({ "build": "4494208705801", "head": "340e97e5" });
    later["publishedAt"] = json!("2026-11-26T00:20:00Z");
    let report = feed::whats_in(&later, Some(&index()));
    assert_eq!(report["since"]["build"], "4494208705801");
    assert_eq!(report["publishedAt"], "2026-11-26T00:20:00Z");
    assert!(feed::whats_in_human(&report, messages()).contains("no PRs are listed"));
    // The oldest build has nothing before it.
    let first = feed::whats_in(&notes("4494208705801", json!([])), Some(&index()));
    assert_eq!(first["since"], Value::Null);
}

#[test]
fn which_reads_the_pr_index_in_either_shape() {
    let entry = json!({ "build": "4572038238101", "shortVersion": "1.0.0-nightly.4572038238101", "publishedAt": "2026-11-26T00:20:00Z" });
    for pr_index in [json!({ "prs": { "57000": entry } }), json!({ "57000": entry })] {
        let answer = feed::which_from_pr_index(&pr_index, 57000).unwrap();
        assert_eq!(answer["build"], "4572038238101");
        assert_eq!(
            feed::which_human(&answer, messages()),
            "PR #57000 shipped in NIGHTLY 4572038238101 (1.0.0-nightly.4572038238101) at 2026-11-26T00:20:00Z\n"
        );
        assert_eq!(feed::which_from_pr_index(&pr_index, 1), None);
    }
}

#[test]
fn which_without_a_pr_index_takes_the_oldest_build_that_lists_the_pr() {
    let builds = [
        notes("4572038238101", json!([{ "pr": 57000, "title": "again", "author": "Leo" }])),
        notes("4569000000000", json!([{ "pr": 57000, "title": "first", "author": "Leo" }])),
        notes("4494208705801", json!([{ "pr": 1, "title": "other", "author": "Leo" }])),
    ];
    let answer = feed::which_from_notes(&builds, 57000).unwrap();
    assert_eq!(answer["build"], "4569000000000");
    assert_eq!(answer["publishedAt"], "2026-11-26T00:01:59Z");
    assert_eq!(feed::which_from_notes(&builds, 2), None);
    let missing = feed::not_shipped(2, Some("4494208705801"));
    assert_eq!(
        feed::which_human(&missing, messages()),
        "PR #2 has not shipped in a NIGHTLY yet (the feed lists builds back to 4494208705801)\n"
    );
}

#[test]
fn the_newest_and_previous_builds_come_from_the_index() {
    assert_eq!(feed::newest(&index()).as_deref(), Some("4572038238101"));
    assert_eq!(feed::previous(&index(), "4572038238101").as_deref(), Some("4569000000000"));
    assert_eq!(feed::previous(&index(), "4494208705801"), None);
}
