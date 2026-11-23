//! A Run from an incognito chat is never saved for the next launch (its task included), so no
//! later launch can post it; only its bare id is kept while it may be open (#31040, #31208;
//! ported from the app's IncognitoSurfacesTests).

use super::sim::{NOW, Sim};
use crate::follower::Kind;
use crate::model::Record;

fn run(id: &str, task: &str, incognito: bool) -> Record {
    Record {
        id: id.into(),
        task: task.into(),
        key: format!("k-{id}"),
        user: "u".into(),
        team: None,
        started: NOW,
        cursor: None,
        told: None,
        changed: None,
        running: None,
        host: None,
        incognito: incognito.then_some(true),
    }
}

#[test]
fn incognito_runs_are_never_saved() {
    let mut sim = Sim::launch(Kind::Runs, None);
    sim.account(Some("u"));
    sim.watch(run("run_secret", "rotate the prod key", true));
    sim.watch(run("run_normal", "make test", false));
    let saved = sim.saved_text();
    assert!(saved.contains("run_normal"));
    assert!(!saved.contains("prod key"), "an incognito Run was saved for the next launch");
    let relaunched = sim.relaunch();
    let ids: Vec<&str> = relaunched.state.records.iter().map(|record| record.id.as_str()).collect();
    assert_eq!(ids, ["run_normal"], "an incognito Run's record was saved for the next launch");
}

/// Issue #31208: an incognito Run is never resumed after a relaunch (its record isn't saved, and
/// no list brings it back), so its id is dropped at the next sign-in instead of staying saved forever.
#[test]
fn an_incognito_runs_id_is_dropped_at_the_next_launchs_sign_in() {
    let mut first = Sim::launch(Kind::Runs, None);
    first.account(Some("u"));
    first.watch(run("run_secret", "rotate the prod key", true));
    assert!(first.saved_text().contains("run_secret"));
    first.stop();
    let mut relaunched = first.relaunch();
    relaunched.account(Some("u"));
    assert!(
        !relaunched.saved_text().contains("run_secret"),
        "an incognito Run's id outlived the launch that could follow it"
    );
}
