use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn json_after_the_separator_is_the_servers_own() {
    let (json, rest) = take_json_flag(&words("mcp add t --json --agent codex -- srv --json"));
    assert!(json);
    assert_eq!(rest, words("mcp add t --agent codex -- srv --json"));
    let (json, rest) = take_json_flag(&words("mcp add t -- srv --json"));
    assert!(!json);
    assert_eq!(rest, words("mcp add t -- srv --json"));
}

#[test]
fn parses_each_verb() {
    let p =
        parse(&words("mcp add fs --agent codex --scope project --env A=1 -- npx -y srv --flag"))
            .unwrap();
    assert_eq!(
        (p.verb.as_str(), p.name.as_deref(), p.agent, p.scope),
        ("add", Some("fs"), Some(Agent::Codex), Some(Scope::Project))
    );
    assert_eq!(p.env, vec![("A".to_owned(), "1".to_owned())]);
    assert_eq!(p.command, words("npx -y srv --flag"));
    let p = parse(&words("mcp add docs --agent=claude --url https://d.example/mcp --header X=y"))
        .unwrap();
    let server = new_server(&p, "docs").unwrap();
    assert_eq!(server.transport, Transport::Http { url: "https://d.example/mcp".into() });
    assert!(parse(&words("mcp list --agent gemini")).unwrap_err().contains("unknown agent"));
    assert!(parse(&words("mcp frob")).unwrap_err().contains("unknown verb"));
    // Every part agent_config.rs dispatches, settings among them (it was left out of the message).
    let unknown = parse(&words("frob list")).unwrap_err();
    for part in ["`skills`", "`hooks`", "`settings`", "`mcp`"] {
        assert!(unknown.contains(part), "{unknown} names {part}");
    }
    assert!(
        new_server(&parse(&words("mcp add x --agent codex")).unwrap(), "x")
            .unwrap_err()
            .contains("command")
    );
    assert!(
        new_server(&parse(&words("mcp add x --agent codex --url ftp://x")).unwrap(), "x")
            .unwrap_err()
            .contains("http")
    );
}

#[test]
fn edits_round_trip_through_the_cli() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(home.join(".codex")).unwrap();
    let env: BTreeMap<String, String> = [
        ("HOME".to_owned(), home.display().to_string()),
        ("CMUX_CODEX_CLI".to_owned(), "/nonexistent/codex".to_owned()),
    ]
    .into();
    let project = format!("--project {}", home.display());
    for line in [
        format!("mcp add fs --agent codex {project} -- /bin/fs serve"),
        format!("mcp disable fs --agent codex {project}"),
        format!("mcp enable fs --agent codex {project}"),
        format!("mcp add fs --agent claude {project} --env TOKEN=secret -- /bin/fs"),
        format!("mcp disable fs --agent claude {project}"),
    ] {
        assert_eq!(run(&words(&line), &env, true), Ok(0), "{line}");
    }
    let paths = Paths::from_env(&env).unwrap();
    let options = Options { project: Some(home), codex_cli: None };
    let claude = mcp::list(&paths, Agent::Claude, &options);
    assert_eq!(claude.servers.len(), 1);
    assert!(!claude.servers[0].enabled);
    let codex = mcp::list(&paths, Agent::Codex, &options);
    assert!(codex.servers[0].enabled);
    assert_eq!(run(&words(&format!("mcp remove fs --agent codex {project}")), &env, true), Ok(0));
    assert!(mcp::list(&paths, Agent::Codex, &options).servers.is_empty());
    assert!(
        run(&words(&format!("mcp remove fs --agent codex {project}")), &env, true)
            .unwrap_err()
            .contains("has no MCP server named fs")
    );
}
