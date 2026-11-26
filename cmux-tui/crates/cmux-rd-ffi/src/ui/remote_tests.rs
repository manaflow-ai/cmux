//! Parity with `CmuxRemoteSharingSetupTests.swift` and `ComputerUseActivityStateTests.swift`.

use serde_json::{Value, json};

use super::*;
use crate::ui::call;

fn ok(request: Value) -> Value {
    let reply = call(request.to_string().as_bytes());
    reply.get("ok").cloned().unwrap_or_else(|| panic!("{request} answered {reply}"))
}

fn err(request: Value) -> String {
    let reply = call(request.to_string().as_bytes());
    reply["err"].as_str().unwrap_or_else(|| panic!("{request} answered {reply}")).to_owned()
}

/// Drives the guide as `proceed(after: "continue")` does, with `present` answering each sheet
/// and `grants` deciding the read after each answer; returns (shared, sheets shown, requests).
fn run_guide(
    mut grants: (bool, bool),
    answers: &[&str],
    after: impl Fn(&str, &str, &mut (bool, bool)),
) -> (bool, Vec<String>, (u32, u32)) {
    let mut state = SetupState { screen: grants.0, control: grants.1, ..Default::default() };
    let mut answers = answers.iter();
    let mut shown = vec![];
    let mut requests = (0, 0);
    loop {
        let next = ok(json!({"op": "remote.setupStep", "args": state}));
        if next["done"] == true {
            return (true, shown, requests);
        }
        let step = next["step"].as_str().unwrap().to_owned();
        let spec = ok(json!({"op": "remote.setupSpec", "args": {"step": step}}));
        let id = spec["identifier"].as_str().unwrap().to_owned();
        shown.push(id.clone());
        let given = answers.next().copied().unwrap_or("cancel");
        after(&id, given, &mut grants);
        let mut args = serde_json::to_value(&state).unwrap();
        args["answer"] = json!(given);
        let reply = ok(json!({"op": "remote.setupAnswer", "args": args}));
        match reply["action"].as_str().unwrap() {
            "stop" => return (false, shown, requests),
            "requestScreen" => requests.0 += 1,
            "requestControl" => requests.1 += 1,
            _ => {}
        }
        state = serde_json::from_value(reply["state"].clone()).unwrap();
        (state.screen, state.control) = grants;
    }
}

const SCREEN: &str = "cmux.dialog.screenSharing.setup.screen";
const SCREEN_CHECK: &str = "cmux.dialog.screenSharing.setup.screenCheck";
const CONTROL: &str = "cmux.dialog.screenSharing.setup.control";
const CONTROL_CHECK: &str = "cmux.dialog.screenSharing.setup.controlCheck";

#[test]
fn cancellation_never_enables_sharing() {
    let (shared, shown, requests) = run_guide((false, false), &["cancel"], |_, _, _| {});
    assert!(!shared);
    assert_eq!(shown, [SCREEN]);
    assert_eq!(requests, (0, 0));
}

#[test]
fn screen_recording_cannot_be_skipped_by_check() {
    let (shared, shown, requests) = run_guide((false, true), &["check", "cancel"], |_, _, _| {});
    assert!(!shared);
    assert_eq!(requests.0, 0);
    assert_eq!(shown, [SCREEN, SCREEN]);
}

#[test]
fn optional_accessibility_advances_only_on_explicit_view() {
    let (shared, shown, requests) = run_guide((true, false), &["check", "view"], |_, _, _| {});
    assert!(shared);
    assert_eq!(requests.1, 0);
    assert_eq!(shown, [CONTROL, CONTROL]);
}

#[test]
fn view_is_refused_while_the_screen_is_missing() {
    let (shared, _, _) = run_guide((false, false), &["view"], |_, _, _| {});
    assert!(!shared);
}

#[test]
fn first_use_refreshes_both_permissions_before_enabling() {
    let (shared, shown, requests) =
        run_guide((false, false), &["allow", "check", "allow", "check"], |id, answer, grants| {
            if answer != "check" {
                return;
            }
            if id.ends_with(".screenCheck") {
                grants.0 = true;
            } else if id.ends_with(".controlCheck") {
                grants.1 = true;
            }
        });
    assert!(shared);
    assert_eq!(requests, (1, 1));
    assert_eq!(shown, [SCREEN, SCREEN_CHECK, CONTROL, CONTROL_CHECK]);
}

#[test]
fn a_grant_made_in_macos_prompt_skips_check_again() {
    let (shared, shown, requests) = run_guide((false, true), &["allow"], |_, answer, grants| {
        if answer == "allow" {
            grants.0 = true;
        }
    });
    assert!(shared);
    assert_eq!(requests.0, 1);
    assert_eq!(shown, [SCREEN]);
}

#[test]
fn losing_screen_recording_in_the_control_step_returns_to_its_guide() {
    let (_, shown, _) =
        run_guide((true, false), &["check", "cancel"], |_, _, grants| grants.0 = false);
    assert_eq!(shown, [CONTROL, SCREEN]);
}

#[test]
fn the_specs_keep_their_keys_and_buttons() {
    let overview = ok(json!({"op": "remote.setupSpec", "args": {"step": "overview"}}));
    assert_eq!(overview["titleKey"], "macScreen.setup.title");
    assert_eq!(
        overview["lineKeys"],
        json!(["macScreen.setup.source", "macScreen.setup.consent", "macScreen.setup.standingYes"])
    );
    let ids = |spec: &Value| {
        spec["buttons"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["id"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>()
    };
    assert_eq!(ids(&overview), ["cancel", "continue"]);
    assert_eq!(overview["buttons"][0]["role"], "cancel");
    let control = ok(json!({"op": "remote.setupSpec", "args": {"step": "controlCheck"}}));
    assert_eq!(ids(&control), ["cancel", "view", "check"]);
    assert!(control["buttons"][1].get("role").is_none());
    assert_eq!(control["buttons"][2]["titleKey"], "macScreen.setup.check");
    let screen = ok(json!({"op": "remote.setupSpec", "args": {"step": "screen"}}));
    assert_eq!(ids(&screen), ["cancel", "allow"]);
    assert_eq!(screen["identifier"], SCREEN);
    assert!(err(json!({"op": "remote.setupSpec", "args": {"step": "bogus"}})).contains("bogus"));
}

fn holds(
    setting_on: bool,
    managed: Option<&str>,
    recorded: bool,
    own_join: bool,
    declined: bool,
) -> bool {
    consent_holds(&ConsentArgs {
        setting_on,
        managed: managed.map(str::to_owned),
        recorded,
        own_join,
        declined,
    })
}

#[test]
fn the_standing_yes_counts_only_where_the_person_or_the_profile_gave_it() {
    assert!(!holds(true, None, false, false, false));
    assert!(holds(true, None, true, false, false));
    assert!(holds(true, Some("device"), false, false, false));
    assert!(!holds(true, Some("team"), false, false, false));
    assert!(!holds(false, Some("device"), true, false, false));
}

#[test]
fn joining_ones_own_account_is_consent_until_declined() {
    assert!(holds(false, None, false, true, false));
    assert!(!holds(false, None, false, true, true));
    assert!(!holds(true, None, false, false, false));
    assert!(!holds(false, Some("team"), false, true, false));
    assert!(holds(true, None, true, false, true));
    assert_eq!(
        ok(json!({"op": "remote.consentHolds", "args": {"settingOn": false, "ownJoin": true}})),
        json!(true)
    );
}

#[test]
fn turning_the_yes_off_records_a_decline_only_over_a_recorded_yes() {
    let forget = |on: bool, recorded: bool| {
        ok(json!({"op": "remote.forgetUnlessOn", "args": {"settingOn": on, "recorded": recorded}}))
    };
    assert_eq!(forget(true, true), json!({"recordDecline": false, "removeRecord": false}));
    assert_eq!(forget(false, true), json!({"recordDecline": true, "removeRecord": true}));
    assert_eq!(forget(false, false), json!({"recordDecline": false, "removeRecord": true}));
}

#[test]
fn the_caller_of_a_control_request() {
    let caller = |params: Value| {
        ok(json!({"op": "remote.callerFromParams", "args": params}))["caller"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    assert_eq!(caller(json!({})), "cli");
    assert_eq!(caller(json!({"caller": {"agent_session": "s1"}})), "agent");
    assert_eq!(caller(json!({"caller": {"home_chat": true}})), "agent");
    assert_eq!(caller(json!({"caller": {"terminal_id": "t1"}})), "terminal");
    assert_eq!(caller(json!({"caller": {"agent_session": ""}})), "cli");
    assert_eq!(
        ok(json!({"op": "remote.callerFromParams", "args": {}}))["messageKey"],
        "macScreen.sharedBy.cli"
    );
}

#[test]
fn the_caller_of_an_action_run() {
    let caller = |args: Value| ok(json!({"op": "remote.callerFromInvocation", "args": args}));
    assert_eq!(
        caller(json!({"origin": "user"})),
        Value::Null,
        "the person's own run needs no notice"
    );
    assert_eq!(caller(json!({"origin": "page"})), Value::Null);
    assert_eq!(caller(json!({"origin": "cli"}))["caller"], "cli");
    assert_eq!(caller(json!({"origin": "cli", "terminal": true}))["caller"], "terminal");
    assert_eq!(caller(json!({"origin": "mcp"}))["caller"], "agent");
    assert_eq!(caller(json!({"origin": "user", "agentSession": true}))["caller"], "agent");
    assert_eq!(caller(json!({"origin": "page", "homeChat": true}))["caller"], "agent");
    assert_eq!(caller(json!({"origin": "remote"}))["caller"], "device");
    assert_eq!(caller(json!({"origin": "user", "viaControlSocket": true}))["caller"], "cli");
}

#[test]
fn remote_confirm_takes_only_the_four_changes() {
    let confirm = |params: Value| {
        call(json!({"op": "remote.confirmRequest", "args": params}).to_string().as_bytes())
    };
    for bad in [
        json!({}),
        json!({"action": "unshare"}),
        json!({"action": "access", "device": "d"}),
        json!({"action": "access", "scope": "full"}),
        json!({"action": "access", "device": "d", "scope": "root"}),
        json!({"action": "delete"}),
    ] {
        assert_eq!(confirm(bad)["err"], CONFIRM_INVALID);
    }
    let share = confirm(json!({"action": "share"}))["ok"].clone();
    assert_eq!(share["kind"], "share");
    assert_eq!(share["redeemsTicket"], false);
    assert_eq!(share["timeoutSeconds"], 600);
    assert_eq!(confirm(json!({"action": "share", "device": "mini"}))["ok"]["kind"], "shareOther");
    assert_eq!(confirm(json!({"action": "allow_agents"}))["ok"]["kind"], "allowAgents");
    let unshare = confirm(json!({"action": "unshare", "agent_ticket": "t"}))["ok"].clone();
    assert_eq!(
        (unshare["kind"].clone(), unshare["redeemsTicket"].clone()),
        (json!("unshare"), json!(true))
    );
    let access = confirm(
        json!({"action": "access", "device": "d", "scope": "view", "agent_ticket": "t"}),
    )["ok"]
        .clone();
    assert_eq!(access["scope"], "view");
    assert_eq!(access["redeemsTicket"], false, "access always asks the person");
}

fn event_sessions(rows: Value) -> Vec<Session> {
    serde_json::from_value(ok(json!({"op": "remote.activitySessions", "args": {"sessions": rows}})))
        .unwrap()
}

#[test]
fn an_event_says_who_acts_on_which_app_newest_first() {
    let sessions = event_sessions(json!([
        {"session": "a", "label": "Codex", "last_action_ms": 4_990_000},
        {"session": "b", "label": "Claude Code", "app": {"id": "com.apple.Notes", "name": "Notes", "pid": 77}, "last_action_ms": 4_999_500},
        {"label": "no session", "last_action_ms": 1},
        {"session": "", "last_action_ms": 1},
        {"session": "no time"},
    ]));
    assert_eq!(sessions.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["b", "a"]);
    assert_eq!(
        sessions[0],
        Session {
            id: "b".into(),
            agent: Some("Claude Code".into()),
            app_id: Some("com.apple.Notes".into()),
            app_name: Some("Notes".into()),
            app_pid: Some(77),
            last_action_ms: 4_999_500.0,
            stopped: false,
        }
    );
    assert_eq!(sessions[1].app_name, None);
    let now = 5_000_000.0;
    let acting = acting(&sessions, now);
    assert!(acting.acting, "the newest acted half a second ago");
    let rows = ok(json!({"op": "remote.menuBar", "args": {"sessions": sessions, "nowMs": now}}));
    assert_eq!(rows[0]["acting"], true);
    assert_eq!(rows[1]["acting"], false);
    assert_eq!(rows[0]["bundleId"], "com.apple.Notes");
    assert!(event_sessions(json!([])).is_empty());
    assert!(event_sessions(Value::Null).is_empty());
}

#[test]
fn empty_labels_and_non_positive_pids_are_dropped() {
    let s = &event_sessions(
        json!([{"session": "a", "label": "", "app": {"id": "", "name": "N", "pid": 0}, "last_action_ms": 1}]),
    )[0];
    assert_eq!(
        (s.agent.clone(), s.app_id.clone(), s.app_name.clone(), s.app_pid),
        (None, None, Some("N".into()), None)
    );
}

#[test]
fn acting_ends_two_seconds_after_the_last_action() {
    let sessions =
        event_sessions(json!([{"session": "a", "label": "Codex", "last_action_ms": 4_999_500}]));
    let at =
        |now: f64| ok(json!({"op": "remote.acting", "args": {"sessions": sessions, "nowMs": now}}));
    assert_eq!(at(5_000_000.0), json!({"acting": true, "untilMs": 5_001_500.0}));
    assert_eq!(at(5_001_400.0)["acting"], true, "still within the window");
    assert_eq!(
        at(5_001_500.0),
        json!({"acting": false, "untilMs": null}),
        "2 s after the last action"
    );
    let old = event_sessions(json!([{"session": "a", "last_action_ms": 4_000_000}]));
    assert!(!acting(&old, 5_000_000.0).acting, "an old action never turns the badge on");
}

#[test]
fn a_stopped_session_is_listed_but_never_acts() {
    let mut sessions = event_sessions(
        json!([{"session": "a", "label": "Codex", "last_action_ms": 4_999_900, "stopped": true}]),
    );
    assert!(sessions[0].stopped);
    assert_eq!(acting(&sessions, 5_000_000.0), Acting { acting: false, until_ms: None });
    let rows = menu_bar(&sessions, 5_000_000.0);
    assert!(rows[0].stopped && !rows[0].acting);
    sessions[0].stopped = false;
    assert!(acting(&sessions, 5_000_000.0).acting);
}

#[test]
fn status_lines_name_the_host_the_grants_and_each_worker() {
    let lines = |status: Value| ok(json!({"op": "remote.statusLines", "args": {"status": status}}));
    assert_eq!(lines(json!({})), json!([{"key": "remote.status.host", "value": "off"}]));
    assert_eq!(
        lines(json!({"state": "ready", "host": {
            "permissions": {"accessibility": true, "screen_recording": false},
            "workers": {"screen-sharing": {"state": "running"}, "computer-use": {"state": "ready"}},
        }})),
        json!([
            {"key": "remote.status.host", "value": "ready"},
            {"key": "remote.status.accessibility", "granted": true},
            {"key": "remote.status.screenRecording", "granted": false},
            {"key": "remote.status.computerUse", "value": "ready"},
            {"key": "remote.status.screenSharing", "value": "running"},
        ])
    );
}

#[test]
fn host_actions_map_to_their_daemon_calls() {
    let action = |name: &str| ok(json!({"op": "remote.hostAction", "args": {"action": name}}));
    assert_eq!(action("refreshPermissions"), json!({"method": "refresh", "params": {}}));
    assert_eq!(action("allowScreenRecording")["params"], json!({"permission": "screen-recording"}));
    assert_eq!(action("allowAccessibility")["params"], json!({"permission": "accessibility"}));
    assert_eq!(action("restartComputerUse")["params"], json!({"worker": "computer-use"}));
    assert_eq!(action("restartScreenSharing")["params"], json!({"worker": "screen-sharing"}));
    assert_eq!(action("stopScreenSession")["method"], "screen.stop_session");
    assert!(err(json!({"op": "remote.hostAction", "args": {"action": "nope"}})).contains("nope"));
}
