use serde_json::{Value, json};

use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn parsed(words: &[&str]) -> Result<Invocation, UsageError> {
    let all = args(words);
    let rest = split(&all).expect("an auth command");
    parse(rest)
}

#[test]
fn token_takes_an_optional_team() {
    assert_eq!(parsed(&["auth", "token"]).unwrap(), Invocation::Token { team: None });
    let team = "team_aaaaaaaaaaaaaaaaaaaa";
    assert_eq!(
        parsed(&["auth", "token", "--team", team]).unwrap(),
        Invocation::Token { team: Some(team.to_owned()) }
    );
    assert_eq!(
        parsed(&["auth", "token", &format!("--team= {team} ")]).unwrap(),
        Invocation::Token { team: Some(team.to_owned()) }
    );
    // An empty team is the app's team, not an empty id.
    assert_eq!(parsed(&["auth", "token", "--team="]).unwrap(), Invocation::Token { team: None });
    assert!(split(&args(&["billing", "status"])).is_none());
}

#[test]
fn globals_stay_out_of_the_verb() {
    let all = args(&["auth", "token", "--json", "--team", "team_aaaaaaaaaaaaaaaaaaaa"]);
    let (global, command) = super::super::parse_globals(&all).expect("globals");
    assert_eq!(global.output, OutputMode::Json);
    assert_eq!(
        parse(split(&command).expect("auth")).unwrap(),
        Invocation::Token { team: Some("team_aaaaaaaaaaaaaaaaaaaa".to_owned()) }
    );
}

#[test]
fn help_and_bad_words_are_refused_or_answered() {
    assert_eq!(parsed(&["auth"]).unwrap(), Invocation::Help);
    assert_eq!(parsed(&["auth", "--help"]).unwrap(), Invocation::Help);
    assert_eq!(parsed(&["auth", "token", "-h"]).unwrap(), Invocation::Help);
    assert_eq!(parsed(&["auth", "help"]).unwrap(), Invocation::Help);
    assert!(parsed(&["auth", "login"]).unwrap_err().0.contains("login"));
    assert!(parsed(&["auth", "token", "extra"]).unwrap_err().0.contains("extra"));
    assert!(parsed(&["auth", "token", "--team"]).unwrap_err().0.contains("--team"));
    assert!(parsed(&["auth", "token", "--refresh"]).is_err());
}

#[test]
fn the_request_names_the_team_only_when_given() {
    assert_eq!(Value::Object(request(None)), json!({}));
    assert_eq!(Value::Object(request(Some("team_x"))), json!({ "team": "team_x" }));
}

#[test]
fn text_output_is_the_bare_token_for_command_substitution() {
    let answer = json!({
        "access_token": "eyJ.eyJ.sig",
        "token_type": "Bearer",
        "team": "team_aaaaaaaaaaaaaaaaaaaa",
        "expires_in": 540,
    });
    assert_eq!(token_line(&answer).as_deref(), Some("eyJ.eyJ.sig\n"));
    assert_eq!(token_line(&json!({})), None);
    assert_eq!(token_line(&json!({ "access_token": "" })), None);
    assert_eq!(token_line(&json!({ "access_token": "a b" })), None);
}

#[test]
fn refusals_exit_with_the_code_a_script_acts_on() {
    assert_eq!(exit_code(&json!({ "code": "not_signed_in" })), 3);
    assert_eq!(exit_code(&json!({ "code": "no_team" })), 3);
    assert_eq!(exit_code(&json!({ "code": "method_not_found" })), 5);
    assert_eq!(exit_code(&json!({ "code": "feature.disabled" })), 1);
    assert_eq!(exit_code(&json!({ "code": "forbidden" })), 1);
}

#[test]
fn usage_is_localized_and_names_the_export_form() {
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let messages = &crate::localization::catalog_for_locale(locale).auth_token;
        assert!(messages.usage.contains("export CMUX_TOKEN=$(cmux auth token)"), "{locale}");
        assert!(messages.usage.contains("--team"), "{locale}");
        assert!(messages.usage.ends_with('\n'), "{locale}");
    }
}
