use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_each_verb() {
    assert_eq!(
        parse(&words("settings get --agent codex --cwd /p")).unwrap(),
        Request {
            verb: Verb::Get,
            agent: Agent::Codex,
            key: None,
            value: None,
            value_stdin: false,
            scope: None,
            cwd: Some("/p".into()),
            rule: None,
            remove: false,
        }
    );
    let set = parse(&words("settings set --agent claude --key model --value -odd --scope=local"))
        .unwrap();
    assert_eq!(set.value.as_deref(), Some("-odd"));
    assert_eq!(set.scope.as_deref(), Some("local"));
    assert!(parse(&words("settings unset --agent claude --key model")).is_ok());
    assert!(parse(&words("settings set --agent claude --key model")).is_err());
    assert!(parse(&words("settings get --agent gemini")).is_err());
    assert!(parse(&words("settings get")).is_err());
    assert!(parse(&words("mcp list --agent claude")).is_err());
    assert!(parse(&words("settings get --agent claude --bogus")).is_err());
}

#[test]
fn parses_permission_rules() {
    let allow = parse(&words("settings allow --rule Bash(npm:*) --scope project")).unwrap();
    assert_eq!(allow.verb, Verb::Rule("allow"));
    assert_eq!(allow.agent, Agent::Claude);
    assert_eq!(allow.rule.as_deref(), Some("Bash(npm:*)"));
    assert!(!allow.remove);
    let deny = parse(&words("settings deny --agent claude --rule=WebFetch --remove")).unwrap();
    assert_eq!((deny.verb, deny.remove), (Verb::Rule("deny"), true));
    assert!(parse(&words("settings ask")).is_err());
    assert!(parse(&words("settings allow --agent codex --rule Bash")).is_err());
    assert!(parse(&words("settings allow --rule Bash --key model")).is_err());
    assert!(parse(&words("settings set --agent claude --key model --value x --remove")).is_err());
}

#[test]
fn parses_env_verbs() {
    let set =
        parse(&words("settings env set --agent codex --name RUST_LOG --value debug --scope user"))
            .unwrap();
    assert_eq!(set.verb, Verb::EnvSet);
    assert_eq!(set.key.as_deref(), Some("RUST_LOG"));
    assert_eq!(set.value.as_deref(), Some("debug"));
    let stdin =
        parse(&words("settings env set --agent claude --name TOKEN --value-stdin")).unwrap();
    assert!(stdin.value_stdin && stdin.value.is_none());
    let unset = parse(&words("settings env unset --agent claude --name X")).unwrap();
    assert_eq!(unset.verb, Verb::EnvUnset);
    assert!(parse(&words("settings env set --agent claude --name X")).is_err());
    assert!(
        parse(&words("settings env set --agent claude --name X --value 1 --value-stdin")).is_err()
    );
    assert!(parse(&words("settings env unset --agent claude --name X --value 1")).is_err());
    assert!(parse(&words("settings env set --agent claude --key X --value 1")).is_err());
    assert!(parse(&words("settings set --agent claude --name X --value 1")).is_err());
    assert!(parse(&words("settings env get --agent claude")).is_err());
}
