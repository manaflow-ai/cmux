//! The teams the App's Cloud wire subscribes in (Leo, Cloud V0 item 1: "harness login attached in advance").
//! The person's spare, its claim and its copy live in the install token's team ([`install_team`], #36037), while
//! the wire's socket is opened in the App's active team. For a person whose active team is not their install's
//! (a company team over a personal install), `cloud.spare.ready` and the snapshot's `spares_needing_login` were
//! told in a team the App never heard, so every claim waited on its own copy (hourly app-chat probe on Leo's
//! NIGHTLY, 13 of 13 spare hits 2026-11-15/16: `login.gate` p50 2.6 s). The wire keeps its active team and adds the
//! install's: in addition, never instead; one team when they are the same.

use serde_json::{Value, json};

use super::install_team;

/// `{"wireTeams": {"active": T}}`: the App's active team, if it has one.
#[derive(serde::Deserialize, Default)]
pub(in crate::link::start_chat_cli) struct WireTeams {
    #[serde(default)]
    pub(in crate::link::start_chat_cli) active: Option<String>,
}

/// The wire's teams, in order: the active team first (its socket keeps every event it had), then the install
/// token's team when it is another. No active team: none, the App keeps its one socket with no team, as before.
pub(in crate::link::start_chat_cli) fn wire_teams(
    active: Option<&str>,
    install_token: &str,
) -> Vec<String> {
    let Some(active) = active.map(str::trim).filter(|team| !team.is_empty()) else {
        return Vec::new();
    };
    let mut teams = vec![active.to_owned()];
    if let Some(install) = install_team(install_token)
        && install != active
    {
        teams.push(install);
    }
    teams
}

/// The answer to a `wireTeams` request, the install token being stdin's first line.
pub(in crate::link::start_chat_cli) fn answer(
    asked: &WireTeams,
    stdin: &mut dyn std::io::BufRead,
) -> Value {
    let mut install = String::new();
    let _ = stdin.read_line(&mut install);
    json!({ "teams": wire_teams(asked.active.as_deref(), &install) })
}
