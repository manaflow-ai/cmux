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
fn passthrough_keeps_arguments_the_global_parser_would_take() {
    let raw = args(&["--app-socket", "/tmp/a.sock", "cr", "--json", "accounts"]);
    assert_eq!(raw_tail(&raw), args(&["--json", "accounts"]));
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
