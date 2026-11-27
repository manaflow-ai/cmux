use serde_json::json;

use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn help_and_bare_words_are_the_help() {
    for list in [&[][..], &["--help"], &["gcp"], &["gcp", "set", "--help"]] {
        assert_eq!(parse(&words(list)).unwrap().verb, Verb::Help, "{list:?}");
    }
    assert!(parse(&words(&["aws", "status"])).is_err());
}

#[test]
fn set_sends_only_what_it_names() {
    let command = parse(&words(&[
        "gcp",
        "set",
        "--project",
        "acme-ci",
        "--zone=us-central1-a",
        "--service-account",
        "pool@acme-ci.iam.gserviceaccount.com",
        "--pool-size",
        "40",
        "--team",
        "team_1",
    ]))
    .unwrap();
    assert_eq!(command.team.as_deref(), Some("team_1"));
    assert_eq!(
        request(&command.verb),
        Some((
            "cloud.provider.gcp.set",
            json!({
                "project": "acme-ci",
                "zone": "us-central1-a",
                "service_account": "pool@acme-ci.iam.gserviceaccount.com",
                "pool_size": 40,
            })
        ))
    );
    let resize = parse(&words(&["gcp", "set", "--pool-size=80"])).unwrap();
    assert_eq!(request(&resize.verb), Some(("cloud.provider.gcp.set", json!({"pool_size": 80}))));
}

#[test]
fn set_refuses_nothing_to_set_and_a_bad_size() {
    assert!(parse(&words(&["gcp", "set"])).is_err());
    assert!(parse(&words(&["gcp", "set", "--pool-size", "0"])).is_err());
    assert!(parse(&words(&["gcp", "set", "--pool-size", "1001"])).is_err());
    assert!(parse(&words(&["gcp", "set", "--pool-size", "ten"])).is_err());
    assert!(parse(&words(&["gcp", "set", "--project", " "])).is_err());
    assert!(parse(&words(&["gcp", "status", "--project", "p"])).is_err());
}

#[test]
fn status_and_off_are_one_op_each() {
    let status = parse(&words(&["gcp", "status"])).unwrap();
    assert_eq!(request(&status.verb), Some(("cloud.provider.gcp.get", json!({}))));
    let off = parse(&words(&["gcp", "off"])).unwrap();
    assert_eq!(request(&off.verb), Some(("cloud.provider.gcp.set", json!({"off": true}))));
    assert_eq!(request(&Verb::Help), None);
}

#[test]
fn the_help_provider_lines_parse() {
    for japanese in [false, true] {
        let help = crate::cli::cloud_help::overview(japanese);
        let lines = help
            .lines()
            .filter_map(|line| line.trim().strip_prefix("cmux vm provider "))
            .collect::<Vec<_>>();
        assert_eq!(lines.len(), 3, "{lines:?}");
        for line in lines {
            let line = line.trim_end_matches(" --json");
            let filled = line
                .split_whitespace()
                .map(|word| match word {
                    "TEAM_ID" => "team_1",
                    "N" => "4",
                    other => other,
                })
                .collect::<Vec<_>>();
            let command = parse(&words(&filled)).unwrap_or_else(|e| panic!("{line}: {}", e.0));
            assert_ne!(command.verb, Verb::Help, "{line}");
            assert_eq!(command.team.as_deref(), Some("team_1"), "{line}");
        }
    }
}
