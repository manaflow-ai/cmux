//! The `notifications.*` wire shapes, through the app-ops entry the FFI calls.

use serde_json::{Value, json};

use super::OPS;
use crate::app_ops::{OpError, call};

fn ok(op: &str, request: Value) -> Value {
    call(op, &request).unwrap_or_else(|error| panic!("{op}: {error:?}"))
}

#[test]
fn every_op_is_dispatched() {
    for op in OPS {
        assert!(!matches!(call(op, &json!({})), Err(OpError::Unknown)), "{op}");
    }
    assert!(matches!(call("notifications.nope", &json!({})), Err(OpError::Unknown)));
}

#[test]
fn parse_answers_prefs_and_diagnostics_in_cmux_json_names() {
    let reply = ok(
        "notifications.parse",
        json!({"root": {"notifications": {"dockBounce": "loud", "sounds": {"when": "always"}}}}),
    );
    assert_eq!(reply["prefs"]["dockBounce"], "once");
    assert_eq!(reply["prefs"]["sounds"]["when"], "always");
    assert_eq!(reply["prefs"]["timeoutSeconds"], 30.0);
    assert_eq!(
        reply["diagnostics"],
        json!([{
            "kind": "invalidValue",
            "path": "notifications.dockBounce",
            "message": "expected one of \"off\", \"once\", \"untilActive\"",
        }])
    );
    assert!(matches!(call("notifications.parse", &json!({})), Err(OpError::Invalid(_))));
}

#[test]
fn the_parsed_prefs_go_back_in_unchanged() {
    let root = json!({"notifications": {
        "quietHours": {"start": "22:00", "end": "07:00"}, "mutedWorkspaces": ["ws_1"],
        "sources": {"terminal": {"sound": "Tink"}},
        "sounds": {"agents": {"codex": {"events": {"finished": "Hero"}}}},
    }});
    let prefs = ok("notifications.parse", json!({"root": root}))["prefs"].clone();
    let reply = ok(
        "notifications.decide",
        json!({"prefs": prefs, "arrival": {"minuteOfDay": 600, "soundScope": {"agent": "Codex"}}}),
    );
    assert_eq!(reply["decision"]["sound"], "Hero");
    assert_eq!(reply["decision"]["soundLevel"], "agent:codex");
    assert_eq!(reply["decision"]["bounce"], "once");
    let quiet =
        ok("notifications.decide", json!({"prefs": prefs, "arrival": {"minuteOfDay": 1380}}));
    assert_eq!(quiet["decision"]["sound"], Value::Null);
    assert_eq!(quiet["decision"]["bounce"], Value::Null);
}

#[test]
fn decide_reads_wire_arrivals() {
    let reply = ok(
        "notifications.decide",
        json!({"arrival": {"source": "cli", "bannerAllowed": false, "appActive": true}}),
    );
    let decision = &reply["decision"];
    assert_eq!(decision["alerts"], true);
    assert_eq!(decision["desktop"], false);
    assert_eq!(decision["soundEvent"], "message");
    assert_eq!(decision["soundVolume"], 1.0);
    assert!(matches!(call("notifications.decide", &json!({})), Err(OpError::Invalid(_))));
    assert!(matches!(
        call("notifications.decide", &json!({"arrival": {"source": "daemon"}})),
        Err(OpError::Invalid(_))
    ));
}

#[test]
fn clears_and_flashes() {
    assert_eq!(
        ok("notifications.clears", json!({"trigger": "click", "source": "terminal"}))["clears"],
        true
    );
    assert_eq!(ok("notifications.clears", json!({"trigger": "timeout"}))["clears"], false);
    let flashes = |typing: bool| {
        ok(
            "notifications.flashes_on_entry",
            json!({"flashesOnRead": true, "flashesOnTyping": typing, "trigger": "keystroke"}),
        )["flashes"]
            .clone()
    };
    assert_eq!((flashes(false), flashes(true)), (json!(false), json!(true)));
}

#[test]
fn sound_choice_and_admit() {
    let reply = ok(
        "notifications.sound_choice",
        json!({"sounds": {"volume": 0.5, "groups": {"Ops": {"sound": "Pop"}}}, "event": "bell",
               "scope": {"groups": [{"id": "grp_1", "name": "Ops"}]}, "fallback": "Glass"}),
    );
    assert_eq!(reply["choice"], json!({"name": "Pop", "volume": 0.5, "level": "group:Ops"}));
    let muted = ok("notifications.sound_choice", json!({"event": "bell", "fallback": "none"}));
    assert_eq!(muted["choice"], Value::Null);

    let first = ok(
        "notifications.sound_admit",
        json!({"event": "finished", "now": 10.0, "cooldownSeconds": 1.5}),
    );
    assert_eq!(first, json!({"admit": true, "last": {"at": 10.0, "urgency": 1}}));
    let held = ok(
        "notifications.sound_admit",
        json!({"event": "bell", "now": 10.5, "cooldownSeconds": 1.5, "last": first["last"]}),
    );
    assert_eq!(held, json!({"admit": false, "last": {"at": 10.0, "urgency": 1}}));
}

#[test]
fn sound_event_and_agent_kind() {
    assert_eq!(
        ok("notifications.sound_event", json!({"source": "agent", "level": "warning"}))["event"],
        "needsInput"
    );
    assert_eq!(
        ok("notifications.sound_event", json!({"source": "x", "level": "x"}))["event"],
        "finished"
    );
    assert_eq!(ok("notifications.agent_kind", json!({"agent": "Claude"}))["agent"], "claude");
    assert_eq!(ok("notifications.agent_kind", json!({"agent": ""}))["agent"], Value::Null);
}

#[test]
fn rules_parse_apply_and_edit() {
    let parsed = ok("notifications.rule_parse", json!({"value": {"sound": "Glass", "pitch": 1}}));
    assert_eq!(parsed, json!({"rule": {"sound": "Glass"}, "problems": ["pitch: unknown key"]}));
    assert_eq!(ok("notifications.rule_accepts", json!({"value": {"sound": 3}}))["accepts"], false);
    let applied = ok(
        "notifications.rule_apply",
        json!({"rule": {"sound": "Glass"}, "sound": "Ping", "event": "needsInput", "volume": 2}),
    );
    assert_eq!(
        applied,
        json!({"isEmpty": false, "rule": {"sound": "Glass", "volume": 1.0, "events": {"needsInput": "Ping"}}})
    );
    let cleared =
        ok("notifications.rule_apply", json!({"rule": {"sound": "Glass"}, "sound": "inherit"}));
    assert_eq!(cleared, json!({"isEmpty": true, "rule": {}}));

    let edit = ok(
        "notifications.sound_edit",
        json!({"level": {"kind": "workspace", "key": "ws_1"}, "sound": "Frog"}),
    );
    assert_eq!(edit["path"], json!(["notifications", "sounds", "workspaces"]));
    assert_eq!(edit["value"], json!({"ws_1": {"sound": "Frog"}}));
    let checked = ok(
        "notifications.sound_checked",
        json!({"sounds": edit["sounds"], "level": {"kind": "workspace", "key": "ws_1"}}),
    );
    assert_eq!(checked["sound"], "Frog");
    let event = ok(
        "notifications.sound_edit",
        json!({"level": {"kind": "event", "key": "bell"}, "sound": "inherit"}),
    );
    assert_eq!(event["path"], json!(["notifications", "sounds", "events", "bell"]));
    assert_eq!(event["value"], Value::Null);
}

#[test]
fn preview_quiet_hours_and_workspace_keys() {
    let preview = ok("notifications.preview_choice", json!({"scope": {"workspace": "ws_1"}}));
    assert_eq!(preview["choice"]["name"], "default");
    assert_eq!(ok("notifications.quiet_minutes", json!({"text": "22:30"}))["minutes"], 1350);
    assert_eq!(ok("notifications.quiet_minutes", json!({"text": "25:00"}))["minutes"], Value::Null);
    let contains = |minute: i64| {
        ok(
            "notifications.quiet_contains",
            json!({"quietHours": {"start": 1320, "end": 420}, "minuteOfDay": minute}),
        )["contains"]
            .clone()
    };
    assert_eq!((contains(1380), contains(720)), (json!(true), json!(false)));
    assert_eq!(ok("notifications.quiet_contains", json!({"minuteOfDay": 0}))["contains"], false);

    let key = ok(
        "notifications.workspace_key",
        json!({"machine": "lab", "workspace": "ws_lab", "localMachine": "local",
               "keys": ["ws_lab"], "ruleKeys": ["ws_lab"]}),
    );
    assert_eq!(
        key,
        json!({
            "settingsKey": "machine:bGFi:workspace:d3NfbGFi",
            "qualified": "machine:bGFi:workspace:d3NfbGFi",
            "mutes": true,
            "legacyRemoteKey": "ws_lab",
            "ruleKey": "ws_lab",
        })
    );
    let ids = ok(
        "notifications.workspace_ids",
        json!({"keys": ["ws_lab", "machine:bGFi:workspace:d3NfMQ=="], "machine": "lab", "localMachine": "local",
               "localIds": ["ws_lab"]}),
    );
    assert_eq!(ids["ids"], json!(["ws_1"]));
}
