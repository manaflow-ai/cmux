use super::*;

const OWN: Own<'static> =
    Own { version: "1.0.0", build_commit: Some("af881f169c64"), build_time: 1_794_000_000 };

fn fixes(restart: &str) -> Fixes<'_> {
    Fixes { restart: Some(restart), rerun: None }
}

fn refusal() -> Value {
    json!({
        "code": "validation.invalid",
        "message": "invalid request envelope",
        "details": {"reason": "invalid request envelope"},
        "retryable": false,
    })
}

#[test]
fn an_envelope_refusal_is_recognized_in_old_and_new_shapes() {
    assert!(is_envelope_refusal(&refusal()));
    let newer = json!({"code":"validation.invalid","message":"invalid request envelope",
            "details":{"error":"unknown variant `agent.message.send`"}});
    assert!(is_envelope_refusal(&newer));
    let other = json!({"code":"validation.invalid","message":"body must be a string"});
    assert!(!is_envelope_refusal(&other));
}

#[test]
fn an_older_daemon_is_named_with_its_build_and_the_restart_fix() {
    let identity =
        json!({"version":"0.1.0","build_commit":"316d139feaf89d9ab7c99dc9cffdce59309bef93"});
    let fix = "cmux daemon restart --socket /run/main.sock";
    let error = explain(&identity, "agent.message.send", &OWN, &fixes(fix)).unwrap();
    let message = error["message"].as_str().unwrap();
    assert!(
        message.starts_with("daemon 0.1.0 (316d139f) is older than this cmux 1.0.0"),
        "{message}"
    );
    assert!(message.contains("agent.message.send"), "{message}");
    assert!(message.contains(fix), "{message}");
    assert!(message.contains("terminals are kept"), "{message}");
    assert!(!error.to_string().contains("invalid request envelope"), "{error}");
    assert_eq!(error["code"], "daemon.outdated");
    assert_eq!(error["details"]["daemon_build"], "316d139feaf89d9ab7c99dc9cffdce59309bef93");
}

#[test]
fn a_daemon_that_does_not_answer_gets_no_restart_advice() {
    let error =
        explain(&Value::Null, "agent.message.send", &OWN, &fixes("cmux daemon restart")).unwrap();
    let message = error["message"].as_str().unwrap();
    assert_eq!(error["code"], "daemon.build_mismatch");
    assert!(!message.contains("daemon restart"), "{message}");
    assert!(!message.contains("invalid request envelope"), "{message}");
}

#[test]
fn a_newer_daemon_says_this_cli_is_older_and_offers_no_restart() {
    let identity = json!({"version":"1.0.0","build_commit":"9f00aa11bb22",
            "build_time": 1_795_000_000_u64});
    let error =
        explain(&identity, "agent.message.send", &OWN, &fixes("cmux daemon restart")).unwrap();
    let message = error["message"].as_str().unwrap();
    assert_eq!(error["code"], "cli.outdated", "{error}");
    assert_eq!(error["details"]["action"], "use_daemon_cli");
    assert!(error["details"].get("fix").is_none(), "{error}");
    assert!(message.contains("newer than this cmux"), "{message}");
    assert!(!message.contains("daemon restart"), "{message}");
    let rerun = "'/opt/cmux/bin/cmux' --json workspace list";
    let named = Fixes { restart: Some("cmux daemon restart"), rerun: Some(rerun) };
    let error = explain(&identity, "agent.message.send", &OWN, &named).unwrap();
    assert!(error["message"].as_str().unwrap().contains(rerun), "{error}");
    assert_eq!(error["details"]["fix"], rerun, "{error}");
}

#[test]
fn a_daemon_with_an_older_build_time_is_older() {
    let identity = json!({"version":"1.0.0","build_commit":"0123456789ab",
            "build_time": 1_793_000_000_u64});
    let error = explain(&identity, "workspace.list", &OWN, &fixes("cmux daemon restart")).unwrap();
    assert_eq!(error["code"], "daemon.outdated", "{error}");
}

#[test]
fn without_a_build_time_of_its_own_the_cli_does_not_guess() {
    let own = Own { build_time: 0, ..OWN };
    let identity =
        json!({"version":"0.1.0","build_commit":"316d139feaf89d9ab7c99dc9cffdce59309bef93"});
    let error = explain(&identity, "workspace.list", &own, &fixes("cmux daemon restart")).unwrap();
    assert_eq!(error["code"], "daemon.build_mismatch", "{error}");
    assert!(!error["message"].as_str().unwrap().contains("daemon restart"), "{error}");
}

#[test]
fn an_older_daemon_whose_socket_is_not_known_gets_no_restart_command() {
    let identity =
        json!({"version":"0.1.0","build_commit":"316d139feaf89d9ab7c99dc9cffdce59309bef93"});
    let unknown = Fixes { restart: None, rerun: None };
    let error = explain(&identity, "tab.rename", &OWN, &unknown).unwrap();
    let message = error["message"].as_str().unwrap();
    assert_eq!(error["code"], "daemon.outdated", "{error}");
    assert!(error["details"].get("fix").is_none(), "{error}");
    assert!(!message.contains("--session"), "{message}");
    assert!(message.contains("is older than this cmux 1.0.0"), "{message}");
    assert!(message.contains("terminals are kept"), "{message}");
}

#[test]
fn a_current_daemon_without_a_build_stamp_is_not_called_older() {
    let identity = json!({"version":"1.0.0","build_commit":"0123456789ab","build_time":null});
    let error = explain(&identity, "workspace.list", &OWN, &fixes("cmux daemon restart")).unwrap();
    assert_eq!(error["code"], "daemon.build_mismatch", "{error}");
    assert!(!error["message"].as_str().unwrap().contains("daemon restart"), "{error}");
}

#[test]
fn the_same_build_keeps_its_own_refusal() {
    let identity = json!({"version":"1.0.0","build_commit":"af881f169c64"});
    assert!(explain(&identity, "agent.message.send", &OWN, &fixes("fix")).is_none());
}
