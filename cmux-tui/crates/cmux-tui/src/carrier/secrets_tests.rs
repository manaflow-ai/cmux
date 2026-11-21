//! Generated keys and values only.

use cmux_remote::crypto::StaticIdentity;
use cmux_remote_protocol::{RpcError, WorkspaceRequest, WorkspaceResponse};
use serde_json::json;

use super::*;

const MACHINE: &str = "vm_0123456789abcdefghij";

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

fn random_hex() -> String {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).unwrap();
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn parses_only_its_own_flags() {
    let parsed = parse(&args(&["secrets", "--machine", MACHINE])).unwrap();
    assert_eq!(parsed.machine, MACHINE);
    assert_eq!(parsed.deadline, DEFAULT_DEADLINE);
    assert!(parse(&args(&["secrets", "--machine", "vm_bad"])).is_none());
    assert!(parse(&args(&["secrets", "--machine", MACHINE, "--machine", MACHINE])).is_none());
    assert!(parse(&args(&["secrets", "--machine", MACHINE, "--value", "x"])).is_none());
    assert!(parse(&args(&["dial", "--machine", MACHINE])).is_none());
}

#[test]
fn a_request_seals_to_the_daemon_and_carries_no_value() {
    let daemon = StaticIdentity::generate().unwrap();
    let value = random_hex();
    let request: Request = serde_json::from_value(json!({
        "api": "https://example.invalid", "credential": random_hex(),
        "op": "replace-machine-secrets", "values": [{"name": "DEMO_KEY", "value": value}],
    }))
    .unwrap();
    let sealed = sealed(&daemon.public_key(), MACHINE, request.op).unwrap();
    let wire = serde_json::to_string(&sealed).unwrap();
    assert!(!wire.contains(&value));
    let WorkspaceRequest::ReplaceMachineSecrets { items } = sealed else { panic!("not a replace") };
    let opened = cmux_remote::secrets::seal::open(
        daemon.private_key(),
        MACHINE,
        cmux_remote::secrets::Purpose::Secret,
        &items[0],
    )
    .unwrap();
    assert_eq!(opened.value.as_slice(), value.as_bytes());
    // Sealed with the time now, which the daemon checks against its window.
    assert!(opened.issued_at.abs_diff(cmux_remote::secrets::seal::unix_now()) <= 5);
    // Another machine's daemon key can't open it.
    let other = StaticIdentity::generate().unwrap();
    assert!(
        cmux_remote::secrets::seal::open(
            other.private_key(),
            MACHINE,
            cmux_remote::secrets::Purpose::Secret,
            &items[0]
        )
        .is_err()
    );
}

#[test]
fn answers_carry_only_fixed_codes() {
    assert_eq!(
        answer_for(Ok(WorkspaceResponse::MachineSecretsReplaced { count: 2 })),
        json!({"ok": true, "count": 2})
    );
    let mut busy = RpcError::new("secret-refused", "busy: machine-secrets.env");
    busy.retryable = true;
    assert_eq!(
        answer_for(Err(busy)),
        json!({"ok": false, "error_code": "refused", "refusal": "busy", "retryable": true})
    );
    // A message that is not a fixed code never comes through.
    let odd = RpcError::new("secret-refused", "SOMETHING ELSE entirely");
    assert_eq!(
        answer_for(Err(odd)),
        json!({"ok": false, "error_code": "refused", "retryable": false})
    );
    assert_eq!(
        answer_for(Err(RpcError::new("unsupported", "x"))),
        json!({"ok": false, "error_code": "unsupported", "retryable": false})
    );
    assert_eq!(
        answer_for(Err(RpcError::new("io", "a daemon's own text"))),
        json!({"ok": false, "error_code": "transport", "retryable": false})
    );
}

#[test]
fn a_malformed_request_is_refused() {
    for body in [
        json!({"op": "replace-machine-secrets", "values": []}),
        json!({"api": "a", "credential": "b", "op": "exec", "command": "id"}),
        json!({"api": "a", "credential": "b", "op": "install-harness-login", "harness": "claude",
               "login_base64": "eA=="}),
    ] {
        assert!(serde_json::from_value::<Request>(body).is_err());
    }
}

#[test]
fn a_request_may_name_the_machines_team() {
    let request: Request = serde_json::from_value(json!({
        "api": "https://example.invalid", "credential": random_hex(),
        "team": "team_0123456789abcdef0123",
        "op": "replace-machine-secrets", "values": [],
    }))
    .unwrap();
    assert_eq!(request.team.as_deref(), Some("team_0123456789abcdef0123"));
}

#[test]
fn a_stalled_exchange_ends_at_the_deadline_with_a_timeout_line() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let line = runtime.block_on(within(
        tokio::time::Instant::now() + std::time::Duration::from_millis(50),
        std::future::pending::<Value>(),
    ));
    assert_eq!(line, json!({"ok": false, "error_code": "timeout", "retryable": true}));
}

#[test]
fn an_unlisted_refusal_carries_no_daemon_text() {
    let named = RpcError::new("secret-refused", "private-access-token: DEMO_KEY");
    assert_eq!(
        answer_for(Err(named)),
        json!({"ok": false, "error_code": "refused", "retryable": false})
    );
    for code in cmux_remote::secrets::REFUSAL_CODES {
        let listed = RpcError::new("secret-refused", format!("{code}: DEMO_KEY"));
        assert_eq!(answer_for(Err(listed))["refusal"], json!(code));
    }
}
