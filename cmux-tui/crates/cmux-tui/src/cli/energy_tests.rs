//! `cmux energy`: the verbs, the app action each runs, and the status text
//! of both owners in both catalogs.

use serde_json::json;

use super::*;
use crate::localization::catalog_for_locale;

fn words(args: &[&str]) -> Vec<String> {
    args.iter().map(|arg| (*arg).to_owned()).collect()
}

#[test]
fn energy_verbs_run_the_app_session_actions() {
    assert_eq!(parse(&[]), Ok(Verb::Status));
    assert_eq!(parse(&words(&["status"])), Ok(Verb::Status));
    assert_eq!(parse(&words(&["off"])), Ok(Verb::Action(TURN_OFF_FOR_NOW)));
    assert_eq!(parse(&words(&["on"])), Ok(Verb::Action(TURN_ON_NOW)));
    assert_eq!(parse(&words(&["auto"])), Ok(Verb::Action(TURN_ON_NOW)));
    assert_eq!(parse(&words(&["turn-on"])), Ok(Verb::Action(TURN_ON_NOW)));
    assert_eq!(parse(&words(&["turn-off-for-now"])), Ok(Verb::Action(TURN_OFF_FOR_NOW)));
    assert_eq!(parse(&words(&["help"])), Ok(Verb::Help));
    assert_eq!(parse(&words(&["off", "--help"])), Ok(Verb::Help));
    assert!(parse(&words(&["sometimes"])).is_err());
    assert!(parse(&words(&["off", "now"])).is_err());
}

#[test]
fn energy_actions_go_through_action_run_by_id() {
    for action in [TURN_OFF_FOR_NOW, TURN_ON_NOW] {
        let Ok(super::super::app::AppCommand::Call { method, params, .. }) =
            super::super::app::run_action(action, &[], ActionName::Any)
        else {
            panic!("{action} is one action.run");
        };
        assert_eq!(method, "action.run");
        assert_eq!(params["action"], action, "{params}");
    }
}

#[test]
fn energy_status_reads_both_owners() {
    let messages = &catalog_for_locale("en").energy;
    let app = app_part(&json!({
        "policy": {"isSaver": true, "reason": "battery"},
        "inputs": {"sessionOverride": false},
        "processes": [{"pid": 1}],
    }));
    assert_eq!(app.as_object().map(|app| app.len()), Some(2), "only policy and inputs: {app}");
    let daemon = daemon_reply(json!({"id": "energy-status", "ok": true,
        "data": {"saver": true, "source": "app", "reason": "battery", "override": true, "reading": false}}));
    let report = report(Ok(app), daemon);
    assert_eq!(report["daemon"]["source"], "app", "{report}");
    assert_eq!(
        status_text(&report, messages),
        "Energy Saver: on (battery low)\nDaemon: on, as the app set it"
    );

    let held = report_of(json!({"isSaver": false}), json!({"sessionOverride": true}));
    let down = super::report(held, Err("connection refused".into()));
    assert_eq!(
        status_text(&down, messages),
        "Energy Saver: off for now (cmux energy on ends this)\nDaemon: no answer (connection refused)"
    );

    let refused = daemon_reply(json!({"id": "energy-status", "ok": false,
        "error_code": "energy.not_trusted"}));
    let no_app = super::report(Err("no app".into()), refused);
    let japanese = &catalog_for_locale("ja_JP.UTF-8").energy;
    assert_eq!(
        status_text(&no_app, japanese),
        "省エネモード: cmux アプリが応答しません\nデーモン: 応答なし (energy.not_trusted)"
    );
}

fn report_of(policy: Value, inputs: Value) -> Result<Value, String> {
    Ok(json!({"policy": policy, "inputs": inputs}))
}

#[test]
fn energy_mcp_tool_takes_no_arguments() {
    assert_eq!(mcp_tool()["name"], MCP_STATUS_TOOL);
    assert!(mcp_arguments(&Map::new()).is_ok());
    let mut extra = Map::new();
    extra.insert("saver".into(), json!(true));
    assert!(mcp_arguments(&extra).is_err());
}
