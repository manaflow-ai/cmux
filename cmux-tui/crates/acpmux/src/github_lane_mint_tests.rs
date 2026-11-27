use super::*;
use serde_json::json;

fn ask(perms: Value) -> TokenAsk {
    TokenAsk {
        repo: "o/r".into(),
        permissions: perms.as_object().unwrap().clone(),
        label: Some("git-credential".into()),
    }
}

#[test]
fn git_and_gh_asks_are_tokens_the_mac_accepts() {
    for asked in
        cmux_host::github_cli::credential_asks("o/r", cmux_host::github_cli::GitOp::Unknown, true)
            .into_iter()
            .chain([
                cmux_host::github_cli::gh_ask("o/r", true),
                cmux_host::github_cli::gh_ask("o/r", false),
            ])
    {
        let r = request_for(&asked);
        assert!(crate::github_broker::validate(&r).is_ok(), "{:?}", asked.permissions);
    }
}

#[test]
fn a_token_asking_past_its_limits_is_refused_before_it_is_sent() {
    for perms in [
        json!({"administration": "write"}),
        json!({"checks": "write"}),
        json!({"contents": "admin"}),
        json!({}),
    ] {
        let r = request_for(&ask(perms.clone()));
        assert!(crate::github_broker::validate(&r).is_err(), "{perms}");
    }
    let mut r = request_for(&ask(json!({"contents": "write"})));
    r.title = Some("t".into());
    assert!(crate::github_broker::validate(&r).is_err(), "a token takes no other field");
}

#[test]
fn only_an_installation_token_is_minted() {
    assert!(minted(&json!({"token": "ghs_abc123"})).is_ok());
    for bad in [
        json!({"token": "ghp_abc"}),
        json!({"token": "ghs_a b"}),
        json!({}),
        json!({"output": "x"}),
    ] {
        assert!(minted(&bad).is_err(), "{bad}");
    }
}

#[test]
fn the_macs_errors_become_codes_cmux_github_explains() {
    let e = |data: Value| RpcError::new(-32045, "m ghs_secret0123").with_data(data);
    let code = |data: Value| refusal(&e(data)).code;
    assert_eq!(
        code(json!({"reason": "github.not_connected", "code": "integration.not_found"})),
        "integration.not_found"
    );
    assert_eq!(code(json!({"reason": "github.not_connected"})), "github.not_connected");
    assert_eq!(code(json!({"reason": "github.no_owner"})), "github.no_owner");
    assert_eq!(code(json!({"reason": "github.busy", "retryable": true})), "busy");
    assert_eq!(
        code(json!({"reason": "github.app_token", "code": "unreachable"})),
        "integration.unavailable"
    );
    assert_eq!(code(json!({"reason": "odd"})), "github.app_token");
    assert!(!refusal(&e(json!({}))).message.contains("ghs_"), "no token goes on");
}
