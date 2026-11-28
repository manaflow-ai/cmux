use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn parsed(words: &[&str]) -> Result<Invocation, UsageError> {
    let all = args(words);
    let (word, rest) = split(&all).expect("a coderouter command");
    parse(word, rest, &all)
}

#[test]
fn cmux_owns_status_machines_and_claude_and_everything_else_passes_through() {
    assert_eq!(
        parsed(&["coderouter", "status"]).unwrap(),
        Invocation::Owned(Verb::Status { team: None })
    );
    assert_eq!(
        parsed(&["coderouter", "machines", "--team", "t1"]).unwrap(),
        Invocation::Owned(Verb::Machines { team: Some("t1".into()) })
    );
    assert_eq!(
        parsed(&["coderouter", "claude"]).unwrap(),
        Invocation::Owned(Verb::ClaudeList { team: None })
    );
    assert_eq!(parsed(&["coderouter", "--help"]).unwrap(), Invocation::Help);
    assert_eq!(
        parsed(&["coderouter", "login", "--json"]).unwrap(),
        Invocation::Passthrough(args(&["login", "--json"]))
    );
    assert_eq!(parsed(&["coderouter"]).unwrap(), Invocation::Passthrough(vec![]));
    // `cr` is always the CodeRouter CLI, even for cmux's own verbs.
    assert_eq!(
        parsed(&["cr", "status", "--help"]).unwrap(),
        Invocation::Passthrough(args(&["status", "--help"]))
    );
    assert!(split(&args(&["workspace", "list"])).is_none());
}

#[test]
fn passthrough_keeps_arguments_the_global_parser_would_take() {
    let raw = args(&["--app-socket", "/tmp/a.sock", "cr", "--json", "accounts"]);
    assert_eq!(raw_tail(&raw), args(&["--json", "accounts"]));
}

#[test]
fn claude_verbs_take_an_account_and_reject_extra_words() {
    assert_eq!(
        parsed(&["coderouter", "claude", "disable", "work", "--team", "t"]).unwrap(),
        Invocation::Owned(Verb::ClaudeState {
            team: Some("t".into()),
            account: "work".into(),
            enable: false
        })
    );
    assert_eq!(
        parsed(&["coderouter", "claude", "rm", "work"]).unwrap(),
        Invocation::Owned(Verb::ClaudeRemove { team: None, account: "work".into() })
    );
    assert!(parsed(&["coderouter", "claude", "remove"]).is_err());
    assert!(parsed(&["coderouter", "claude", "remove", "a", "b"]).is_err());
    assert!(parsed(&["coderouter", "claude", "clear", "x"]).is_err());
    assert!(parsed(&["coderouter", "claude", "frob"]).is_err());
}

#[test]
fn a_secret_is_never_accepted_on_the_command_line() {
    let error = parsed(&["coderouter", "claude", "add", "oauth-token", "sk-ant-oat01-abc"])
        .expect_err("a token in argv was accepted");
    assert_eq!(error.0, crate::localization::catalog().coderouter.secret_in_argv);
    assert!(parsed(&["coderouter", "claude", "add", "api-key", "--token", "x"]).is_err());
    assert!(parsed(&["coderouter", "claude", "add"]).is_err());
    assert!(parsed(&["coderouter", "claude", "add", "api-key", "--region", "us"]).is_err());
    assert_eq!(
        parsed(&["coderouter", "claude", "add", "bedrock", "--model", "c=b", "--label", "w"])
            .unwrap(),
        Invocation::Owned(Verb::ClaudeAdd {
            team: None,
            label: Some("w".into()),
            credential: Credential::Bedrock {
                region: None,
                models: vec![("c".into(), "b".into())]
            },
        })
    );
    assert!(parsed(&["coderouter", "claude", "add", "bedrock", "--model", "c="]).is_err());
}

fn with_sources<T>(
    env: &[(&str, &str)],
    stdin_is_terminal: bool,
    stdin: &str,
    typed: &str,
    body: impl FnOnce(&mut SecretSources<'_>) -> T,
) -> (T, bool, bool) {
    let env: Vec<(String, String)> =
        env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    let lookup = move |name: &str| env.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
    let mut stdin_read = false;
    let mut prompted = false;
    let stdin = stdin.to_owned();
    let typed = typed.to_owned();
    let mut read_stdin = || {
        stdin_read = true;
        Ok(stdin.clone())
    };
    let mut prompt_hidden = |_: &str| {
        prompted = true;
        Ok(typed.clone())
    };
    let result = body(&mut SecretSources {
        env: &lookup,
        stdin_is_terminal,
        read_stdin: &mut read_stdin,
        prompt_hidden: &mut prompt_hidden,
    });
    (result, stdin_read, prompted)
}

#[test]
fn secrets_come_from_the_variable_stdin_or_a_hidden_prompt() {
    let token = "sk-ant-oat01-aaaaaaaaaaaaaaaaaaaaaaaa";
    // A terminal with the variable set: the variable, nothing read.
    let (result, read, prompted) = with_sources(&[(OAUTH_ENV, token)], true, "", "", |s| {
        add_params(None, Some("work"), &Credential::OauthToken { stdin: false }, s)
    });
    let params = result.unwrap();
    assert_eq!(params["token"], token);
    assert_eq!(params["kind"], "anthropic_oauth");
    assert_eq!(params["label"], "work");
    assert!(!read && !prompted);
    // --stdin wins over the variable.
    let (result, read, _) =
        with_sources(&[(OAUTH_ENV, "ignored")], true, &format!("\n{token}\n"), "", |s| {
            add_params(Some("t"), None, &Credential::OauthToken { stdin: true }, s)
        });
    let params = result.unwrap();
    assert_eq!((params["token"].as_str(), params["teamId"].as_str()), (Some(token), Some("t")));
    assert!(read);
    // A terminal without the variable prompts with echo off.
    let (result, read, prompted) = with_sources(&[], true, "", "sk-ant-api-key-1", |s| {
        add_params(None, None, &Credential::ApiKey { stdin: false }, s)
    });
    assert_eq!(result.unwrap()["apiKey"], "sk-ant-api-key-1");
    assert!(!read && prompted);
    // Wrong kinds of secret are refused before anything is sent.
    let (result, _, _) = with_sources(&[(API_KEY_ENV, token)], true, "", "", |s| {
        add_params(None, None, &Credential::ApiKey { stdin: false }, s)
    });
    assert!(result.is_err());
    let (result, _, _) = with_sources(&[], false, "\n\n", "", |s| {
        add_params(None, None, &Credential::OauthToken { stdin: false }, s)
    });
    assert!(result.is_err());
}

#[test]
fn bedrock_reads_aws_credentials_from_the_environment() {
    let env = [
        ("AWS_ACCESS_KEY_ID", "AKIA1"),
        ("AWS_SECRET_ACCESS_KEY", "secret"),
        ("AWS_DEFAULT_REGION", "us-west-2"),
    ];
    let credential = Credential::Bedrock { region: None, models: vec![("c".into(), "b".into())] };
    let (result, read, prompted) =
        with_sources(&env, true, "", "", |s| add_params(None, None, &credential, s));
    let params = Value::Object(result.unwrap());
    assert_eq!(
        params,
        json!({
            "kind": "bedrock", "region": "us-west-2", "accessKeyId": "AKIA1",
            "secretAccessKey": "secret", "modelIds": {"c": "b"},
        })
    );
    assert!(!read && !prompted);
    let (result, _, _) =
        with_sources(&env[..2], true, "", "", |s| add_params(None, None, &credential, s));
    assert!(result.is_err());
}

#[test]
fn accounts_resolve_by_handle_then_id_identifier_and_a_unique_label() {
    let accounts = json!([
        {"id": "a1", "account": "acct_one", "kind": "anthropic_oauth", "label": "Work", "identifier": "sk-…1"},
        {"id": "a2", "account": "acct_two", "kind": "anthropic_api_key", "label": "home", "identifier": "sk-…2"},
        {"id": "a3", "account": "acct_three", "kind": "anthropic_api_key", "label": "home", "identifier": "sk-…3"},
        {"id": "acct_two", "account": "acct_four", "kind": "bedrock", "label": "x", "identifier": "b-…4"},
    ]);
    // The handle wins over an `id` with the same text.
    assert_eq!(account_id("acct_two", &accounts).unwrap(), "a2");
    assert_eq!(account_id("acct_three", &accounts).unwrap(), "a3");
    assert_eq!(account_id("a1", &accounts).unwrap(), "a1");
    assert_eq!(account_id("sk-…2", &accounts).unwrap(), "a2");
    assert_eq!(account_id("work", &accounts).unwrap(), "a1");
    // Handles are exact.
    assert!(account_id("ACCT_ONE", &accounts).is_err());
    let ambiguous = account_id("home", &accounts).unwrap_err();
    assert_eq!(
        ambiguous.candidates,
        vec![
            "acct_two  anthropic_api_key  home".to_owned(),
            "acct_three  anthropic_api_key  home".to_owned(),
        ]
    );
    assert!(account_id("nope", &accounts).unwrap_err().candidates.is_empty());
    assert!(is_uuid("3f2a1b4c-0000-4000-8000-0123456789ab"));
    assert!(!is_uuid("work"));
}

#[test]
fn an_email_is_never_a_selector() {
    let accounts = json!([{"id": "a1", "account": "acct_one", "label": "s@e.com"}]);
    for selector in ["s@e.com", "s\u{FF20}e.com", "s\u{FE6B}e.com", "s%40e.com", "s%2540e.com"] {
        let error = account_id(selector, &accounts).unwrap_err();
        assert!(error.message.contains("acct_"), "{selector}: {}", error.message);
    }
}

#[test]
fn account_text_shows_the_handle_and_never_the_server_account() {
    let accounts = json!([{
        "id": "a1", "account": "acct_one", "server_account": "srv-secret",
        "kind": "anthropic_oauth", "identifier": "sk-…1", "label": "work", "state": "active",
    }]);
    assert_eq!(
        account_lines(Some(&accounts)),
        json!("acct_one  anthropic_oauth  sk-…1  (work)  active")
    );
    assert!(!account_lines(Some(&accounts)).to_string().contains("srv-secret"));
    assert_eq!(
        account_lines(Some(&json!([]))),
        json!(crate::localization::catalog().coderouter.no_accounts)
    );
}

#[test]
fn error_text_redacts_emails_in_paths_and_selectors() {
    assert_eq!(
        redact_emails("timed out: GET /api/coderouter/claude-upstream/s@e.com?x=1"),
        "timed out: GET /api/coderouter/claude-upstream/<email>?x=1"
    );
    assert_eq!(redact_emails("no match for \"a%40b.c\""), "no match for \"<email>\"");
    assert_eq!(redact_emails("plain message"), "plain message");
}

#[test]
fn passthrough_removes_every_cmux_variable_and_keeps_the_rest() {
    let environment = [
        (OsString::from("CMUX_SOCKET_PATH"), OsString::from("/tmp/x")),
        (OsString::from("CMUX_TAG"), OsString::from("t")),
        (OsString::from("HOME"), OsString::from("/home/u")),
    ];
    let command = passthrough_command(
        Path::new("/A.app/Contents/Resources/bin/coderouter"),
        &args(&["login"]),
        environment,
    );
    let envs: Vec<_> = command.get_envs().collect();
    assert_eq!(
        envs,
        vec![
            (std::ffi::OsStr::new("CMUX_SOCKET_PATH"), None),
            (std::ffi::OsStr::new("CMUX_TAG"), None),
        ]
    );
    assert_eq!(command.get_args().collect::<Vec<_>>(), vec![std::ffi::OsStr::new("login")]);
}

#[test]
fn the_bundled_cli_is_found_next_to_the_bundled_cmux() {
    let directory = tempfile::tempdir().unwrap();
    let bin = directory.path().join("cmux DEV.app/Contents/Resources/bin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("cmux"), b"").unwrap();
    let found = bundled_coderouter(&bin.join("cmux")).unwrap();
    assert!(found.ends_with("cmux DEV.app/Contents/Resources/bin/coderouter"), "{found:?}");
    assert_eq!(bundled_coderouter(Path::new("/usr/local/bin/cmux")), None);
}

/// A fake app that answers each line with the next response.
fn fake_app(responses: Vec<Value>) -> (PathBuf, std::thread::JoinHandle<Vec<Value>>) {
    use std::os::unix::net::UnixListener;
    let directory = tempfile::tempdir().unwrap().keep();
    let socket = directory.join("app.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let handle = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut received = Vec::new();
        let mut responses = responses.into_iter();
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap() > 0 {
            received.push(serde_json::from_str::<Value>(&line).unwrap());
            line.clear();
            let Some(response) = responses.next() else { break };
            writeln!(writer, "{response}").unwrap();
        }
        let _ = std::fs::remove_dir_all(directory);
        received
    });
    (socket, handle)
}

#[test]
fn disable_resolves_a_label_then_updates_that_account_on_one_connection() {
    let list =
        json!({"id": 1, "ok": true, "result": {"accounts": [{"id": "acc-1", "label": "work"}]}});
    let updated = json!({"id": 1, "ok": true, "result": {"ok": true}});
    let (socket, app) = fake_app(vec![list, updated]);
    let global =
        GlobalArgs { app_socket: Some(socket), output: OutputMode::Quiet, ..GlobalArgs::default() };
    let verb = Verb::ClaudeState { team: Some("t".into()), account: "work".into(), enable: false };
    assert_eq!(run(&global, Invocation::Owned(verb)), 0);
    let received = app.join().unwrap();
    let methods: Vec<_> = received.iter().map(|r| r["method"].clone()).collect();
    assert_eq!(
        methods,
        vec![json!("coderouter.claude_upstream.get"), json!("coderouter.claude_upstream.update")]
    );
    assert_eq!(received[1]["params"]["accountId"], "acc-1");
    assert_eq!(received[1]["params"]["state"], "disabled");
    assert_eq!(received[1]["params"]["teamId"], "t");
}

#[test]
fn selector_and_app_errors_use_the_documented_exit_codes() {
    let quiet = |socket| GlobalArgs {
        app_socket: Some(socket),
        output: OutputMode::Quiet,
        ..GlobalArgs::default()
    };
    let list = json!({"id": 1, "ok": true, "result": {"accounts": [
        {"id": "a2", "account": "acct_two", "label": "home"},
        {"id": "a3", "account": "acct_three", "label": "home"},
    ]}});
    let (socket, app) = fake_app(vec![list]);
    let verb = Verb::ClaudeRemove { team: None, account: "home".into() };
    assert_eq!(run(&quiet(socket), Invocation::Owned(verb)), 2);
    assert_eq!(app.join().unwrap().len(), 1, "an ambiguous label removes nothing");

    let signed_out =
        json!({"id": 1, "ok": false, "error": {"code": "not_signed_in", "message": "sign in"}});
    let (socket, app) = fake_app(vec![signed_out]);
    assert_eq!(run(&quiet(socket), Invocation::Owned(Verb::ClaudeList { team: None })), 3);
    app.join().unwrap();

    let unsupported =
        json!({"id": 1, "ok": false, "error": {"code": "method_not_found", "message": "no"}});
    let (socket, app) = fake_app(vec![unsupported]);
    assert_eq!(run(&quiet(socket), Invocation::Owned(Verb::ClaudeList { team: None })), 5);
    app.join().unwrap();
}
