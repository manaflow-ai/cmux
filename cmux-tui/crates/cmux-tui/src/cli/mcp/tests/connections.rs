//! `cmux mcp ls|tools NAME|audit|rm|auth|key|policy|approve-tools` (`super::super::connections`):
//! the CLI reads, removes, or opens Settings > MCP Servers; it never sets a policy, signs in,
//! takes a key or approves held tools.

use serde_json::{Value, json};

use super::super::connections::{Command, Handoff, execute, parse};

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

fn listed() -> Value {
    json!({"connections": [
        {"id": "mcp_0000000000000001", "name": "linear", "title": "Linear", "publisher": "linear.app",
         "verified": true, "url": "https://mcp.linear.app/mcp", "auth": "oauth", "hasSecret": true,
         "scope": "chief", "state": "connected", "addedAt": 1,
         "tools": [{"name": "create_issue", "policy": "ask"}, {"name": "list_issues", "policy": "always"}],
         "held": ["create_issue"]},
        {"id": "mcp_0000000000000002", "name": "weather", "title": "Weather", "publisher": "weather.example",
         "verified": false, "url": "https://weather.example/mcp", "auth": "key", "hasSecret": false,
         "scope": "everywhere", "state": "needsKey", "addedAt": 2, "tools": []},
    ]})
}

/// Records each app method and answers like an app with `listed()`.
fn app(sent: &mut Vec<(String, Value)>) -> impl FnMut(&str, Value) -> Result<Value, Value> + '_ {
    move |method: &str, params: Value| {
        sent.push((method.to_owned(), params.clone()));
        match method {
            "mcp.servers.list" => Ok(listed()),
            "mcp.servers.audit" => Ok(json!({"lines": [{"event": "remove", "seq": 3}]})),
            "mcp.servers.remove" => {
                Ok(json!({"removed": "mcp_0000000000000002", "name": "weather"}))
            }
            "mcp.servers.open" => Ok(json!({"opened": true})),
            other => Err(json!({"code": "method_not_found", "message": other})),
        }
    }
}

#[test]
fn serve_and_a_bare_tools_stay_the_mcp_server_commands() {
    assert_eq!(parse(&args(&["serve"])), None);
    assert_eq!(parse(&args(&["tools"])), None);
    assert_eq!(parse(&args(&["--help"])), None);
    assert_eq!(parse(&args(&["tools", "linear"])), Some(Ok(Command::Tools("linear".into()))));
    assert_eq!(parse(&args(&["ls"])), Some(Ok(Command::List)));
    assert_eq!(
        parse(&args(&["audit", "--limit", "5"])),
        Some(Ok(Command::Audit { limit: Some(5) }))
    );
    assert!(matches!(parse(&args(&["audit", "--limit", "0"])), Some(Err(_))));
    assert_eq!(parse(&args(&["rm", "linear"])), Some(Ok(Command::Remove("linear".into()))));
    assert!(matches!(parse(&args(&["rm"])), Some(Err(_))));
}

#[test]
fn auth_key_and_policy_only_open_settings() {
    for (verb, handoff) in [
        ("auth", Handoff::Auth),
        ("key", Handoff::Key),
        ("policy", Handoff::Policy),
        ("approve-tools", Handoff::ApproveTools),
    ] {
        assert_eq!(
            parse(&args(&[verb, "linear"])),
            Some(Ok(Command::Open { name: "linear".into(), handoff })),
            "{verb}"
        );
    }
    assert_eq!(
        parse(&args(&["policy", "linear", "create_issue", "always"])),
        Some(Ok(Command::Open { name: "linear".into(), handoff: Handoff::Policy })),
        "the tool and policy do not change anything from the CLI"
    );

    let mut sent = Vec::new();
    let opened = execute(
        &Command::Open { name: "LINEAR".into(), handoff: Handoff::Policy },
        &mut app(&mut sent),
    )
    .expect("opens");
    let methods: Vec<&str> = sent.iter().map(|(m, _)| m.as_str()).collect();
    assert_eq!(methods, ["mcp.servers.list", "mcp.servers.open"]);
    assert_eq!(sent[1].1, json!({"connection": "mcp_0000000000000001", "focus": true}));
    assert_eq!(opened.json["name"], "linear");
}

#[test]
fn key_never_takes_or_echoes_a_key() {
    let refused = parse(&args(&["key", "weather", "sk-live-secret"])).expect("a key command");
    let message = refused.expect_err("a key argument is refused");
    assert!(!message.contains("sk-live-secret"), "{message}");
    let refused =
        parse(&args(&["key", "weather", "--value", "sk-live-secret"])).expect("a key command");
    assert!(!refused.expect_err("refused").contains("sk-live-secret"));
}

#[test]
fn an_unknown_name_opens_nothing() {
    let mut sent = Vec::new();
    let error = execute(
        &Command::Open { name: "nope".into(), handoff: Handoff::Auth },
        &mut app(&mut sent),
    )
    .expect_err("unknown");
    assert_eq!(error["code"], "not_found");
    assert_eq!(sent.len(), 1, "only the list was read");
    let error =
        execute(&Command::Tools("nope".into()), &mut app(&mut Vec::new())).expect_err("unknown");
    assert_eq!(error["code"], "not_found");
}

#[test]
fn reads_print_the_rows_and_tools_and_rm_removes_by_name() {
    let mut sent = Vec::new();
    let list = execute(&Command::List, &mut app(&mut sent)).expect("list");
    assert_eq!(list.json, listed());
    assert!(list.human.contains("linear\tconnected\tchief\tlinear.app"), "{}", list.human);
    assert!(list.human.contains("https://weather.example/mcp"), "{}", list.human);

    let tools =
        execute(&Command::Tools("linear".into()), &mut app(&mut Vec::new())).expect("tools");
    assert_eq!(tools.json["tools"][1], json!({"name": "list_issues", "policy": "always"}));
    assert!(tools.human.contains("create_issue\task\theld"), "{}", tools.human);
    assert!(tools.human.contains("list_issues\talways\n"), "{}", tools.human);
    assert_eq!(tools.json["held"], json!(["create_issue"]));
    assert!(list.human.contains("2 tools, 1 held"), "{}", list.human);

    let audit = execute(&Command::Audit { limit: None }, &mut app(&mut Vec::new())).expect("audit");
    assert_eq!(audit.json["lines"][0]["event"], "remove");

    let mut sent = Vec::new();
    let removed = execute(&Command::Remove("weather".into()), &mut app(&mut sent)).expect("rm");
    assert_eq!(sent, [("mcp.servers.remove".to_owned(), json!({"connection": "weather"}))]);
    assert_eq!(removed.json["name"], "weather");
}

#[test]
fn no_command_sends_a_trust_changing_method() {
    let commands = [
        Command::List,
        Command::Tools("linear".into()),
        Command::Audit { limit: Some(3) },
        Command::Remove("linear".into()),
        Command::Open { name: "linear".into(), handoff: Handoff::Auth },
        Command::Open { name: "weather".into(), handoff: Handoff::Key },
        Command::Open { name: "linear".into(), handoff: Handoff::Policy },
        Command::Open { name: "linear".into(), handoff: Handoff::ApproveTools },
    ];
    let mut sent = Vec::new();
    for command in &commands {
        let _ = execute(command, &mut app(&mut sent));
    }
    for (method, _) in &sent {
        assert!(
            ["mcp.servers.list", "mcp.servers.audit", "mcp.servers.remove", "mcp.servers.open"]
                .contains(&method.as_str()),
            "{method}"
        );
    }
}
