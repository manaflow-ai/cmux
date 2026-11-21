use std::fs;

use super::*;

struct Home {
    _dir: tempfile::TempDir,
    paths: Paths,
    project: PathBuf,
}

fn home() -> Home {
    let dir = tempfile::tempdir().unwrap();
    let root = fs::canonicalize(dir.path()).unwrap();
    let home = root.join("home");
    let project = home.join("repo");
    fs::create_dir_all(project.join(".git")).unwrap();
    fs::create_dir_all(home.join(".codex")).unwrap();
    let env: BTreeMap<String, String> = [("HOME".to_owned(), home.display().to_string())].into();
    Home { _dir: dir, paths: Paths::from_env(&env).unwrap(), project }
}

fn names(listing: &Listing) -> Vec<(String, &'static str, bool)> {
    listing.servers.iter().map(|s| (s.name.clone(), s.scope.id(), s.enabled)).collect()
}

fn target(agent: Agent, name: &str, scope: Option<Scope>, project: Option<&Path>) -> Target {
    Target { agent, name: name.into(), scope, project: project.map(Path::to_path_buf) }
}

fn stdio(name: &str, command: &str) -> NewServer {
    NewServer {
        name: name.into(),
        transport: Transport::Stdio {
            command: command.into(),
            args: vec!["--token".into(), "sekrit".into(), "serve".into()],
        },
        env: vec![("API_KEY".into(), "sk-live-123".into())],
        headers: vec![],
    }
}

const CLAUDE_JSON: &str = r#"{
  "numStartups": 55,
  "mcpServers": {
    "agent-memory": {
      "type": "stdio",
      "command": "/bin/memory",
      "args": [
        "mcp"
      ],
      "env": {
        "MEMORY_TOKEN": "secret-value"
      }
    },
    "docs": {
      "type": "http",
      "url": "https://user:pw@docs.example/mcp?api_key=abc&x=1",
      "headers": {
        "Authorization": "Bearer xyz"
      }
    }
  },
  "projects": {
    "PROJECT": {
      "allowedTools": [],
      "mcpServers": {
        "local-one": {
          "type": "stdio",
          "command": "/bin/local"
        }
      },
      "disabledMcpServers": [
        "docs"
      ],
      "disabledMcpjsonServers": [
        "off-json"
      ],
      "enabledMcpjsonServers": [
        "shared"
      ]
    }
  },
  "zLast": true
}"#;

fn claude_fixture(h: &Home) {
    fs::write(
        &h.paths.claude_json,
        CLAUDE_JSON.replace("PROJECT", &h.project.display().to_string()),
    )
    .unwrap();
    fs::write(
        h.project.join(".mcp.json"),
        r#"{"mcpServers":{"shared":{"command":"npx","args":["srv"]},"off-json":{"command":"x"},"agent-memory":{"command":"/bin/other"}}}"#,
    )
    .unwrap();
}

#[test]
fn claude_lists_every_scope_with_switches_and_no_secrets() {
    let h = home();
    claude_fixture(&h);
    let listing = list(
        &h.paths,
        Agent::Claude,
        &Options { project: Some(h.project.clone()), codex_cli: None },
    );
    assert!(listing.problems.is_empty(), "{:?}", listing.problems);
    assert_eq!(
        names(&listing),
        vec![
            ("agent-memory".into(), "user", true),
            ("docs".into(), "user", false),
            ("local-one".into(), "local", true),
            ("shared".into(), "project", true),
            ("off-json".into(), "project", false),
            ("agent-memory".into(), "project", true),
        ]
    );
    let by = |name: &str, scope: Scope| {
        listing.servers.iter().find(|s| s.name == name && s.scope == scope).unwrap()
    };
    assert_eq!(by("shared", Scope::Project).approval, Some("approved"));
    assert_eq!(by("off-json", Scope::Project).approval, Some("pending"));
    // Project wins over user for the same name.
    assert!(by("agent-memory", Scope::User).shadowed);
    assert!(!by("agent-memory", Scope::Project).shadowed);
    assert_eq!(by("docs", Scope::User).transport, "http");
    assert_eq!(by("docs", Scope::User).headers, vec!["Authorization"]);
    assert_eq!(by("agent-memory", Scope::User).env, vec!["MEMORY_TOKEN"]);
    let shown = serde_json::to_string(&listing).unwrap();
    for secret in ["secret-value", "Bearer xyz", ":pw@", "abc"] {
        assert!(!shown.contains(secret), "{secret} leaked: {shown}");
    }
    assert!(shown.contains("https://user:*****@docs.example/mcp?api_key=*****&x=1"));
    // Without a folder: the user servers only, all on.
    let bare = list(&h.paths, Agent::Claude, &Options::default());
    assert_eq!(
        names(&bare),
        vec![("agent-memory".into(), "user", true), ("docs".into(), "user", true)]
    );
}

#[test]
fn claude_edits_round_trip_and_keep_the_rest() {
    let h = home();
    claude_fixture(&h);
    let before = fs::read_to_string(&h.paths.claude_json).unwrap();
    let opts = Options { project: Some(h.project.clone()), codex_cli: None };
    let p = Some(h.project.as_path());

    // Add (user), then everything else in the file is as it was, in order.
    let out = apply(
        &h.paths,
        &target(Agent::Claude, "added", None, p),
        &Edit::Add(stdio("added", "/bin/added")),
        &opts,
    )
    .unwrap();
    assert_eq!(out.scope, Scope::User);
    assert!(out.changed && out.backup.is_some());
    assert_eq!(fs::read_to_string(fsio::backup_path(&h.paths.claude_json)).unwrap(), before);
    let after = fs::read_to_string(&h.paths.claude_json).unwrap();
    let added = list(&h.paths, Agent::Claude, &opts);
    let row = added.servers.iter().find(|s| s.name == "added").unwrap();
    assert_eq!(row.args, vec!["--token", MASK, "serve"]);
    assert_eq!(row.env, vec!["API_KEY"]);
    let keys: Vec<String> =
        Json::parse(&after).unwrap().as_object().unwrap().iter().map(|(k, _)| k.clone()).collect();
    assert_eq!(keys, ["numStartups", "mcpServers", "projects", "zLast"]);
    assert!(after.contains("\"sk-live-123\""), "the value is written to the agent's file");

    // Disable, enable, remove: back to the original bytes.
    apply(&h.paths, &target(Agent::Claude, "added", None, p), &Edit::Disable, &opts).unwrap();
    assert!(
        !list(&h.paths, Agent::Claude, &opts)
            .servers
            .iter()
            .find(|s| s.name == "added")
            .unwrap()
            .enabled
    );
    apply(&h.paths, &target(Agent::Claude, "added", None, p), &Edit::Enable, &opts).unwrap();
    assert!(
        list(&h.paths, Agent::Claude, &opts)
            .servers
            .iter()
            .find(|s| s.name == "added")
            .unwrap()
            .enabled
    );
    apply(&h.paths, &target(Agent::Claude, "added", None, p), &Edit::Remove, &opts).unwrap();
    let back = fs::read_to_string(&h.paths.claude_json).unwrap();
    // The toggles leave an empty-again list behind only where one was made.
    assert_eq!(back, before);

    // Re-enabling a disabled user server for the folder drops it from the folder's list.
    apply(&h.paths, &target(Agent::Claude, "docs", Some(Scope::User), p), &Edit::Enable, &opts)
        .unwrap();
    assert!(
        list(&h.paths, Agent::Claude, &opts)
            .servers
            .iter()
            .find(|s| s.name == "docs")
            .unwrap()
            .enabled
    );

    // Local and project scopes.
    apply(
        &h.paths,
        &target(Agent::Claude, "mine", Some(Scope::Local), p),
        &Edit::Add(stdio("mine", "/bin/mine")),
        &opts,
    )
    .unwrap();
    apply(
        &h.paths,
        &target(Agent::Claude, "team", Some(Scope::Project), p),
        &Edit::Add(NewServer {
            name: "team".into(),
            transport: Transport::Http { url: "https://t.example/mcp".into() },
            env: vec![],
            headers: vec![("X-Key".into(), "v".into())],
        }),
        &opts,
    )
    .unwrap();
    let listing = list(&h.paths, Agent::Claude, &opts);
    assert!(listing.servers.iter().any(|s| s.name == "mine" && s.scope == Scope::Local));
    let team = listing.servers.iter().find(|s| s.name == "team").unwrap();
    assert_eq!(
        (team.scope, team.transport.as_str(), team.approval),
        (Scope::Project, "http", Some("pending"))
    );
    apply(&h.paths, &target(Agent::Claude, "team", None, p), &Edit::Enable, &opts).unwrap();
    assert_eq!(
        list(&h.paths, Agent::Claude, &opts)
            .servers
            .iter()
            .find(|s| s.name == "team")
            .unwrap()
            .approval,
        Some("approved")
    );
    apply(&h.paths, &target(Agent::Claude, "off-json", None, p), &Edit::Enable, &opts).unwrap();
    assert!(
        list(&h.paths, Agent::Claude, &opts)
            .servers
            .iter()
            .find(|s| s.name == "off-json")
            .unwrap()
            .enabled
    );
    apply(&h.paths, &target(Agent::Claude, "team", None, p), &Edit::Remove, &opts).unwrap();
    apply(&h.paths, &target(Agent::Claude, "mine", None, p), &Edit::Remove, &opts).unwrap();
    let listing = list(&h.paths, Agent::Claude, &opts);
    assert!(!listing.servers.iter().any(|s| s.name == "team" || s.name == "mine"));
}

#[test]
fn claude_refuses_what_it_cannot_do() {
    let h = home();
    claude_fixture(&h);
    let opts = Options::default();
    let err =
        apply(&h.paths, &target(Agent::Claude, "agent-memory", None, None), &Edit::Disable, &opts)
            .unwrap_err();
    assert!(err.contains("--project"), "{err}");
    let err = apply(
        &h.paths,
        &target(Agent::Claude, "nope", Some(Scope::User), None),
        &Edit::Remove,
        &opts,
    )
    .unwrap_err();
    assert!(err.contains("no user server named nope"), "{err}");
    let err = apply(&h.paths, &target(Agent::Claude, "bad name", None, None), &Edit::Remove, &opts)
        .unwrap_err();
    assert!(err.contains("not a server name"), "{err}");
    // An add never replaces the person's own server of that name.
    let before = fs::read_to_string(&h.paths.claude_json).unwrap();
    let err = apply(
        &h.paths,
        &target(Agent::Claude, "agent-memory", Some(Scope::User), None),
        &Edit::Add(stdio("agent-memory", "/bin/other")),
        &opts,
    )
    .unwrap_err();
    assert!(err.contains("already has a user server named agent-memory"), "{err}");
    assert_eq!(fs::read_to_string(&h.paths.claude_json).unwrap(), before);
    // A switch for a server Claude Code does not have writes nothing.
    let err = apply(
        &h.paths,
        &target(Agent::Claude, "nope", Some(Scope::User), Some(&h.project)),
        &Edit::Disable,
        &opts,
    )
    .unwrap_err();
    assert!(err.contains("no user server named nope"), "{err}");
    assert_eq!(fs::read_to_string(&h.paths.claude_json).unwrap(), before);
    fs::write(&h.paths.claude_json, "{ not json").unwrap();
    let err = apply(
        &h.paths,
        &target(Agent::Claude, "x", None, None),
        &Edit::Add(stdio("x", "/bin/x")),
        &opts,
    )
    .unwrap_err();
    assert!(err.contains("not JSON"), "{err}");
    assert_eq!(fs::read_to_string(&h.paths.claude_json).unwrap(), "{ not json");
    assert_eq!(list(&h.paths, Agent::Claude, &opts).problems.len(), 1);
}

const CODEX_TOML: &str = r#"# my codex config
model = "gpt-5"

[mcp_servers.repo]
command = "/bin/repo"  # the repo tools
args = ["mcp"]
startup_timeout_sec = 30

[mcp_servers.repo.env]
REPO_TOKEN = "t0ken"

[mcp_servers.docs]
url = "https://docs.example/mcp"
bearer_token_env_var = "DOCS_TOKEN"
enabled = false

[profiles.fast]
model = "gpt-5-mini"
"#;

#[test]
fn codex_lists_and_round_trips_with_comments() {
    let h = home();
    let config = h.paths.codex_config();
    fs::write(&config, CODEX_TOML).unwrap();
    fs::create_dir_all(h.project.join(".codex")).unwrap();
    fs::write(
        h.project.join(".codex/config.toml"),
        "[mcp_servers.repo]\ncommand = \"/bin/project-repo\"\n",
    )
    .unwrap();
    let opts = Options { project: Some(h.project.clone()), codex_cli: None };
    let listing = list(&h.paths, Agent::Codex, &opts);
    assert_eq!(
        names(&listing),
        vec![
            ("repo".into(), "project", true),
            ("repo".into(), "user", true),
            ("docs".into(), "user", false)
        ]
    );
    let err = apply(
        &h.paths,
        &target(Agent::Codex, "repo", Some(Scope::User), None),
        &Edit::Add(stdio("repo", "/bin/other")),
        &opts,
    )
    .unwrap_err();
    assert!(err.contains("already has a user server named repo"), "{err}");
    assert_eq!(fs::read_to_string(&config).unwrap(), CODEX_TOML);
    let docs = listing.servers.iter().find(|s| s.name == "docs").unwrap();
    assert_eq!(docs.transport, "http");
    assert_eq!(docs.headers, vec!["Authorization ($DOCS_TOKEN)"]);
    assert!(
        listing
            .servers
            .iter()
            .find(|s| s.name == "repo" && s.scope == Scope::User)
            .unwrap()
            .shadowed
    );
    assert!(!serde_json::to_string(&listing).unwrap().contains("t0ken"));

    let user = Options::default();
    apply(&h.paths, &target(Agent::Codex, "docs", None, None), &Edit::Enable, &user).unwrap();
    assert!(!fs::read_to_string(&config).unwrap().contains("enabled = false"));
    apply(&h.paths, &target(Agent::Codex, "docs", None, None), &Edit::Disable, &user).unwrap();
    assert!(
        !list(&h.paths, Agent::Codex, &user)
            .servers
            .iter()
            .find(|s| s.name == "docs")
            .unwrap()
            .enabled
    );
    apply(
        &h.paths,
        &target(Agent::Codex, "added", None, None),
        &Edit::Add(stdio("added", "/bin/added")),
        &user,
    )
    .unwrap();
    let text = fs::read_to_string(&config).unwrap();
    assert!(text.starts_with("# my codex config\n"), "{text}");
    assert!(text.contains("command = \"/bin/repo\"  # the repo tools"), "{text}");
    assert!(text.contains("[mcp_servers.added]"), "{text}");
    let added = list(&h.paths, Agent::Codex, &user);
    let row = added.servers.iter().find(|s| s.name == "added").unwrap();
    assert_eq!(
        (row.command.as_deref(), row.env.clone()),
        (Some("/bin/added"), vec!["API_KEY".to_owned()])
    );
    apply(&h.paths, &target(Agent::Codex, "added", None, None), &Edit::Remove, &user).unwrap();
    // Re-adding `enabled = false` on docs puts it at the table's end: the rest is byte for byte.
    let text = fs::read_to_string(&config).unwrap();
    assert_eq!(text, CODEX_TOML);

    // A project server.
    apply(
        &h.paths,
        &target(Agent::Codex, "repo", Some(Scope::Project), Some(&h.project)),
        &Edit::Disable,
        &user,
    )
    .unwrap();
    assert!(
        fs::read_to_string(h.project.join(".codex/config.toml"))
            .unwrap()
            .contains("enabled = false")
    );
    let err =
        apply(&h.paths, &target(Agent::Codex, "x", Some(Scope::Local), None), &Edit::Remove, &user)
            .unwrap_err();
    assert!(err.contains("no local scope"), "{err}");
}

#[test]
fn codex_new_file_and_plugin_switch() {
    let h = home();
    let user = Options::default();
    apply(
        &h.paths,
        &target(Agent::Codex, "web", None, None),
        &Edit::Add(NewServer {
            name: "web".into(),
            transport: Transport::Http { url: "https://w.example/mcp".into() },
            env: vec![],
            headers: vec![],
        }),
        &user,
    )
    .unwrap();
    assert_eq!(
        fs::read_to_string(h.paths.codex_config()).unwrap(),
        "[mcp_servers.web]\nurl = \"https://w.example/mcp\"\n"
    );
    // A plugin's server is switched in the plugin's own table.
    let plugin = h.paths.codex_plugin_cache().join("market").join("tools").join("1.0");
    fs::create_dir_all(&plugin).unwrap();
    fs::write(plugin.join(".mcp.json"), r#"{"mcpServers":{"tool_srv":{"command":"./run"}}}"#)
        .unwrap();
    let out = apply(
        &h.paths,
        &target(Agent::Codex, "tool_srv", Some(Scope::Plugin), None),
        &Edit::Disable,
        &user,
    )
    .unwrap();
    assert!(out.changed);
    let text = fs::read_to_string(h.paths.codex_config()).unwrap();
    assert!(
        text.contains("[plugins.\"tools@market\".mcp_servers.tool_srv]\nenabled = false"),
        "{text}"
    );
    let err = apply(
        &h.paths,
        &target(Agent::Codex, "tool_srv", Some(Scope::Plugin), None),
        &Edit::Remove,
        &user,
    )
    .unwrap_err();
    assert!(err.contains("turned off, not removed"), "{err}");
}

#[cfg(unix)]
#[test]
fn codex_plugin_rows_come_from_the_cli() {
    use std::os::unix::fs::PermissionsExt as _;
    let h = home();
    fs::write(h.paths.codex_config(), "[mcp_servers.repo]\ncommand = \"/bin/repo\"\n").unwrap();
    let plugin = h.paths.codex_plugin_cache().join("market").join("tools").join("1.0");
    fs::create_dir_all(&plugin).unwrap();
    fs::write(plugin.join(".mcp.json"), r#"{"mcpServers":{"tool_srv":{"command":"./run"}}}"#)
        .unwrap();
    let cli = h.paths.home.join("codex");
    fs::write(
        &cli,
        "#!/bin/sh\necho '[{\"name\":\"repo\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"/bin/repo\"}},{\"name\":\"tool_srv\",\"enabled\":false,\"transport\":{\"type\":\"stdio\",\"command\":\"./run\",\"args\":[],\"env\":{\"K\":\"v\"},\"env_vars\":[\"PATH\"]}}]'\n",
    )
    .unwrap();
    fs::set_permissions(&cli, fs::Permissions::from_mode(0o755)).unwrap();
    let listing = list(&h.paths, Agent::Codex, &Options { project: None, codex_cli: Some(cli) });
    assert!(listing.problems.is_empty(), "{:?}", listing.problems);
    assert_eq!(
        names(&listing),
        vec![("repo".into(), "user", true), ("tool_srv".into(), "plugin", false)]
    );
    let row = &listing.servers[1];
    assert_eq!(
        (row.plugin.as_deref(), row.removable, row.env.clone()),
        (Some("tools@market"), false, vec!["K".to_owned(), "PATH".to_owned()])
    );
}

#[test]
fn masks() {
    let args: Vec<String> =
        ["--api-key", "k", "--port", "3", "TOKEN=abc", "plain=1", "--auth-token=z"]
            .iter()
            .map(|s| s.to_string())
            .collect();
    assert_eq!(
        mask_args(&args),
        ["--api-key", MASK, "--port", "3", "TOKEN=*****", "plain=1", "--auth-token=*****"]
    );
    assert_eq!(mask_url("https://h.example/mcp"), "https://h.example/mcp");
    assert_eq!(mask_url("https://tok@h.example/"), "https://*****@h.example/");
    assert_eq!(mask_url("https://u:pw@h.example:8/a?b=1"), "https://u:*****@h.example:8/a?b=1");
    assert_eq!(mask_url("https://h.example/a@b"), "https://h.example/a@b");
    assert_eq!(mask_url("https://u@h.example?token=x"), "https://*****@h.example?token=*****");
    assert_eq!(
        mask_url("https://h.example/?key=1&token=2&q=3"),
        "https://h.example/?key=*****&token=*****&q=3"
    );
}
