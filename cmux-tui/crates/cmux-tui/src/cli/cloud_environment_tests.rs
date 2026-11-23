use super::*;

fn words(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

#[test]
fn parses_only_complete_environment_commands() {
    assert_eq!(parse(&words(&["get"])).unwrap(), Command::Get);
    assert_eq!(parse(&words(&["get", "--persisted"])).unwrap(), Command::GetPersisted);
    assert_eq!(
        parse(&words(&["set", "staging"])).unwrap(),
        Command::Set(Environment::parse("staging").unwrap())
    );
    assert_eq!(
        parse(&words(
            &["check-create", "--backend", "staging", "--params", r#"{"size":"large"}"#,]
        ))
        .unwrap(),
        Command::CheckCreate {
            backend: "staging".into(),
            params: serde_json::json!({"size": "large"}),
        }
    );
    for args in [
        &["set"][..],
        &["get", "prod"],
        &["set", "https://example.com"],
        &["set", "preview-../../prod"],
    ] {
        assert!(parse(&words(args)).is_err(), "{args:?}");
    }
    assert!(parse(&words(&["check-create", "--backend", "staging", "--params", "[]",])).is_err());
}

#[test]
fn launch_args_accept_one_backend_and_reject_duplicates_or_missing_values() {
    assert_eq!(
        launch_backend(&["--foo".into(), "--cloud-backend=staging".into()]).unwrap(),
        Some("staging".into())
    );
    assert_eq!(
        launch_backend(&["--cloud-backend".into(), "preview-7".into()]).unwrap(),
        Some("preview-7".into())
    );
    assert_eq!(
        launch_backend(&[
            "/Applications/cmux.app/Contents/MacOS/cmux".into(),
            "--unrelated".into()
        ])
        .unwrap(),
        None
    );
    assert_eq!(
        parse(&words(&["get", "--launch-args", r#"["cmux", "--unrelated"]"#])).unwrap(),
        Command::Get
    );
    for args in [
        vec!["--cloud-backend".into()],
        vec!["--cloud-backend".into(), "--other".into()],
        vec!["--cloud-backend=staging".into(), "--cloud-backend=prod".into()],
        vec!["--cloud-backend".into(), "staging".into(), "--cloud-backend=prod".into()],
        vec!["--cloud-backend=untrusted".into()],
    ] {
        assert!(launch_backend(&args).is_err(), "{args:?}");
    }
}

/// The `cloud env` lines of `cmux cloud --help` parse here, each named environment of
/// `set`'s `a|b|c` alternatives included.
#[test]
fn the_help_env_lines_parse() {
    for japanese in [false, true] {
        let help = crate::cli::cloud_help::overview(japanese);
        let lines = help
            .lines()
            .filter_map(|line| line.trim().strip_prefix("cmux vm env "))
            .collect::<Vec<_>>();
        assert_eq!(lines.len(), 2, "{lines:?}");
        for line in lines {
            let line = line.trim_end_matches(" --json");
            let (verb, names) = line.split_once(' ').unwrap_or((line, ""));
            if names.is_empty() {
                assert_eq!(parse(&words(&[verb])).unwrap(), Command::Get, "{line}");
                continue;
            }
            for name in names.split('|') {
                let name = if name == "preview-N" { "preview-7" } else { name };
                assert!(
                    matches!(parse(&words(&[verb, name])), Ok(Command::Set(_))),
                    "{line}: {name}"
                );
            }
        }
    }
}

#[test]
fn live_apply_checks_bundle_before_sending_mutation() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    let home = tempfile::tempdir().unwrap();
    let socket = home.path().join("app.sock");
    let server = UnixListener::bind(&socket).unwrap();
    let receiver = std::thread::spawn(move || {
        let (stream, _) = server.accept().unwrap();
        let mut stream = BufReader::new(stream);
        let mut line = String::new();
        stream.read_line(&mut line).unwrap();
        assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["method"], "system.identify");
        stream
            .get_mut()
            .write_all(b"{\"id\":1,\"ok\":true,\"result\":{\"bundle_id\":\"com.cmuxterm.app\"}}\n")
            .unwrap();
        line.clear();
        assert_eq!(stream.read_line(&mut line).unwrap(), 0, "must not mutate another bundle");
    });
    let global = GlobalArgs {
        socket: None,
        session: None,
        machine: None,
        app_socket: Some(socket),
        idempotency_key: None,
        all_sessions: false,
        output: OutputMode::Human,
    };
    let selection = Resolver::new("com.cmuxterm.app.debug.env-test", home.path())
        .unwrap()
        .resolve(None)
        .unwrap();
    let error = apply(&global, &selection).unwrap_err();
    assert!(error.contains("another app bundle"), "{error}");
    receiver.join().unwrap();
}
