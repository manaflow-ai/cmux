use serde_json::json;

use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

/// The personal team is the same id the Swift gate (`GitHubConnections.personalTeam`) and acpmux's
/// `personal_team_of` compute: `team_` and 20 hex digits of SHA-256 of `personal:<user>`.
#[test]
fn personal_team_matches_the_backend_formula() {
    let team = personal_team_of("user_0123456789abcdef0123");
    assert!(team.starts_with("team_") && team.len() == 25, "{team}");
    assert_eq!(team, personal_team_of("user_0123456789abcdef0123"));
    assert_ne!(team, personal_team_of("user_other"));
}

/// With no `--team`, the gate's two teams: the install token's, then the person's own; once each; `--no-personal`
/// drops the personal one; asked teams replace both.
#[test]
fn teams_are_the_gates_teams() {
    let personal = personal_team_of("u");
    assert_eq!(
        teams(&[], (Some("team_a"), Some("u")), true),
        vec![("team_a".to_owned(), "install"), (personal.clone(), "personal")]
    );
    assert_eq!(
        teams(&[], (Some("team_a"), Some("u")), false),
        vec![("team_a".to_owned(), "install")]
    );
    assert_eq!(teams(&[], (Some(&personal), Some("u")), true), vec![(personal.clone(), "install")]);
    assert_eq!(
        teams(&words(&["team_x", "team_x", "team_y"]), (Some("team_a"), Some("u")), true),
        vec![("team_x".to_owned(), "asked"), ("team_y".to_owned(), "asked")]
    );
    assert!(teams(&[], (None, None), true).is_empty());
}

fn status(mode: &str, online: bool) -> Value {
    let body = json!({"ok": true, "gateway": {"mode": mode, "online": online}});
    super::super::inference_gateway_admin::status_answer(false, &body)
}

/// Ready when either team serves the agent (the gate's union), whichever team it is.
#[test]
fn either_team_serving_is_ready() {
    let rows = [
        team_row("team_a", "install", &status("off", false)),
        team_row("team_p", "personal", &status("gateway", true)),
    ];
    let answer = verdict("claude", &rows);
    assert_eq!(answer["ready"], true);
    assert!(answer["reason"].is_null());
    assert_eq!(answer["serves"], json!(["claude", "codex"]));
    assert_eq!(answer["teams"][1]["gateway"]["online"], true);
}

/// Not ready always carries a reason naming each team's state.
#[test]
fn not_ready_says_why_per_team() {
    let rows = [
        team_row("team_a", "install", &status("off", false)),
        team_row("team_p", "personal", &status("gateway", false)),
    ];
    let answer = verdict("claude", &rows);
    assert_eq!(answer["ready"], false);
    assert_eq!(answer["reason"]["code"], "gateway_offline");
    let message = answer["reason"]["message"].as_str().unwrap();
    assert!(
        message.contains("team_a: mode off")
            && message.contains("team_p: gateway mode on, gateway offline"),
        "{message}"
    );

    let unread = error_json("api.unreachable", "the cmux API did not answer");
    let rows = [team_row("team_a", "install", &unread)];
    let answer = verdict("claude", &rows);
    assert_eq!(answer["reason"]["code"], "gateway_unread");
    assert_eq!(answer["teams"][0]["error"]["code"], "api.unreachable");

    assert_eq!(
        verdict("claude", &[team_row("team_a", "install", &status("off", false))])["reason"]["code"],
        "gateway_off"
    );
    assert_eq!(verdict("claude", &[])["reason"]["code"], "no_team");
}

#[test]
fn parse_defaults_and_refusals() {
    let none = |_: &str| None;
    let o = parse(&[], &none).unwrap();
    assert_eq!((o.agent.as_str(), o.personal, o.token.clone()), ("claude", true, TokenSource::App));
    let o = parse(&words(&["--agent=codex", "--team", "team_x", "--no-personal"]), &none).unwrap();
    assert_eq!(
        (o.agent.as_str(), o.teams.clone(), o.personal),
        ("codex", words(&["team_x"]), false)
    );
    assert!(parse(&words(&["--agent", "gemini"]), &none).is_err());
    assert!(parse(&words(&["--token-file", "/t"]), &none).is_err());
    assert!(parse(&words(&["--bogus"]), &none).is_err());
}
