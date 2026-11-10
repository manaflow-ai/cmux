//! The decisions' cases (CloudCLITargetTests, CloudNewWorkspaceTests, CloudWorkspaceSetupLifecycleTests,
//! CloudCapRefusalRunTests, CloudTrackedResultsTests, CloudBrowserActionTests, CloudGitHubSetupTests).

use super::*;

fn lookup(value: Value) -> Lookup {
    serde_json::from_value(value).unwrap()
}

#[test]
fn a_named_machine_is_found_or_not_found() {
    assert_eq!(machine(&lookup(json!({"named": "vm-1", "namedFound": true}))), Ok(Pick::Named));
    let missing = machine(&lookup(json!({"named": "vm-9", "byUser": true, "activeFound": true})))
        .unwrap_err();
    assert_eq!(missing, Said::with("unknownMachine", ["vm-9"]).not_found());
}

#[test]
fn only_a_person_may_mean_the_machine_in_view() {
    assert_eq!(
        machine(&lookup(json!({"activeFound": true, "cloudCount": 1}))),
        Err(Said::key("noMachine"))
    );
    assert_eq!(
        machine(&lookup(json!({"byUser": true, "activeFound": true, "cloudCount": 3}))),
        Ok(Pick::Active)
    );
    assert_eq!(machine(&lookup(json!({"byUser": true, "cloudCount": 1}))), Ok(Pick::Only));
    assert_eq!(
        machine(&lookup(json!({"byUser": true, "cloudCount": 2}))),
        Err(Said::key("noMachine"))
    );
}

#[test]
fn new_cloud_workspace_routes() {
    assert_eq!(new_workspace(true, true, false, false), NewWorkspace::Workspace);
    assert_eq!(new_workspace(true, false, true, true), NewWorkspace::Connecting);
    assert_eq!(new_workspace(false, false, true, true), NewWorkspace::Setup);
    assert_eq!(new_workspace(false, false, true, false), NewWorkspace::NewMachine);
    assert_eq!(
        new_workspace(false, false, false, true),
        NewWorkspace::NewMachine,
        "a CLI with no target gets a new machine"
    );
}

#[test]
fn new_cloud_machine_starts() {
    assert_eq!(new_machine_start(true, true, true), NewMachineStart::Setup);
    assert_eq!(new_machine_start(true, false, true), NewMachineStart::Default);
    assert_eq!(new_machine_start(true, true, false), NewMachineStart::Default);
    assert_eq!(new_machine_start(false, true, true), NewMachineStart::Requested);
}

#[test]
fn setup_readiness_ends_on_teardown_even_after_a_workspace() {
    assert_eq!(setup_readiness(true, true, true), Readiness::Ended);
    assert_eq!(setup_readiness(false, true, false), Readiness::Ready);
    assert_eq!(setup_readiness(false, false, true), Readiness::Waiting);
    assert_eq!(setup_readiness(false, false, false), Readiness::Ended);
}

#[test]
fn a_creation_settles() {
    assert_eq!(creation(false, false, true), Creation::Gone);
    assert_eq!(creation(false, true, false), Creation::Created);
    assert_eq!(creation(true, true, true), Creation::Created);
    assert_eq!(creation(true, false, true), Creation::Failed);
    assert_eq!(creation(true, false, false), Creation::Pending);
}

fn run(value: Value) -> Result<Fields, Failure> {
    settled(&serde_json::from_value(value).unwrap())
}

#[test]
fn a_create_answers_its_machine_or_pending() {
    let made = run(json!({"state": "created", "creationId": "c-1",
        "machine": {"id": "vm-1", "title": "box", "status": "running"}, "workspaceId": "ws-1"}))
    .unwrap();
    assert_eq!(
        Value::Object(made),
        json!({"machine_id": "vm-1", "title": "box", "status": "running", "target": "machine:vm-1", "workspace_id": "ws-1"})
    );
    let waited = run(json!({"creationId": "c-1"})).unwrap();
    assert_eq!(
        Value::Object(waited),
        json!({"pending": true, "status": "creating", "creation_id": "c-1"})
    );
}

#[test]
fn a_plan_refusal_names_the_plan_and_its_code() {
    let refused = run(json!({"state": "failed", "reason": "Pro allows 3 machines", "plan": "pro"}))
        .unwrap_err();
    assert_eq!(refused.code, Some(PLAN_REQUIRED_CODE));
    assert_eq!(refused.reason, Said::text("new Cloud machine: Pro allows 3 machines (plan: pro)"));
    let failed = run(json!({"state": "failed", "reason": "HTTP 503"})).unwrap_err();
    assert_eq!((failed.code, failed.reason), (None, Said::text("new Cloud machine: HTTP 503")));
    let declined = run(json!({"state": "gone"})).unwrap_err();
    assert_eq!((declined.reason, declined.refusal), (Said::key("createDeclined"), true));
}

#[test]
fn a_returned_machine_wins_over_a_failed_or_gone_phase() {
    for state in ["failed", "gone"] {
        let made = run(json!({"state": state, "reason": "late", "creationId": "c-1",
            "machine": {"id": "vm-1", "title": "box", "status": "running"}}))
        .unwrap();
        assert_eq!(made["machine_id"], json!("vm-1"), "{state}");
    }
}

#[test]
fn the_diagnostics_summary_names_the_first_thing_to_fix() {
    let machines: Vec<Diagnosed> = serde_json::from_value(json!([
        {"title": "ok"}, {"title": "old", "compatibility": "update cmux-tui"}, {"title": "down", "failure": "no route"}])).unwrap();
    assert_eq!(
        diagnostics_summary(Some("Cloud is off"), true, &machines, "me"),
        Said::text("Cloud is off")
    );
    assert_eq!(diagnostics_summary(None, false, &machines, "me"), Said::key("signInFirst"));
    assert_eq!(
        diagnostics_summary(None, true, &machines, "me"),
        Said::text("old: update cmux-tui")
    );
    assert_eq!(
        diagnostics_summary(None, true, &machines[..1], "me@x (Team)"),
        Said::with("diagnosticsAllWell", ["me@x (Team)"])
    );
}

#[test]
fn a_team_switch_takes_an_id_or_a_name() {
    let teams: Vec<Team> =
        serde_json::from_value(json!([{"id": "t1", "name": "Mine"}, {"id": "t2", "name": "Ours"}]))
            .unwrap();
    assert_eq!(team(&teams, Some("t1"), Some("Ours")), Ok(Some("t2".into())));
    assert_eq!(team(&teams, Some("t1"), Some("t2")), Ok(Some("t2".into())));
    assert_eq!(team(&teams, Some("t1"), Some("t1")), Ok(None), "the active team is a no-op");
    assert_eq!(
        team(&teams, None, Some("nope")),
        Err(Said::with("noSuchTeam", ["nope"]).invalid_target())
    );
    assert_eq!(team(&teams, None, None), Err(Said::with("noSuchTeam", [""]).invalid_target()));
    assert_eq!(team(&[], None, Some("t1")), Err(Said::key("noTeams")));
}

#[test]
fn set_up_github_says_the_app_or_the_fallback_and_why() {
    let named = Said::with("gitHubAppConfirmBody", ["Ada", "—"]);
    assert_eq!(github_confirm(Some("Ada"), None, GitHubApp::Ready), vec![named]);
    assert_eq!(
        github_confirm(None, None, GitHubApp::Ready),
        vec![Said::key("gitHubAppConfirmNoIdentity")]
    );
    assert_eq!(
        github_confirm(Some("Ada"), Some("ada@x.dev"), GitHubApp::NotConnected),
        vec![
            Said::key("gitHubFallbackNotConnected"),
            Said::with("gitHubConfirmBody", ["Ada", "ada@x.dev"])
        ]
    );
    assert_eq!(
        github_confirm(None, None, GitHubApp::NotConfigured),
        vec![Said::key("gitHubFallbackNotConfigured"), Said::key("gitHubConfirmNoIdentity")]
    );
    assert_eq!(
        github_confirm(None, Some("ada@x.dev"), GitHubApp::Unknown),
        vec![
            Said::key("gitHubFallbackUnknown"),
            Said::with("gitHubConfirmBody", ["—", "ada@x.dev"])
        ]
    );
}

#[test]
fn a_port_failure_names_the_limit_or_the_detail() {
    let names = PortNames { name: "dev box".into(), id: "vm-1".into(), port: Some(3000) };
    assert_eq!(
        port_failure(Some("cmux.cloud.port_limit"), "x", &names),
        Said::with("portLimit", ["dev box", "vm-1", "3000"])
    );
    assert_eq!(
        port_failure(Some("other"), " The link is down... \n", &names),
        Said::with("portFailed", ["dev box", "vm-1", "3000", "The link is down"])
    );
    assert_eq!(detail("no route."), "no route");
}
