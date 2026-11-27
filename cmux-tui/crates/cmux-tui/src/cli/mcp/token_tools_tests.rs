use super::*;

fn args(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

#[test]
fn each_tool_is_its_cmux_token_command() {
    assert_eq!(words(LIST, &args(json!({}))).unwrap().unwrap(), ["token", "list"]);
    assert_eq!(
        words(
            CREATE,
            &args(json!({"name": "ci", "scopes": ["usage", "machines"], "expires": "30d",
                "spend_cap_usd": 25, "team": "team_0123456789abcdef0123", "team_token": true}))
        )
        .unwrap()
        .unwrap(),
        [
            "token",
            "create",
            "ci",
            "--scope",
            "usage,machines",
            "--expires",
            "30d",
            "--spend-cap",
            "25",
            "--team-token",
            "--team",
            "team_0123456789abcdef0123"
        ]
    );
    assert_eq!(
        words(REVOKE, &args(json!({"token": "laptop"}))).unwrap().unwrap(),
        ["token", "revoke", "laptop"]
    );
    assert!(words("cloud_machines", &args(json!({}))).is_none());
}

#[test]
fn bad_arguments_never_reach_the_cli() {
    for (name, arguments) in [
        (CREATE, json!({})),
        (CREATE, json!({"name": "--team-token"})),
        (CREATE, json!({"name": "ci", "scopes": ["vault"]})),
        (CREATE, json!({"name": "ci", "expires": "5y"})),
        (CREATE, json!({"name": "ci", "spend_cap_usd": 0})),
        (REVOKE, json!({})),
    ] {
        assert!(words(name, &args(arguments.clone())).unwrap().is_err(), "{name} {arguments}");
    }
}

#[test]
fn the_tools_are_listed() {
    let names: Vec<String> = super::super::tool_list::first_party()
        .iter()
        .filter_map(|tool| tool["name"].as_str().map(str::to_owned))
        .collect();
    for name in [LIST, CREATE, REVOKE] {
        assert!(names.iter().any(|n| n == name), "{name}");
    }
}
