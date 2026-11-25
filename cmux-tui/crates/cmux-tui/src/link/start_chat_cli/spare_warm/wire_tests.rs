use super::install_token;
use super::wire::{WireTeams, answer, wire_teams};

const ACTIVE: &str = "team_aaaaaaaaaaaaaaaaaaaa";
const PERSONAL: &str = "team_0123456789abcdef0123";

#[test]
fn the_wire_adds_the_install_tokens_team_to_the_active_one() {
    assert_eq!(
        wire_teams(Some(ACTIVE), &install_token(PERSONAL)),
        vec![ACTIVE.to_owned(), PERSONAL.to_owned()]
    );
}

#[test]
fn the_same_team_is_one_subscription() {
    assert_eq!(wire_teams(Some(PERSONAL), &install_token(PERSONAL)), vec![PERSONAL.to_owned()]);
}

#[test]
fn the_active_team_is_never_replaced() {
    // An install token with no team, or no token: the active team alone, as before.
    assert_eq!(wire_teams(Some(ACTIVE), ""), vec![ACTIVE.to_owned()]);
    assert_eq!(wire_teams(Some(ACTIVE), "not-a-jwt"), vec![ACTIVE.to_owned()]);
    // No active team: no team list, so the App keeps its one socket with no team.
    assert!(wire_teams(None, &install_token(PERSONAL)).is_empty());
    assert!(wire_teams(Some(" "), &install_token(PERSONAL)).is_empty());
}

#[test]
fn the_answer_reads_the_install_token_from_stdin() {
    let asked = WireTeams { active: Some(ACTIVE.to_owned()) };
    let stdin = format!("{}\n", install_token(PERSONAL));
    assert_eq!(
        answer(&asked, &mut stdin.as_bytes())["teams"],
        serde_json::json!([ACTIVE, PERSONAL])
    );
}
