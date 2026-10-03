use serde_json::json;

use super::super::command::{CommandPlan, RequestPlan};
use super::*;

fn plan(args: &[&str]) -> RequestPlan {
    let args = args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    match super::super::command::parse(&args, super::super::Surface::Cmux) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        _ => panic!("{args:?} did not parse to a request"),
    }
}

fn wire(plan: &RequestPlan) -> &'static str {
    match plan.operation {
        WireOperation::Typed(operation) => operation.wire_name(),
        WireOperation::Raw { .. } => panic!("typed"),
    }
}

#[test]
fn every_verb_sends_its_settings_operation_on_the_session_route() {
    for (args, operation) in [
        (vec!["settings", "list"], "settings.list"),
        (vec!["settings", "get", "ui.animationSpeed"], "settings.get"),
        (vec!["settings", "set", "ui.animationSpeed", "off"], "settings.set"),
        (vec!["settings", "reset", "ui.animationSpeed"], "settings.reset"),
        (vec!["settings", "unset", "ui.animationSpeed"], "settings.reset"),
        (vec!["settings", "reset-all"], "settings.reset_all"),
        (vec!["settings", "snapshot"], "settings.snapshot"),
        (vec!["settings", "schema"], "settings.schema"),
    ] {
        let plan = plan(&args);
        assert_eq!(wire(&plan), operation, "{args:?}");
        assert!(handles(&plan));
        assert_eq!(plan.params["machine"], "current");
        assert_eq!(plan.params["session"], "current");
    }
}

#[test]
fn set_takes_json_first_then_a_bare_string() {
    let number = plan(&["settings", "set", "layout.panePadding", "4"]);
    assert_eq!(number.params["value"], json!(4));
    assert_eq!(number.params["key"], "layout.panePadding");
    let text = plan(&["settings", "set", "window.titlebar", "minimal"]);
    assert_eq!(text.params["value"], json!("minimal"));
    let object = plan(&["settings", "set", "notifications.quietHours", r#"{"start":"22:00","end":"07:00"}"#]);
    assert_eq!(object.params["value"]["start"], "22:00");
    assert_eq!(parse_value("true"), json!(true));
    assert_eq!(parse_value("\"quoted\""), json!("quoted"));
}

#[test]
fn flags_name_a_key_path_a_revision_and_a_section() {
    let path = plan(&[
        "settings",
        "set",
        "--path-json",
        r#"["shortcuts","bindings","tabGroup.create"]"#,
        "cmd+g",
        "--if-revision",
        "7",
    ]);
    assert_eq!(path.params["path"], json!(["shortcuts", "bindings", "tabGroup.create"]));
    assert!(path.params.get("key").is_none());
    assert_eq!(path.params["if_revision"], "7");
    let list = plan(&["settings", "list", "--section", "appearance"]);
    assert_eq!(list.params["section"], "appearance");
    assert!(plan(&["settings", "reset-all", "--origin", "user"]).params["origin"] == "user");
}

#[test]
fn bad_command_lines_are_usage_errors() {
    let parse = |args: &[&str]| {
        let args = args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
        super::super::command::parse(&args, super::super::Surface::Cmux)
    };
    assert!(parse(&["settings"]).is_err());
    assert!(parse(&["settings", "get"]).is_err());
    assert!(parse(&["settings", "set", "a.b", "1", "extra"]).is_err());
    assert!(parse(&["settings", "set", "a.b", "1", "--if-revision", "x"]).is_err());
    assert!(parse(&["settings", "get", "a", "--path-json", "[\"a\"]"]).is_err());
    assert!(parse(&["settings", "reset", "a", "--origin", "root"]).is_err());
    assert!(parse(&["settings", "list", "--bogus", "1"]).is_err());
}

#[test]
fn human_output_marks_customized_and_managed_rows() {
    let list = plan(&["settings", "list"]);
    let rows = json!([
        {"key": "ui.animationSpeed", "value": "off", "customized": true, "managed": null},
        {"key": "appearance.density", "value": "compact", "customized": false,
         "managed": {"source": "mdm", "reason": "managed"}},
        {"key": "layout.panePadding", "value": null, "customized": false, "managed": null},
    ]);
    assert_eq!(
        human(&list, &rows),
        "ui.animationSpeed   \"off\"  *\nappearance.density  \"compact\"  managed (mdm)\nlayout.panePadding  -\n"
    );
    let set = plan(&["settings", "set", "ui.animationSpeed", "off"]);
    let result = json!({"value": {"keys": ["ui.animationSpeed"]}, "revision": "4", "replayed": false, "generation": "g"});
    assert_eq!(human(&set, &result), "revision 4: ui.animationSpeed\n");
}

#[test]
fn refusals_exit_two_with_the_accepted_values() {
    let invalid = json!({"code": "settings.invalid", "message": "ui.animationSpeed does not accept \"warp\"",
        "details": {"key": "ui.animationSpeed", "kind": "choice", "accepted": {"choices": ["fast", "normal", "off"]}}});
    assert_eq!(
        refusal_text(&invalid),
        "cmux: ui.animationSpeed does not accept \"warp\" (accepted: fast, normal, off)\n"
    );
    assert!(is_refusal(&invalid));
    let range = json!({"code": "settings.invalid", "message": "m", "details": {"accepted": {"range": {"min": 0, "max": 16}}}});
    assert_eq!(refusal_text(&range), "cmux: m (accepted: 0 to 16)\n");
    for code in ["settings.managed", "settings.agent_refused", "revision.conflict", "validation.invalid"] {
        assert!(is_refusal(&json!({"code": code})), "{code}");
    }
    assert!(!is_refusal(&json!({"code": "operation.failed"})));
    assert!(!is_refusal(&json!({"code": "transport.closed"})));
}
