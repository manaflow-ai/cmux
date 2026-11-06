//! The per-bundle NEXT Cloud backend. Resolution and persistence belong to Rust;
//! neither the app nor a shell keeps a second endpoint table.

use std::path::PathBuf;

use cmux_cloud_environment::{Environment, Resolver, check_create_capabilities};
use cmux_json::JsonSet as _;
use serde_json::Value;

use super::{GlobalArgs, OutputMode, UsageError};

mod relaunch;

const USAGE: &str = super::cloud_help::ENV_USAGE;

#[derive(Debug, PartialEq)]
enum Command {
    Help,
    Get,
    GetPersisted,
    GetBackend(String),
    CheckCreate { backend: String, params: Value },
    Set(Environment),
    Relaunch { pid: i32, bundle: PathBuf },
}

fn parse(words: &[String]) -> Result<Command, UsageError> {
    match words {
        [] => Ok(Command::Help),
        [word] if matches!(word.as_str(), "help" | "--help" | "-h") => Ok(Command::Help),
        [word] if word == "get" => Ok(Command::Get),
        [word, flag] if word == "get" && flag == "--persisted" => Ok(Command::GetPersisted),
        [word, flag, backend]
            if word == "get" && matches!(flag.as_str(), "--backend" | "--cloud-backend") =>
        {
            Environment::parse(backend).map_err(UsageError::new)?;
            Ok(Command::GetBackend(backend.clone()))
        }
        [word, flag, value] if word == "get" && flag == "--launch-args" => {
            let args: Vec<String> = serde_json::from_str(value)
                .map_err(|error| UsageError::new(format!("invalid --launch-args JSON: {error}")))?;
            let backend = launch_backend(&args).map_err(UsageError::new)?;
            Ok(backend.map(Command::GetBackend).unwrap_or(Command::Get))
        }
        [word, backend_flag, backend, params_flag, params]
            if word == "check-create"
                && backend_flag == "--backend"
                && params_flag == "--params" =>
        {
            Environment::parse(backend).map_err(UsageError::new)?;
            let params: Value = serde_json::from_str(params)
                .map_err(|error| UsageError::new(format!("invalid --params JSON: {error}")))?;
            if !params.is_object() {
                return Err(UsageError::new("--params must be a JSON object"));
            }
            Ok(Command::CheckCreate { backend: backend.clone(), params })
        }
        [word, name] if word == "set" => {
            Environment::parse(name).map(Command::Set).map_err(UsageError::new)
        }
        [word, pid_flag, pid, path_flag, path]
            if word == "relaunch" && pid_flag == "--pid" && path_flag == "--bundle-path" =>
        {
            let pid = pid
                .parse::<i32>()
                .ok()
                .filter(|pid| *pid > 1)
                .ok_or_else(|| UsageError::new("invalid app process identifier"))?;
            let bundle = PathBuf::from(path);
            if !bundle.is_absolute()
                || bundle.extension().is_none_or(|extension| extension != "app")
            {
                return Err(UsageError::new("expected an absolute app bundle path"));
            }
            Ok(Command::Relaunch { pid, bundle })
        }
        _ => Err(UsageError::new(USAGE)),
    }
}

fn launch_backend(args: &[String]) -> Result<Option<String>, String> {
    let mut found = None;
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if let Some(value) = arg.strip_prefix("--cloud-backend=") {
            if value.is_empty() || found.is_some() {
                return Err("duplicate or empty --cloud-backend".into());
            }
            found = Some(value.to_owned());
        } else if arg == "--cloud-backend" {
            let value = args.get(index + 1).ok_or("--cloud-backend requires a value")?;
            if value.is_empty() || value.starts_with('-') || found.is_some() {
                return Err("duplicate or empty --cloud-backend".into());
            }
            found = Some(value.clone());
            index += 1;
        }
        index += 1;
    }
    if let Some(value) = &found {
        Environment::parse(value)?;
    }
    Ok(found)
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, words) = super::parse_globals(args).ok()?;
    let [scope, noun, rest @ ..] = words.as_slice() else { return None };
    if scope != "cloud" || noun != "env" {
        return None;
    }
    // `get --cache-first`: the app's launch read (Resolver::client_config_cache_first).
    let (cache_first, rest) = match rest {
        [get, flag, tail @ ..] if get == "get" && flag == "--cache-first" => {
            (true, std::iter::once(get.clone()).chain(tail.iter().cloned()).collect::<Vec<_>>())
        }
        _ => (false, rest.to_vec()),
    };
    let command = match parse(&rest) {
        Ok(command) => command,
        Err(error) => {
            return Some(super::app::failure("usage.invalid", &error.0, global.output, 2));
        }
    };
    if command == Command::Help {
        print!(
            "{}",
            if crate::localization::catalog().is_japanese() {
                super::cloud_help::ENV_USAGE_JA
            } else {
                USAGE
            }
        );
        return Some(0);
    }
    if let Command::Relaunch { pid, bundle } = command {
        return Some(match relaunch::after_exit(pid, &bundle) {
            Ok(()) => 0,
            Err(message) => {
                super::app::failure("cloud_environment.relaunch_failed", &message, global.output, 1)
            }
        });
    }
    Some(match run(command, &global, cache_first) {
        Ok(value) => match global.output {
            OutputMode::Human => {
                if value.get("check_create").is_some() {
                    println!("ok");
                    0
                } else {
                    println!("{}", value.get("name").and_then(Value::as_str).unwrap_or("unknown"));
                    if value.get("restart_required") == Some(&Value::Bool(true)) {
                        eprintln!(
                            "{}",
                            if value.get("restart_scheduled") == Some(&Value::Bool(true)) {
                                "The app is restarting. Sign in to Cloud again."
                            } else {
                                "Restart this app and sign in to Cloud again to apply the selection."
                            }
                        );
                    }
                    0
                }
            }
            output => super::wire::print_local_success(&value, output),
        },
        Err(message) => super::app::failure("cloud_environment.failed", &message, global.output, 1),
    })
}

fn run(command: Command, global: &GlobalArgs, cache_first: bool) -> Result<Value, String> {
    let exe = std::env::current_exe().ok();
    let identity =
        crate::app_identity::AppIdentity::detect(|key| std::env::var(key).ok(), exe.as_deref())
            .ok_or("Run the cmux CLI bundled with the NEXT DEV or nightly app.")?;
    let build = identity.build();
    let bundle = build.bundle_id().ok_or("This app has no bundle identifier.")?;
    let home = std::env::var_os("HOME").map(PathBuf::from).ok_or("HOME is unavailable.")?;
    let resolver = Resolver::new(bundle, &home)?;
    let switching = matches!(command, Command::Set(_));
    let reads = matches!(command, Command::Get | Command::GetPersisted | Command::GetBackend(_));
    let check_create = match &command {
        Command::CheckCreate { backend, params } => Some((backend.clone(), params.clone())),
        _ => None,
    };
    // A failed read cannot prevent an explicit set from repairing malformed
    // state. set() independently enforces permissions and I/O failures.
    let previous = switching.then(|| resolver.resolve(None).ok()).flatten();
    let selection = match command {
        Command::Get => resolver.resolve(
            std::env::var("CMUX_NEXT_CLOUD_BACKEND")
                .ok()
                .or_else(|| std::env::var("CMUX_NEXT_CLOUD_ENV").ok())
                .as_deref(),
        )?,
        Command::GetPersisted => resolver.resolve(None)?,
        Command::GetBackend(backend) => resolver.resolve(Some(&backend))?,
        Command::CheckCreate { backend, .. } => resolver.resolve(Some(&backend))?,
        Command::Set(environment) => resolver.set(environment)?,
        Command::Help | Command::Relaunch { .. } => return Err("expected get or set".into()),
    };
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("create client-config runtime: {error}"))?;
    let selection = if cache_first && reads {
        runtime.block_on(resolver.client_config_cache_first(selection))?
    } else {
        runtime.block_on(resolver.client_config(selection))?
    };
    if let Some((_, params)) = check_create {
        check_create_capabilities(&selection, &params)?;
        return Ok(serde_json::json!({
            "check_create": true,
            "ok": true,
            "backend": selection.api_origin,
            "config_source": selection.config_source,
        }));
    }
    let scheduled = if switching { apply(global, &selection)? } else { false };
    let changed = switching
        && previous.is_none_or(|previous| previous.auth_namespace != selection.auth_namespace);
    let mut value = serde_json::to_value(selection).map_err(|error| error.to_string())?;
    value.set("restart_required", Value::Bool(scheduled || changed));
    value.set("sign_in_required", Value::Bool(scheduled || changed));
    value.set("restart_scheduled", Value::Bool(scheduled));
    Ok(value)
}

/// Persisted selection is useful while the app is stopped too. A running app
/// must identify itself before it may be asked to restart; an explicit socket
/// can never restart a different bundle.
fn apply(
    global: &GlobalArgs,
    selection: &cmux_cloud_environment::Selection,
) -> Result<bool, String> {
    use serde_json::json;
    use std::os::unix::net::UnixStream;
    let saved = |message: String| {
        format!(
            "Saved {} for {}; restart that app to apply it: {message}",
            selection.configuration.name, selection.bundle_id,
        )
    };
    let socket = super::app::socket_path(global).map_err(&saved)?;
    let mut stream = match UnixStream::connect(socket) {
        Ok(stream) => stream,
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
            ) =>
        {
            return Ok(false);
        }
        Err(error) => return Err(saved(error.to_string())),
    };
    stream
        .set_write_timeout(Some(super::app::READ_TIMEOUT))
        .map_err(|error| saved(error.to_string()))?;
    let identified =
        super::app::exchange(&mut stream, "system.identify", json!({}), super::app::READ_TIMEOUT)
            .map_err(&saved)?
            .map_err(|error| saved(error.to_string()))?;
    if identified.get("bundle_id").and_then(Value::as_str) != Some(selection.bundle_id.as_str()) {
        return Err(saved("the selected socket belongs to another app bundle".into()));
    }
    if !identified.get("methods").and_then(Value::as_array).is_some_and(|methods| {
        methods.iter().any(|method| method.as_str() == Some("cloud.environment.apply"))
    }) {
        return Ok(false);
    }
    let response = super::app::exchange(
        &mut stream,
        "cloud.environment.apply",
        json!({
            "bundle_id": selection.bundle_id,
            "name": selection.configuration.name,
            "auth_namespace": selection.auth_namespace,
            "origin": super::app::action_origin(),
        }),
        super::app::WAITING_RUN_TIMEOUT,
    )
    .map_err(&saved)?
    .map_err(|error| saved(error.to_string()))?;
    response
        .get("restart_scheduled")
        .and_then(Value::as_bool)
        .ok_or_else(|| saved("the app did not acknowledge the environment switch".into()))
}

#[cfg(test)]
mod tests {
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
            parse(&words(&[
                "check-create",
                "--backend",
                "staging",
                "--params",
                r#"{"size":"large"}"#,
            ]))
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
        assert!(
            parse(&words(&["check-create", "--backend", "staging", "--params", "[]",])).is_err()
        );
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
                .filter_map(|line| line.trim().strip_prefix("cmux cloud env "))
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
                .write_all(
                    b"{\"id\":1,\"ok\":true,\"result\":{\"bundle_id\":\"com.cmuxterm.app\"}}\n",
                )
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
}
