use super::*;

#[test]
fn names_follow_the_platform_and_model_keys_are_kept() {
    for name in ["GITHUB_TOKEN", "_X", "a1", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"] {
        assert!(name_ok(name), "{name}");
    }
    for name in ["", "1A", "A-B", "PATH", "path", "LD_PRELOAD", "CMUX_X", "OPENAI_BASE_URL", "A B"]
    {
        assert!(!name_ok(name), "{name}");
    }
    assert!(!name_ok(&"A".repeat(129)));
}

#[test]
fn key_shaped_names_match_the_platform_rule() {
    for name in
        ["TOKEN", "GITHUB_TOKEN", "npm_token", "AWS_SECRET_ACCESS_KEY", "DB_PASSWORD", "X_APIKEY"]
    {
        assert!(key_shaped(name), "{name}");
    }
    for name in ["TOKENS", "MYTOKEN", "NODE_ENV", "SECRETARY", "API_KEY_ID"] {
        assert!(!key_shaped(name), "{name}");
    }
}

#[test]
fn hosts_are_lowercase_dns_names_with_an_optional_wildcard_and_port() {
    for host in ["api.github.com", "*.example.com", "localhost.dev:8080", "a-b.c1.io"] {
        assert!(host_ok(host), "{host}");
    }
    for host in [
        "API.github.com",
        "github",
        "*.com",
        "-a.com",
        "a.com:0",
        "a.com:65536",
        "a.1com",
        "https://a.com",
        "a..com",
    ] {
        assert!(!host_ok(host), "{host}");
    }
}

#[test]
fn a_key_shaped_or_model_key_name_cannot_be_a_plain_variable() {
    let params = json!({"name":"GITHUB_TOKEN","delivery":"env"});
    let error = policy(params.as_object().unwrap(), "GITHUB_TOKEN").unwrap_err();
    assert!(
        matches!(error, CloudError::Rejected { ref code, .. } if code == "vault.key_shaped_variable")
    );
    let params = json!({"delivery":"env"});
    let error = policy(params.as_object().unwrap(), "OPENAI_API_KEY").unwrap_err();
    assert!(
        matches!(error, CloudError::Rejected { ref code, .. } if code == "vault.key_shaped_variable")
    );
    let params = json!({"delivery":"env","allowedHosts":[]});
    let ok = policy(params.as_object().unwrap(), "NODE_ENV").unwrap().unwrap();
    assert_eq!(Value::Object(ok), json!({"delivery":"env","allowedHosts":[]}));
    let params = json!({"allowedHosts":["NOT A HOST"]});
    let error = policy(params.as_object().unwrap(), "X").unwrap_err();
    assert!(
        matches!(error, CloudError::Rejected { ref code, .. } if code == "vault.invalid_hosts")
    );
    let many: Vec<String> = (0..17).map(|i| format!("h{i}.example.com")).collect();
    let params = json!({"allowedHosts":many});
    assert!(policy(params.as_object().unwrap(), "X").is_err());
}

#[test]
fn replies_keep_only_names_revisions_policy_and_hosts() {
    let listed = entries(&json!({"entries":[
        {"name":"GITHUB_TOKEN","revision":3,"updatedAt":17,"delivery":"proxy",
         "allowedHosts":["api.github.com","BAD HOST"],"value":"hunter2","fingerprint":"ab12"},
        {"name":"NODE_ENV","revision":1,"updatedAt":5},
        {"name":"bad name","revision":1},
    ]}));
    assert_eq!(
        Value::Array(listed),
        json!([
            {"name":"GITHUB_TOKEN","revision":3,"updatedAt":17,"delivery":"proxy",
             "allowedHosts":["api.github.com"],"keyShaped":true},
            {"name":"NODE_ENV","revision":1,"updatedAt":5,"delivery":"env","allowedHosts":[],"keyShaped":false},
        ])
    );
    let wrote = written(
        &json!({"name":"X","revision":2,"warning":"w","value":"hunter2","fingerprint":"ab"}),
    );
    assert_eq!(wrote, json!({"name":"X","revision":2,"warning":"w"}));
    let listed = grants(&json!({"grants":[
        {"kind":"joined","id":"mac-1","entries":["A","PATH"],"expiresAt":9,"grantedAt":1,"token":"t"},
        {"kind":"cloud","id":"m","expiresAt":0,"grantedAt":2},
        {"kind":"other","id":"x"},
    ]}));
    assert_eq!(
        Value::Array(listed),
        json!([
            {"kind":"joined","id":"mac-1","entries":["A"],"expiresAt":9,"grantedAt":1},
            {"kind":"cloud","id":"m","expiresAt":0,"grantedAt":2},
        ])
    );
}

#[test]
fn wipe_zeroes_every_string() {
    let mut value = json!({"value":"hunter2","nested":["abc"]});
    wipe(&mut value);
    assert!(!value.to_string().contains("hunter2") && !value.to_string().contains("abc"));
}
